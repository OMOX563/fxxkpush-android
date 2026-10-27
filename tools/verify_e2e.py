#!/usr/bin/env python3
"""FxxkPush Android 端到端验证脚本。

在模拟器/真机上装好 app 并填好配置后运行，用来验证整条推送链路：

  1. app 进程是否活着
  2. 前台服务（PushService）是否在跑
  3. WebSocket 是否连上
  4. 从 VPS 发一条消息，app 收不收得到（查 logcat + sqlite）
  5. 消息有没有落进本地缓存
  6. 点通知的深链能不能跳详情

用法：
    python verify_e2e.py            # 全部检查
    python verify_e2e.py --send     # 额外发一条测试消息
    python verify_e2e.py --adb "ip:port"   # 指定设备

前提：
  - app 已安装（adb install -r xxx.apk）
  - app 里已填好服务器地址 / token / topic（或者用 --configure 自动填）
"""
import argparse
import base64
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.request

PKG = "cc.omox.fxxkpush"
ACTIVITY = f"{PKG}/.MainActivity"
ADB = r"C:\Users\omo\AppData\Local\Android\Sdk\platform-tools\adb.exe"

GREEN, RED, YELLOW, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[0m"

results = []


def sh(args, timeout=60, use_adb=True):
    """跑一条命令，返回 (rc, stdout+stderr)。"""
    cmd = ([ADB] + args) if use_adb else args
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout,
                           encoding="utf-8", errors="replace")
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except FileNotFoundError:
        return 127, "adb not found: %s" % ADB
    except subprocess.TimeoutExpired:
        return 124, "timeout after %ss" % timeout


def check(name, ok, detail=""):
    results.append((name, ok, detail))
    mark = f"{GREEN}PASS{RESET}" if ok else f"{RED}FAIL{RESET}"
    print(f"  [{mark}] {name}" + (f"  {detail}" if detail else ""))
    return ok


def server_config():
    """从本机 FxxkPush 安装版配置里读服务器地址与 token。"""
    p = os.path.expandvars(
        r"%LOCALAPPDATA%\Programs\FxxkPush\data\fp.config.json")
    with open(p, encoding="utf-8") as f:
        cfg = json.load(f)
    return cfg


def cfg_from_disk():
    return server_config()


def _tap(x, y):
    sh(["shell", "input", "tap", str(x), str(y)])


def _type_text(text):
    # adb input text 不支持空格与中文，用 %s 占位
    safe = text.replace(" ", "%s").replace(":", "\\:")
    sh(["shell", "input", "text", safe])


def configure_app(cfg):
    """用 UI 自动化把「服务器地址 / token / 话题」填进设置页。

    坐标从 uiautomator dump 里读 EditText 的 bounds，不写死。
    release 包不能 run-as 写 SharedPreferences，只能走 UI。
    """
    base = os.environ.get("FP_NTFY_URL", "http://185.170.211.110:2586")
    token = cfg["ntfy"]["token"]

    # 进设置页：右上角齿轮
    sh(["shell", "am", "start", "-n", PKG + "/.MainActivity"])
    time.sleep(2)
    _tap(1020, 200)          # AppBar 右侧设置图标
    time.sleep(2)

    # dump 找三个 EditText
    sh(["shell", "uiautomator", "dump", "/sdcard/ui.xml"])
    rc, out = sh(["shell", "cat", "/sdcard/ui.xml"], timeout=60)
    edits = re.findall(
        r'class="android.widget.EditText"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"',
        out)
    if len(edits) < 3:
        print("  [跳过] 只找到 %d 个输入框，配置页结构可能变了" % len(edits))
        return False

    values = [base, token, "fp-phone"]
    labels = ["服务器地址", "访问令牌", "订阅话题"]
    for (x1, y1, x2, y2), val, label in zip(edits, values, labels):
        cx, cy = (int(x1) + int(x2)) // 2, (int(y1) + int(y2)) // 2
        _tap(cx, cy)
        time.sleep(0.5)
        _type_text(val)
        time.sleep(0.5)
        print("  已填 %s" % label)

    # 收起键盘再点「保存并连接」（键盘会挡住按钮）
    sh(["shell", "input", "keyevent", "111"])   # ESC 收键盘
    time.sleep(1)
    rc, out = sh(["shell", "uiautomator", "dump", "/sdcard/ui.xml"])
    m = re.search(r'text="保存并连接"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', out)
    if m:
        x1, y1, x2, y2 = map(int, m.groups())
        _tap((x1 + x2) // 2, (y1 + y2) // 2)
        print("  已点「保存并连接」")
    else:
        print("  [跳过] 找不到「保存并连接」按钮")
    time.sleep(2)
    return True


# ---------------------------------------------------------------- 1) 进程
def check_process():
    rc, out = sh(["shell", "pidof", PKG])
    pids = [x for x in out.strip().split() if x.isdigit()]
    if not pids:
        # pidof 找不到时退回 ps
        rc2, out2 = sh(["shell", "ps", "-A"])
        pids = [ln.split()[1] for ln in out2.splitlines()
                if PKG in ln and "ps" not in ln.split()[0]]
    return check("app 进程存活", bool(pids),
                 "pid=%s" % (",".join(pids) if pids else "无"))


# ---------------------------------------------------------------- 2) 服务
def check_service():
    """前台服务 = 有一条常驻通知 + 进程带 PushService 的 cmdline。"""
    rc, out = sh(["shell", "dumpsys", "activity", "services", PKG])
    running = "PushService" in out
    detail = ""
    if running:
        m = re.search(r"PushService.*?isForeground=true", out, re.S)
        detail = "前台服务在跑" if m else "服务在跑（非前台？）"
    else:
        detail = "PushService 未运行"
    return check("前台服务 PushService", running, detail)


def check_foreground_notification():
    """常驻通知存在 = 服务真的被系统认定为前台。"""
    rc, out = sh(["shell", "dumpsys", "notification", "--noredact"])
    has = "fxxkpush" in out.lower() and "FxxkPush" in out
    return check("常驻通知存在（保活凭证）", has)


# ---------------------------------------------------------------- 3) 连接
def check_ws_connected():
    """从 app 的 logcat 里找 WebSocket 握手成功记录。"""
    rc, out = sh(["logcat", "-d", "-s", "FxxkPush:*"], timeout=30)
    connected = "ws connected" in out
    err = re.findall(r"ws failure: (.+)", out)
    return check("WebSocket 已连接", connected,
                 ("失败原因: %s" % err[-1][:60]) if err and not connected else "")


# ---------------------------------------------------------------- 4) 收消息
def send_test_message(cfg, topic="fp-phone", priority=4, title="E2E 测试"):
    """按 ntfy 正确格式发布：POST 根路径，topic 放 body。"""
    base = os.environ.get("FP_NTFY_URL", "http://185.170.211.110:2586")
    token = cfg["ntfy"]["token"]
    body = json.dumps({
        "topic": topic,
        "message": "E2E 验证 %s" % time.strftime("%H:%M:%S"),
        "title": title,
        "priority": priority,
        "tags": ["bell"],
    }).encode()
    req = urllib.request.Request(
        base + "/", data=body, method="POST",
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer " + token})
    with urllib.request.urlopen(req, timeout=15) as r:
        return r.status, json.loads(r.read().decode())


def check_receive(cfg, timeout=45):
    """发一条消息，等 app 落地（sqlite 里有记录 / logcat 有通知记录）。"""
    print("\n--- 发测试消息 ---")
    try:
        st, resp = send_test_message(cfg)
        print("  发布 HTTP %s  id=%s" % (st, resp.get("id")))
    except Exception as e:
        return check("收到推送消息", False, "发布失败: %s" % str(e)[:80])

    msg_id = resp.get("id", "")
    deadline = time.time() + timeout
    got_log = False
    while time.time() < deadline:
        time.sleep(3)
        rc, out = sh(["logcat", "-d", "-s", "FxxkPush:*"], timeout=30)
        if msg_id and msg_id in out:
            got_log = True
            break
        if "message stored+notified" in out:
            got_log = True
            break
    return check("收到推送消息（logcat 有落地记录）", got_log,
                 "等待 %ds" % timeout if not got_log else "")


def check_store(cfg):
    """消息是否进了 app 的 sqlite（run-as 读，因为 debug 包可调试）。"""
    # release 包没有 run-as 权限；debug 包才行
    rc, out = sh(["shell", "run-as", PKG, "ls", "databases"], timeout=30)
    if rc != 0 or 'fxxkpush.db' not in out:
        return check("消息落进本地 sqlite", False,
                     "读不到（release 包无 run-as 权限，跳过）")
    rc2, out2 = sh(["shell", "run-as", PKG, "sqlite3", "databases/fxxkpush.db",
                    "select count(*) from messages"], timeout=30)
    n = out2.strip().splitlines()[-1] if out2.strip() else '?'
    return check("消息落进本地 sqlite", n.isdigit() and int(n) > 0,
                 "共 %s 条" % n)


# ---------------------------------------------------------------- 5) 深链
def check_deeplink():
    """发深链，验证 Activity 被拉起。"""
    rc, out = sh(["shell", "am", "start", "-a", "android.intent.action.VIEW",
                  "-d", "fxxkpush://message/test", PKG], timeout=30)
    ok = "Error" not in out and "Exception" not in out
    time.sleep(2)
    rc2, out2 = sh(["shell", "dumpsys", "activity", "top"], timeout=30)
    foreground = PKG in out2
    return check("深链拉起 app", ok and foreground,
                 out.strip().splitlines()[0][:60] if out.strip() else "")


# ---------------------------------------------------------------- 6) 通知
def check_notification():
    rc, out = sh(["shell", "dumpsys", "notification", "--noredact"], timeout=45)
    has = "fxxkpush" in out.lower()
    return check("系统通知已发出", has)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--send", action="store_true", help="发一条测试消息")
    ap.add_argument("--adb", help="指定设备 serial")
    ap.add_argument("--install", metavar="APK", help="先装这个 APK")
    ap.add_argument("--configure", action="store_true",
                    help="用 UI 自动化把服务器配置填进去")
    args = ap.parse_args()

    if args.adb:
        os.environ["ANDROID_SERIAL"] = args.adb

    if args.install:
        print("\n--- 安装 APK ---")
        rc, out = sh(["install", "-r", args.install], timeout=300)
        print("  " + out.strip().splitlines()[-1] if out.strip() else "  (无输出)")
        if "Success" not in out:
            print("  安装失败，先解决这个")
            return 2

    print("=" * 62)
    print("  FxxkPush Android 端到端验证")
    print("=" * 62)

    rc, out = sh(["devices"], use_adb=False)
    print("\n设备:", out.strip()[:200])

    if args.configure:
        print("\n--- 配置服务器 ---")
        configure_app(cfg_from_disk())

    print("\n--- 基础检查 ---")
    check_process()
    check_service()
    check_foreground_notification()
    check_ws_connected()

    cfg = server_config()
    if args.send:
        print("\n--- 推送链路 ---")
        check_receive(cfg)
        check_store(cfg)
        check_notification()

    print("\n--- 深链 ---")
    check_deeplink()

    ok = sum(1 for _, o, _ in results if o)
    total = len(results)
    print("\n" + "=" * 62)
    color = GREEN if ok == total else YELLOW
    print(f"  {color}{ok}/{total} 项通过{RESET}")
    for name, o, detail in results:
        if not o:
            print(f"    {RED}✗{RESET} {name}  {detail}")
    print("=" * 62)
    return 0 if ok == total else 1


if __name__ == "__main__":
    sys.exit(main())

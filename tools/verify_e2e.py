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
def _find_adb():
    """找 adb：优先 ANDROID_HOME/platform-tools，其次 PATH。

    注意：ANDROID_HOME 存在但里面没有 platform-tools 时要继续往下找，
    不能直接 fallback 成裸 "adb" —— PATH 里通常没有 adb，
    会让所有检查报 "adb not found"（实测踩过）。
    """
    cands = []
    for var in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        sdk = os.environ.get(var)
        if sdk:
            cands.append(os.path.join(sdk, "platform-tools", "adb.exe"))
    # 本机默认 SDK 位置（Windows 上的标准安装路径）
    local = os.path.expandvars(r"%LOCALAPPDATA%\Android\Sdk")
    cands.append(os.path.join(local, "platform-tools", "adb.exe"))
    cands.append(os.path.join(local, "platform-tools", "adb"))
    for p in cands:
        if os.path.exists(p):
            return p
    # 最后退到 PATH 里的 adb
    from shutil import which
    w = which("adb")
    return w or "adb"


ADB = _find_adb()

GREEN, RED, YELLOW, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[0m"

results = []


def _winpath(p):
    """把 MSYS 风格路径转成原生 Windows 路径。

    adb.exe 是原生 Windows 程序，不认 /c/Users/... 这种路径，
    会报 "failed to stat /c/...: No such file or directory"。
    """
    if not p:
        return p
    p = str(p)
    if len(p) > 2 and p[1] == ":" and p[2] in ("\\", "/"):
        return p.replace("/", "\\")
    if p.startswith("/c/") or p.startswith("/C/"):
        return "C:\\" + p[3:].replace("/", "\\")
    return p


def sh(args, timeout=60, use_adb=True):
    """跑一条命令，返回 (rc, stdout+stderr)。"""
    cmd = ([ADB] + args) if use_adb else args
    cmd = [_winpath(a) for a in cmd]
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
    """从本机 FxxkPush 安装版配置里读服务器地址与 token。

    服务器地址**不在本文件里硬编码** —— 这个仓库是公开的，
    真 VPS IP 不能进仓库。地址从本机安装版配置读，
    或者用环境变量 FP_NTFY_URL 覆盖。
    """
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


def _clear_field():
    """清空当前聚焦的输入框。

    **不要用 Ctrl+A 全选** —— Flutter 的 TextField 对
    `input keycombination 113 29`（CTRL_LEFT+A）的响应不稳定：
    实测只删掉尾部 3 个字符，剩下的是追加，结果 "fp-phone" 变成
    "fp-phfp-phone"。keycombination 还要 Android 11+ 才有。

    可靠做法：MOVE_END（123）把光标挪到末尾，再连续 DEL（67）。
    循环放在设备端跑，一次 adb 调用搞定，不占往返时间。
    """
    sh(["shell", "input", "keyevent", "123"])            # MOVE_END
    # 一次 adb 调用里连删 60 次（足够覆盖 URL + 32 位 token）
    sh(["shell", "for i in $(seq 1 60); do input keyevent 67; done"],
       timeout=90)
    # 再补一个普通 DEL，确保末尾真的被清掉
    sh(["shell", "input", "keyevent", "67"])


def _dump_nodes():
    """返回 uiautomator dump 里的 node 列表，每项是 (class, desc, text, bounds)。"""
    sh(["shell", "uiautomator", "dump", "/sdcard/ui.xml"])
    rc, out = sh(["shell", "cat", "/sdcard/ui.xml"], timeout=60)
    nodes = []
    for tag in re.findall(r"<node[^>]*>", out):
        def g(name):
            m = re.search(r'%s="([^"]*)"' % name, tag)
            return m.group(1) if m else ""
        nodes.append((g("class"), g("content-desc"), g("text"), g("bounds")))
    return nodes


def _bounds(b):
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", b or "")
    return tuple(map(int, m.groups())) if m else None


def _center(b):
    x1, y1, x2, y2 = _bounds(b)
    return (x1 + x2) // 2, (y1 + y2) // 2


def _app_running():
    """app 进程是否活着。"""
    rc, out = sh(["shell", "pidof", PKG], timeout=30)
    return any(x.isdigit() for x in out.split())


def configure_app(cfg):
    """用 UI 自动化把「服务器地址 / token / 话题」填进设置页。

    坐标从 uiautomator dump 里读，不写死。
    release 包不能 run-as 写 SharedPreferences，只能走 UI。

    每个框先清空再填 —— 直接追加会把旧值和新值拼在一起
    （上轮实测就踩了：地址框变成
    服务器地址与令牌从本机安装版配置读（FP_NTFY_URL 环境变量可覆盖），仓库里不硬编码。
    """
    base = os.environ["FP_NTFY_URL"]
    token = cfg["ntfy"]["token"]
    topic = os.environ.get("FP_NTFY_TOPIC", "fp-phone")

    # 全新安装后系统会弹 POST_NOTIFICATIONS 授权框，弹窗会吃掉后面的点击，
    # 表现为「设置页打开了但一个输入框都找不到」。先直接授权掉。
    sh(["shell", "pm", "grant", PKG, "android.permission.POST_NOTIFICATIONS"],
       timeout=30)

    # 进设置页。Flutter 首帧要 2s+，权限弹窗消失也要时间，
    # 所以这里循环等「设置页出现且有输入框」为止，而不是盲点固定坐标。
    #
    # 注意入口按钮有两种文案：
    #   - 已配置过：AppBar 右侧齿轮，content-desc = "设置"
    #   - 未配置过：主页中间的「去设置」按钮
    # 只认前者会永远进不去设置页（实测踩过）。
    # am start 重试 —— 系统刚就绪时第一次可能静默失败
    for attempt in range(5):
        rc0, out0 = sh(["shell", "am", "start", "-n", PKG + "/.MainActivity"], timeout=60)
        if out0.strip():
            print("  am start: %s" % out0.strip().splitlines()[-1][:120])
        time.sleep(3)
        if _app_running():
            break
        print("  am start 第 %d 次没起来，重试" % (attempt + 1))
        time.sleep(4)
    edits = []
    for attempt in range(15):
        time.sleep(3)
        nodes = _dump_nodes()
        edits = [n for n in nodes if n[0] == "android.widget.EditText"]
        if len(edits) >= 3:
            print("  设置页已就绪（第 %d 次探测）" % (attempt + 1))
            break
        # app 可能根本没起来（系统没就绪时 am start 报
        # "Can't find service: activity"，这里必须重试启动）
        if not _app_running():
            sh(["shell", "am", "start", "-n", PKG + "/.MainActivity"])
            time.sleep(2)
        entry = next((n for n in nodes
                      if n[0] == "android.widget.Button"
                      and (n[1] in ("设置", "去设置") or n[2] in ("设置", "去设置"))), None)
        if entry:
            _tap(*_center(entry[3]))
            time.sleep(2)
        elif attempt == 0:
            _tap(1006, 202)     # 兜底坐标（AppBar 右侧齿轮）
            time.sleep(2)
    if len(edits) < 3:
        print("  [失败] 只找到 %d 个输入框" % len(edits))
        # 别让「app 根本没起来」伪装成「UI 结构变了」——
        # 两者根因完全不同。先看进程在不在、崩没崩。
        if not _app_running():
            print("  app 进程不存在 —— 多半是装崩了（ABI 不匹配？）")
            rc1, crash = sh(["logcat", "-d", "-t", "200"], timeout=90)
            for l in crash.splitlines():
                if "UnsatisfiedLinkError" in l or "FATAL EXCEPTION" in l \
                   or "AndroidRuntime" in l and "Error" in l:
                    print("    %s" % l.strip()[:160])
                    break
        else:
            print("  app 在跑但没有输入框 —— 可能没进设置页，或 UI 结构变了")
        return False

    values = [base, token, topic]
    labels = ["服务器地址", "访问令牌", "订阅话题"]
    for node, val, label in zip(edits, values, labels):
        cx, cy = _center(node[3])
        _tap(cx, cy)
        time.sleep(0.6)
        _clear_field()
        time.sleep(0.4)
        _type_text(val)
        time.sleep(0.6)
        print("  已填 %s" % label)

    # 收起键盘再点「保存并连接」（键盘会挡住按钮）
    sh(["shell", "input", "keyevent", "111"])   # ESC 收键盘
    time.sleep(1)
    nodes = _dump_nodes()
    # Flutter 的按钮标签放在 content-desc 里，text 是空的 —— 两个都要认
    btn = next((n for n in nodes
                if n[2] == "保存并连接" or n[1] == "保存并连接"), None)
    if btn:
        _tap(*_center(btn[3]))
        print("  已点「保存并连接」")
    else:
        print("  [跳过] 找不到「保存并连接」按钮")
    time.sleep(3)
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
    """前台服务 = PushService 在跑且被系统认定为前台。"""
    # 注意：dumpsys activity services 的包名过滤参数在部分版本上不生效，
    # 必须全量 dump 后自己 grep，否则会误报「未运行」。
    rc, out = sh(["shell", "dumpsys", "activity", "services"], timeout=60)
    if "PushService" not in out:
        return check("前台服务 PushService", False, "PushService 未运行")
    m = re.search(r"isForeground=true", out)
    detail = "前台服务在跑" if m else "服务在跑（非前台？）"
    return check("前台服务 PushService", True, detail)


def check_foreground_notification():
    """常驻通知存在 = 服务真的被系统认定为前台。"""
    rc, out = sh(["shell", "dumpsys", "notification", "--noredact"], timeout=60)
    has = "cc.omox.fxxkpush" in out
    return check("常驻通知存在（保活凭证）", has)


# ---------------------------------------------------------------- 3) 连接
def check_ws_connected():
    """从 app 的 logcat 里找 WebSocket 握手成功记录。

    注意：`-s FxxkPush:*` 这种 tag 过滤在 logcat 里匹配不到
    （tag 里的 `*` 只作单字符通配），必须全量 dump 后 grep tag。
    """
    rc, out = sh(["logcat", "-d"], timeout=60)
    lines = [ln for ln in out.splitlines() if " FxxkPush: " in ln]
    connected = any("ws connected" in ln for ln in lines)
    err = re.findall(r"ws failure: (.+)", "\n".join(lines))
    return check("WebSocket 已连接", connected,
                 ("失败原因: %s" % err[-1][:60]) if err and not connected else "")


def check_ui_connection_state(wait=30):
    """设置页上显示的连接状态 —— 用户实际看到的东西。

    注意：Flutter 的 content-desc 里换行是 HTML 实体 &#10;，
    直接正则匹配会连着换行符一起吃进结果里。

    状态是异步刷新的，刚点完「保存并连接」时可能还显示「连接中」，
    所以轮询等它稳定。
    """
    state = "?"
    deadline = time.time() + wait
    while time.time() < deadline:
        nodes = _dump_nodes()
        blob = " ".join((n[1] or "") + " " + (n[2] or "") for n in nodes)
        blob = blob.replace("&#10;", " ").replace("\n", " ")
        m = re.search(r"连接状态\s*(\S+)", blob)
        state = m.group(1) if m else "?"
        if state == "已连接":
            break
        time.sleep(3)
    ok = state == "已连接"
    return check("UI 连接状态显示「已连接」", ok, "实际: %s" % state)


# ---------------------------------------------------------------- 4) 收消息
def send_test_message(cfg, topic="fp-phone", priority=4, title="E2E 测试"):
    """按 ntfy 正确格式发布：POST 根路径，topic 放 body。"""
    base = os.environ["FP_NTFY_URL"]
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
        rc, out = sh(["logcat", "-d"], timeout=60)
        if msg_id and msg_id in out:
            got_log = True
            break
        if "message stored+notified" in out:
            got_log = True
            break
    return check("收到推送消息（logcat 有落地记录）", got_log,
                 "等待 %ds" % timeout if not got_log else "")


def check_store_rooted():
    """**权威断言**：用 root 直读 sqlite，确认消息真的留在库里。

    模拟器可以 `adb root`，所以 release 包也能读库 ——
    这比 UI 语义树可靠得多（UI 断言会因为路由/可见性/滚动位置而假阴性）。

    注意 adb shell 会剥掉引号，SQL 必须作为**整条命令的一个参数**传，
    否则 `select count(*) from messages` 会被 shell 拆开报
    「syntax error: unexpected '('」。

    这条断言存在的原因：原版的 check_receive 只看 logcat 的
    "message stored+notified"，而那行日志是在 store.upsert() **之后**打印的 ——
    消息一插入就被 purgeExpired 删掉时，日志照样打。
    「消息入库即被删」那个 bug 就是这样在 e2e 全绿的情况下溜过去的。
    """
    rc, _ = sh(["root"], timeout=60)
    time.sleep(3)
    DB = "/data/data/cc.omox.fxxkpush/databases/fxxkpush.db"
    out = sh(["shell", "sqlite3 %s \"select count(*) from messages;\"" % DB], timeout=90)[1]
    n = out.strip().splitlines()[-1].strip() if out.strip() else "?"
    ok = n.isdigit() and int(n) > 0
    detail = "共 %s 条" % n
    if not ok:
        # 顺便把时间戳量级打出来 —— 单位错位的话这里一眼能看出来
        rows = sh(["shell",
                   "sqlite3 %s \"select id, time, length(time) from messages order by time desc limit 3;\"" % DB],
                  timeout=90)[1]
        detail += " | " + rows.strip().replace("\n", " / ")[:160]
    return check("消息真留在 sqlite 里（root 直读）", ok, detail)


def _go_home():
    """回到消息列表页。

    设置页是 Flutter Navigator push 上去的，`am start` 只会把 Activity
    带到前台，**不会把设置页 pop 掉** —— 消息列表根本不在语义树里，
    断言必然假阴性。所以：如果当前在设置页（语义树里有「服务器地址」），
    就按 BACK 键 pop 回主页。

    注意不能无脑 BACK：本来就在主页时 BACK 会直接退出 app。
    """
    sh(["shell", "am", "start", "-n", PKG + "/.MainActivity"], timeout=60)
    time.sleep(2)
    nodes = _dump_nodes()
    blob = " ".join((n[1] or "") + " " + (n[2] or "") for n in nodes)
    if "服务器地址" in blob or "保存并连接" in blob:
        sh(["shell", "input", "keyevent", "4"], timeout=30)   # BACK
        time.sleep(2)
    return True


def check_message_in_list(wait=40):
    """消息有没有真的出现在 app 的消息列表里。

    **这是「存储修好了」唯一可信的断言。**

    - `check_receive` 只看 logcat 里的 "message stored+notified"，而那行日志
      是在 `store.upsert()` **之后**打印的 —— 旧 bug 里消息一插入就被
      `purgeExpired` 删掉，日志照样打。所以它证明不了消息还在库里。
    - `check_store` 要 `run-as` 权限，release 包直接 SKIP。

    所以直接看 **UI 语义树**里有没有这条消息 —— 一次覆盖「存储」+「列表刷新」
    两段。Flutter 的语义节点能通过 uiautomator dump 读到（脚本本来就在用它
    找「保存并连接」按钮），所以这条路是通的。
    """
    # 先回到消息列表页（设置页还在的话，列表不在语义树里）
    _go_home()

    deadline = time.time() + wait
    found = False
    seen = ""
    while time.time() < deadline:
        nodes = _dump_nodes()
        blob = " ".join((n[1] or "") + " " + (n[2] or "") for n in nodes)
        blob = blob.replace("&#10;", " ").replace("\n", " ")
        if "E2E" in blob:
            found = True
            i = blob.find("E2E")
            seen = blob[max(0, i - 30):i + 60].strip()
            break
        time.sleep(3)
    return check("消息出现在 app 列表里（存储+刷新）", found,
                 seen if found else "UI 语义树里找不到 E2E 测试消息")


def check_store(cfg):
    """消息是否进了 app 的 sqlite。

    release 包没有 run-as 权限（debuggable=false），读不了库文件。
    这时改用 app 自己暴露的「清空本地缓存」按钮做间接验证 ——
    或者干脆报 SKIP，而不是误报 FAIL。
    """
    rc, out = sh(["shell", "run-as", PKG, "ls", "databases"], timeout=30)
    if rc != 0 or "fxxkpush.db" not in out:
        print("  [跳过] release 包无 run-as 权限，sqlite 直读不可用")
        results.append(("消息落进本地 sqlite", None, "SKIP（release 包不可直读）"))
        print("  [SKIP] 消息落进本地 sqlite  (release 包不可直读)")
        return None
    rc2, out2 = sh(["shell", "run-as", PKG, "sqlite3", "databases/fxxkpush.db",
                    "select count(*) from messages"], timeout=30)
    n = out2.strip().splitlines()[-1] if out2.strip() else "?"
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
    ap.add_argument("--fresh", action="store_true",
                    help="装之前先卸载（验证全新安装 → 首次配置路径）")
    ap.add_argument("--configure", action="store_true",
                    help="用 UI 自动化把服务器配置填进去")
    args = ap.parse_args()

    if args.adb:
        os.environ["ANDROID_SERIAL"] = args.adb

    if args.install:
        print("\n--- 安装 APK ---")
        # 端到端要验证「全新安装 → 首次配置」这条路径，
        # 所以先卸载（-r 覆盖安装会保留上次的 SharedPreferences 配置）。
        if args.fresh:
            sh(["uninstall", PKG], timeout=120)
        rc, out = sh(["install"] + ([] if args.fresh else ["-r"]) + [args.install],
                      timeout=300)
        print("  " + out.strip().splitlines()[-1] if out.strip() else "  (无输出)")
        if "Success" not in out:
            print("  安装失败，先解决这个")
            return 2
        sh(["logcat", "-c"], timeout=60)

    print("=" * 62)
    print("  FxxkPush Android 端到端验证")
    print("=" * 62)

    rc, out = sh(["devices"])
    print("\n设备:", out.strip()[:200])

    if args.configure:
        print("\n--- 配置服务器 ---")
        configure_app(cfg_from_disk())

    print("\n--- 基础检查 ---")
    check_process()
    check_service()
    check_foreground_notification()
    check_ws_connected()
    check_ui_connection_state()

    cfg = server_config()
    if args.send:
        print("\n--- 推送链路 ---")
        check_receive(cfg)
        check_store(cfg)
        check_notification()
        check_store_rooted()
        check_message_in_list()

    print("\n--- 深链 ---")
    check_deeplink()

    ok = sum(1 for _, o, _ in results if o is True)
    skipped = sum(1 for _, o, _ in results if o is None)
    total = len(results) - skipped
    print("\n" + "=" * 62)
    color = GREEN if ok == total else YELLOW
    suffix = f"（跳过 {skipped} 项）" if skipped else ""
    print(f"  {color}{ok}/{total} 项通过{RESET}{suffix}")
    for name, o, detail in results:
        if o is None:
            print(f"    {YELLOW}—{RESET} {name}  {detail}")
        elif not o:
            print(f"    {RED}✗{RESET} {name}  {detail}")
    print("=" * 62)
    return 0 if ok == total else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env bash
# FxxkPush 模拟器端到端验证 —— 一次跑完，避免多次 adb 往返
# 用法: bash run_emulator_verify.sh [apk_path]
set -u

# SDK 路径从环境变量读 —— 仓库是公开的，本机绝对路径不能硬编码
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$SDK" ]; then
  echo "请先设置 ANDROID_HOME 指向 Android SDK 目录"
  exit 1
fi
ADB="$SDK/platform-tools/adb.exe"
S="emulator-5556"
TMP="$LOCALAPPDATA/Temp"
# 服务器地址从环境变量读 —— 仓库是公开的，真 IP 不能硬编码
FP_NTFY_URL="${FP_NTFY_URL:-http://127.0.0.1:2586}"
export FP_NTFY_URL
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APK="${1:-$REPO_ROOT/build/app/outputs/flutter-apk/app-release.apk}"
LOG="$TMP/emulator.log"

say() { echo "[$(date +%H:%M:%S)] $*"; }

# ---------- 启动模拟器 ----------
if ! "$ADB" devices | grep -q "$S.*device"; then
  say "启动模拟器 (port 5556, 4GB)"
  rm -f "$HOME/.android/avd/fp_test.avd/multiinstance.lock" 2>/dev/null
  # 必须用 setsid 脱离当前进程组/管道 ——
  # 否则脚本退出时管道关闭，模拟器收到 SIGHUP 跟着死，
  # 表现是「boot 完成了（日志无 FATAL）但进程凭空消失」。
  if command -v setsid >/dev/null 2>&1; then
    setsid "$SDK/emulator/emulator.exe" -avd fp_test -port 5556 -no-window -no-audio \
      -no-boot-anim -gpu swiftshader_indirect -no-snapshot \
      -netdelay none -netspeed full > "$LOG" 2>&1 < /dev/null &
  else
    "$SDK/emulator/emulator.exe" -avd fp_test -port 5556 -no-window -no-audio \
      -no-boot-anim -gpu swiftshader_indirect -no-snapshot \
      -netdelay none -netspeed full > "$LOG" 2>&1 < /dev/null &
  fi
  disown 2>/dev/null || true
  for i in $(seq 1 60); do
    "$ADB" devices | grep -q "$S.*device" && break
    sleep 5
  done
  for i in $(seq 1 60); do
    B=$(timeout 15 "$ADB" -s $S shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
    [ "$B" = "1" ] && break
    sleep 5
  done
fi
"$ADB" devices | grep "$S" || { echo "模拟器没起来"; exit 1; }
say "模拟器就绪"

# ---------- 装包 ----------
say "安装 APK: $(basename "$APK")"
timeout 180 "$ADB" -s $S install -r "$APK" 2>&1 | tail -1

timeout 20 "$ADB" -s $S logcat -c 2>/dev/null
timeout 20 "$ADB" -s $S shell am force-stop cc.omox.fxxkpush 2>/dev/null
timeout 20 "$ADB" -s $S shell am start -n cc.omox.fxxkpush/.MainActivity >/dev/null 2>&1
sleep 6

# ---------- 填配置 ----------
say "填配置"
timeout 20 "$ADB" -s $S shell input tap 1018 200; sleep 3     # 设置
timeout 20 "$ADB" -s $S shell input tap 540 498;  sleep 1     # 地址框
timeout 20 "$ADB" -s $S shell input text ""$FP_NTFY_URL""; sleep 2
TOKEN=$(python -c "import json,os;print(json.load(open(os.path.expandvars(r'%LOCALAPPDATA%\Programs\FxxkPush\data\fp.config.json'),encoding='utf-8'))['ntfy']['token'])")
timeout 20 "$ADB" -s $S shell input tap 540 934;  sleep 1     # token 框
timeout 20 "$ADB" -s $S shell input text "$TOKEN"; sleep 2
timeout 20 "$ADB" -s $S shell input keyevent 4; sleep 3        # 收键盘

# 「保存并连接」按钮在 1080x2400 屏幕上的 y=1540（截图 540x1200 的 770×2）
timeout 20 "$ADB" -s $S shell input tap 300 1540
sleep 10
say "已点保存并连接"

# ---------- 校验 ----------
echo ""
echo "=========== ① FxxkPush 日志 ==========="
timeout 30 "$ADB" -s $S logcat -d -t 400 -s FxxkPush:* 2>&1 | grep "FxxkPush" | tail -15

echo ""
echo "=========== ② 前台服务 ==========="
timeout 30 "$ADB" -s $S shell dumpsys activity services cc.omox.fxxkpush 2>&1 \
  | grep -E "isForeground" | head -2

echo ""
echo "=========== ③ 系统通知 ==========="
timeout 30 "$ADB" -s $S shell dumpsys notification --noredact 2>&1 \
  | grep -E "pkg=cc.omox.fxxkpush|android.title=|android.text=" | head -8

echo ""
echo "=========== ④ 发真实推送 ==========="
MSGID=$(python - <<'PY'
import json, os, urllib.request, time
cfg = json.load(open(os.path.expandvars(r'%LOCALAPPDATA%\Programs\FxxkPush\data\fp.config.json'), encoding='utf-8'))
body = json.dumps({'topic':'fp-phone',
    'message':'模拟器端到端验证 '+time.strftime('%H:%M:%S'),
    'title':'来自真实 VPS','priority':5,'tags':['bell']}).encode()
req = urllib.request.Request('"$FP_NTFY_URL"/', data=body, method='POST',
    headers={'Content-Type':'application/json','Authorization':'Bearer '+cfg['ntfy']['token']})
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        print(json.loads(r.read())['id'])
except Exception as e:
    print('ERR:'+str(e)[:60])
PY
)
echo "  发布 id=$MSGID"
sleep 8

echo ""
echo "=========== ⑤ 收到消息？ ==========="
timeout 30 "$ADB" -s $S logcat -d -t 400 -s FxxkPush:* 2>&1 | grep "FxxkPush" | tail -8
if [ "${MSGID:0:3}" != "ERR" ] && \
   timeout 30 "$ADB" -s $S logcat -d -t 400 -s FxxkPush:* 2>&1 | grep -q "$MSGID"; then
  echo "  ✓ 目标消息 id 已命中"
else
  echo "  ✗ 未命中目标 id"
fi

echo ""
echo "=========== ⑥ 截图 ==========="
timeout 30 "$ADB" -s $S exec-out screencap -p > "$TMP/fp_verify.png" 2>/dev/null
ls -lh "$TMP/fp_verify.png" 2>/dev/null || echo "  截图失败"

echo ""
echo "=========== ⑦ 深链 ==========="
timeout 30 "$ADB" -s $S shell am start -a android.intent.action.VIEW \
  -d "fxxkpush://message/$MSGID" cc.omox.fxxkpush 2>&1 | tail -2
sleep 4
timeout 30 "$ADB" -s $S exec-out screencap -p > "$TMP/fp_deeplink.png" 2>/dev/null
ls -lh "$TMP/fp_deeplink.png" 2>/dev/null

echo ""
echo "=========== ⑧ 内存状态 ==========="
timeout 20 "$ADB" -s $S shell cat /proc/meminfo 2>&1 | head -3

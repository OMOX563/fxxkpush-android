#!/usr/bin/env bash
# FxxkPush 模拟器端到端验证 —— 一次性跑完
#
# 关键约束（都是踩过的坑）：
#   * 绝不用 `adb kill-server` —— 它会连带杀掉模拟器
#   * 模拟器启动要等 ~90 秒，boot_completed 才是真正的就绪信号
#   * `adb logcat -d` 不带 -t 会卡死 adb server，必须带 `-t N`
#   * 每次 adb 调用都要 timeout 保护
set -u

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$SDK" ]; then
  echo "请先设置 ANDROID_HOME 指向 Android SDK 目录"
  exit 1
fi
ADB="$SDK/platform-tools/adb.exe"
S="${FP_EMULATOR_SERIAL:-emulator-5554}"
TMP="${TEMP:-$LOCALAPPDATA/Temp}"
FP_NTFY_URL="${FP_NTFY_URL:-http://127.0.0.1:2586}"
export FP_NTFY_URL
PKG="cc.omox.fxxkpush"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APK="${1:-$REPO_ROOT/build/app/outputs/flutter-apk/app-release.apk}"

say() { echo "[$(date +%H:%M:%S)] $*"; }
A() { timeout "${A_TIMEOUT:-60}" "$ADB" -s "$S" "$@" 2>&1; }

# ---------- 1) 等设备 ----------
say "等待设备 $S"
for i in $(seq 1 60); do
  A devices | grep -q "^$S.*device" && break
  sleep 5
done
A devices | grep -q "^$S" || { echo "设备没起来"; exit 1; }

# ---------- 2) 等 boot ----------
say "等待 boot_completed"
for i in $(seq 1 60); do
  [ "$(A shell getprop sys.boot_completed | tr -d '\r')" = "1" ] && break
  sleep 5
done
[ "$(A shell getprop sys.boot_completed | tr -d '\r')" = "1" ] || { echo "boot 未完成"; exit 1; }
say "boot 完成：Android $(A shell getprop ro.build.version.release | tr -d '\r') / $(A shell getprop ro.product.cpu.abi | tr -d '\r')"

# ---------- 3) 装包 ----------
say "安装 $(basename "$APK")"
A install -r "$APK" | tail -1
A logcat -c
A shell pm grant $PKG android.permission.POST_NOTIFICATIONS 2>/dev/null
A shell am force-stop $PKG
A shell am start -n $PKG/.MainActivity >/dev/null
sleep 6

# ---------- 4) 填配置 ----------
say "填配置"
A shell input tap 1018 200; sleep 3          # 设置
A shell input tap 540 498;  sleep 1          # 地址
A shell input text "$FP_NTFY_URL"; sleep 2
TOKEN=$(python -c "import json,os;print(json.load(open(os.path.expandvars(r'%LOCALAPPDATA%\Programs\FxxkPush\data\fp.config.json'),encoding='utf-8'))['ntfy']['token'])" 2>/dev/null)
A shell input tap 540 934;  sleep 1          # token
A shell input text "$TOKEN"; sleep 2
A shell input keyevent 4; sleep 3             # 收键盘
A shell input tap 300 1540; sleep 10          # 保存并连接

# ---------- 5) 校验 ----------
echo ""
echo "=========== ① FxxkPush 日志 ==========="
A_TIMEOUT=40 A logcat -d -t 300 -s FxxkPush:* | grep FxxkPush | tail -12

echo ""
echo "=========== ② 前台服务 ==========="
A_TIMEOUT=40 A shell dumpsys activity services $PKG | grep isForeground | head -2

echo ""
echo "=========== ③ 系统通知 ==========="
A_TIMEOUT=40 A shell dumpsys notification --noredact | grep -E "pkg=$PKG|android.title=|android.text=" | head -8

echo ""
echo "=========== ④ 发真实推送 ==========="
MSGID=$(python - <<'PY'
import json, os, urllib.request, time
cfg = json.load(open(os.path.expandvars(r'%LOCALAPPDATA%\Programs\FxxkPush\data\fp.config.json'), encoding='utf-8'))
base = os.environ.get('FP_NTFY_URL')
body = json.dumps({'topic':'fp-phone',
    'message':'模拟器端到端验证 '+time.strftime('%H:%M:%S'),
    'title':'来自真实 VPS','priority':5,'tags':['bell']}).encode()
req = urllib.request.Request(base+'/', data=body, method='POST',
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
LOG5=$(A_TIMEOUT=40 A logcat -d -t 300 -s FxxkPush:*)
echo "$LOG5" | grep FxxkPush | tail -8
if [ "${MSGID:0:3}" != "ERR" ] && echo "$LOG5" | grep -q "$MSGID"; then
  echo "  ✓ 目标消息 id 已命中"
else
  echo "  ✗ 未命中目标 id"
fi

echo ""
echo "=========== ⑥ 截图 ==========="
A_TIMEOUT=40 A exec-out screencap -p > "$TMP/fp_verify.png" 2>/dev/null
ls -lh "$TMP/fp_verify.png" 2>/dev/null || echo "  截图失败"

echo ""
echo "=========== ⑦ 深链 ==========="
A shell am start -a android.intent.action.VIEW -d "fxxkpush://message/$MSGID" $PKG | tail -2
sleep 4
A_TIMEOUT=40 A exec-out screencap -p > "$TMP/fp_deeplink.png" 2>/dev/null
ls -lh "$TMP/fp_deeplink.png" 2>/dev/null

echo ""
echo "=========== ⑧ 内存状态 ==========="
A shell cat /proc/meminfo | head -3 | tr -d '\r'

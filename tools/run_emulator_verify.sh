#!/usr/bin/env bash
# FxxkPush 模拟器端到端验证 —— 一次跑完，避免多次 adb 往返。
#
# 设计要点（都是实测踩出来的坑）：
#
#  1. 模拟器生命周期必须绑在脚本内。用 Start-Process / WMI 把它甩出去，
#     它会在 Hermes 调用间隙被回收（实测 4~8 分钟后干净退出、无崩溃记录），
#     表现为「上一步还连着，下一步 device 就不见了」。
#     脚本里用 & 起进程，脚本是 Hermes 跟踪的后台任务，模拟器全程活着。
#
#  2. 真正的模拟器进程是 qemu-system-x86_64-headless，emulator.exe 只是启动器。
#     只杀 emulator.exe 会留下真身占着 AVD，新实例秒退。
#
#  3. boot 判定用 adb 设备状态=device，不能用 getprop sys.boot_completed ——
#     后者重启后仍是 1，会误判成已 boot 而设备其实 offline。
#
#  4. 配置用 UI 自动化（verify_e2e.py），不写死坐标：
#     硬编码坐标在不同屏幕尺寸/未配置状态下全错，
#     而且「追加式输入」会把新旧值拼在一起（实测地址框变成
#     http://<旧值片段>http://… 这种鬼样子）。
#
# 用法:
#   FP_NTFY_URL=http://<host>:<port> bash run_emulator_verify.sh [apk_path]
set -u

ADB="${ADB:-}"
if [ -z "$ADB" ]; then
  for c in "$LOCALAPPDATA/Android/Sdk/platform-tools/adb.exe" \
           "${ANDROID_HOME:-}/platform-tools/adb.exe" \
           "${ANDROID_SDK_ROOT:-}/platform-tools/adb.exe"; do
    [ -n "$c" ] && [ -f "$c" ] && ADB="$c" && break
  done
fi
[ -z "$ADB" ] && { echo "找不到 adb，请设置 ANDROID_HOME 或 ADB 环境变量"; exit 1; }

EMU="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}/emulator/emulator.exe"
TMP="$LOCALAPPDATA/Temp"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APK="${1:-$REPO_ROOT/build/app/outputs/flutter-apk/app-release.apk}"
LOG="$TMP/emulator.log"



say() { echo "[$(date +%H:%M:%S)] $*"; }

# ---- ABI 守卫 ------------------------------------------------------------
# 装错 ABI 的包 → UnsatisfiedLinkError: libflutter.so is for EM_AARCH64
# instead of EM_X86_64（模拟器是 x86_64，手机是 arm64）。
# 交付给手机的包是 arm64-only，直接装到模拟器上必崩，
# 症状是「app 没起来 / 前台服务没跑」，但根因跟 app 逻辑无关 ——
# 别去查代码，先查 ABI。
APK_ABI="$(unzip -l "$APK" 2>/dev/null | awk '/lib\/.*\.so$/ {split($4,a,"/"); print a[2]}' | sort -u | tr '\n' ',')"
say "APK ABI: ${APK_ABI:-未知}"
case "$APK_ABI" in
  *x86_64*)  say "  → 含 x86_64，模拟器可跑" ;;
  *)         say "  → **不含 x86_64**，装到 x86_64 模拟器上会 UnsatisfiedLinkError 崩溃！"
             say "     重建成 fat 包： flutter build apk --release --target-platform android-arm64,android-x64"
             exit 2 ;;
esac


# 模拟器跑在宿主机的 10.0.2.2 后面（模拟器自己的 127.0.0.1 是模拟器内部）。
# 若 FP_NTFY_URL 指向 127.0.0.1，模拟器连的是它自己，必然连不上。
if [ -z "${FP_NTFY_URL:-}" ]; then
  echo "必须设置 FP_NTFY_URL —— 服务器地址不写进仓库（隐私红线）"
  echo "例如: FP_NTFY_URL=http://<host>:<port>"
  exit 1
fi
case "$FP_NTFY_URL" in
  *127.0.0.1*|*localhost*)
    say "注意：FP_NTFY_URL 指向 127.0.0.1，模拟器连不到宿主机的这个端口"
    say "      模拟器访问宿主请用 10.0.2.2，或直接填 VPS 的真实地址"
    ;;
esac
export FP_NTFY_URL

cleanup() {
  "$ADB" emu kill >/dev/null 2>&1
  sleep 2
  pwsh -NoProfile -Command '
Get-Process | Where-Object { $_.ProcessName -match "emulator|qemu-system" } |
  ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }' >/dev/null 2>&1
}
trap cleanup EXIT

# ---------- 清场：上一轮的残留必须杀干净 ----------
say "清场"
cleanup >/dev/null 2>&1
rm -f "$HOME/.android/avd/fp_test.avd/"*.lock 2>/dev/null
"$ADB" kill-server >/dev/null 2>&1
"$ADB" start-server >/dev/null 2>&1

# ---------- 启动模拟器（脚本子进程，全程存活） ----------
say "启动模拟器"
"$EMU" -avd fp_test -no-window -no-audio -no-boot-anim \
       -gpu swiftshader_indirect -no-snapshot -memory 2048 -cores 2   # cores 4 + memory 2048 会让 qemu 直接 segfault（实测） \
       > "$LOG" 2>&1 &
EMU_PID=$!
say "emu pid=$EMU_PID"

READY=0
for i in $(seq 1 90); do
  if "$ADB" devices 2>/dev/null | grep -qE "emulator-[0-9]+\s+device"; then
    say "设备就绪 (poll $i)"; READY=1; break
  fi
  if ! kill -0 "$EMU_PID" 2>/dev/null; then
    echo "模拟器进程已死，日志尾部："; tail -20 "$LOG"; exit 1
  fi
  sleep 4
done
[ "$READY" = "1" ] || { echo "模拟器启动超时"; "$ADB" devices; exit 1; }
for i in $(seq 1 30); do
  B=$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')
  [ "$B" = "1" ] && break
  sleep 4
done
say "boot_completed=$B"

# sys.boot_completed=1 不等于系统能接命令 —— system_server 可能还没起来，
# 这时 am start 会报 "Can't find service: activity"，app 静默起不来。
# 真正的就绪标志是 activity 服务在册。
SYSREADY=0
for i in $(seq 1 40); do
  S=$("$ADB" shell "service check activity" 2>/dev/null | tr -d '\r\n')
  case "$S" in
    *"found"*) SYSREADY=1; say "系统服务就绪 (poll $i)"; break;;
  esac
  sleep 5
done
[ "$SYSREADY" = "1" ] || { echo "系统服务未就绪，$S"; exit 1; }

# 再静置一会儿。system_server 在册 ≠ 能正常起 app：
# 实测 boot_completed=1 后立刻 am start，app 会静默起不来
# （症状是「装好了但进程不在」，看着像 ABI 不匹配，其实是系统没稳）。
say "静置 25s 让系统彻底就绪"
sleep 25

# ---------- 端到端验证（装包 + 填配置 + 发消息 + 校验） ----------
say "跑端到端验证"
cd "$REPO_ROOT"
python tools/verify_e2e.py --install "$APK" --fresh --configure --send
RC=$?

# ---------- 截图留证 ----------
"$ADB" exec-out screencap -p > "$TMP/fp_verify.png" 2>/dev/null
[ -s "$TMP/fp_verify.png" ] && say "截图: $TMP/fp_verify.png"
say "验证脚本退出码=$RC"
exit $RC

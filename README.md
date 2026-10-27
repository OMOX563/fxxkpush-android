# FxxkPush Android

FxxkPush 的 Android 客户端 —— **Flutter 重写版**。

接收 [ntfy](https://ntfy.sh) 推送，手机端零配置起步。

---

## 特性

| | |
|---|---|
| **轻量** | 单服务器 / 单账号 / 单话题，不做多端管理；APK ~20MB（只打 arm64） |
| **可靠** | 原生 `ForegroundService` + 常驻通知持有 WebSocket，纯 Dart 方案在息屏后会被系统冻结 |
| **液态玻璃 UI** | 明暗双主题，设计令牌逐值对齐 ntfy fork 的实测值（ink 13.7:1 / muted 5.8:1） |
| **离线可读** | 消息落本地 sqlite，冷启动也能看到历史（最多 500 条） |
| **root 友好** | 已 root 的设备会自动尝试把自己加进 Doze 白名单 |

## 架构

```
┌─ Flutter / Dart ──────────────────────┐
│  ui/         列表 · 详情 · 设置        │
│  core/       令牌 · 配置 · 状态 · 桥接  │
├──────────────────────────────────────┤
│  MethodChannel  ⇄  Kotlin             │
├──────────────────────────────────────┤
│  PushService (ForegroundService)      │
│    ├ OkHttp WebSocket → ntfy /topic/ws│
│    ├ MessageStore (sqlite)            │
│    └ Notifier → 系统通知              │
└──────────────────────────────────────┘
```

**为什么订阅放原生**：Android 8 之后 Dart isolate 在后台随时会被系统冻结，
纯 Dart 的 WebSocket 撑不过几分钟。原生前台服务是 Android 唯一官方认可的
长连接保活方式。

**为什么消息落地也放原生**：消息是**后台**收到的（Dart isolate 可能根本没跑），
落地必须在原生，否则冷启动打开 app 会看到空列表 —— 而用户明明收到过通知。

## 使用

1. 装 APK
2. 首次启动进「设置」，填：
   - **服务器地址** —— 如 `http://<你的服务器>:2586`
   - **访问令牌** —— ntfy 的 access token（`tk_…`）
   - **订阅话题** —— 默认 `fp-phone`
3. 保存后自动开始订阅

> **不预置任何服务器地址** —— APK 公开分发，预置真地址等于把地址送上门。
> 地址由使用者首次启动时手填。

### 保活

- 应用会跑一个前台服务（通知栏常驻一条「已连接 · fp-phone」）
- 若被系统杀：设置 → 应用 → FxxkPush → 电池 → **无限制**
- 已 root：app 会自动 `dumpsys deviceidle whitelist +cc.omox.fxxkpush`

## 图标

自有设计，**不含 ntfy 官方视觉元素**（旧版 fork 用的是 ntfy 原图）。

深蓝紫渐变底 + 两条信号带指向白色接收环，下带中段留断口以避免
「圆环 + 手柄」的放大镜联想。母版在 `assets/brand/`，可复现。

Android adaptive icon 分三层：

```
<adaptive-icon>
  <background android:drawable="@mipmap/ic_launcher_background"/>
  <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
  <monochrome android:drawable="@drawable/ic_notification"/>
</adaptive-icon>
```

## 开发

```bash
flutter pub get
flutter run                      # 连真机
flutter build apk --release     # 出包
```

需要 JDK 17 + Android SDK（compileSdk 36 / minSdk 26）。

### 签名

`android/key.properties` 不进 git（见 `.gitignore`）。CI 从 GitHub Secrets
里的 PEM 现场生成 keystore：

```
KEY_PEM_B64 / CERT_PEM_B64 / KEYSTORE_PASS / KEY_PASS
```

本地出签名包：把 `android/key.properties` 填好即可，缺失时自动退回 debug key。

### ABI

只打 `arm64-v8a`。Flutter 引擎每个 ABI 一份，实测 debug 构建：

```
arm64-v8a 51.7MB + x86_64 38.3MB + armeabi-v7a 31.7MB = 121.7MB
```

砍掉后三份变一份，release 从 54MB 降到 20MB 上下。
需要其他架构的话改 `android/app/build.gradle.kts` 的 `abiFilters`。

## 隐私

- 配置（含服务器地址与 token）只存本机 SharedPreferences
- 不收集任何遥测，无第三方 SDK（除 `shared_preferences`）
- APK 内不含任何真实服务器地址或凭据

## License

见仓库。

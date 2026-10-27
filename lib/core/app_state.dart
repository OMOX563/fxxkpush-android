import 'dart:async';

import 'package:flutter/foundation.dart';

import 'config.dart';
import 'models.dart';
import 'native_bridge.dart';

/// 全局状态：配置 + 消息列表 + 连接状态。
///
/// 用 ChangeNotifier 而不是 Riverpod/Bloc —— 这 app 只有「配置」和「消息列表」
/// 两个状态源，引第三方状态库不值当（APK 体积 + 学习成本）。
class AppState extends ChangeNotifier {
  AppState({ConfigStore? store})
      : _store = store ?? ConfigStore(),
        _config = AppConfig();

  final ConfigStore _store;

  AppConfig _config;
  List<NtfyMessage> _messages = const [];
  String _connState = 'disconnected';
  String? _pendingDeepLink;
  StreamSubscription<Map<String, dynamic>>? _eventSub;
  Timer? _pollTimer;

  AppConfig get config => _config;
  List<NtfyMessage> get messages => _messages;
  String get connState => _connState;
  bool get isConfigured => _config.isConfigured;
  bool get isConnected => _connState == 'connected';

  /// 启动：读配置 → 拉消息 → 订阅原生事件 → 起轮询
  Future<void> init() async {
    _config = await _store.load();
    notifyListeners();

    await refreshMessages();

    _eventSub = NativeBridge.events.listen(_onNativeEvent);

    // 轮询兜底：原生收到消息后 Dart 不一定醒着（EventChannel 只在 App 前台时通），
    // 所以每隔几秒拉一次原生缓存，保证列表不漏。
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      refreshMessages(silent: true);
      _pollConnState();
    });

    if (_config.isConfigured) {
      await startService();
    }
  }

  void _onNativeEvent(Map<String, dynamic> e) {
    final type = e['type'];
    if (type == 'deeplink') {
      final v = e['value'] as String? ?? '';
      // 形如 "message/<id>"
      if (v.startsWith('message/')) {
        _pendingDeepLink = v.substring('message/'.length);
      }
      notifyListeners();
    }
  }

  /// 深链待处理的消息 id（UI 取走后清空）
  String? takePendingDeepLink() {
    final v = _pendingDeepLink;
    _pendingDeepLink = null;
    return v;
  }

  Future<void> _pollConnState() async {
    final s = await NativeBridge.connectionState();
    if (s != _connState) {
      _connState = s;
      notifyListeners();
    }
  }

  /// 拉取原生缓存的消息
  Future<void> refreshMessages({bool silent = false}) async {
    final list = await NativeBridge.fetchMessages();
    if (list.isEmpty && _messages.isEmpty) {
      if (!silent) {
        notifyListeners();
      }
      return;
    }
    _messages = list;
    notifyListeners();
  }

  /// 保存配置（并按需重启订阅）
  Future<void> saveConfig(AppConfig c) async {
    _config = c;
    await _store.save(c);
    notifyListeners();
    if (c.isConfigured) {
      await startService();
    }
  }

  /// 启动/重启前台服务（订阅）
  Future<bool> startService() async {
    if (!_config.isConfigured) return false;
    final ok = await NativeBridge.startService(
      baseUrl: _config.baseUrl,
      token: _config.token,
      topic: _config.topic,
    );
    _connState = 'connecting';
    notifyListeners();
    return ok;
  }

  Future<void> stopService() async {
    await NativeBridge.stopService();
    _connState = 'disconnected';
    notifyListeners();
  }

  Future<void> clearMessages() async {
    await NativeBridge.clearMessages();
    _messages = const [];
    notifyListeners();
  }

  /// 反馈（👍/👎）到 feedback topic
  Future<bool> sendFeedback(String text) async {
    final ok = await NativeBridge.publish(
      baseUrl: _config.baseUrl,
      token: _config.token,
      topic: 'fp-feedback',
      message: text,
    );
    return ok;
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _pollTimer?.cancel();
    super.dispose();
  }
}

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 应用配置：服务器地址、访问令牌、订阅话题。
///
/// **绝不硬编码真实服务器地址** —— 这是本项目的隐私红线：
/// APK 要能公开分发，预置了真 VPS IP 就等于把地址送上门。
/// 首次启动由用户手填。
class AppConfig {
  AppConfig({
    this.baseUrl = '',
    this.token = '',
    this.topic = 'fp-phone',
    this.user = '',
    this.password = '',
  });

  final String baseUrl;
  final String token;
  final String topic;
  final String user;
  final String password;

  bool get isConfigured => baseUrl.trim().isNotEmpty;

  /// WebSocket 订阅地址。ntfy 的 `/<topic>/ws` 走同端口升级。
  String get wsUrl {
    final b = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (b.isEmpty) return '';
    final scheme = b.startsWith('https') ? 'wss' : 'ws';
    final hostPort = b.replaceFirst(RegExp(r'^https?://'), '');
    return '$scheme://$hostPort/$topic/ws';
  }

  Map<String, String> get authHeaders {
    if (token.isNotEmpty) return {'Authorization': 'Bearer $token'};
    if (user.isNotEmpty) {
      return {'Authorization': 'Basic ${base64Encode(utf8.encode('$user:$password'))}'};
    }
    return const {};
  }

  AppConfig copyWith({
    String? baseUrl,
    String? token,
    String? topic,
    String? user,
    String? password,
  }) {
    return AppConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      token: token ?? this.token,
      topic: topic ?? this.topic,
      user: user ?? this.user,
      password: password ?? this.password,
    );
  }

  Map<String, dynamic> toJson() => {
        'baseUrl': baseUrl,
        'token': token,
        'topic': topic,
        'user': user,
        'password': password,
      };

  factory AppConfig.fromJson(Map<String, dynamic> j) => AppConfig(
        baseUrl: j['baseUrl'] as String? ?? '',
        token: j['token'] as String? ?? '',
        topic: j['topic'] as String? ?? 'fp-phone',
        user: j['user'] as String? ?? '',
        password: j['password'] as String? ?? '',
      );
}

/// 配置仓库（SharedPreferences 持久化）
class ConfigStore {
  static const _k = 'fxxkpush.config';

  Future<AppConfig> load() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_k);
    if (raw == null || raw.isEmpty) return AppConfig();
    try {
      return AppConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return AppConfig();
    }
  }

  Future<void> save(AppConfig c) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_k, jsonEncode(c.toJson()));
  }
}

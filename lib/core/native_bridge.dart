import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'models.dart';

/// 原生侧桥接（Kotlin 前台服务 + WebSocket）。
///
/// **为什么要原生而不是纯 Dart**：
///   Android 8 以后 Dart isolate 在后台随时可能被系统杀掉，
///   纯 Dart 的 WebSocket 会在息屏几分钟后断开。
///   把「订阅 + 保活」放进原生 ForegroundService（常驻通知），
///   由原生持连接，消息通过 [MethodChannel] 的 poll 拉取 / EventChannel 推送。
///
/// 设计取舍：
///   - 订阅连接**只在原生**（OkHttp WebSocket），Dart 不重复连。
///   - 消息落盘在原生（sqlite），Dart 负责 UI 展示 —— 冷启动也能看到历史。
///   - [MethodChannel] 用方法调用，[EventChannel] 用于原生主动推事件。
class NativeBridge {
  static const _methods = MethodChannel('cc.omox.fxxkpush/methods');
  static const _events = EventChannel('cc.omox.fxxkpush/events');

  /// 解析失败计数（只用于日志节流）
  static int _parseErrCount = 0;

  /// 原生主动推来的事件流（新消息 / 连接状态变化）
  static Stream<Map<String, dynamic>>? _eventStream;

  static Stream<Map<String, dynamic>> get events {
    _eventStream ??= _events
        .receiveBroadcastStream()
        .map((e) => (e as Map).cast<String, dynamic>())
        .handleError((Object e) {
      // 通道错误不该把整个 app 拖崩 —— 保活失败时界面仍要能用
      debugPrint('NativeBridge event stream error: $e');
    });
    return _eventStream!;
  }

  /// 原生侧服务是否在跑（前台服务活着）
  static Future<bool> isServiceRunning() async {
    try {
      return await _methods.invokeMethod<bool>('isServiceRunning') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 启动前台服务（订阅）。参数：baseUrl / token / topic。
  static Future<bool> startService({
    required String baseUrl,
    required String token,
    required String topic,
  }) async {
    try {
      final ok = await _methods.invokeMethod<bool>('startService', {
        'baseUrl': baseUrl,
        'token': token,
        'topic': topic,
      });
      return ok ?? false;
    } on PlatformException catch (e) {
      debugPrint('startService failed: ${e.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 停前台服务
  static Future<void> stopService() async {
    try {
      await _methods.invokeMethod<void>('stopService');
    } on PlatformException {
      // 忽略
    } on MissingPluginException {
      // 忽略
    }
  }

  /// 拉取原生缓存里的消息（最新在前）
  static Future<List<NtfyMessage>> fetchMessages({int limit = 200}) async {
    try {
      final raw = await _methods.invokeMethod<List<dynamic>>(
        'fetchMessages',
        {'limit': limit},
      );
      if (raw == null) {
        debugPrint('fetchMessages: raw is null');
        return const [];
      }
      debugPrint('fetchMessages: raw len=${raw.length} '
          'type0=${raw.isEmpty ? "-" : raw.first.runtimeType} '
          'first=${raw.isEmpty ? "-" : (raw.first.toString().length > 100 ? raw.first.toString().substring(0, 100) : raw.first)}');
      final parsed = raw
          .whereType<String>()
          .map((s) {
            try {
              return NtfyMessage.fromJson(
                  jsonDecode(s) as Map<String, dynamic>);
            } catch (e, st) {
              // **别把异常吞掉** —— 之前这里是 `catch (_) { return null; }`，
              // 结果所有消息解析失败时，列表静默变成空，UI 一直显示「暂无消息」，
              // 而原生侧日志显示「fetchMessages -> 123 rows」。
              // 症状和数据完全对不上，只能靠这条日志定位。
              //
              // 只给**第一条**失败打完整堆栈 —— 124 条全失败的话，
              // 每条都打一遍会把 logcat 刷爆，真正的信息反而看不见。
              if (_parseErrCount == 0) {
                debugPrint('fetchMessages parse failed: $e\n$st\n  raw: ${s.length > 200 ? s.substring(0, 200) : s}');
              }
              _parseErrCount++;
              return null;
            }
          })
          .whereType<NtfyMessage>()
          .toList(growable: false);
      debugPrint('fetchMessages: parsed ${parsed.length}/${raw.length}');
      return parsed;
    } on PlatformException catch (e) {
      debugPrint('fetchMessages failed: ${e.message}');
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  /// 清空原生缓存
  static Future<void> clearMessages() async {
    try {
      await _methods.invokeMethod<void>('clearMessages');
    } on PlatformException {
      // 忽略
    } on MissingPluginException {
      // 忽略
    }
  }

  /// 反馈：调用 ntfy 的 publish 接口发到 feedback topic
  static Future<bool> publish({
    required String baseUrl,
    required String token,
    required String topic,
    required String message,
  }) async {
    try {
      final ok = await _methods.invokeMethod<bool>('publish', {
        'baseUrl': baseUrl,
        'token': token,
        'topic': topic,
        'message': message,
      });
      return ok ?? false;
    } on PlatformException catch (e) {
      debugPrint('publish failed: ${e.message}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 连接状态（供 UI 显示）：connected / connecting / disconnected / error
  static Future<String> connectionState() async {
    try {
      return await _methods.invokeMethod<String>('connectionState') ??
          'disconnected';
    } on PlatformException {
      return 'disconnected';
    } on MissingPluginException {
      return 'disconnected';
    }
  }
}

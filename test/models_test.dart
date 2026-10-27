import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fxxkpush/core/models.dart';

void main() {
  group('NtfyMessage.fromJson —— 字段解析', () {
    test('解析真实 ntfy 推送结构', () {
      // 这是实测从 VPS ntfy 服务器拉到的真实消息体
      const raw = '{"id":"CFcQfBVPceND","time":1793127022,"expires":1793170222,'
          '"event":"message","topic":"fp-phone","title":"FxxkPush 验证",'
          '"message":"验证消息 02:50:35","priority":4,"tags":["bell"]}';
      final m = NtfyMessage.fromJson(raw == '' ? {} : _decode(raw));

      expect(m.id, 'CFcQfBVPceND');
      expect(m.topic, 'fp-phone');
      expect(m.title, 'FxxkPush 验证');
      expect(m.message, '验证消息 02:50:35');
      expect(m.priority, 4);
      expect(m.tags, ['bell']);
      expect(m.isHigh, isTrue);          // priority>=4
    });

    test('priority=3 不算高优', () {
      final m = NtfyMessage.fromJson(_decode(
          '{"id":"x","time":1,"event":"message","topic":"t",'
          '"message":"m","priority":3}'));
      expect(m.isHigh, isFalse);
    });

    test('缺字段时用默认值，不抛异常', () {
      final m = NtfyMessage.fromJson(_decode('{"id":"x"}'));
      expect(m.message, '');
      expect(m.title, '');
      expect(m.priority, 3);
      expect(m.tags, isEmpty);
      expect(m.time, greaterThan(0));     // 兜底成当前时间
    });

    test('actions 解析', () {
      final m = NtfyMessage.fromJson(_decode(
          '{"id":"x","time":1,"message":"m","actions":['
          '{"action":"view","label":"打开","view":"https://x"}]}'));
      expect(m.actions.length, 1);
      expect(m.actions.first.action, 'view');
      expect(m.actions.first.label, '打开');
    });
  });

  group('本地时间', () {
    test('epoch 秒转本地时间', () {
      final m = NtfyMessage.fromJson(_decode(
          '{"id":"x","time":1793127022,"message":"m"}'));
      // 只验证不是 1970 就行，具体值取决于时区
      expect(m.localTime.year, greaterThan(2020));
    });
  });
}

Map<String, dynamic> _decode(String s) => jsonDecode(s) as Map<String, dynamic>;

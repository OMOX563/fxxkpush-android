/// ntfy 消息模型（只覆盖 FxxkPush 实际用到的字段）
///
/// ntfy publish 出去的 JSON 结构大致是：
/// ```json
/// {"id":"...","time":1700000000,"expires":1700003600,"event":"message",
///  "topic":"fp-phone","message":"...","title":"...","priority":4,
///  "tags":["warning"],"icon":"...","actions":[...],"click":"..."}
/// ```
/// `event` 有 message / open / keepalive / poll_request 四种，
/// 后两种是协议控制帧，不进列表。
class NtfyMessage {
  const NtfyMessage({
    required this.id,
    required this.topic,
    required this.message,
    required this.time,
    this.title = '',
    this.priority = 3,
    this.tags = const [],
    this.icon = '',
    this.click = '',
    this.actions = const [],
  });

  final String id;
  final String topic;
  final String message;
  final int time; // epoch 秒
  final String title;
  final int priority; // 1=min 2=low 3=default 4=high 5=max
  final List<String> tags;
  final String icon;
  final String click;
  final List<NtfyAction> actions;

  /// 优先级 >= 4 视为高优（红色强调）
  bool get isHigh => priority >= 4;

  /// ntfy 的时间戳是 epoch 秒，本地显示用本地时区
  DateTime get localTime =>
      DateTime.fromMillisecondsSinceEpoch(time * 1000);

  factory NtfyMessage.fromJson(Map<String, dynamic> j) {
    final rawTags = (j['tags'] as List?) ?? const [];
    final rawActions = (j['actions'] as List?) ?? const [];
    return NtfyMessage(
      id: (j['id'] as String?) ?? '',
      topic: (j['topic'] as String?) ?? '',
      message: (j['message'] as String?) ?? '',
      time: (j['time'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title: (j['title'] as String?) ?? '',
      priority: (j['priority'] as num?)?.toInt() ?? 3,
      tags: rawTags.map((e) => e.toString()).toList(growable: false),
      icon: (j['icon'] as String?) ?? '',
      click: (j['click'] as String?) ?? '',
      actions: rawActions
          .whereType<Map>()
          .map((e) => NtfyAction.fromJson(e.cast<String, dynamic>()))
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'topic': topic,
        'message': message,
        'time': time,
        'title': title,
        'priority': priority,
        'tags': tags,
        'icon': icon,
        'click': click,
        'actions': actions.map((a) => a.toJson()).toList(),
      };
}

/// 消息上的动作按钮（ntfy action）
class NtfyAction {
  const NtfyAction({
    required this.action,
    required this.label,
    this.view = '',
    this.url = '',
    this.clear = false,
  });

  final String action; // view / http / broadcast / publish
  final String label;
  final String view;
  final String url;
  final bool clear;

  factory NtfyAction.fromJson(Map<String, dynamic> j) => NtfyAction(
        action: (j['action'] as String?) ?? 'view',
        label: (j['label'] as String?) ?? '',
        view: (j['view'] as String?) ?? '',
        url: (j['url'] as String?) ?? '',
        clear: (j['clear'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'action': action,
        'label': label,
        'view': view,
        'url': url,
        'clear': clear,
      };
}

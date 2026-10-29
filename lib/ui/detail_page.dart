import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/glass_tokens.dart';
import '../core/models.dart';
import '../core/theme.dart';

/// 详情页：完整消息 + 反馈
class DetailPage extends StatefulWidget {
  const DetailPage({super.key, required this.state, required this.message});

  final AppState state;
  final NtfyMessage message;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  bool _feedbackBusy = false;
  String? _feedbackMsg;

  /// 用户的选择：0 = 未选，1 = 有用，-1 = 没用。
  ///
  /// 从 [NtfyMessage.feedback] 起步 —— 那是本地 sqlite 里记着的，
  /// 所以退出再进来，选择还在。
  /// （widget.message 是构造时的快照，不能直接改，所以本地存一份。）
  late int _feedback;

  @override
  void initState() {
    super.initState();
    _feedback = widget.message.feedback;
  }

  /// 记录反馈。
  ///
  /// value: 1 = 有用，-1 = 没用。**再点同一个 = 取消选择**。
  Future<void> _sendFeedback(int value, String payload) async {
    final next = (_feedback == value) ? 0 : value;
    setState(() => _feedbackBusy = true);
    final (local, remote) =
        await widget.state.setFeedback(widget.message.id, next, payload: payload);
    if (!mounted) return;

    final msg = !local
        ? '记录失败'
        : (next == 0
            ? '已取消记录'
            : (remote ? '已记录' : '已记录（未同步到服务器）'));

    setState(() {
      _feedbackBusy = false;
      if (local) _feedback = next;
      _feedbackMsg = msg;
    });

    if (!local) return;
    // **弹窗确认** —— 点了必须立刻有反馈，不然用户不知道记上没有
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Row(
          children: [
            Icon(
              next == 0
                  ? Icons.undo
                  : (next > 0 ? Icons.check_circle : Icons.cancel),
              size: 18,
              color: Colors.white,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                next == 0
                    ? '已取消记录'
                    : (next > 0 ? '已记录：标记为有用' : '已记录：标记为没用'),
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
        backgroundColor: next == 0
            ? const Color(0xFF334155)
            : (next > 0 ? const Color(0xFF268257) : const Color(0xFFB42318)),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final g = context.glass;
    final m = widget.message;

    return Scaffold(
      appBar: AppBar(
        title: Text(m.title.isEmpty ? '消息详情' : m.title),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              g.brand.withValues(alpha: 0.22),
              g.brandDim.withValues(alpha: 0.16),
              g.bgBase,
            ],
            stops: const [0.0, 0.45, 1.0],
          ),
        ),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            // 元信息
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _Chip(
                        label: m.topic,
                        color: g.brand,
                      ),
                      const SizedBox(width: 8),
                      if (m.isHigh)
                        _Chip(label: '高优先级', color: g.alertHigh)
                      else if (m.priority <= 2)
                        _Chip(label: '低优先级', color: g.alertLow),
                      const Spacer(),
                      Text(
                        _fmt(m.localTime),
                        style: TextStyle(color: g.inkFaint, fontSize: 12),
                      ),
                    ],
                  ),
                  if (m.tags.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: m.tags
                          .map((t) => _Chip(label: t, color: g.inkMuted))
                          .toList(),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),

            // 正文
            GlassCard(
              strong: true,
              child: SelectableText(
                m.message,
                style: TextStyle(
                  color: g.ink,
                  fontSize: 15,
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 12),

            // 反馈
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '这条消息有用吗？',
                    style: TextStyle(
                      color: g.ink,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      _FeedbackButton(
                        icon: Icons.thumb_up_outlined,
                        filledIcon: Icons.thumb_up,
                        label: '有用',
                        color: g.ok,
                        busy: _feedbackBusy,
                        selected: _feedback == 1,
                        onTap: () => _sendFeedback(1, '👍 $feedbackPayload'),
                      ),
                      const SizedBox(width: 10),
                      _FeedbackButton(
                        icon: Icons.thumb_down_outlined,
                        filledIcon: Icons.thumb_down,
                        label: '没用',
                        // **用 alertHigh（红），不是 alertMid（橙）** ——
                        // 「没用」是明确的否定反馈，橙色看着像「注意」而不是「否」。
                        color: g.alertHigh,
                        busy: _feedbackBusy,
                        selected: _feedback == -1,
                        onTap: () => _sendFeedback(-1, '👎 $feedbackPayload'),
                      ),
                    ],
                  ),
                  if (_feedbackMsg != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _feedbackMsg!,
                      style: TextStyle(
                        color: _feedbackMsg == '记录失败' ? g.alertHigh : g.ok,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),

            // 消息 id（排障用）
            GlassCard(
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'ID  ${m.id}',
                      style: TextStyle(
                        color: g.inkFaint,
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 反馈正文：带上来源与原消息摘要，AI 分诊侧才知道你在说哪条
  String get feedbackPayload {
    final m = widget.message;
    final brief = m.message.length > 60
        ? '${m.message.substring(0, 60)}…'
        : m.message;
    return '[${m.topic}] $brief';
  }

  static String _fmt(DateTime dt) {
    String p(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${p(dt.month)}-${p(dt.day)} ${p(dt.hour)}:${p(dt.minute)}:${p(dt.second)}';
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w500),
      ),
    );
  }
}

/// 反馈按钮。
///
/// 选中时**整块填充纯色**（绿=有用 / 红=没用）、文字与图标转白、
/// 线性图标换成实心 —— 一眼能看出这条已经打过分了。
/// 未选中时保持描边风格，颜色淡一点。
class _FeedbackButton extends StatelessWidget {
  const _FeedbackButton({
    required this.icon,
    required this.filledIcon,
    required this.label,
    required this.color,
    required this.busy,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final IconData filledIcon;
  final String label;
  final Color color;
  final bool busy;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          // 选中 → 纯色填充；未选中 → 透明（描边在外层画）
          color: selected ? color : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? color : color.withValues(alpha: 0.45),
            width: selected ? 0 : 1,
          ),
        ),
        child: OutlinedButton.icon(
          onPressed: busy ? null : onTap,
          icon: Icon(
            selected ? filledIcon : icon,
            size: 17,
            color: selected ? Colors.white : color,
          ),
          label: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : color,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          style: OutlinedButton.styleFrom(
            side: BorderSide.none,
            backgroundColor: Colors.transparent,
            padding: const EdgeInsets.symmetric(vertical: 11),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
    );
  }
}

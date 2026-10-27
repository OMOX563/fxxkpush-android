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

  Future<void> _sendFeedback(String text) async {
    setState(() => _feedbackBusy = true);
    final ok = await widget.state.sendFeedback(text);
    if (!mounted) return;
    setState(() {
      _feedbackBusy = false;
      _feedbackMsg = ok ? '已反馈' : '反馈失败';
    });
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
                        label: '有用',
                        color: g.ok,
                        busy: _feedbackBusy,
                        onTap: () => _sendFeedback('👍 $feedbackPayload'),
                      ),
                      const SizedBox(width: 10),
                      _FeedbackButton(
                        icon: Icons.thumb_down_outlined,
                        label: '没用',
                        color: g.alertMid,
                        busy: _feedbackBusy,
                        onTap: () => _sendFeedback('👎 $feedbackPayload'),
                      ),
                    ],
                  ),
                  if (_feedbackMsg != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _feedbackMsg!,
                      style: TextStyle(
                        color: _feedbackMsg == '已反馈' ? g.ok : g.alertHigh,
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

class _FeedbackButton extends StatelessWidget {
  const _FeedbackButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.busy,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: OutlinedButton.icon(
        onPressed: busy ? null : onTap,
        icon: Icon(icon, size: 17, color: color),
        label: Text(label, style: TextStyle(color: color)),
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: color.withValues(alpha: 0.45)),
          padding: const EdgeInsets.symmetric(vertical: 11),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}

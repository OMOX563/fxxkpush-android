import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/glass_tokens.dart';
import '../core/models.dart';
import '../core/theme.dart';
import 'detail_page.dart';
import 'settings_page.dart';

/// 主界面：消息列表
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.state});

  final AppState state;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// 深链目标在本地缓存里找不到的轮数（兜底用，避免深链永远挂着）
  int _missingDeepLinkRounds = 0;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onState);
  }

  @override
  void dispose() {
    widget.state.removeListener(_onState);
    super.dispose();
  }

  void _onState() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final g = context.glass;

    // 处理深链（点通知进来）
    //
    // 关键：只有在**消息列表里确实有那条消息**时才消费深链。
    // 冷启动时原生可能已存了消息但 Dart 还没拉完（refreshMessages 是异步的），
    // 这时若把深链取走就再也找不回来 —— 表现为「点通知进 app 但什么都没发生」。
    final pending = s.peekPendingDeepLink();
    if (pending != null) {
      final match = s.messages.cast<NtfyMessage?>().firstWhere(
            (m) => m?.id == pending,
            orElse: () => null,
          );
      if (match != null) {
        s.consumeDeepLink();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => DetailPage(state: s, message: match)),
          );
        });
      }
      // match == null → 保留深链，等列表刷新后由下一次 build 重试
      //
      // 但如果轮询若干轮后仍找不到（消息已被清缓存、或消息不在本地库），
      // 深链会一直挂着 —— 加个计数兜底，避免「永远转圈」。
      else {
        _missingDeepLinkRounds++;
        if (_missingDeepLinkRounds == 6) {
          // 约 30 秒（轮询 5 秒一次）仍找不到 → 放弃并提示
          s.consumeDeepLink();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('这条消息不在本地缓存里')),
            );
          });
        }
      }
    } else {
      _missingDeepLinkRounds = 0;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('FxxkPush'),
        actions: [
          _ConnDot(state: s.connState),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => SettingsPage(state: s)),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Container(
        decoration: _bgDecoration(g),
        child: _body(s, g),
      ),
    );
  }

  Widget _body(AppState s, GlassTokens g) {
    if (!s.isConfigured) {
      return _Empty(
        icon: Icons.settings_suggest_outlined,
        title: '尚未配置',
        subtitle: '填入服务器地址与访问令牌后开始接收推送',
        action: FilledButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => SettingsPage(state: s)),
          ),
          child: const Text('去设置'),
        ),
      );
    }

    if (s.messages.isEmpty) {
      return _Empty(
        icon: Icons.inbox_outlined,
        title: '暂无消息',
        subtitle: s.isConnected ? '订阅已连接，等待推送…' : '连接中…',
        action: IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: () => s.refreshMessages(),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => s.refreshMessages(),
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
        itemCount: s.messages.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (_, i) => _MessageTile(
          message: s.messages[i],
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => DetailPage(state: s, message: s.messages[i]),
            ),
          ),
        ),
      ),
    );
  }
}

/// 连接状态小圆点
class _ConnDot extends StatelessWidget {
  const _ConnDot({required this.state});

  final String state;

  @override
  Widget build(BuildContext context) {
    final g = context.glass;
    final (color, label) = switch (state) {
      'connected' => (g.ok, '已连接'),
      'connecting' => (g.alertLow, '连接中'),
      'error' => (g.alertHigh, '连接错误'),
      _ => (g.inkFaint, '未连接'),
    };
    return Tooltip(
      message: label,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ],
        ),
      ),
    );
  }
}

/// 列表项
class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.message, required this.onTap});

  final NtfyMessage message;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final g = context.glass;
    final time = _fmtTime(message.localTime);

    return GlassCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 优先级色条
          Container(
            width: 3,
            height: 42,
            margin: const EdgeInsets.only(right: 11, top: 2),
            decoration: BoxDecoration(
              color: message.isHigh ? g.alertHigh : g.brand,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (message.title.isNotEmpty)
                      Expanded(
                        child: Text(
                          message.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: g.ink,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      )
                    else
                      const Spacer(),
                    Text(
                      time,
                      style: TextStyle(color: g.inkFaint, fontSize: 11.5),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  message.message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: g.inkMuted,
                    fontSize: 13.5,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _fmtTime(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(dt.year, dt.month, dt.day);
    final hm =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    if (d == today) return hm;
    if (d == today.subtract(const Duration(days: 1))) return '昨天 $hm';
    return '${dt.month}/${dt.day} $hm';
  }
}

/// 空状态
class _Empty extends StatelessWidget {
  const _Empty({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final g = context.glass;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 46, color: g.inkFaint),
            const SizedBox(height: 14),
            Text(
              title,
              style: TextStyle(
                color: g.ink,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: g.inkMuted, fontSize: 13.5),
            ),
            if (action != null) ...[const SizedBox(height: 18), action!],
          ],
        ),
      ),
    );
  }
}

/// 背景：品牌色氛围斑（对应 fork 里的「氛围斑 26/20/16%」）
BoxDecoration _bgDecoration(GlassTokens g) {
  return BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        g.brand.withValues(alpha: 0.26),
        g.brandDim.withValues(alpha: 0.20),
        g.bgBase,
      ],
      stops: const [0.0, 0.45, 1.0],
    ),
  );
}

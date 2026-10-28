import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/config.dart';
import '../core/glass_tokens.dart';
import '../core/theme.dart';

/// 设置页：服务器地址、访问令牌、订阅话题
///
/// **刻意不预置任何真实地址** —— APK 要公开分发，预置了真 VPS IP 等于送上门。
/// 首次启动由用户手填；填完存在本机 SharedPreferences。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.state});

  final AppState state;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _url;
  late final TextEditingController _token;
  late final TextEditingController _topic;
  bool _obscureToken = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // 订阅 AppState —— **不订阅的话这一页永远是 stale 的**。
    //
    // 症状：用户点「保存并连接」，WebSocket 其实连上了（通知能收到），
    // 但页面上的「连接状态」一直显示「连接中」——
    // AppState.notifyListeners() 只通知注册过的 listener，
    // 这一页没注册就永远不重建。
    // （home_page 有注册，所以主页的小圆点是对的，只有设置页不对。）
    widget.state.addListener(_onStateChanged);
    final c = widget.state.config;
    _url = TextEditingController(text: c.baseUrl);
    _token = TextEditingController(text: c.token);
    _topic = TextEditingController(text: c.topic);
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChanged);
    _url.dispose();
    _token.dispose();
    _topic.dispose();
    super.dispose();
  }

  /// AppState 变化 → 重建本页（连接状态、按钮态等）
  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    await widget.state.saveConfig(
      AppConfig(
        baseUrl: _url.text.trim(),
        token: _token.text.trim(),
        topic: _topic.text.trim().isEmpty ? 'fp-phone' : _topic.text.trim(),
      ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存，订阅将自动重连')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final g = context.glass;
    final s = widget.state;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
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
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _label(g, '服务器地址'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      hintText: 'http://<你的服务器>:2586',
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'ntfy 服务所在地址，端口通常是 2586',
                    style: TextStyle(color: g.inkFaint, fontSize: 11.5),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '支持 http:// 与 https://。自建 ntfy 多数没有 TLS，'
                    '用 http:// 时系统会放行明文连接。',
                    style: TextStyle(color: g.inkFaint, fontSize: 11.5),
                  ),

                  const SizedBox(height: 18),
                  _label(g, '访问令牌'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _token,
                    obscureText: _obscureToken,
                    autocorrect: false,
                    decoration: InputDecoration(
                      hintText: 'tk_…（ntfy access token）',
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscureToken
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 19,
                          color: g.inkFaint,
                        ),
                        onPressed: () =>
                            setState(() => _obscureToken = !_obscureToken),
                      ),
                    ),
                  ),

                  const SizedBox(height: 18),
                  _label(g, '订阅话题'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _topic,
                    autocorrect: false,
                    decoration: const InputDecoration(hintText: 'fp-phone'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // 连接状态 + 操作
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '连接状态',
                        style: TextStyle(
                          color: g.ink,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        _connLabel(s.connState),
                        style: TextStyle(
                          color: _connColor(s.connState, g),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: _busy ? null : _save,
                          child: const Text('保存并连接'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            await s.stopService();
                            if (context.mounted) setState(() {});
                          },
                          child: const Text('断开'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextButton.icon(
                    onPressed: () async {
                      await s.clearMessages();
                      if (context.mounted) setState(() {});
                    },
                    icon: Icon(Icons.delete_outline, size: 17, color: g.inkMuted),
                    label: Text('清空本地缓存',
                        style: TextStyle(color: g.inkMuted, fontSize: 13)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // 保活说明
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.bolt_outlined, size: 17, color: g.brand),
                      const SizedBox(width: 6),
                      Text(
                        '保持后台连接',
                        style: TextStyle(
                          color: g.ink,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '本应用用「前台服务 + 常驻通知」保活（Android 唯一官方认可的'
                    '长连方式）。若你已 root，app 会自动尝试把自己加入 Doze '
                    '白名单；仍被系统杀的话，请到「设置 → 应用 → FxxkPush → '
                    '电池」里选「无限制」，并在系统自启动管理里允许它。',
                    style: TextStyle(
                      color: g.inkMuted,
                      fontSize: 12.5,
                      height: 1.5,
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

  Widget _label(GlassTokens g, String t) => Text(
        t,
        style: TextStyle(
          color: g.ink,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      );

  String _connLabel(String s) => switch (s) {
        'connected' => '已连接',
        'connecting' => '连接中',
        'error' => '连接错误',
        _ => '未连接',
      };

  Color _connColor(String s, GlassTokens g) => switch (s) {
        'connected' => g.ok,
        'connecting' => g.alertLow,
        'error' => g.alertHigh,
        _ => g.inkFaint,
      };
}

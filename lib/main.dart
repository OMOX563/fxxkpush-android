import 'package:flutter/material.dart';

import 'core/app_state.dart';
import 'core/theme.dart';
import 'ui/home_page.dart';

void main() {
  runApp(const FxxkPushApp());
}

class FxxkPushApp extends StatefulWidget {
  const FxxkPushApp({super.key});

  @override
  State<FxxkPushApp> createState() => _FxxkPushAppState();
}

class _FxxkPushAppState extends State<FxxkPushApp> {
  final AppState _state = AppState();

  @override
  void initState() {
    super.initState();
    _state.init();
  }

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FxxkPush',
      debugShowCheckedModeBanner: false,
      theme: FxxkPushTheme.light(),
      darkTheme: FxxkPushTheme.dark(),
      themeMode: ThemeMode.system,
      home: HomePage(state: _state),
      // **必须兜住未知路由，否则点通知会闪退。**
      //
      // app 自己的深链是 `fxxkpush://message/<id>`，处理路径是：
      //   Android intent → MainActivity.handleDeepLink() → EventChannel
      //   → AppState._pendingDeepLink → home_page 用 MaterialPageRoute push 详情页
      //
      // 但 **Flutter 引擎也会抢同一个 intent**：AndroidManifest 里配了
      // `<data android:scheme="fxxkpush"/>`，而 Flutter 的
      // `shouldHandleDeeplinking()` 默认返回 true —— 于是引擎把整个 URI
      // 当成路由名（"fxxkpush://message/xxx"）通过 pushNamed 推给 Navigator。
      //
      // 而本 app 没有配 routes/onUnknownRoute，WidgetsApp 会走
      // `_onUnknownRoute` → `widget.onUnknownRoute!` → **空断言崩**：
      //   Null check operator used on a null value
      //   #0 _WidgetsAppState._onUnknownRoute (app.dart:1590)
      //   #2 NavigatorState.pushNamed
      //
      // 崩了之后 Navigator 状态就坏了 —— 页面不再重建，
      // 消息列表会一直停在「暂无消息」，哪怕 sqlite 里有一百多条。
      //
      // 这里返回 null：未知路由不 push 任何页面，Flutter 只打一条警告。
      // app 自己的详情页由原生那条路负责，不会被这里干扰。
      onUnknownRoute: (settings) {
        debugPrint('unknown route ignored (handled by native deep link): '
            '${settings.name}');
        return null;
      },
    );
  }
}

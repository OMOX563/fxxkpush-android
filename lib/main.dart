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
    );
  }
}

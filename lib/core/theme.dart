import 'package:flutter/material.dart';

import 'glass_tokens.dart';

/// 应用主题：明暗两套 + 玻璃令牌扩展
class FxxkPushTheme {
  static ThemeData light() => _build(GlassTokens.light, Brightness.light);
  static ThemeData dark() => _build(GlassTokens.dark, Brightness.dark);

  static ThemeData _build(GlassTokens g, Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: g.brand,
      brightness: brightness,
    ).copyWith(
      surface: g.bgBase,
      onSurface: g.ink,
      primary: g.brand,
      error: g.alertHigh,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: g.bgBase,
      extensions: [g],
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        foregroundColor: g.ink,
        titleTextStyle: TextStyle(
          color: g.ink,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
      ),
      cardTheme: CardThemeData(
        color: g.glassFill,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: g.glassStroke, width: 1),
        ),
      ),
      dividerTheme: DividerThemeData(color: g.glassStrokeDim, thickness: 1),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: g.glassFill,
        hintStyle: TextStyle(color: g.inkFaint),
        labelStyle: TextStyle(color: g.inkMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: g.glassStroke),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: g.glassStroke),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: g.brand, width: 1.6),
        ),
      ),
      textTheme: Typography.material2021().black.apply(
            bodyColor: g.ink,
            displayColor: g.ink,
          ),
    );
  }
}

/// 玻璃卡片：半透明 + 细边 + 轻阴影
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.borderRadius = 18,
    this.strong = false,
  });

  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final double borderRadius;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final g = context.glass;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(borderRadius),
      side: BorderSide(
        color: strong ? g.glassStroke : g.glassStroke.withValues(alpha: 0.7),
        width: 1,
      ),
    );

    return Material(
      color: strong ? g.glassFillStrong : g.glassFill,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

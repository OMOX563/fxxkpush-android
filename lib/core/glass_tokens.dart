import 'package:flutter/material.dart';

/// FxxkPush 液态玻璃 · 设计令牌
///
/// 数值从 ntfy-android fork 的 Compose 版 `GlassTokens.kt` 逐值移植
/// （浅色/深色两套，16 个槽位）。那份是 2026-10-15 实测调出来的：
/// 初版「氛围斑 8% + 卡片 62% 白」叠出来几乎是纯白，色斑被吃光，
/// 看上去像「官方 ntfy 加了张图」；现值「斑 26/20/16% + 卡片 44% 白」
/// 叠出 (215,226,248)，品牌蓝明确透上来，同时 ink 13.7:1、
/// ink-muted 5.8:1，仍高于 §8 要求的 7:1 / 4.5:1。
///
/// **别随手改这些值** —— 改完必须重新核对对比度。
@immutable
class GlassTokens extends ThemeExtension<GlassTokens> {
  const GlassTokens({
    required this.brand,
    required this.brandDim,
    required this.brandContainer,
    required this.glassFill,
    required this.glassFillStrong,
    required this.glassStroke,
    required this.glassStrokeDim,
    required this.ink,
    required this.inkMuted,
    required this.inkFaint,
    required this.bgBase,
    required this.bgVeil,
    required this.alertHigh,
    required this.alertMid,
    required this.alertLow,
    required this.ok,
  });

  final Color brand;
  final Color brandDim;
  final Color brandContainer;
  final Color glassFill;
  final Color glassFillStrong;
  final Color glassStroke;
  final Color glassStrokeDim;
  final Color ink;
  final Color inkMuted;
  final Color inkFaint;
  final Color bgBase;
  final Color bgVeil;
  final Color alertHigh;
  final Color alertMid;
  final Color alertLow;
  final Color ok;

  @override
  GlassTokens copyWith({
    Color? brand,
    Color? brandDim,
    Color? brandContainer,
    Color? glassFill,
    Color? glassFillStrong,
    Color? glassStroke,
    Color? glassStrokeDim,
    Color? ink,
    Color? inkMuted,
    Color? inkFaint,
    Color? bgBase,
    Color? bgVeil,
    Color? alertHigh,
    Color? alertMid,
    Color? alertLow,
    Color? ok,
  }) {
    return GlassTokens(
      brand: brand ?? this.brand,
      brandDim: brandDim ?? this.brandDim,
      brandContainer: brandContainer ?? this.brandContainer,
      glassFill: glassFill ?? this.glassFill,
      glassFillStrong: glassFillStrong ?? this.glassFillStrong,
      glassStroke: glassStroke ?? this.glassStroke,
      glassStrokeDim: glassStrokeDim ?? this.glassStrokeDim,
      ink: ink ?? this.ink,
      inkMuted: inkMuted ?? this.inkMuted,
      inkFaint: inkFaint ?? this.inkFaint,
      bgBase: bgBase ?? this.bgBase,
      bgVeil: bgVeil ?? this.bgVeil,
      alertHigh: alertHigh ?? this.alertHigh,
      alertMid: alertMid ?? this.alertMid,
      alertLow: alertLow ?? this.alertLow,
      ok: ok ?? this.ok,
    );
  }

  @override
  GlassTokens lerp(ThemeExtension<GlassTokens>? other, double t) {
    if (other is! GlassTokens) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return GlassTokens(
      brand: l(brand, other.brand),
      brandDim: l(brandDim, other.brandDim),
      brandContainer: l(brandContainer, other.brandContainer),
      glassFill: l(glassFill, other.glassFill),
      glassFillStrong: l(glassFillStrong, other.glassFillStrong),
      glassStroke: l(glassStroke, other.glassStroke),
      glassStrokeDim: l(glassStrokeDim, other.glassStrokeDim),
      ink: l(ink, other.ink),
      inkMuted: l(inkMuted, other.inkMuted),
      inkFaint: l(inkFaint, other.inkFaint),
      bgBase: l(bgBase, other.bgBase),
      bgVeil: l(bgVeil, other.bgVeil),
      alertHigh: l(alertHigh, other.alertHigh),
      alertMid: l(alertMid, other.alertMid),
      alertLow: l(alertLow, other.alertLow),
      ok: l(ok, other.ok),
    );
  }

  static const light = GlassTokens(
    brand: Color(0xFF2C6BED),
    brandDim: Color(0xFF1E4FB0),
    brandContainer: Color(0xFFDCE7FF),
    glassFill: Color(0x70FFFFFF),
    glassFillStrong: Color(0xC7FFFFFF),
    glassStroke: Color(0xCCFFFFFF),
    glassStrokeDim: Color(0x140F172A),
    ink: Color(0xFF0F172A),
    inkMuted: Color(0xFF475569),
    inkFaint: Color(0xFF7C8899),
    bgBase: Color(0xFFEEF2F7),
    bgVeil: Color(0x66FFFFFF),
    alertHigh: Color(0xFFB42318),
    alertMid: Color(0xFFC2410C),
    alertLow: Color(0xFF996F00),
    ok: Color(0xFF268257),
  );

  static const dark = GlassTokens(
    brand: Color(0xFF8FB6FF),
    brandDim: Color(0xFFB8CFF8),
    brandContainer: Color(0xFF1C3A66),
    glassFill: Color(0x701A2230),
    glassFillStrong: Color(0xB81E2836),
    glassStroke: Color(0x33FFFFFF),
    glassStrokeDim: Color(0x3D000000),
    ink: Color(0xFFE8EEF7),
    inkMuted: Color(0xFF94A3B8),
    inkFaint: Color(0xFF64748B),
    bgBase: Color(0xFF0B0F16),
    bgVeil: Color(0x4D000000),
    alertHigh: Color(0xFFFF6B6B),
    alertMid: Color(0xFFFF8B3D),
    alertLow: Color(0xFFFFD426),
    ok: Color(0xFF4CC38A),
  );
}

/// 取当前主题下的玻璃令牌
extension GlassTokensX on BuildContext {
  GlassTokens get glass =>
      Theme.of(this).extension<GlassTokens>() ?? GlassTokens.light;
}

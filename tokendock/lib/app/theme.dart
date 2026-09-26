import 'package:flutter/material.dart';

/// TokenDock visual tokens.
///
/// Single source of truth for the canvas/surface/ink ramps, status accents,
/// spacing, radii, and typography across light, dark, and high-contrast
/// modes. Components resolve the active ramp with [TokenDockTheme.colorsOf]
/// so they stay flat, composable content primitives with no hardcoded colors.
class TokenDockColors {
  const TokenDockColors({
    required this.canvas,
    required this.surface,
    required this.mutedSurface,
    required this.ink,
    required this.mutedInk,
    required this.hairline,
    required this.lime,
    required this.limeInk,
    required this.statusNormal,
    required this.statusOk,
    required this.statusWarning,
    required this.statusLimited,
    required this.statusUpdating,
    required this.quotaFill,
  });

  final Color canvas;
  final Color surface;
  final Color mutedSurface;
  final Color ink;
  final Color mutedInk;
  final Color hairline;
  final Color lime;
  final Color limeInk;
  final Color statusNormal;
  final Color statusOk;
  final Color statusWarning;
  final Color statusLimited;
  final Color statusUpdating;
  final Color quotaFill;

  /// Every color in the ramp, for opacity/readability audits in tests.
  List<Color> get values => <Color>[
    canvas,
    surface,
    mutedSurface,
    ink,
    mutedInk,
    hairline,
    lime,
    limeInk,
    statusNormal,
    statusOk,
    statusWarning,
    statusLimited,
    statusUpdating,
    quotaFill,
  ];
}

abstract final class TokenDockTheme {
  static const TokenDockColors light = TokenDockColors(
    canvas: Color(0xFFF5F5F0),
    surface: Color(0xFFFFFFFF),
    mutedSurface: Color(0xFFF0F0EA),
    ink: Color(0xFF17161B),
    mutedInk: Color(0xFF6C6A73),
    hairline: Color(0xFFE2E1DA),
    lime: Color(0xFFC8F54A),
    limeInk: Color(0xFF182000),
    statusNormal: Color(0xFF1769C2),
    statusOk: Color(0xFF087A4C),
    statusWarning: Color(0xFFA85A00),
    statusLimited: Color(0xFFC33737),
    statusUpdating: Color(0xFF6C6A73),
    quotaFill: Color(0xFF1769C2),
  );

  /// Dark counterpart of [light], not an inverted copy of it.
  ///
  /// The status accents are lightened here so they clear WCAG 2.2 AA (4.5:1)
  /// for text against the dark surfaces. They previously reused the light
  /// ramp verbatim, which left "Connected", "Degraded", "Limited" and the
  /// quota blue between 3.06:1 and 3.29:1 on [surface]. Each keeps its
  /// semantic hue so the label and glyph still read as green/amber/red/blue.
  static const TokenDockColors dark = TokenDockColors(
    canvas: Color(0xFF151419),
    surface: Color(0xFF1E1D23),
    mutedSurface: Color(0xFF29272F),
    ink: Color(0xFFF4F3F0),
    mutedInk: Color(0xFFB6B2BD),
    hairline: Color(0xFF393640),
    lime: Color(0xFFC8F54A),
    limeInk: Color(0xFF182000),
    statusNormal: Color(0xFF8AB8FF),
    statusOk: Color(0xFF34A853),
    statusWarning: Color(0xFFE8A33D),
    statusLimited: Color(0xFFF26D6D),
    statusUpdating: Color(0xFFB6B2BD),
    quotaFill: Color(0xFF8AB8FF),
  );

  /// Dark-based ramp where every value is fully opaque and text accents are
  /// brightened so body and muted copy stay readable on the canvas.
  static const TokenDockColors highContrast = TokenDockColors(
    canvas: Color(0xFF000000),
    surface: Color(0xFF000000),
    mutedSurface: Color(0xFF1A1A1A),
    ink: Color(0xFFFFFFFF),
    mutedInk: Color(0xFFE8E6E0),
    hairline: Color(0xFFFFFFFF),
    lime: Color(0xFFC8F54A),
    limeInk: Color(0xFF000000),
    statusNormal: Color(0xFF8AB8FF),
    statusOk: Color(0xFF4ADE80),
    statusWarning: Color(0xFFFFB020),
    statusLimited: Color(0xFFFF7A7A),
    statusUpdating: Color(0xFFFFFFFF),
    quotaFill: Color(0xFF8AB8FF),
  );

  /// Resolves the active ramp: high-contrast wins when the platform requests
  /// it, otherwise follows the ambient [Theme] brightness.
  static TokenDockColors colorsOf(BuildContext context) {
    if (MediaQuery.highContrastOf(context)) return highContrast;
    return Theme.of(context).brightness == Brightness.dark ? dark : light;
  }

  static ThemeData lightTheme() => _build(Brightness.light, light);
  static ThemeData darkTheme() => _build(Brightness.dark, dark);
  static ThemeData highContrastTheme() => _build(Brightness.dark, highContrast);

  static ThemeData _build(Brightness brightness, TokenDockColors colors) {
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: TokenDockTypography.fontFamily,
      scaffoldBackgroundColor: colors.canvas,
      cardColor: colors.surface,
      dividerColor: colors.hairline,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: colors.ink,
        onPrimary: colors.canvas,
        secondary: colors.lime,
        onSecondary: colors.limeInk,
        surface: colors.surface,
        onSurface: colors.ink,
        error: colors.statusLimited,
        onError: colors.surface,
      ),
      textTheme: TextTheme(
        titleMedium: TokenDockTypography.titleStyle(color: colors.ink),
        bodyMedium: TokenDockTypography.bodyStyle(color: colors.ink),
        labelSmall: TokenDockTypography.metadataStyle(color: colors.mutedInk),
      ),
    );
  }
}

abstract final class TokenDockSpacing {
  static const double s4 = 4;
  static const double s8 = 8;
  static const double s12 = 12;
  static const double s16 = 16;
  static const double s20 = 20;
  static const double s24 = 24;
}

abstract final class TokenDockRadii {
  static const double r12 = 12;
  static const double r20 = 20;
  static const double pill = 999;
}

/// The type ramp, fixed by the first-goal design spec.
///
/// Spec: "11px metadata, 13px body, 15px account/provider label, 18px section
/// heading, and 22px widget heading; quota percentages use 20px semibold
/// tabular figures so values do not reflow."
///
/// Every step is a named token rather than a `copyWith` at the call site. Two
/// of these roles had no token at all and were expressed as inline overrides,
/// which is how the ramp drifted out of sync with the spec in the first place
/// (audit C-19).
abstract final class TokenDockTypography {
  static const String fontFamily = 'Segoe UI Variable';

  /// The ramp, in one place, so a change is one edit rather than a sweep.
  static const double metadataSize = 11;
  static const double bodySize = 13;
  static const double titleSize = 15;
  static const double sectionHeadingSize = 18;
  static const double widgetHeadingSize = 22;
  static const double quotaFigureSize = 20;

  static const List<FontFeature> _tabular = <FontFeature>[
    FontFeature.tabularFigures(),
  ];

  /// Secondary information: cache age, status labels, hints. 11px.
  static TextStyle metadataStyle({Color? color}) => TextStyle(
    fontFamily: fontFamily,
    fontSize: metadataSize,
    fontWeight: FontWeight.w400,
    color: color,
  );

  /// Running text. 13px.
  static TextStyle bodyStyle({Color? color}) => TextStyle(
    fontFamily: fontFamily,
    fontSize: bodySize,
    fontWeight: FontWeight.w400,
    color: color,
  );

  /// Account and provider labels. 15px.
  static TextStyle titleStyle({Color? color}) => TextStyle(
    fontFamily: fontFamily,
    fontSize: titleSize,
    fontWeight: FontWeight.w600,
    color: color,
  );

  /// Section headings within a surface. 18px.
  static TextStyle sectionHeadingStyle({Color? color}) => TextStyle(
    fontFamily: fontFamily,
    fontSize: sectionHeadingSize,
    fontWeight: FontWeight.w600,
    color: color,
  );

  /// The widget's own title. 22px.
  static TextStyle widgetHeadingStyle({Color? color}) => TextStyle(
    fontFamily: fontFamily,
    fontSize: widgetHeadingSize,
    fontWeight: FontWeight.w600,
    color: color,
  );

  /// The number the product exists to answer. 20px semibold, tabular.
  static TextStyle quotaStyle({Color? color}) => TextStyle(
    fontFamily: fontFamily,
    fontSize: quotaFigureSize,
    fontWeight: FontWeight.w600,
    color: color,
    fontFeatures: _tabular,
  );

  /// Time remaining until a quota resets.
  ///
  /// Its own step rather than [quotaStyle]. The countdown is metadata *about* a
  /// figure, and at 20px semibold it competed with the number it annotates
  /// instead of supporting it. Tabular because the value changes in place.
  static TextStyle countdownStyle({Color? color}) => TextStyle(
    fontFamily: fontFamily,
    fontSize: bodySize,
    fontWeight: FontWeight.w400,
    color: color,
    fontFeatures: _tabular,
  );
}

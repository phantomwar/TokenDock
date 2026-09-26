import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// Flat circular provider monogram. Content primitive, no card chrome.
///
/// Derives a one-letter glyph from [provider] so account headers and compact
/// rows stay consistent without duplicating display strings.
///
/// 24px, down from 32. At 32 the disc was exactly as tall as the account name it
/// precedes, so the two competed and the name — the thing a user scans for —
/// lost. The glyph drops to the body step with the disc so it still fits inside.
class ProviderIcon extends StatelessWidget {
  const ProviderIcon({super.key, required this.provider});

  /// The disc's diameter.
  ///
  /// Named because the glyph has to be sized against it; shrinking the disc
  /// without the glyph is how a monogram ends up clipped.
  static const double diameter = 24;

  final String provider;
  String get _monogram {
    final trimmed = provider.trim();
    if (trimmed.isEmpty) return '?';
    return trimmed.substring(0, 1).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final colors = TokenDockTheme.colorsOf(context);
    return Semantics(
      label: 'Provider $provider',
      child: Container(
        width: diameter,
        height: diameter,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colors.mutedSurface,
          shape: BoxShape.circle,
          border: Border.all(color: colors.hairline),
        ),
        child: Text(
          _monogram,
          style: TokenDockTypography.bodyStyle(color: colors.ink),
        ),
      ),
    );
  }
}

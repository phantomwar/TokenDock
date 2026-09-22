import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// Flat circular provider monogram. Content primitive, no card chrome.
///
/// Derives a one-letter glyph from [provider] so account headers and compact
/// rows stay consistent without duplicating display strings.
class ProviderIcon extends StatelessWidget {
  const ProviderIcon({super.key, required this.provider});

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
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colors.mutedSurface,
          shape: BoxShape.circle,
          border: Border.all(color: colors.hairline),
        ),
        child: Text(
          _monogram,
          style: TokenDockTypography.titleStyle(color: colors.ink),
        ),
      ),
    );
  }
}

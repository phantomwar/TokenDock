import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// Plain group label. Flat text primitive for section titles above cards.
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = TokenDockTheme.colorsOf(context);
    return Text(
      title,
      style: TokenDockTypography.captionStyle(color: colors.mutedInk),
    );
  }
}

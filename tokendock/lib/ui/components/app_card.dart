import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// The one shell surface in the visual system.
///
/// Flat [Card]-free container: surface fill, hairline border, 12dp radius.
/// Content primitives (headers, rows, icons) compose inside it and must not
/// add their own card chrome.
class AppCard extends StatelessWidget {
  const AppCard({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final colors = TokenDockTheme.colorsOf(context);
    return Container(
      padding: padding ??
          const EdgeInsets.all(
            TokenDockSpacing.s16,
          ),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(TokenDockRadii.r12),
        border: Border.all(color: colors.hairline),
      ),
      child: child,
    );
  }
}

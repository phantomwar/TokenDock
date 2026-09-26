import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// Outer desktop widget container per the visual specification.
///
/// Canvas fill, 20px radius, 1px hairline stroke, and a restrained
/// low-opacity shadow. Carries the single `TokenDock` header plus an optional
/// [actions] slot, then the main content area.
///
/// Provides its own [Directionality] and [Material] ancestors (plus default
/// [MediaQuery] data when none is inherited) so `TokenDockWidget` can be
/// pumped cleanly standalone in widget tests without throwing missing
/// directionality errors.
class WidgetShell extends StatelessWidget {
  const WidgetShell({super.key, required this.child, this.actions});

  final Widget child;
  final Widget? actions;

  @override
  Widget build(BuildContext context) {
    final Widget content = Directionality(
      textDirection: TextDirection.ltr,
      child: Material(
        color: Colors.transparent,
        child: Builder(
          builder: (BuildContext innerContext) {
            final colors = TokenDockTheme.colorsOf(innerContext);
            return Container(
              decoration: BoxDecoration(
                color: colors.canvas,
                borderRadius: BorderRadius.circular(TokenDockRadii.r20),
                border: Border.all(color: colors.hairline),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x0F000000),
                    blurRadius: 16,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(TokenDockSpacing.s16),
              child: Column(
                mainAxisSize: MainAxisSize.max,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          'TokenDock',
                          style: TokenDockTypography.widgetHeadingStyle(
                            color: colors.ink,
                          ),
                        ),
                      ),
                      actions ?? const SizedBox.shrink(),
                    ],
                  ),
                  const SizedBox(height: TokenDockSpacing.s12),
                  Expanded(child: child),
                ],
              ),
            );
          },
        ),
      ),
    );
    // Standalone test pumps have no MediaQuery ancestor; fall back to
    // defaults so TokenDockTheme.colorsOf resolves instead of throwing.
    // Inherited MediaQuery data (text scale, real metrics) is preserved.
    if (MediaQuery.maybeOf(context) == null) {
      return MediaQuery(data: const MediaQueryData(), child: content);
    }
    return content;
  }
}

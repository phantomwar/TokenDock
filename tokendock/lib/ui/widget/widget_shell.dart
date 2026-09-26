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
/// The widget's own width, measured **before** [WidgetShell]'s padding.
///
/// The density breakpoints (`< 330` compact, `330..550` normal, `> 550`
/// expanded) are specified against the visible width of the widget. Reading
/// them from a `LayoutBuilder` *inside* the 16px-per-side padding instead
/// double-counts the padding: the shipped 360px window measured 328px, fell
/// under the 330 threshold, and therefore rendered the compact density — the
/// least informative layout — permanently, at every window size the app
/// actually uses.
///
/// [of] falls back to the `MediaQuery` width when there is no shell above, so a
/// standalone pump still resolves to something sensible.
class WidgetShellExtent extends InheritedWidget {
  const WidgetShellExtent({
    super.key,
    required this.width,
    required super.child,
  });

  final double width;

  static double of(BuildContext context) {
    final extent = context
        .dependOnInheritedWidgetOfExactType<WidgetShellExtent>();
    if (extent != null) return extent.width;
    final media = MediaQuery.maybeOf(context);
    return media?.size.width ?? 360;
  }

  @override
  bool updateShouldNotify(WidgetShellExtent oldWidget) =>
      oldWidget.width != width;
}

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
        // Captured **outside** the padding, because the density breakpoints are
        // specified against the widget's own width. See [WidgetShellExtent].
        child: LayoutBuilder(
          builder: (BuildContext outerContext, BoxConstraints outer) {
            return WidgetShellExtent(
              width: outer.maxWidth,
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

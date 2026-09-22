import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// Flat linear quota meter. Pure bar, no numbers.
///
/// A null [percent] renders zero fill and no percentage text so the adjacent
/// textual quota values in [QuotaRow] stay authoritative. Finite values are
/// clamped to a bounded 0–100 fill.
class QuotaBar extends StatelessWidget {
  const QuotaBar({super.key, required this.percent});

  final double? percent;

  @override
  Widget build(BuildContext context) {
    final colors = TokenDockTheme.colorsOf(context);
    final double clamped = percent == null
        ? 0
        : (percent! / 100).clamp(0.0, 1.0).toDouble();
    return Semantics(
      label: percent == null
          ? 'Quota usage unknown'
          : 'Quota usage ${(clamped * 100).round()} percent',
      value: percent == null ? null : '${(clamped * 100).round()}%',
      child: ExcludeSemantics(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(TokenDockRadii.pill),
          child: Container(
            height: 6,
            color: colors.mutedSurface,
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: clamped,
              child: Container(color: colors.statusNormal),
            ),
          ),
        ),
      ),
    );
  }
}

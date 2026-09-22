import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../models/quota.dart';
import 'quota_bar.dart';

/// One labelled quota with authoritative textual values and a flat meter.
///
/// The text line (`remaining/limit unit`) is the source of truth: when
/// [quota] has no numbers it reads `Unavailable`, and the sibling [QuotaBar]
/// deliberately shows zero fill with no percentage. Figures use tabular
/// numerals.
class QuotaRow extends StatelessWidget {
  const QuotaRow({super.key, required this.quota});

  final Quota quota;

  /// Authoritative textual rendering of the remaining/limit pair.
  static String valueTextOf(Quota quota) {
    if (quota.remaining == null || quota.limit == null) {
      return 'Unavailable';
    }
    final unit =
        quota.unit == null || quota.unit!.isEmpty ? '' : ' ${quota.unit}';
    return '${_number(quota.remaining!)}/${_number(quota.limit!)}$unit';
  }

  static String _number(double value) {
    return value == value.truncateToDouble()
        ? value.truncate().toString()
        : value.toString();
  }

  @override
  Widget build(BuildContext context) {
    final colors = TokenDockTheme.colorsOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                quota.label,
                style: TokenDockTypography.bodyStyle(color: colors.ink),
              ),
            ),
            Text(
              valueTextOf(quota),
              style: TokenDockTypography.quotaStyle(color: colors.mutedInk),
            ),
          ],
        ),
        const SizedBox(height: TokenDockSpacing.s8),
        QuotaBar(percent: quota.percent),
      ],
    );
  }
}

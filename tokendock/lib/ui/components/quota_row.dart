import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../models/quota.dart';
import 'quota_bar.dart';

/// One labelled quota with authoritative textual values and a flat meter.
///
/// The text line (`remaining/limit unit`) is the source of truth: when
/// [quota] has no cap it reads `No key cap`, and the sibling [QuotaBar]
/// deliberately shows zero fill with no percentage. Figures use tabular
/// numerals.
class QuotaRow extends StatelessWidget {
  const QuotaRow({super.key, required this.quota});

  final Quota quota;

  /// The value shown on the right of the row.
  ///
  /// Three shapes, because providers report three different things and
  /// collapsing them loses information:
  ///
  /// - **A percentage** reads `88% used`. It previously read `88/100 %` from
  ///   the `remaining/limit` pair, which is redundant — a percent quota's limit
  ///   is always 100 — and ambiguous enough to be read as "88% *left*", the
  ///   opposite of the truth. A full quota read `100/100 %`, which reads as
  ///   "100% used" on a connection that has used nothing.
  /// - **An absolute meter** keeps `5.25/10.5 USD`. The pair is informative
  ///   there, and a zero against a real limit is a meaningful exhausted state
  ///   that must not be confused with the absence of a cap.
  /// - **No cap** reads `No key cap`. Audit C-31 kept this distinct from
  ///   `Unavailable`, which is the wording for a real failure, so a key with no
  ///   ceiling does not read as broken. It is no longer placed in the value
  ///   position: an absence must not occupy the largest type on the card while
  ///   real figures compete with it.
  static String valueTextOf(Quota quota) {
    if (isPercentage(quota)) {
      final used = (quota.percent ?? 0).clamp(0.0, 100.0).toDouble();
      return '${used.round()}% used';
    }
    // A limit of zero is how a provider reports "no quota configured", which is
    // the same situation as an absent one. Rendering it numerically produced
    // "5/0 USD", which no user can interpret. A zero *remaining* against a real
    // limit is a meaningful exhausted state and stays numeric.
    if (quota.remaining == null || quota.limit == null || quota.limit == 0) {
      return 'No key cap';
    }
    final unit = quota.unit == null || quota.unit!.isEmpty
        ? ''
        : ' ${quota.unit}';
    return '${_number(quota.remaining!)}/${_number(quota.limit!)}$unit';
  }

  /// Whether [quota] is a percentage meter rather than an absolute one.
  ///
  /// Keyed on the unit, not on `limit == 100`. An absolute quota can
  /// legitimately total 100 — 100 credits, 100 requests — and keying on the
  /// value would turn a real balance into a "100% used" warning.
  static bool isPercentage(Quota quota) => quota.unit == '%';

  /// Whether [quota] has no cap at all, and so has no figure worth leading with.
  static bool hasNoCap(Quota quota) =>
      !isPercentage(quota) &&
      (quota.remaining == null || quota.limit == null || quota.limit == 0);

  static String _number(double value) {
    return value == value.truncateToDouble()
        ? value.truncate().toString()
        : value.toString();
  }

  @override
  Widget build(BuildContext context) {
    final colors = TokenDockTheme.colorsOf(context);
    final uncapped = hasNoCap(quota);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Text(
                quota.label,
                style: TokenDockTypography.bodyStyle(color: colors.ink),
              ),
            ),
            const SizedBox(width: TokenDockSpacing.s8),
            // `Flexible`, not a bare `Text`. The authoritative value must not be
            // truncated, so it wraps onto a second line rather than overflowing:
            // a wide absolute meter such as `12345.5/100000 requests` is
            // legitimately wider than a 360px window, and an unconstrained Text
            // drew a 140px overflow stripe. This only became reachable when the
            // default window stopped falling into the compact density.
            if (!uncapped)
              Flexible(
                child: Text(
                  valueTextOf(quota),
                  textAlign: TextAlign.end,
                  style: TokenDockTypography.quotaStyle(color: colors.ink),
                ),
              ),
          ],
        ),
        const SizedBox(height: TokenDockSpacing.s8),
        // A null percent is *unknown*, not zero, so an uncapped or unreported
        // meter must not render as an empty track that reads as "used nothing".
        if (!uncapped) QuotaBar(percent: quota.percent),
        if (uncapped)
          Text(
            valueTextOf(quota),
            style: TokenDockTypography.metadataStyle(color: colors.mutedInk),
          ),
      ],
    );
  }
}

import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// Remaining-time label for a quota `resetAt`.
///
/// UTC timestamps are converted to local time before the remaining duration
/// is computed. A null [resetAt] renders nothing; a past (or exactly elapsed)
/// [resetAt] renders `Resetting…`; a future one renders a short countdown
/// such as `Resets in 2h 15m` or `Resets in 45m` with tabular figures.
///
/// An optional [now] clock override keeps widget tests deterministic.
class CountdownText extends StatelessWidget {
  const CountdownText({super.key, required this.resetAt, this.now});

  final DateTime? resetAt;
  final DateTime Function()? now;

  /// Short human countdown for [remaining], e.g. `Resets in 2h 15m`.
  static String formatRemaining(Duration remaining) {
    final int minutes = remaining.inMinutes;
    final int hours = minutes ~/ 60;
    final int days = hours ~/ 24;
    if (days > 0) {
      final int restHours = hours % 24;
      return restHours == 0
          ? 'Resets in ${days}d'
          : 'Resets in ${days}d ${restHours}h';
    }
    if (hours > 0) {
      final int restMinutes = minutes % 60;
      return restMinutes == 0
          ? 'Resets in ${hours}h'
          : 'Resets in ${hours}h ${restMinutes}m';
    }
    if (minutes > 0) {
      return 'Resets in ${minutes}m';
    }
    return 'Resets in <1m';
  }

  @override
  Widget build(BuildContext context) {
    final DateTime? reset = resetAt;
    if (reset == null) {
      return const SizedBox.shrink();
    }
    final DateTime current = now != null ? now!() : DateTime.now();
    final Duration remaining = reset.toLocal().difference(current);
    if (remaining <= Duration.zero) {
      return Text(
        'Resetting…',
        style: TokenDockTypography.quotaStyle(
          color: TokenDockTheme.colorsOf(context).mutedInk,
        ),
      );
    }
    return Text(
      formatRemaining(remaining),
      style: TokenDockTypography.quotaStyle(
        color: TokenDockTheme.colorsOf(context).mutedInk,
      ),
    );
  }
}

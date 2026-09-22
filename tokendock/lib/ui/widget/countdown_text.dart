import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// Remaining-time label for a quota `resetAt`.
///
/// UTC timestamps are converted to local time before the remaining duration
/// is computed. A null [resetAt] renders nothing; a past (or exactly elapsed)
/// [resetAt] renders `Resetting…`; a future one renders a short countdown
/// such as `Resets in 2h 15m` or `Resets in 45m` with tabular figures.
///
/// Automatically updates via a local periodic timer without network calls.
/// An optional [now] clock override keeps widget tests deterministic.
class CountdownText extends StatefulWidget {
  const CountdownText({
    super.key,
    required this.resetAt,
    this.now,
    this.tickInterval = const Duration(seconds: 1),
  });

  final DateTime? resetAt;
  final DateTime Function()? now;
  final Duration tickInterval;

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
  State<CountdownText> createState() => _CountdownTextState();
}

class _CountdownTextState extends State<CountdownText> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void didUpdateWidget(CountdownText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resetAt != widget.resetAt ||
        oldWidget.tickInterval != widget.tickInterval) {
      _startTimer();
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = null;
    final reset = widget.resetAt;
    if (reset == null) return;

    final current = widget.now != null ? widget.now!() : DateTime.now();
    final remaining = reset.toLocal().difference(current);
    if (remaining <= Duration.zero) {
      return;
    }

    _timer = Timer.periodic(widget.tickInterval, (_) {
      if (!mounted) return;
      setState(() {});
      final updatedNow = widget.now != null ? widget.now!() : DateTime.now();
      if (reset.toLocal().difference(updatedNow) <= Duration.zero) {
        _timer?.cancel();
        _timer = null;
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final DateTime? reset = widget.resetAt;
    if (reset == null) {
      return const SizedBox.shrink();
    }
    final DateTime current =
        widget.now != null ? widget.now!() : DateTime.now();
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
      CountdownText.formatRemaining(remaining),
      style: TokenDockTypography.quotaStyle(
        color: TokenDockTheme.colorsOf(context).mutedInk,
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// `Last updated <relative age>` that keeps counting while the widget sits idle.
///
/// The age label must reflect real elapsed time, not the value of
/// `DateTime.now()` on the first frame. [TokenDockWidget.formatRelativeAge] is
/// a pure function, so without a timer driving a rebuild the label froze for
/// as long as nothing else rebuilt the tree, which on a manual refresh interval
/// or a persistently failing provider meant showing "just now" indefinitely.
class RelativeAgeText extends StatefulWidget {
  const RelativeAgeText({
    super.key,
    required this.since,
    this.tickInterval = const Duration(seconds: 30),
    this.now,
  });

  /// Timestamp the age is measured from.
  final DateTime since;

  /// How often to re-evaluate. The label only has minute granularity, so a
  /// sub-minute tick would burn rebuilds for no visible change.
  final Duration tickInterval;

  /// Clock override for deterministic tests.
  final DateTime Function()? now;

  /// Human relative age for [dateTime], e.g. `just now`, `5m ago`, `2h ago`.
  ///
  /// A timestamp in the future, from clock skew or a bad provider value, reads
  /// as `just now` rather than a negative age.
  static String format(DateTime dateTime, {DateTime? now}) {
    final current = now ?? DateTime.now();
    final diff = current.difference(dateTime);
    if (diff.isNegative || diff.inSeconds < 60) {
      return 'just now';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    } else if (diff.inHours < 24) {
      return '${diff.inHours}h ago';
    } else {
      return '${diff.inDays}d ago';
    }
  }

  @override
  State<RelativeAgeText> createState() => _RelativeAgeTextState();
}

class _RelativeAgeTextState extends State<RelativeAgeText> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(RelativeAgeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.since != widget.since ||
        oldWidget.tickInterval != widget.tickInterval ||
        oldWidget.now != widget.now) {
      _start();
    }
  }

  void _start() {
    _timer?.cancel();
    _timer = null;
    _timer = Timer.periodic(widget.tickInterval, (_) {
      if (mounted) setState(() {});
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
    final now = widget.now != null ? widget.now!() : DateTime.now();
    return Text(
      'Last updated ${RelativeAgeText.format(widget.since, now: now)}',
      style: TokenDockTypography.metadataStyle(
        color: TokenDockTheme.colorsOf(context).mutedInk,
      ),
    );
  }
}

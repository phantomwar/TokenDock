import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../models/connection_status.dart';

/// Connection state rendered as glyph plus text.
///
/// Color is never the only signal: every [ConnectionStatus] maps to a
/// distinct user-facing label and icon, and the widget exposes the same
/// label as its semantic label.
class StatusIndicator extends StatelessWidget {
  const StatusIndicator({super.key, required this.status});

  final ConnectionStatus status;

  /// User-facing label for [status]. `limited` always reads `Limited`.
  static String labelOf(ConnectionStatus status) {
    return switch (status) {
      ConnectionStatus.ok => 'Connected',
      ConnectionStatus.warning => 'Degraded',
      ConnectionStatus.limited => 'Limited',
      ConnectionStatus.authError => 'Auth error',
      ConnectionStatus.error => 'Unavailable',
      ConnectionStatus.updating => 'Updating',
    };
  }

  static IconData iconOf(ConnectionStatus status) {
    return switch (status) {
      ConnectionStatus.ok => Icons.check_circle_outline,
      ConnectionStatus.warning => Icons.warning_amber_outlined,
      ConnectionStatus.limited => Icons.pause_circle_outline,
      ConnectionStatus.authError => Icons.lock_outline,
      ConnectionStatus.error => Icons.error_outline,
      ConnectionStatus.updating => Icons.sync_outlined,
    };
  }

  static Color colorOf(BuildContext context, ConnectionStatus status) {
    final colors = TokenDockTheme.colorsOf(context);
    return switch (status) {
      ConnectionStatus.ok => colors.statusOk,
      ConnectionStatus.warning => colors.statusWarning,
      ConnectionStatus.limited => colors.statusLimited,
      ConnectionStatus.authError => colors.statusLimited,
      ConnectionStatus.error => colors.statusLimited,
      ConnectionStatus.updating => colors.statusUpdating,
    };
  }

  @override
  Widget build(BuildContext context) {
    final label = labelOf(status);
    final color = colorOf(context, status);
    return Semantics(
      label: label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(iconOf(status), size: 16, color: color),
          const SizedBox(width: TokenDockSpacing.s4),
          Text(
            label,
            style: TokenDockTypography.captionStyle(color: color),
          ),
        ],
      ),
    );
  }
}

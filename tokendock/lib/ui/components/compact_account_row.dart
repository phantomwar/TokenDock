import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../models/connection.dart';
import '../../models/connection_status.dart';
import 'provider_icon.dart';
import 'status_indicator.dart';

/// Single-line account summary for dense lists.
///
/// Flat content row: monogram, display name, and status. No card chrome,
/// no interaction; the parent decides selection and layout.
class CompactAccountRow extends StatelessWidget {
  const CompactAccountRow({
    super.key,
    required this.connection,
    required this.status,
  });

  final Connection connection;
  final ConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = TokenDockTheme.colorsOf(context);
    return Row(
      children: <Widget>[
        ProviderIcon(provider: connection.provider),
        const SizedBox(width: TokenDockSpacing.s8),
        Expanded(
          child: Text(
            connection.displayName,
            style: TokenDockTypography.bodyStyle(color: colors.ink),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        StatusIndicator(status: status),
      ],
    );
  }
}

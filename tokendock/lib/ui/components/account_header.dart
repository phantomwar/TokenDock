import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../models/connection.dart';
import 'provider_icon.dart';
import 'status_indicator.dart';
import '../../models/connection_status.dart';

/// Account identity header: icon, display name, plan, and live status.
///
/// Content primitive that composes inside [AppCard]; carries no card chrome
/// of its own. Reuses [Connection] display values without duplicating them.
class AccountHeader extends StatelessWidget {
  const AccountHeader({
    super.key,
    required this.connection,
    required this.status,
  });

  final Connection connection;
  final ConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = TokenDockTheme.colorsOf(context);
    final plan = connection.plan;
    return Row(
      children: <Widget>[
        ProviderIcon(provider: connection.provider),
        const SizedBox(width: TokenDockSpacing.s12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                connection.displayName,
                style: TokenDockTypography.titleStyle(color: colors.ink),
              ),
              if (plan != null && plan.isNotEmpty)
                Text(
                  plan,
                  style:
                      TokenDockTypography.captionStyle(color: colors.mutedInk),
                ),
            ],
          ),
        ),
        StatusIndicator(status: status),
      ],
    );
  }
}

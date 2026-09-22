import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../models/connection_status.dart';
import '../components/account_header.dart';
import '../components/compact_account_row.dart';
import '../components/quota_row.dart';
import '../components/status_indicator.dart';
import '../settings/connections_screen.dart';
import 'countdown_text.dart';
import 'widget_shell.dart';

/// Responsive mock widget surface with first-run states.
///
/// Density is selected exclusively from the available width via
/// [LayoutBuilder]: `< 330px` compact, `330px .. 550px` normal, `> 550px`
/// expanded. Composes only Task 3 primitives and Task 2 models; accounts are
/// grouped with thin dividers inside [WidgetShell] (no nested floating
/// cards).
class TokenDockWidget extends StatelessWidget {
  const TokenDockWidget({
    super.key,
    required this.state,
    this.onAddConnection,
    this.onOpenConnections,
    this.onRefreshAll,
  });

  const TokenDockWidget.loading({
    super.key,
    this.onAddConnection,
    this.onOpenConnections,
    this.onRefreshAll,
  }) : state = const AppState.loading();

  const TokenDockWidget.empty({
    super.key,
    this.onAddConnection,
    this.onOpenConnections,
    this.onRefreshAll,
  }) : state = const AppState.empty();

  TokenDockWidget.loaded({
    super.key,
    required List<AccountItem> accounts,
    this.onAddConnection,
    this.onOpenConnections,
    this.onRefreshAll,
  }) : state = AppState(accounts: accounts);

  final AppState state;
  final VoidCallback? onAddConnection;
  final VoidCallback? onOpenConnections;
  final VoidCallback? onRefreshAll;

  /// Formats relative age for a timestamp, e.g. `just now`, `5m ago`, `2h ago`.
  static String formatRelativeAge(DateTime dateTime, {DateTime? now}) {
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

  void _openConnections(BuildContext context) {
    if (onOpenConnections != null) {
      onOpenConnections!();
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ConnectionsScreen(appState: state),
      ),
    );
  }

  void _handleAddConnection(BuildContext context) {
    if (onAddConnection != null) {
      onAddConnection!();
      return;
    }
    _openConnections(context);
  }

  Widget? _buildHeaderActions(BuildContext context) {
    if (state.isLoading || state.accounts.isEmpty) {
      return null;
    }
    final colors = TokenDockTheme.colorsOf(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        IconButton(
          key: const Key('headerRefreshButton'),
          icon: Icon(Icons.refresh, size: 18, color: colors.mutedInk),
          tooltip: 'Refresh All',
          onPressed: () {
            if (onRefreshAll != null) {
              onRefreshAll!();
            } else {
              state.refreshAll();
            }
          },
        ),
        IconButton(
          key: const Key('headerSettingsButton'),
          icon: Icon(Icons.settings_outlined, size: 18, color: colors.mutedInk),
          tooltip: 'Connections',
          onPressed: () => _openConnections(context),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: WidgetShell(
        actions: _buildHeaderActions(context),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            if (state.isLoading) {
              return _buildLoading(context);
            }
            if (state.accounts.isEmpty) {
              return _buildEmpty(context);
            }
            final double width = constraints.maxWidth;
            if (width < 330) {
              return _buildCompact(context, state.accounts);
            }
            if (width <= 550) {
              return _buildNormal(context, state.accounts);
            }
            return _buildExpanded(context, state.accounts);
          },
        ),
      ),
    );
  }

  /// Loading state: three neutral skeleton rows; no [CompactAccountRow].
  Widget _buildLoading(BuildContext context) {
    final colors = TokenDockTheme.colorsOf(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < 3; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: TokenDockSpacing.s8),
          Semantics(
            label: 'Loading account',
            child: Container(
              key: ValueKey<String>('skeleton-$i'),
              height: 56,
              decoration: BoxDecoration(
                color: colors.mutedSurface,
                borderRadius:
                    BorderRadius.circular(TokenDockRadii.r12),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// First-run empty state with an `Add Connection` action.
  Widget _buildEmpty(BuildContext context) {
    final colors = TokenDockTheme.colorsOf(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          'No connections yet',
          style: TokenDockTypography.bodyStyle(color: colors.mutedInk),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: TokenDockSpacing.s12),
        FilledButton(
          key: const Key('addConnectionButton'),
          onPressed: () => _handleAddConnection(context),
          child: const Text('Add Connection'),
        ),
      ],
    );
  }

  /// Compact density: one dense row per account plus primary quota text.
  Widget _buildCompact(BuildContext context, List<AccountItem> accounts) {
    final colors = TokenDockTheme.colorsOf(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < accounts.length; i++) ...<Widget>[
          if (i > 0)
            Divider(color: colors.hairline, height: TokenDockSpacing.s24),
          Focus(
            child: Semantics(
              label:
                  '${accounts[i].connection.displayName}, ${StatusIndicator.labelOf(accounts[i].snapshot.status)}',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  CompactAccountRow(
                    connection: accounts[i].connection,
                    status: accounts[i].snapshot.status,
                  ),
                  if (accounts[i].snapshot.quotas.isNotEmpty) ...<Widget>[
                    const SizedBox(height: TokenDockSpacing.s4),
                    Text(
                      QuotaRow.valueTextOf(accounts[i].snapshot.quotas.first),
                      style:
                          TokenDockTypography.quotaStyle(color: colors.mutedInk),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Normal density: account header plus the primary quota row.
  Widget _buildNormal(BuildContext context, List<AccountItem> accounts) {
    final colors = TokenDockTheme.colorsOf(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < accounts.length; i++) ...<Widget>[
          if (i > 0)
            Divider(color: colors.hairline, height: TokenDockSpacing.s24),
          Focus(
            child: Semantics(
              label:
                  '${accounts[i].connection.displayName}, ${StatusIndicator.labelOf(accounts[i].snapshot.status)}',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AccountHeader(
                    connection: accounts[i].connection,
                    status: accounts[i].snapshot.status,
                  ),
                  if (accounts[i].snapshot.quotas.isNotEmpty) ...<Widget>[
                    const SizedBox(height: TokenDockSpacing.s8),
                    QuotaRow(quota: accounts[i].snapshot.quotas.first),
                    if (accounts[i].snapshot.quotas.first.resetAt !=
                        null) ...<Widget>[
                      const SizedBox(height: TokenDockSpacing.s4),
                      CountdownText(
                        resetAt: accounts[i].snapshot.quotas.first.resetAt,
                      ),
                    ],
                  ],
                  if (accounts[i].snapshot.error != null &&
                      accounts[i].snapshot.error!.isNotEmpty) ...<Widget>[
                    const SizedBox(height: TokenDockSpacing.s4),
                    Text(
                      accounts[i].snapshot.error!,
                      style: TokenDockTypography.captionStyle(
                        color: colors.statusLimited,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Expanded density: every quota, plan, refresh time, and error/stale text.
  Widget _buildExpanded(BuildContext context, List<AccountItem> accounts) {
    final colors = TokenDockTheme.colorsOf(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int i = 0; i < accounts.length; i++) ...<Widget>[
          if (i > 0)
            Divider(color: colors.hairline, height: TokenDockSpacing.s24),
          Focus(
            child: Semantics(
              label:
                  '${accounts[i].connection.displayName}, ${StatusIndicator.labelOf(accounts[i].snapshot.status)}',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AccountHeader(
                    connection: accounts[i].connection,
                    status: accounts[i].snapshot.status,
                  ),
                  for (final quota in accounts[i].snapshot.quotas) ...<Widget>[
                    const SizedBox(height: TokenDockSpacing.s8),
                    QuotaRow(quota: quota),
                    if (quota.resetAt != null) ...<Widget>[
                      const SizedBox(height: TokenDockSpacing.s4),
                      CountdownText(resetAt: quota.resetAt),
                    ],
                  ],
                  const SizedBox(height: TokenDockSpacing.s8),
                  Text(
                    'Last updated ${formatRelativeAge(accounts[i].snapshot.fetchedAt)}',
                    style:
                        TokenDockTypography.captionStyle(color: colors.mutedInk),
                  ),
                  if (accounts[i].snapshot.error != null &&
                      accounts[i].snapshot.error!.isNotEmpty) ...<Widget>[
                    const SizedBox(height: TokenDockSpacing.s4),
                    Text(
                      accounts[i].snapshot.error!,
                      style: TokenDockTypography.captionStyle(
                        color: colors.statusLimited,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

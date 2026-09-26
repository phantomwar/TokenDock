import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../components/account_header.dart';
import '../components/compact_account_row.dart';
import '../components/quota_row.dart';
import '../components/status_indicator.dart';
import '../settings/connections_screen.dart';
import 'countdown_text.dart';
import 'relative_age_text.dart';
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

  // Not `const`: `state` is a real `ChangeNotifier` now, and a canonicalised
  // AppState would be one shared object across every loading shell (C-24).
  TokenDockWidget.loading({
    super.key,
    this.onAddConnection,
    this.onOpenConnections,
    this.onRefreshAll,
  }) : state = AppState.loading();

  TokenDockWidget.empty({
    super.key,
    this.onAddConnection,
    this.onOpenConnections,
    this.onRefreshAll,
  }) : state = AppState.empty();

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

  /// Relative cache-age formatting, e.g. `just now`, `5m ago`, `2h ago`.
  ///
  /// Kept as a forwarder so existing callers and tests keep a stable entry
  /// point; the ticking label itself lives in [RelativeAgeText].
  static String formatRelativeAge(DateTime dateTime, {DateTime? now}) =>
      RelativeAgeText.format(dateTime, now: now);

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
        Semantics(
          label: 'Refresh All',
          button: true,
          child: IconButton(
            key: const Key('headerRefreshButton'),
            icon: Icon(Icons.refresh, size: 18, color: colors.mutedInk),
            onPressed: () {
              if (onRefreshAll != null) {
                onRefreshAll!();
              } else {
                state.refreshAll();
              }
            },
          ),
        ),
        Semantics(
          label: 'Connections',
          button: true,
          child: IconButton(
            key: const Key('headerSettingsButton'),
            icon: Icon(
              Icons.settings_outlined,
              size: 18,
              color: colors.mutedInk,
            ),
            onPressed: () => _openConnections(context),
          ),
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
            final Widget content;
            final double width = constraints.maxWidth;
            if (width < 330) {
              content = _buildCompact(context, state.accounts);
            } else if (width <= 550) {
              content = _buildNormal(context, state.accounts);
            } else {
              content = _buildExpanded(context, state.accounts);
            }
            return SingleChildScrollView(
              key: const Key('tokenDockAccountScroll'),
              child: content,
            );
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
                borderRadius: BorderRadius.circular(TokenDockRadii.r12),
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

  /// The frame every density shares: inter-account divider, keyboard focus
  /// ring, the account's accessibility label, the cache age, and the error.
  ///
  /// Audit C-22: these were re-implemented three times, and the copies had
  /// already drifted — compact had dropped the error line, so a failing
  /// account showed a stale quota number in the default density with no
  /// visible reason while the other two explained themselves. Nothing
  /// asserted the asymmetry, so it read as intent.
  ///
  /// [body] renders the part that genuinely differs per density, and must end
  /// with its own trailing gap, because that gap differs: expanded separates
  /// the footer further because it stacks every quota above it.
  Widget _buildAccounts(
    BuildContext context,
    List<AccountItem> accounts,
    Widget Function(AccountItem account) body,
  ) {
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
                  body(accounts[i]),
                  RelativeAgeText(since: accounts[i].snapshot.fetchedAt),
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

  /// Compact density: one dense row per account plus primary quota text.
  Widget _buildCompact(BuildContext context, List<AccountItem> accounts) {
    final colors = TokenDockTheme.colorsOf(context);
    return _buildAccounts(context, accounts, (account) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CompactAccountRow(
            connection: account.connection,
            status: account.snapshot.status,
          ),
          if (account.snapshot.quotas.isNotEmpty) ...<Widget>[
            const SizedBox(height: TokenDockSpacing.s4),
            Text(
              QuotaRow.valueTextOf(account.snapshot.quotas.first),
              style: TokenDockTypography.quotaStyle(color: colors.ink),
            ),
          ],
          const SizedBox(height: TokenDockSpacing.s4),
        ],
      );
    });
  }

  /// Normal density: account header plus the primary quota row.
  Widget _buildNormal(BuildContext context, List<AccountItem> accounts) {
    return _buildAccounts(context, accounts, (account) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AccountHeader(
            connection: account.connection,
            status: account.snapshot.status,
          ),
          if (account.snapshot.quotas.isNotEmpty) ...<Widget>[
            const SizedBox(height: TokenDockSpacing.s8),
            QuotaRow(quota: account.snapshot.quotas.first),
            if (account.snapshot.quotas.first.resetAt != null) ...<Widget>[
              const SizedBox(height: TokenDockSpacing.s4),
              CountdownText(resetAt: account.snapshot.quotas.first.resetAt),
            ],
          ],
          const SizedBox(height: TokenDockSpacing.s4),
        ],
      );
    });
  }

  /// Expanded density: every quota, plan, refresh time, and error/stale text.
  Widget _buildExpanded(BuildContext context, List<AccountItem> accounts) {
    return _buildAccounts(context, accounts, (account) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AccountHeader(
            connection: account.connection,
            status: account.snapshot.status,
          ),
          for (final quota in account.snapshot.quotas) ...<Widget>[
            const SizedBox(height: TokenDockSpacing.s8),
            QuotaRow(quota: quota),
            if (quota.resetAt != null) ...<Widget>[
              const SizedBox(height: TokenDockSpacing.s4),
              CountdownText(resetAt: quota.resetAt),
            ],
          ],
          const SizedBox(height: TokenDockSpacing.s8),
        ],
      );
    });
  }
}

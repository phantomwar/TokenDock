import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../models/quota.dart';
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
    this.onExitApp,
  });

  // Not `const`: `state` is a real `ChangeNotifier` now, and a canonicalised
  // AppState would be one shared object across every loading shell (C-24).
  TokenDockWidget.loading({
    super.key,
    this.onAddConnection,
    this.onOpenConnections,
    this.onRefreshAll,
    this.onExitApp,
  }) : state = AppState.loading();

  TokenDockWidget.empty({
    super.key,
    this.onAddConnection,
    this.onOpenConnections,
    this.onRefreshAll,
    this.onExitApp,
  }) : state = AppState.empty();

  TokenDockWidget.loaded({
    super.key,
    required List<AccountItem> accounts,
    this.onAddConnection,
    this.onOpenConnections,
    this.onRefreshAll,
    this.onExitApp,
  }) : state = AppState(accounts: accounts);

  final AppState state;
  final VoidCallback? onAddConnection;
  final VoidCallback? onOpenConnections;
  final VoidCallback? onRefreshAll;

  /// Finalises the program.
  ///
  /// Deliberately *not* hide-to-tray. The native close already hides to tray
  /// (PRD 10), so a button that merely hid the window would close the *window*
  /// and leave the program running with nothing on screen to say so, which is
  /// the opposite of what a close button is for. This is the tray's `Exit`
  /// (PRD 11), surfaced where a user can actually find it.
  ///
  /// Async because the real exit disposes the tray icon before destroying the
  /// native window, and that order matters.
  final Future<void> Function()? onExitApp;

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

  /// The window's close affordance.
  ///
  /// The window is frameless (`TitleBarStyle.hidden` in `main`), so the native
  /// title bar's close button does not exist. PRD 10 specifies a close button
  /// and PRD 11 specifies a tray `Exit`; the first had nothing to attach itself
  /// to, so the only way out was a right-click on a tray icon. The app looked
  /// like a dashboard with no off switch.
  ///
  /// Quits, rather than hiding to the tray. Hiding is what the native close
  /// already does, and doing it here too would mean the button closed the window
  /// while the program carried on running headless — the one outcome a close
  /// button must never produce.
  static const String closeLabel = 'Close TokenDock';

  Widget? _buildHeaderActions(BuildContext context) {
    final colors = TokenDockTheme.colorsOf(context);
    final bool hasAccounts = !state.isLoading && state.accounts.isNotEmpty;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // Refresh and settings stay gated on there being something to act on:
        // with no connections there is nothing to refresh and nowhere to
        // configure, and offering them anyway is two dead controls.
        if (hasAccounts) ...<Widget>[
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
        // Unconditional, and last.
        //
        // Unconditional because the gate above used to cover the whole header,
        // which left a first-run user with no connections and no loading state
        // with *no* header actions at all: on a frameless always-on-top window,
        // that is a widget with no way to close it except the tray.
        //
        // Last because refresh is the most-pressed button here and this one ends
        // the process. Windows puts close at the far right for the same reason.
        Semantics(
          label: closeLabel,
          button: true,
          // No Tooltip, matching the two actions above it. A `Tooltip` needs an
          // Overlay ancestor, and the header is deliberately the one piece of
          // the widget that still works in a bare standalone pump; adding one
          // here broke every test that mounts `TokenDockWidget` on its own. The
          // semantics label is the part that actually matters — it is what a
          // screen reader announces — and it needs no overlay.
          child: IconButton(
            key: const Key('headerCloseButton'),
            icon: Icon(Icons.close, size: 18, color: colors.mutedInk),
            onPressed: () {
              final exit = onExitApp;
              if (exit == null) return;
              unawaited(exit());
            },
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
        child: Builder(
          // Built once, outside the shell's padding, so the density is chosen
          // from the widget's own width rather than the padded content width.
          // See [WidgetShellExtent] for why that distinction is the whole
          // difference between the shipped 360px window showing quotas and
          // showing one line per account.
          builder: (BuildContext context) {
            if (state.isLoading) {
              return _buildLoading(context);
            }
            if (state.accounts.isEmpty) {
              return _buildEmpty(context);
            }
            final Widget content;
            final double width = WidgetShellExtent.of(context);
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
                  // Every account is refreshed in the same cycle, so three
                  // identical "just now" lines are one fact written three
                  // times. Stated on the first account only; the value is the
                  // same for all of them, and the age keeps ticking either way.
                  if (i == 0)
                    RelativeAgeText(since: accounts[i].snapshot.fetchedAt),
                  if (accounts[i].snapshot.error != null &&
                      accounts[i].snapshot.error!.isNotEmpty) ...<Widget>[
                    const SizedBox(height: TokenDockSpacing.s4),
                    Text(
                      accounts[i].snapshot.error!,
                      style: TokenDockTypography.metadataStyle(
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

  /// Normal density: account header plus every quota window.
  ///
  /// This renders **all** windows, not just the first. The window is 360px,
  /// which is the normal density, so `quotas.first` was the whole quota
  /// display: OpenCode Go's three windows, MiniMax's two and z.ai's three were
  /// each reduced to one row, and the window that was actually running out was
  /// usually not that one. The product question is "which of my subscriptions
  /// still has limit?", and answering it needs the windows, not a sample.
  ///
  /// Ordered most-exhausted first, so the binding constraint is findable
  /// without reading every row. See [orderedByUrgency].
  Widget _buildNormal(BuildContext context, List<AccountItem> accounts) {
    return _buildAccounts(context, accounts, (account) {
      final quotas = orderedByUrgency(account.snapshot.quotas);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AccountHeader(
            connection: account.connection,
            status: account.snapshot.status,
          ),
          for (final quota in quotas) ...<Widget>[
            const SizedBox(height: TokenDockSpacing.s8),
            QuotaRow(quota: quota),
            if (quota.resetAt != null) ...<Widget>[
              const SizedBox(height: TokenDockSpacing.s4),
              CountdownText(resetAt: quota.resetAt),
            ],
          ],
          const SizedBox(height: TokenDockSpacing.s4),
        ],
      );
    });
  }

  /// [quotas] with the most-exhausted window first.
  ///
  /// Stable for equal percentages, so a provider's own ordering is preserved
  /// rather than reshuffled on every refresh — a list that reorders itself is
  /// unreadable to someone tracking a specific window.
  ///
  /// A quota with no percentage sorts last: it is unknown, not healthy, and
  /// putting it first would imply a worse state than the data supports.
  static List<Quota> orderedByUrgency(List<Quota> quotas) {
    final known = quotas.where((q) => q.percent != null).toList()
      ..sort((a, b) => (b.percent ?? 0).compareTo(a.percent ?? 0));
    final unknown = quotas.where((q) => q.percent == null);
    return <Quota>[...known, ...unknown];
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
          for (final quota in orderedByUrgency(
            account.snapshot.quotas,
          )) ...<Widget>[
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

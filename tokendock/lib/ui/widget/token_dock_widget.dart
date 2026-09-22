import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../components/account_header.dart';
import '../components/compact_account_row.dart';
import '../components/quota_row.dart';
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
  const TokenDockWidget({super.key, required this.state, this.onAddConnection});

  const TokenDockWidget.loading({super.key, this.onAddConnection})
      : state = const AppState.loading();

  const TokenDockWidget.empty({super.key, this.onAddConnection})
      : state = const AppState.empty();

  const TokenDockWidget.loaded({
    super.key,
    required List<AccountItem> accounts,
    this.onAddConnection,
  }) : state = AppState(accounts: accounts);

  final AppState state;
  final VoidCallback? onAddConnection;

  @override
  Widget build(BuildContext context) {
    return WidgetShell(
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
          onPressed: onAddConnection,
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
          CompactAccountRow(
            connection: accounts[i].connection,
            status: accounts[i].snapshot.status,
          ),
          if (accounts[i].snapshot.quotas.isNotEmpty) ...<Widget>[
            const SizedBox(height: TokenDockSpacing.s4),
            Text(
              QuotaRow.valueTextOf(accounts[i].snapshot.quotas.first),
              style: TokenDockTypography.quotaStyle(color: colors.mutedInk),
            ),
          ],
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
          AccountHeader(
            connection: accounts[i].connection,
            status: accounts[i].snapshot.status,
          ),
          if (accounts[i].snapshot.quotas.isNotEmpty) ...<Widget>[
            const SizedBox(height: TokenDockSpacing.s8),
            QuotaRow(quota: accounts[i].snapshot.quotas.first),
            if (accounts[i].snapshot.quotas.first.resetAt != null) ...<Widget>[
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
            'Updated ${accounts[i].snapshot.fetchedAt.toLocal()}',
            style: TokenDockTypography.captionStyle(color: colors.mutedInk),
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
      ],
    );
  }
}

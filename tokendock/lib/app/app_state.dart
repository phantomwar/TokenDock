import '../models/connection.dart';
import '../models/provider_snapshot.dart';

/// One account pairing a [Connection] with its latest [ProviderSnapshot].
///
/// Immutable value holder for the widget surface. Never performs persistence
/// or network work; later tasks hydrate it from the database and providers.
class AccountItem {
  const AccountItem({required this.connection, required this.snapshot});

  final Connection connection;
  final ProviderSnapshot snapshot;
}

/// Widget-surface state for [TokenDockWidget].
///
/// Pure and immutable: a loading flag plus the loaded account list. The
/// first-run empty state is simply "not loading with no accounts".
class AppState {
  const AppState({this.isLoading = false, this.accounts = const []});

  const AppState.loading() : isLoading = true, accounts = const [];

  const AppState.empty() : isLoading = false, accounts = const [];

  /// True while the initial database open is still in flight.
  final bool isLoading;

  /// Alias kept for call sites that read the open phase as [isOpening].
  bool get isOpening => isLoading;

  final List<AccountItem> accounts;
}

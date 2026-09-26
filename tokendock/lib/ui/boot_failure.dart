import 'package:flutter/material.dart';
import 'package:tokendock/app/theme.dart';

/// Shown when the database cannot be opened or migrated.
///
/// `main` used to `await AppDatabase.open()` unguarded, so a failed migration
/// threw out of `main` before `runApp`: the process died with no window, no
/// message, and no way to retry. The user could not tell a transient file lock
/// from a corrupt database, and could do nothing about either.
///
/// The alternative -- silently falling back to an in-memory database -- was
/// rejected. It would launch, look healthy, and discard every stored connection
/// and credential on exit. A visible failure the user can act on is strictly
/// better than a working-looking app that loses their data.
class BootFailureApp extends StatelessWidget {
  const BootFailureApp({
    super.key,
    required this.onRetry,
    required this.onExit,
  });

  final Future<void> Function() onRetry;
  final Future<void> Function() onExit;

  /// Deliberately not interpolated from a caught error.
  ///
  /// Every user-facing string in this app is a compile-time literal, because a
  /// raw exception can carry SQL, a file path, or a credential fragment, and
  /// this dialog is the last place that data would be visible. The cause is
  /// logged by the caller instead.
  static const String title = 'TokenDock could not start';
  static const String body =
      'The local database could not be opened or upgraded. Nothing has been '
      'changed. If this keeps happening, another copy of TokenDock may be '
      'holding the file, or it may need to be reset from Settings.';
  static const String retryLabel = 'Try again';
  static const String exitLabel = 'Exit';

  @override
  Widget build(BuildContext context) {
    final colors = TokenDockTheme.colorsOf(context);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: TokenDockTheme.lightTheme(),
      darkTheme: TokenDockTheme.darkTheme(),
      highContrastTheme: TokenDockTheme.highContrastTheme(),
      highContrastDarkTheme: TokenDockTheme.highContrastTheme(),
      home: Scaffold(
        backgroundColor: colors.canvas,
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(TokenDockSpacing.s16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Semantics(
                    header: true,
                    child: Text(
                      title,
                      style: TokenDockTypography.sectionHeadingStyle(
                        color: colors.ink,
                      ),
                    ),
                  ),
                  const SizedBox(height: TokenDockSpacing.s8),
                  Text(
                    body,
                    style: TokenDockTypography.bodyStyle(color: colors.ink),
                  ),
                  const SizedBox(height: TokenDockSpacing.s16),
                  Row(
                    children: <Widget>[
                      FilledButton(
                        key: const Key('bootRetryButton'),
                        onPressed: () => onRetry(),
                        child: const Text(retryLabel),
                      ),
                      const SizedBox(width: TokenDockSpacing.s8),
                      OutlinedButton(
                        key: const Key('bootExitButton'),
                        onPressed: () => onExit(),
                        child: const Text(exitLabel),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

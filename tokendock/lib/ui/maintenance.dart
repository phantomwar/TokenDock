/// Runs [open], and on failure produces [surface] instead of letting the error
/// escape.
///
/// This exists because an exception thrown out of `main` before `runApp` kills
/// the process with no window and no message. The caller supplies the failure
/// surface so the decision stays here and the presentation stays in the widget
/// layer.
///
/// The error is handed to [surface] rather than discarded: the caller can log or
/// report it. What it must not do is reach `runApp` unhandled.
Future<T> openOrSurface<T>({
  required Future<T> Function() open,
  required T Function(Object error) surface,
}) async {
  try {
    return await open();
  } on Object catch (error) {
    return surface(error);
  }
}

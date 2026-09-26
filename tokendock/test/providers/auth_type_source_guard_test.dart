import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Audit C-28: `Connection.authType` is a `String?` column while adapters
/// declare an `AuthKind`. Six call sites hardcoded `'oauth'` or `'none'`
/// instead of deriving the value from the adapter that would actually
/// authenticate the connection, so the two representations could disagree with
/// nothing to notice.
///
/// This is a source guard rather than a behavioural test because the defect is
/// textual: there is no runtime state in which `'oauth'` as a literal is wrong,
/// only a state in which it *drifts* from `AuthKind.oauth.name`. It mirrors the
/// existing guard that fails if any `lib/` file outside `theme.dart` uses the
/// Material palette.
void main() {
  final libFiles = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .toList();

  test('the lib directory is where this guard expects to run', () {
    expect(libFiles, isNotEmpty);
  });

  test('no lib file hardcodes an auth_type string literal', () {
    final offenders = <String>[];
    // Matches `authType: '...'`, `authType != '...'` and the ternary form, and
    // deliberately does not match `AuthKind.oauth.name`, which is the point.
    final pattern = RegExp(r"authType\s*(==|!=)\s*'|\bauthType:\s*'");

    for (final file in libFiles) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (pattern.hasMatch(lines[i])) {
          offenders.add('${file.path}:${i + 1}: ${lines[i].trim()}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'auth_type must be derived from AuthKind, not written as a literal. '
          'Use AuthKind.oauth.name / AuthKind.none.name.',
    );
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/storage/secure_secret_store.dart';

/// What actually protects a stored credential at rest on Windows.
///
/// The product docs have said "DPAPI" for a long time. That is not what runs.
/// `flutter_secure_storage` 11.2 delegates to the federated
/// `flutter_secure_storage_windows`, whose native side encrypts values itself
/// and writes them under
/// `%APPDATA%\<CompanyName>\<ProductName>\flutter_secure_storage.dat`, with the
/// directory names taken from the executable's version resource
/// (`windows/runner/Runner.rc`). No `CryptProtectData` is involved.
///
/// The distinction matters, so the test holds the doc's claim to account rather
/// than restating it. DPAPI means the OS binds the ciphertext to the Windows
/// account; an application-level cipher is a different guarantee with a
/// different threat model. What this test asserts is the property that is
/// actually true and that matters: the plaintext is not on disk.
///
/// Scope note: this is a Windows-desktop integration test, so it is exercised by
/// `flutter test integration_test/ -d windows`, not by the plain unit suite.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Namespaced so it cannot collide with a real credential, and removed again
  // in tearDown so a failed run leaves nothing behind.
  const key = 'tokendock_selftest_probing_key';
  const secret = 'sk-selftest-must-not-appear-on-disk-0123456789';

  late SecureSecretStore store;

  setUp(() {
    store = SecureSecretStore();
  });

  tearDown(() async {
    await store.delete(key);
  });

  test(
    'a credential survives a write and a read through the real plugin',
    () async {
      await store.write(key, secret);

      expect(await store.read(key), secret);
    },
  );

  test('the stored blob is not the plaintext on disk', () async {
    await store.write(key, secret);

    // The plugin derives its directory from the CompanyName and ProductName in
    // the executable's version resource, which `windows/runner/Runner.rc` is
    // the source of. Reading it keeps the test honest if those change.
    final resource = File('windows/runner/Runner.rc');
    expect(
      resource.existsSync(),
      isTrue,
      reason: 'this test must run from the package root, not from a build dir',
    );
    String versionResource(String field) {
      final match = RegExp('VALUE\\s+"$field",\\s*"([^"]*)"')
          .firstMatch(resource.readAsStringSync());
      if (match == null) {
        throw StateError('Runner.rc has no $field');
      }
      return match.group(1)!;
    }

    final company = versionResource('CompanyName');
    final product = versionResource('ProductName');
    final roaming = Platform.environment['APPDATA'];
    expect(roaming, isNotNull, reason: 'APPDATA must exist on Windows');

    final dir = Directory('$roaming\\$company\\$product');
    expect(
      dir.existsSync(),
      isTrue,
      reason: 'expected the plugin to have created ${dir.path}',
    );

    final files = dir.listSync().whereType<File>().toList();
    expect(files, isNotEmpty, reason: 'nothing was written to ${dir.path}');

    // The whole point: none of the stored bytes may contain the secret in the
    // clear, in any encoding the file could plausibly hold.
    for (final file in files) {
      final bytes = file.readAsBytesSync();
      final asLatin1 = latin1.decode(bytes);
      final asUtf8 = const Utf8Decoder(allowMalformed: true).convert(bytes);
      final asBase64 = base64.encode(bytes);

      expect(
        asLatin1,
        isNot(contains(secret)),
        reason: '${file.path} leaks the secret',
      );
      expect(
        asUtf8,
        isNot(contains(secret)),
        reason: '${file.path} leaks the secret',
      );
      expect(asBase64, isNot(contains(secret)));
      // Nor a distinctive fragment, and nor the key name.
      expect(asUtf8, isNot(contains('must-not-appear-on-disk')));
      expect(asLatin1, isNot(contains('must-not-appear-on-disk')));
      expect(asLatin1, isNot(contains('tokendock_selftest_probing_key')));
      expect(asUtf8, isNot(contains('tokendock_selftest_probing_key')));
    }
  });

  test('deleting removes the value', () async {
    await store.write(key, secret);
    expect(await store.read(key), secret);

    await store.delete(key);

    expect(await store.read(key), isNull);
  });
}

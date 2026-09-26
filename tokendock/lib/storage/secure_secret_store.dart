import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secret_store.dart';

/// Encrypted-at-rest secret store for Windows using [FlutterSecureStorage].
///
/// Not DPAPI, despite what earlier revisions of the docs said. The plugin
/// encrypts values itself and writes
/// `%APPDATA%\<CompanyName>\<ProductName>\flutter_secure_storage.dat`, taking
/// the directory names from the executable's version resource
/// (`windows/runner/Runner.rc`). DPAPI would mean the OS binds the ciphertext to
/// the Windows account; this is an application-level cipher, which is a
/// different guarantee with a different threat model.
///
/// The property that is true, and that matters, is that the plaintext is not on
/// disk. `integration_test/secret_store_windows_test.dart` asserts it against
/// the real plugin, so a plugin upgrade that changes this fails there instead
/// of quietly making the documentation a lie.
class SecureSecretStore implements SecretStore {
  SecureSecretStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              wOptions: WindowsOptions(),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<void> write(String key, String value) async {
    await _storage.write(key: key, value: value);
  }

  @override
  Future<String?> read(String key) async {
    return _storage.read(key: key);
  }

  @override
  Future<void> delete(String key) async {
    await _storage.delete(key: key);
  }
}

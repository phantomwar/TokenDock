import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secret_store.dart';

/// DPAPI-backed secret store for Windows using [FlutterSecureStorage].
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

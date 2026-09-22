import 'package:tokendock/storage/secret_store.dart';

/// In-memory implementation of [SecretStore] for testing.
class MemorySecretStore implements SecretStore {
  MemorySecretStore([Map<String, String>? initialData])
      : _storage = initialData != null
            ? Map<String, String>.from(initialData)
            : <String, String>{};

  final Map<String, String> _storage;

  @override
  Future<void> write(String key, String value) async {
    _storage[key] = value;
  }

  @override
  Future<String?> read(String key) async {
    return _storage[key];
  }

  @override
  Future<void> delete(String key) async {
    _storage.remove(key);
  }

  /// Returns an unmodifiable snapshot of the stored entries.
  Map<String, String> get entries => Map.unmodifiable(_storage);

  /// Clears all entries from the store.
  void clear() {
    _storage.clear();
  }
}

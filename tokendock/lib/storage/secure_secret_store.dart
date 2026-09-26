import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secret_store.dart';
import 'secret_store_migration.dart';

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
    : _storage = storage ?? _defaultStorage();

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

  static FlutterSecureStorage _defaultStorage() =>
      const FlutterSecureStorage(wOptions: WindowsOptions());
}

/// Moves a credential store left behind by a build that used the placeholder
/// company name.
///
/// Called explicitly from `main` rather than from [SecureSecretStore]'s
/// constructor, and that placement is load-bearing. The constructor is reachable
/// from the unit suite -- `secret_store_test.dart` builds the real default
/// store -- and a migration that moves the user's actual credentials must never
/// be a side effect of a constructor a test can reach. Boot is the right owner:
/// it runs once, before anything can read a secret, and it is the one place
/// where a failure can still be reported to the user.
///
/// Cheap and idempotent: every other path is two `existsSync` calls.
///
/// [roamingAppData] defaults to `%APPDATA%` and exists only so a test can point
/// this at a temporary root. A test must never be able to make the real profile
/// move, so the real value is the one production passes by omission.
void relocateLegacySecretStore({String? roamingAppData}) {
  final roaming = roamingAppData ?? Platform.environment['APPDATA'];
  if (roaming == null || roaming.isEmpty) return;

  final paths = secretStorePaths(roaming);
  final outcome = migrateSecretStoreDirectory(
    legacyDirectory: paths.legacy,
    currentDirectory: paths.current,
  );

  switch (outcome) {
    case SecretStoreMigrationOutcome.moved:
      debugPrint(
        'TokenDock: relocated the credential store to ${paths.current.path}',
      );
    case SecretStoreMigrationOutcome.bothPresent:
      // Not fatal and deliberately not merged: reconciling two stores means
      // reading and rewriting credentials, and guessing which is authoritative
      // risks destroying the newer one. Surfaced because a stale second copy
      // should not be discovered by accident.
      debugPrint(
        'TokenDock: found credential stores in both ${paths.legacy.path} and '
        '${paths.current.path}; using the current one and leaving the older '
        'untouched.',
      );
    case SecretStoreMigrationOutcome.failed:
      debugPrint(
        'TokenDock: could not relocate the credential store from '
        '${paths.legacy.path}. Credentials already stored there will need to be '
        'entered again.',
      );
    case SecretStoreMigrationOutcome.nothingToDo:
    case SecretStoreMigrationOutcome.alreadyCurrent:
      break;
  }
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/storage/secret_store_migration.dart';
import 'package:tokendock/storage/secure_secret_store.dart';

/// Changing the Windows `CompanyName` moves where `flutter_secure_storage`
/// keeps its file, because the plugin derives that path from the executable's
/// version resource.
///
/// The shipped value was `com.example` -- the Flutter template placeholder, and
/// a domain RFC 2606 reserves for examples. Leaving it in place means any other
/// Flutter app built from a template collides in the same directory, and Windows
/// shows `com.example` as the publisher. Correcting it is right, but it would
/// silently orphan every credential already stored, which is why the move has to
/// happen rather than just the rename.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('tokendock_secret_move');
  });

  tearDown(() async {
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  Directory legacy() => Directory(
    '${root.path}${Platform.pathSeparator}com.example${Platform.pathSeparator}tokendock',
  );
  Directory current() => Directory(
    '${root.path}${Platform.pathSeparator}TokenDock${Platform.pathSeparator}tokendock',
  );

  /// The leading bytes are deliberately not valid UTF-8, so comparing bytes
  /// rather than decoded text is what actually proves the file was relocated
  /// intact.
  List<int> storeBytes(String marker) => <int>[
    0x00,
    0xFF,
    0x10,
    0x80,
    ...marker.codeUnits,
  ];

  /// Stands in for the plugin's `flutter_secure_storage.dat`, holding bytes
  /// that are not valid UTF-8 so the migration cannot cheat by reading text.
  void seedStore(Directory dir, {required String marker}) {
    dir.createSync(recursive: true);
    File('${dir.path}${Platform.pathSeparator}$secureStorageFileName')
        .writeAsBytesSync(storeBytes(marker));
  }

  List<int> readBytes(Directory dir) =>
      File('${dir.path}${Platform.pathSeparator}$secureStorageFileName')
          .readAsBytesSync();

  test('moves the store when only the legacy directory exists', () {
    seedStore(legacy(), marker: 'AAAA');

    final outcome = migrateSecretStoreDirectory(
      legacyDirectory: legacy(),
      currentDirectory: current(),
    );

    expect(outcome, SecretStoreMigrationOutcome.moved);
    expect(legacy().existsSync(), isFalse);
    expect(readBytes(current()), storeBytes('AAAA'));
  });

  test('is a no-op when there is nothing to move', () {
    expect(
      migrateSecretStoreDirectory(
        legacyDirectory: legacy(),
        currentDirectory: current(),
      ),
      SecretStoreMigrationOutcome.nothingToDo,
    );
  });

  test('is a no-op when the current directory already exists', () {
    seedStore(current(), marker: 'BBBB');

    expect(
      migrateSecretStoreDirectory(
        legacyDirectory: legacy(),
        currentDirectory: current(),
      ),
      SecretStoreMigrationOutcome.alreadyCurrent,
    );
    expect(readBytes(current()), storeBytes('BBBB'));
  });

  test('never clobbers the current store when both exist', () {
    seedStore(legacy(), marker: 'AAAA');
    seedStore(current(), marker: 'BBBB');

    final outcome = migrateSecretStoreDirectory(
      legacyDirectory: legacy(),
      currentDirectory: current(),
    );

    expect(outcome, SecretStoreMigrationOutcome.bothPresent);
    // The newer store wins; the legacy one is left untouched rather than
    // deleted, because deleting a credential file on a guess is the one
    // irreversible mistake available here.
    expect(readBytes(current()), storeBytes('BBBB'));
    expect(readBytes(legacy()), storeBytes('AAAA'));
  });

  test('is idempotent, so a second run changes nothing', () {
    seedStore(legacy(), marker: 'AAAA');

    expect(
      migrateSecretStoreDirectory(
        legacyDirectory: legacy(),
        currentDirectory: current(),
      ),
      SecretStoreMigrationOutcome.moved,
    );
    expect(
      migrateSecretStoreDirectory(
        legacyDirectory: legacy(),
        currentDirectory: current(),
      ),
      SecretStoreMigrationOutcome.alreadyCurrent,
    );
    expect(readBytes(current()), storeBytes('AAAA'));
  });

  test('handles the legacy directory being empty', () {
    legacy().createSync(recursive: true);

    expect(
      migrateSecretStoreDirectory(
        legacyDirectory: legacy(),
        currentDirectory: current(),
      ),
      SecretStoreMigrationOutcome.moved,
    );
    expect(current().existsSync(), isTrue);
  });

  test('a failure is reported, never thrown', () {
    // The current location's parent is a *file*, so creating the parent
    // directory must fail. The app still has to start: losing a stored
    // credential costs the user one re-login, refusing to launch costs them
    // everything.
    final blocker = File('${root.path}${Platform.pathSeparator}blocked_parent');
    blocker.writeAsStringSync('x');
    seedStore(
      Directory('${root.path}${Platform.pathSeparator}legacy\\tokendock'),
      marker: 'AAAA',
    );

    final outcome = migrateSecretStoreDirectory(
      legacyDirectory: Directory(
        '${root.path}${Platform.pathSeparator}legacy\\tokendock',
      ),
      currentDirectory: Directory('${blocker.path}\\TokenDock\\tokendock'),
    );

    expect(outcome, SecretStoreMigrationOutcome.failed);
    // And the legacy store is still there, not half-moved.
    expect(
      readBytes(
        Directory('${root.path}${Platform.pathSeparator}legacy\\tokendock'),
      ),
      storeBytes('AAAA'),
    );
  });

  test('the boot entry point moves a legacy store, given a root to look in', () {
    // This is the end-to-end proof, on a temporary root: the function `main`
    // calls actually relocates a store, so the wiring is not merely plausible.
    seedStore(legacy(), marker: 'AAAA');

    relocateLegacySecretStore(roamingAppData: root.path);

    expect(legacy().existsSync(), isFalse);
    expect(readBytes(current()), storeBytes('AAAA'));
  });

  test('the boot entry point is harmless when there is nothing to move', () {
    expect(
      () => relocateLegacySecretStore(roamingAppData: root.path),
      returnsNormally,
    );
    // Idempotent, so a second launch is a no-op.
    seedStore(current(), marker: 'BBBB');
    relocateLegacySecretStore(roamingAppData: root.path);
    expect(readBytes(current()), storeBytes('BBBB'));
  });

  test('an empty APPDATA is a no-op rather than a throw', () {
    expect(
      () => relocateLegacySecretStore(roamingAppData: ''),
      returnsNormally,
    );
  });

  test('the real app paths are derived from the roaming app data root', () {
    final paths = secretStorePaths('C:\\Users\\someone\\AppData\\Roaming');

    expect(paths.legacy.path, contains('com.example'));
    expect(paths.current.path, isNot(contains('com.example')));
    expect(paths.current.path, contains(legacyCompanyNameReplacement));
    expect(paths.legacy.path, endsWith(productName));
  });
}

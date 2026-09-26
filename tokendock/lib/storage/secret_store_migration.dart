import 'dart:io';

/// Moves an existing credential store out of the placeholder company name.
///
/// `flutter_secure_storage` derives its Windows storage path from the
/// executable's version resource:
/// `%APPDATA%\<CompanyName>\<ProductName>\flutter_secure_storage.dat`. The
/// project shipped the Flutter template default, `com.example`, which RFC 2606
/// reserves for examples. Any other template-built Flutter app would collide in
/// the same directory, and Windows lists `com.example` as the publisher.
///
/// Correcting `windows/runner/Runner.rc` is a one-line change with a nasty
/// consequence: the plugin would immediately look in a directory that does not
/// exist, and every stored credential would read as `null` -- the app would look
/// fine and silently lose the user's keys. So the rename is paired with this
/// move, which runs before the first read.
enum SecretStoreMigrationOutcome {
  /// The store was relocated.
  moved,

  /// Only the current location exists, or only the legacy one and it was moved.
  alreadyCurrent,

  /// Nothing to move: neither directory exists.
  nothingToDo,

  /// Both exist. The current one wins and the legacy one is left alone.
  bothPresent,

  /// The move did not succeed. The app still starts.
  failed,
}

/// The file the plugin writes inside its directory.
const String secureStorageFileName = 'flutter_secure_storage.dat';

/// The `CompanyName` the project shipped by accident, kept here so the
/// migration can find what earlier builds left behind.
const String legacyCompanyName = 'com.example';

/// What `Runner.rc` uses now. Any change to this constant needs a new legacy
/// entry and a further step in this migration.
const String legacyCompanyNameReplacement = 'TokenDock';

/// The product name, unchanged, so only the company segment moves.
const String productName = 'tokendock';

/// The two directories a build can be looking at.
class SecretStorePaths {
  const SecretStorePaths({required this.legacy, required this.current});

  final Directory legacy;
  final Directory current;
}

/// Derives both candidate directories from a roaming app data root.
///
/// [roamingAppData] is `%APPDATA%`. Exposed so the derivation is testable
/// without touching a real user profile.
SecretStorePaths secretStorePaths(String roamingAppData) {
  String at(String company) => Platform.isWindows
      ? '$roamingAppData\\$company\\$productName'
      : '$roamingAppData/$company/$productName';
  return SecretStorePaths(
    legacy: Directory(at(legacyCompanyName)),
    current: Directory(at(legacyCompanyNameReplacement)),
  );
}

/// Relocates the credential store, once, if it is still in the legacy place.
///
/// Deliberately total: every failure path returns [SecretStoreMigrationOutcome]
/// rather than throwing. A failed move costs the user one re-login per
/// connection; refusing to launch costs them the app.
SecretStoreMigrationOutcome migrateSecretStoreDirectory({
  required Directory legacyDirectory,
  required Directory currentDirectory,
}) {
  try {
    final legacyExists = legacyDirectory.existsSync();
    final currentExists = currentDirectory.existsSync();

    if (!legacyExists) {
      return currentExists
          ? SecretStoreMigrationOutcome.alreadyCurrent
          : SecretStoreMigrationOutcome.nothingToDo;
    }
    if (currentExists) {
      // Not an error and not a merge. Two stores cannot be reconciled without
      // reading and rewriting credentials, and guessing which is authoritative
      // risks destroying the newer one. The legacy copy is left for the user to
      // inspect.
      return SecretStoreMigrationOutcome.bothPresent;
    }

    currentDirectory.parent.createSync(recursive: true);
    legacyDirectory.renameSync(currentDirectory.path);
    return SecretStoreMigrationOutcome.moved;
  } on FileSystemException {
    return SecretStoreMigrationOutcome.failed;
  } on Object {
    return SecretStoreMigrationOutcome.failed;
  }
}

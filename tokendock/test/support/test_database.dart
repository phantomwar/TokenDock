import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tokendock/storage/connection_health_repository.dart';
import 'package:tokendock/storage/connection_repository.dart';
import 'package:tokendock/storage/migration_001.dart';
import 'package:tokendock/storage/migration_002.dart';
import 'package:tokendock/storage/migration_003.dart';
import 'package:tokendock/storage/migration_004.dart';
import 'package:tokendock/storage/quota_cache_repository.dart';
import 'package:tokendock/storage/settings_repository.dart';

class TestDatabase {
  TestDatabase._(this.database)
    : connectionRepository = SqliteConnectionRepository(database),
      connectionHealthRepository = SqliteConnectionHealthRepository(database),
      quotaCacheRepository = SqliteQuotaCacheRepository(database),
      settingsRepository = SqliteSettingsRepository(database);

  final Database database;
  final ConnectionRepository connectionRepository;
  final ConnectionHealthRepository connectionHealthRepository;
  final QuotaCacheRepository quotaCacheRepository;
  final SettingsRepository settingsRepository;

  static Future<TestDatabase> create() async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await Migration001.run(db);
    await Migration002.run(db);
    await Migration003.run(db);
    await Migration004.run(db);
    // Same order as `AppDatabase.open`, so the repositories are exercised
    // under the contract production runs with. Without this the cascade would
    // only ever be tested through the application's own manual delete, and a
    // regression in the declared foreign key would go unnoticed here.
    await db.execute('PRAGMA foreign_keys = ON');
    return TestDatabase._(db);
  }

  Future<void> close() async {
    await database.close();
  }
}

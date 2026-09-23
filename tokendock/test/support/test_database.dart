import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tokendock/storage/connection_health_repository.dart';
import 'package:tokendock/storage/connection_repository.dart';
import 'package:tokendock/storage/migration_001.dart';
import 'package:tokendock/storage/migration_002.dart';
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
    return TestDatabase._(db);
  }

  Future<void> close() async {
    await database.close();
  }
}

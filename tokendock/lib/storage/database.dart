import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tokendock/storage/connection_health_repository.dart';
import 'package:tokendock/storage/connection_repository.dart';
import 'package:tokendock/storage/migration_001.dart';
import 'package:tokendock/storage/migration_002.dart';
import 'package:tokendock/storage/migration_003.dart';
import 'package:tokendock/storage/quota_cache_repository.dart';
import 'package:tokendock/storage/settings_repository.dart';

class AppDatabase {
  AppDatabase(this.database)
    : connectionRepository = SqliteConnectionRepository(database),
      connectionHealthRepository = SqliteConnectionHealthRepository(database),
      quotaCacheRepository = SqliteQuotaCacheRepository(database),
      settingsRepository = SqliteSettingsRepository(database);

  final Database database;
  final ConnectionRepository connectionRepository;
  final ConnectionHealthRepository connectionHealthRepository;
  final QuotaCacheRepository quotaCacheRepository;
  final SettingsRepository settingsRepository;

  static Future<String> defaultDatabasePath() async {
    String? localAppData;
    try {
      if (Platform.isWindows) {
        localAppData = Platform.environment['LOCALAPPDATA'];
      }
    } catch (_) {}

    final String baseDir;
    if (localAppData != null && localAppData.isNotEmpty) {
      baseDir = '$localAppData\\TokenDock';
    } else {
      final appSupport = await getApplicationSupportDirectory();
      baseDir = '${appSupport.path}${Platform.pathSeparator}TokenDock';
    }

    final dir = Directory(baseDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return '$baseDir${Platform.pathSeparator}tokendock.db';
  }

  static Future<AppDatabase> open({String? path}) async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dbPath = path ?? await defaultDatabasePath();
    final factory = (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
        ? databaseFactoryFfi
        : databaseFactory;
    final db = await factory.openDatabase(dbPath);
    await Migration001.run(db);
    await Migration002.run(db);
    await Migration003.run(db);
    return AppDatabase(db);
  }

  Future<void> close() async {
    await database.close();
  }
}

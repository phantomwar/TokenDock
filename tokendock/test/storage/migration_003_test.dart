import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tokendock/storage/database.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  test('AppDatabase.open runs migration003 and adds identity metadata columns', () async {
    final app = await AppDatabase.open(path: inMemoryDatabasePath);
    addTearDown(app.close);

    final version = await app.database.rawQuery('PRAGMA user_version');
    expect((version.first.values.first as num).toInt(), 3);

    final columns = await app.database.rawQuery('PRAGMA table_info(connections)');
    final names = columns.map((column) => column['name'] as String).toSet();
    expect(names, containsAll({'auth_type', 'identity_key', 'provider_data'}));
  });
}

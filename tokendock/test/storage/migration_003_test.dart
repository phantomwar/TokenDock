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

    // No `user_version` assertion here on purpose. This test is about what
    // migration003 adds, and pinning the global version made it break every
    // time a later migration landed. `migration_004_test.dart` owns the
    // version; the columns below are the proof that 003 ran.
    final columns = await app.database.rawQuery('PRAGMA table_info(connections)');
    final names = columns.map((column) => column['name'] as String).toSet();
    expect(names, containsAll({'auth_type', 'identity_key', 'provider_data'}));
  });
}

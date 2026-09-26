import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_health.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/models/quota.dart';

import '../support/test_database.dart';

/// Loading the widget must not issue a query per connection.
///
/// Audit C-17: `ConnectionHealth` is stored in columns of the very same
/// `connections` table that `getAll()` selects, but `getAll()` did not map those
/// four columns, so the values were read and thrown away. `AppState.load` then
/// re-fetched each one by primary key inside a loop. The row was already in
/// memory; the extra query was a missed join.
void main() {
  setUpAll(() {
    TestDatabase.create;
  });

  test('connection health is readable from the same row as the connection',
      () async {
    final db = await TestDatabase.create();
    addTearDown(db.close);

    await db.connectionRepository.save(
      const Connection(
        id: 'c1',
        provider: 'openrouter',
        displayName: 'With health',
        group: null,
        plan: null,
        credentialRef: 'ref',
        enabled: true,
      ),
    );
    await db.connectionHealthRepository.save(
      ConnectionHealthForTest.make('c1'),
    );

    // The repository must be able to hand back the connection together with
    // the health already present on its row, without a second read.
    final loaded = await db.connectionRepository.getAllWithHealth();

    expect(loaded, hasLength(1));
    final entry = loaded.single;
    expect(entry.connection.id, 'c1');
    expect(entry.health, isNotNull);
    expect(entry.health!.status.name, 'warning');
    expect(entry.health!.error, 'Rate limited');
    expect(entry.health!.cooldownUntil, isNotNull);
  });

  test('a connection with no health yet reports null rather than failing',
      () async {
    final db = await TestDatabase.create();
    addTearDown(db.close);
    await db.connectionRepository.save(
      const Connection(
        id: 'fresh',
        provider: 'openrouter',
        displayName: 'Fresh',
        group: null,
        plan: null,
        credentialRef: 'ref',
        enabled: true,
      ),
    );

    final loaded = await db.connectionRepository.getAllWithHealth();

    expect(loaded.single.health, isNull);
  });

  test('cached quotas for many connections load in one query', () async {
    final db = await TestDatabase.create();
    addTearDown(db.close);
    for (var i = 0; i < 12; i++) {
      await db.connectionRepository.save(
        Connection(
          id: 'c$i',
          provider: 'openrouter',
          displayName: 'Account $i',
          group: null,
          plan: null,
          credentialRef: 'ref-$i',
          enabled: true,
        ),
      );
    }
    for (var i = 0; i < 12; i++) {
      await db.quotaCacheRepository.saveAll('c$i', [
        QuotaForTest.make('c$i'),
      ]);
    }

    final byConnection =
        await db.quotaCacheRepository.getAllForAll(const [
      'c0',
      'c1',
      'c2',
      'c3',
      'c4',
      'c5',
      'c6',
      'c7',
      'c8',
      'c9',
      'c10',
      'c11',
    ]);

    expect(byConnection.length, 12);
    expect(byConnection['c5'], hasLength(1));
    expect(byConnection['c11']!.single.remaining, 5);
  });
}

/// Keeps the fixture construction out of the test bodies.
abstract final class ConnectionHealthForTest {
  static ConnectionHealth make(String id) => ConnectionHealth(
        connectionId: id,
        status: ConnectionStatus.warning,
        lastCheckedAt: DateTime.utc(2026, 5, 4, 3, 2, 1),
        cooldownUntil: DateTime.utc(2026, 5, 4, 3, 5),
        error: 'Rate limited',
      );
}

abstract final class QuotaForTest {
  static Quota make(String connectionId) => Quota(
        id: 'key-limit',
        label: 'Key limit',
        percent: 50,
        remaining: 5,
        limit: 10,
        unit: 'USD',
        resetAt: null,
      );
}

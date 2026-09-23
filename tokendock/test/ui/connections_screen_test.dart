import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/app/app_state.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/quota.dart';
import 'package:tokendock/storage/connection_repository.dart';

import '../support/memory_secret_store.dart';
import '../support/test_app.dart';

class FailingConnectionRepository implements ConnectionRepository {
  @override
  Future<List<Connection>> getAll() async => [];

  @override
  Future<void> save(Connection connection) async {
    throw Exception('Database write failed');
  }

  @override
  Future<void> delete(String id) async {}
}

void main() {
  late MemoryConnectionRepository connectionRepo;
  late MemoryQuotaCacheRepository quotaCacheRepo;
  late MemorySecretStore store;

  setUp(() {
    connectionRepo = MemoryConnectionRepository();
    quotaCacheRepo = MemoryQuotaCacheRepository();
    store = MemorySecretStore();
  });

  group('ConnectionsScreen - Test-Before-Save Gate', () {
    testWidgets('Save remains disabled until a connection test succeeds',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        TestConnectionsScreen.withResult(
          success: false,
          error: 'Invalid API key',
          connectionRepo: connectionRepo,
          secretStore: store,
        ),
      );
      await tester.pumpAndSettle();

      // Open Add dialog
      await tester.tap(find.byKey(const Key('addConnection')));
      await tester.pumpAndSettle();

      // Save button is initially disabled
      final saveBtnInitial =
          tester.widget<ElevatedButton>(find.byKey(const Key('saveConnection')));
      expect(saveBtnInitial.onPressed, isNull);

      // Fill in fields
      await tester.enterText(
          find.byKey(const Key('connectionDisplayNameField')), 'My Test Key');
      await tester.enterText(
          find.byKey(const Key('connectionCredentialField')), 'sk-bad-key');
      await tester.pumpAndSettle();

      // Save button remains disabled after typing
      final saveBtnAfterTyping =
          tester.widget<ElevatedButton>(find.byKey(const Key('saveConnection')));
      expect(saveBtnAfterTyping.onPressed, isNull);

      // Tap Test Connection
      await tester.tap(find.byKey(const Key('testConnectionButton')));
      await tester.pumpAndSettle();

      // Failure error message is displayed
      expect(find.text('Invalid API key'), findsOneWidget);

      // Save button is STILL disabled
      final saveBtnAfterFail =
          tester.widget<ElevatedButton>(find.byKey(const Key('saveConnection')));
      expect(saveBtnAfterFail.onPressed, isNull);
    });

    testWidgets(
        'Successful test enables Save, and saving creates connection and stores secret in secret store',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        TestConnectionsScreen.withResult(
          success: true,
          connectionRepo: connectionRepo,
          quotaCacheRepo: quotaCacheRepo,
          secretStore: store,
          quotas: const [
            Quota(
              id: 'credits',
              label: 'Credits',
              percent: 50.0,
              remaining: 50.0,
              limit: 100.0,
              unit: 'USD',
              resetAt: null,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // Open Add dialog
      await tester.tap(find.byKey(const Key('addConnection')));
      await tester.pumpAndSettle();

      // Enter connection details
      await tester.enterText(
          find.byKey(const Key('connectionDisplayNameField')), 'OpenRouter Main');
      await tester.enterText(
          find.byKey(const Key('connectionGroupField')), 'Production');
      await tester.enterText(find.byKey(const Key('connectionCredentialField')),
          'sk-or-v1-validsecretkey1234');
      await tester.pumpAndSettle();

      // Save disabled before test
      expect(
          tester
              .widget<ElevatedButton>(find.byKey(const Key('saveConnection')))
              .onPressed,
          isNull);

      // Tap Test Connection
      await tester.tap(find.byKey(const Key('testConnectionButton')));
      await tester.pumpAndSettle();

      // Connected and quota preview displayed
      expect(find.text('Connected'), findsOneWidget);
      expect(find.textContaining('Credits: 50.0 / 100.0 USD'), findsOneWidget);

      // Save button is now enabled
      final saveBtnEnabled =
          tester.widget<ElevatedButton>(find.byKey(const Key('saveConnection')));
      expect(saveBtnEnabled.onPressed, isNotNull);

      // Tap Save
      await tester.ensureVisible(find.byKey(const Key('saveConnection')));
      await tester.tap(find.byKey(const Key('saveConnection')));
      await tester.pumpAndSettle();

      // Dialog closed, connection listed on screen
      expect(find.text('OpenRouter Main'), findsOneWidget);
      expect(find.textContaining('openrouter • Production'), findsOneWidget);

      // Verify connection in repository
      final conns = await connectionRepo.getAll();
      expect(conns.length, 1);
      final conn = conns.first;
      expect(conn.displayName, 'OpenRouter Main');
      expect(conn.group, 'Production');
      expect(conn.provider, 'openrouter');

      // Verify secret in secret store
      final savedSecret = await store.read(conn.credentialRef);
      expect(savedSecret, 'sk-or-v1-validsecretkey1234');

      // Verify cached quota
      final cachedQuotas = await quotaCacheRepo.getAll(conn.id);
      expect(cachedQuotas.length, 1);
      expect(cachedQuotas.first.label, 'Credits');
    });

    testWidgets(
        'saving a tested OAuth connection persists the replacement secret',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        TestConnectionsScreen.withResult(
          success: true,
          connectionRepo: connectionRepo,
          secretStore: store,
          replacementSecret: 'rotated-secret',
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('addConnection')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('connectionDisplayNameField')), 'OAuth');
      await tester.enterText(
          find.byKey(const Key('connectionCredentialField')), 'old-secret');
      await tester.tap(find.byKey(const Key('testConnectionButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('saveConnection')));
      await tester.pumpAndSettle();

      final saved = (await connectionRepo.getAll()).single;
      expect(await store.read(saved.credentialRef), 'rotated-secret');
    });

    testWidgets(
        'Editing credential after successful test disables Save button again until re-tested',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        TestConnectionsScreen.withResult(
          success: true,
          connectionRepo: connectionRepo,
          secretStore: store,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('addConnection')));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(const Key('connectionDisplayNameField')), 'Key A');
      await tester.enterText(
          find.byKey(const Key('connectionCredentialField')), 'sk-key-first');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('testConnectionButton')));
      await tester.pumpAndSettle();

      // Save button is enabled
      expect(
          tester
              .widget<ElevatedButton>(find.byKey(const Key('saveConnection')))
              .onPressed,
          isNotNull);

      // Edit credential
      await tester.enterText(
          find.byKey(const Key('connectionCredentialField')), 'sk-key-modified');
      await tester.pumpAndSettle();

      // Save button MUST be disabled again
      expect(
          tester
              .widget<ElevatedButton>(find.byKey(const Key('saveConnection')))
              .onPressed,
          isNull);
    });
  });

  group('ConnectionsScreen - Credential Compensation Transactions', () {
    testWidgets(
        'Compensation on add failure: if repository save fails, secret is rolled back and removed from secret store',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final failingRepo = FailingConnectionRepository();
      await tester.pumpWidget(
        TestConnectionsScreen.withResult(
          success: true,
          connectionRepo: failingRepo,
          secretStore: store,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('addConnection')));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(const Key('connectionDisplayNameField')), 'Fail Conn');
      await tester.enterText(find.byKey(const Key('connectionCredentialField')),
          'sk-transient-secret-key');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('testConnectionButton')));
      await tester.pumpAndSettle();

      // Save enabled
      expect(
          tester
              .widget<ElevatedButton>(find.byKey(const Key('saveConnection')))
              .onPressed,
          isNotNull);

      // Tap Save
      await tester.ensureVisible(find.byKey(const Key('saveConnection')));
      await tester.tap(find.byKey(const Key('saveConnection')));
      await tester.pumpAndSettle();

      // Secret was rolled back and removed from secret store!
      expect(store.entries.isEmpty, isTrue);

      // Safe error message is displayed
      expect(find.textContaining('Database write failed'), findsOneWidget);
    });

    testWidgets(
        'Replacement compensation: updating secret writes new secret, saves connection, and deletes old secret',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const oldSecretRef = 'old-secret-ref-uuid';
      const oldSecret = 'sk-or-v1-oldsecretkey1111';
      await store.write(oldSecretRef, oldSecret);

      await connectionRepo.save(
        const Connection(
          id: 'conn-replace-1',
          provider: 'openrouter',
          displayName: 'Primary Key',
          group: null,
          plan: 'Pro',
          credentialRef: oldSecretRef,
          enabled: true,
        ),
      );

      await tester.pumpWidget(
        TestConnectionsScreen.withResult(
          success: true,
          connectionRepo: connectionRepo,
          secretStore: store,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Primary Key'), findsOneWidget);

      // Tap Edit
      await tester.tap(find.byKey(const Key('editConnection_conn-replace-1')));
      await tester.pumpAndSettle();

      // Masked secret is displayed
      expect(find.text('sk-...1111'), findsOneWidget);

      // Enter new secret
      await tester.enterText(find.byKey(const Key('connectionCredentialField')),
          'sk-or-v1-newsecretkey2222');
      await tester.pumpAndSettle();

      // Save button disabled because secret changed
      expect(
          tester
              .widget<ElevatedButton>(find.byKey(const Key('saveConnection')))
              .onPressed,
          isNull);

      // Test connection
      await tester.tap(find.byKey(const Key('testConnectionButton')));
      await tester.pumpAndSettle();

      // Save button now enabled
      expect(
          tester
              .widget<ElevatedButton>(find.byKey(const Key('saveConnection')))
              .onPressed,
          isNotNull);

      // Tap Save
      await tester.ensureVisible(find.byKey(const Key('saveConnection')));
      await tester.tap(find.byKey(const Key('saveConnection')));
      await tester.pumpAndSettle();

      // Verify connection in repository has a new credentialRef
      final conns = await connectionRepo.getAll();
      expect(conns.length, 1);
      final updatedConn = conns.first;
      expect(updatedConn.credentialRef, isNot(oldSecretRef));

      // Verify old secret was deleted
      expect(await store.read(oldSecretRef), isNull);

      // Verify new secret is stored
      expect(await store.read(updatedConn.credentialRef),
          'sk-or-v1-newsecretkey2222');
    });

    testWidgets(
        'Deletion: removing connection deletes from database and secret store',
        (tester) async {
      const secretRef = 'delete-target-ref';
      await store.write(secretRef, 'sk-or-v1-deletetarget');

      await connectionRepo.save(
        const Connection(
          id: 'conn-to-delete',
          provider: 'openrouter',
          displayName: 'Key To Remove',
          group: null,
          plan: null,
          credentialRef: secretRef,
          enabled: true,
        ),
      );

      await tester.pumpWidget(
        TestConnectionsScreen(
          connectionRepo: connectionRepo,
          secretStore: store,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Key To Remove'), findsOneWidget);

      // Tap delete button
      await tester.tap(find.byKey(const Key('deleteConnection_conn-to-delete')));
      await tester.pumpAndSettle();

      // Connection is deleted from repository
      final conns = await connectionRepo.getAll();
      expect(conns.isEmpty, isTrue);

      // Secret is deleted from secret store
      expect(await store.read(secretRef), isNull);
      expect(store.entries.isEmpty, isTrue);

      // Screen shows empty state
      expect(find.text('No connections yet'), findsOneWidget);
    });

    testWidgets(
        'Masking: editing existing connection displays masked secret without revealing plaintext',
        (tester) async {
      const secretRef = 'mask-test-ref';
      const secretValue = 'sk-or-v1-supersecretplaintext9999';
      await store.write(secretRef, secretValue);

      await connectionRepo.save(
        const Connection(
          id: 'conn-mask-test',
          provider: 'openrouter',
          displayName: 'Masked Connection',
          group: null,
          plan: null,
          credentialRef: secretRef,
          enabled: true,
        ),
      );

      await tester.pumpWidget(
        TestConnectionsScreen(
          connectionRepo: connectionRepo,
          secretStore: store,
        ),
      );
      await tester.pumpAndSettle();

      // Tap Edit
      await tester.tap(find.byKey(const Key('editConnection_conn-mask-test')));
      await tester.pumpAndSettle();

      // Masked secret (sk-...9999) is displayed
      expect(find.text('sk-...9999'), findsOneWidget);

      // Plaintext secret is NEVER revealed in the widget tree
      expect(find.text(secretValue), findsNothing);
    });

    testWidgets('Toggling connection enabled updates database', (tester) async {
      await store.write('toggle-ref', 'sk-or-v1-toggle');
      await connectionRepo.save(
        const Connection(
          id: 'conn-toggle',
          provider: 'openrouter',
          displayName: 'Toggle Conn',
          group: null,
          plan: null,
          credentialRef: 'toggle-ref',
          enabled: true,
        ),
      );

      await tester.pumpWidget(
        TestConnectionsScreen(
          connectionRepo: connectionRepo,
          secretStore: store,
        ),
      );
      await tester.pumpAndSettle();

      // Toggle switch to disable
      await tester.tap(find.byKey(const Key('toggleConnection_conn-toggle')));
      await tester.pumpAndSettle();

      final conns = await connectionRepo.getAll();
      expect(conns.first.enabled, isFalse);
    });
  });

  group('AppState - Direct transaction & compensation tests', () {
    test('addConnection writes secret, saves connection, and handles rollback',
        () async {
      final appState = AppState(
        connectionRepository: connectionRepo,
        quotaCacheRepository: quotaCacheRepo,
        secretStore: store,
      );

      final conn = await appState.addConnection(
        provider: 'openrouter',
        displayName: 'Direct Add',
        secret: 'sk-direct-secret',
      );

      expect(conn.displayName, 'Direct Add');
      expect(await store.read(conn.credentialRef), 'sk-direct-secret');
      expect(appState.accounts.length, 1);
    });

    test('addConnection rolls back secret when save fails', () async {
      final appState = AppState(
        connectionRepository: FailingConnectionRepository(),
        secretStore: store,
      );

      await expectLater(
        appState.addConnection(
          provider: 'openrouter',
          displayName: 'Fail Add',
          secret: 'sk-transient-secret',
        ),
        throwsA(isA<Exception>()),
      );

      // Secret was rolled back
      expect(store.entries.isEmpty, isTrue);
    });

    test('updateConnection replaces secret and cleans up old secret', () async {
      final appState = AppState(
        connectionRepository: connectionRepo,
        secretStore: store,
      );

      final conn1 = await appState.addConnection(
        provider: 'openrouter',
        displayName: 'Initial Conn',
        secret: 'sk-secret-1',
      );

      final oldRef = conn1.credentialRef;

      final updated = await appState.updateConnection(
        existing: conn1,
        displayName: 'Updated Conn',
        newSecret: 'sk-secret-2',
      );

      expect(updated.credentialRef, isNot(oldRef));
      expect(await store.read(oldRef), isNull);
      expect(await store.read(updated.credentialRef), 'sk-secret-2');
    });

    test('removeConnection deletes connection and secret', () async {
      final appState = AppState(
        connectionRepository: connectionRepo,
        secretStore: store,
      );

      final conn = await appState.addConnection(
        provider: 'openrouter',
        displayName: 'Remove Conn',
        secret: 'sk-to-remove',
      );

      expect(appState.accounts.length, 1);

      await appState.removeConnection(conn.id);

      expect(appState.accounts.isEmpty, isTrue);
      expect(await store.read(conn.credentialRef), isNull);
      expect((await connectionRepo.getAll()).isEmpty, isTrue);
    });
  });
}

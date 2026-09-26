import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/app/app_state.dart';
import 'package:tokendock/providers/antigravity/antigravity_oauth.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/models/provider_snapshot.dart';
import 'package:tokendock/models/quota.dart';
import 'package:tokendock/models/test_result.dart';
import 'package:tokendock/providers/provider_adapter.dart';
import 'package:tokendock/providers/provider_registry.dart';
import 'package:tokendock/services/refresh_service.dart';
import 'package:tokendock/storage/connection_repository.dart';
import 'package:tokendock/storage/secret_store.dart';
import 'package:tokendock/storage/settings_repository.dart';
import 'package:tokendock/ui/settings/connections_screen.dart';

import '../support/controlled_provider.dart';
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

class _ControlledAntigravityOAuthProvider extends AntigravityOAuthProvider {
  _ControlledAntigravityOAuthProvider(this.result, {this.loginGate})
    : super(launchExternalBrowser: (_) async {});

  final AntigravityOAuthLoginResult result;
  final Completer<AntigravityOAuthLoginResult>? loginGate;

  @override
  Future<AntigravityOAuthLoginResult> loginWithLoopback(
    Connection connection, {
    Future<void>? cancellation,
  }) async {
    if (loginGate != null) return loginGate!.future;
    return result;
  }
}

class _OnboardingRequiredAntigravityProvider
    extends AntigravityOAuthProvider {
  _OnboardingRequiredAntigravityProvider()
    : super(launchExternalBrowser: (_) async {});

  @override
  Future<AntigravityOAuthLoginResult> loginWithLoopback(
    Connection connection, {
    Future<void>? cancellation,
  }) async {
    throw const AntigravityOnboardingRequired();
  }
}

class _GatedControlledProvider extends ControlledProvider {
  _GatedControlledProvider({
    required super.id,
    required super.name,
    required this.started,
    required this.gate,
    required this.result,
  });

  final Completer<void> started;
  final Completer<void> gate;
  final TestResult result;

  @override
  Future<TestResult> test(Connection connection, String secret) async {
    testCalls++;
    if (!started.isCompleted) started.complete();
    await gate.future;
    return result;
  }
}

class _EmptyKeyRejectingSecretStore implements SecretStore {
  _EmptyKeyRejectingSecretStore(this.delegate);

  final SecretStore delegate;

  @override
  Future<void> write(String key, String value) => delegate.write(key, value);

  @override
  Future<String?> read(String key) {
    if (key.isEmpty) throw StateError('read empty credential ref');
    return delegate.read(key);
  }

  @override
  Future<void> delete(String key) {
    if (key.isEmpty) throw StateError('delete empty credential ref');
    return delegate.delete(key);
  }
}

class _MemorySettingsRepository implements SettingsRepository {
  _MemorySettingsRepository(this.refreshMinutes);

  int refreshMinutes;
  final Map<String, String> values = {};

  @override
  Future<String?> get(String key) async => values[key];

  @override
  Future<void> set(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<int> getRefreshIntervalMinutes() async => refreshMinutes;

  @override
  Future<void> setRefreshIntervalMinutes(int minutes) async {
    refreshMinutes = minutes;
    await set('refresh_interval_minutes', '$minutes');
  }
}

class _BlockingSettingsRepository implements SettingsRepository {
  _BlockingSettingsRepository(this.initialMinutes);

  final int initialMinutes;
  final Completer<int> pendingLoad = Completer<int>();
  final Map<String, String> values = {};
  int persistedMinutes = 3;

  void completeLoad() => pendingLoad.complete(initialMinutes);

  @override
  Future<String?> get(String key) async => values[key];

  @override
  Future<void> set(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<int> getRefreshIntervalMinutes() => pendingLoad.future;

  @override
  Future<void> setRefreshIntervalMinutes(int minutes) async {
    persistedMinutes = minutes;
    await set('refresh_interval_minutes', '$minutes');
  }
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

  testWidgets('refresh interval selector persists supported values', (tester) async {
    final settings = _MemorySettingsRepository(5);
    final state = AppState.test(
      connectionRepository: connectionRepo,
      quotaCacheRepository: quotaCacheRepo,
      secretStore: store,
      settingsRepository: settings,
    );
    await tester.pumpWidget(TestConnectionsScreen(appState: state));
    await tester.pumpAndSettle();

    expect(find.text('5 min'), findsOneWidget);

    await tester.tap(find.byKey(const Key('refreshIntervalMenu')));
    await tester.pumpAndSettle();
    for (final label in const [
      'Every 1 minute',
      'Every 3 minutes',
      'Every 5 minutes',
      'Every 10 minutes',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await tester.tap(find.text('Manual').last);
    await tester.pumpAndSettle();

    expect(find.text('Manual'), findsOneWidget);
    expect(settings.refreshMinutes, 0);

    await tester.tap(find.byKey(const Key('refreshIntervalMenu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Every 10 minutes').last);
    await tester.pumpAndSettle();

    expect(find.text('10 min'), findsOneWidget);
    expect(settings.refreshMinutes, 10);
    state.dispose();
  });

  testWidgets('late initial load cannot overwrite a newer interval choice', (tester) async {
    final settings = _BlockingSettingsRepository(5);
    final state = AppState.test(
      connectionRepository: connectionRepo,
      quotaCacheRepository: quotaCacheRepo,
      secretStore: store,
      settingsRepository: settings,
    );
    await tester.pumpWidget(TestConnectionsScreen(appState: state));
    await tester.pump();

    await tester.tap(find.byKey(const Key('refreshIntervalMenu')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Every 10 minutes').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('10 min'), findsOneWidget);

    settings.completeLoad();
    await tester.pumpAndSettle();

    expect(find.text('10 min'), findsOneWidget);
    expect(settings.persistedMinutes, 10);
    state.dispose();
  });

  group('ConnectionsScreen - Antigravity remote OAuth', () {
    testWidgets(
      'onboards remote account through Google without credential field',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        const secret =
            '{"accessToken":"ui-access","refreshToken":"ui-refresh"}';
        final provider = _ControlledAntigravityOAuthProvider(
          const AntigravityOAuthLoginResult(
            secret: secret,
            identityKey: 'ui@example.com|ui-account',
            projectId: 'ui-project',
            tier: 'pro',
          ),
        );
        final registry = ProviderRegistry(registerDefaults: false)
          ..register(
            FakeProviderAdapter(
              id: 'openrouter',
              name: 'OpenRouter',
              authKind: AuthKind.apiKey,
              testResult: TestResult.success(quotas: const []),
            ),
          )
          ..register(provider);
        final state = AppState.test(
          connectionRepository: connectionRepo,
          quotaCacheRepository: quotaCacheRepo,
          secretStore: store,
          providerRegistry: registry,
        );
        addTearDown(state.dispose);
        await tester.pumpWidget(TestConnectionsScreen(appState: state));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('addConnection')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('connectionProviderField')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Antigravity').last);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('antigravitySourceField')), findsOneWidget);
        expect(find.text('remote'), findsOneWidget);
        expect(
          find.byKey(const Key('connectionCredentialField')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('antigravitySignInButton')),
          findsOneWidget,
        );
        expect(find.text('Sign in with Google'), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('connectionDisplayNameField')),
          'Google Antigravity',
        );
        await tester.tap(find.byKey(const Key('antigravitySignInButton')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('connectionFormDialogTitle')),
          findsNothing,
        );
        final row = (await connectionRepo.getAll()).single;
        expect(row.provider, 'antigravity');
        expect(row.authType, 'oauth');
        expect(jsonDecode(row.providerData!), {
          'source': 'remote',
          'projectId': 'ui-project',
          'tier': 'pro',
        });
        expect(store.entries, {row.credentialRef: secret});
      },
    );

    testWidgets('onboarding requirement explains the next action', (tester) async {
      final registry = ProviderRegistry(registerDefaults: false)
        ..register(_OnboardingRequiredAntigravityProvider());
      final state = AppState.test(
        connectionRepository: connectionRepo,
        quotaCacheRepository: quotaCacheRepo,
        secretStore: store,
        providerRegistry: registry,
      );
      addTearDown(state.dispose);
      await tester.pumpWidget(TestConnectionsScreen(appState: state));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('addConnection')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('connectionDisplayNameField')),
        'Antigravity account',
      );
      await tester.tap(find.byKey(const Key('antigravitySignInButton')));
      await tester.pumpAndSettle();

      expect(
        find.text('Complete onboarding in Antigravity, then try again.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('connectionFormDialogTitle')),
        findsOneWidget,
      );
      expect(await connectionRepo.getAll(), isEmpty);
      expect(store.entries, isEmpty);
    });

    testWidgets('cancelling Google sign-in keeps the onboarding dialog open', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final loginGate = Completer<AntigravityOAuthLoginResult>();
      final provider = _ControlledAntigravityOAuthProvider(
        const AntigravityOAuthLoginResult(
          secret: '{"accessToken":"unused"}',
          identityKey: 'cancelled@example.com|cancelled-account',
          projectId: 'unused-project',
          tier: 'free',
        ),
        loginGate: loginGate,
      );
      final registry = ProviderRegistry(registerDefaults: false)
        ..register(provider);
      final state = AppState.test(
        connectionRepository: connectionRepo,
        quotaCacheRepository: quotaCacheRepo,
        secretStore: store,
        providerRegistry: registry,
      );
      addTearDown(state.dispose);
      await tester.pumpWidget(TestConnectionsScreen(appState: state));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('addConnection')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('connectionProviderField')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Antigravity').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('connectionDisplayNameField')),
        'Cancelled Antigravity',
      );
      await tester.tap(find.byKey(const Key('antigravitySignInButton')));
      await tester.pump();

      expect(
        find.byKey(const Key('antigravityCancelLoginButton')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('antigravityCancelLoginButton')));
      loginGate.complete(provider.result);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('connectionFormDialogTitle')),
        findsOneWidget,
      );
      expect(await connectionRepo.getAll(), isEmpty);
      expect(store.entries, isEmpty);
    });
    testWidgets('closing dialog during Google sign-in prevents persistence', (
      tester,
    ) async {
      final loginGate = Completer<AntigravityOAuthLoginResult>();
      final provider = _ControlledAntigravityOAuthProvider(
        const AntigravityOAuthLoginResult(
          secret: '{"accessToken":"must-not-persist"}',
          identityKey: 'closed@example.com|closed-account',
          projectId: 'closed-project',
          tier: 'free',
        ),
        loginGate: loginGate,
      );
      final registry = ProviderRegistry(registerDefaults: false)
        ..register(provider);
      final state = AppState.test(
        connectionRepository: connectionRepo,
        quotaCacheRepository: quotaCacheRepo,
        secretStore: store,
        providerRegistry: registry,
      );
      addTearDown(state.dispose);
      await tester.pumpWidget(TestConnectionsScreen(appState: state));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('addConnection')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('connectionProviderField')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Antigravity').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('connectionDisplayNameField')),
        'Closed dialog',
      );
      await tester.tap(find.byKey(const Key('antigravitySignInButton')));
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      loginGate.complete(provider.result);
      await tester.pumpAndSettle();
      expect(await connectionRepo.getAll(), isEmpty);
      expect(store.entries, isEmpty);
    });

    testWidgets(
      'reconnects remote account in place and preserves cached quota',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        const existing = Connection(
          id: 'ui-antigravity-reconnect',
          provider: 'antigravity',
          displayName: 'Antigravity account',
          group: null,
          plan: 'free',
          credentialRef: 'ui-old-secret',
          enabled: true,
          authType: 'oauth',
          identityKey: 'old@example.com|old-account',
          providerData:
              '{"source":"remote","projectId":"old-project","tier":"free"}',
        );
        const cached = Quota(
          id: 'ui-cached-quota',
          label: 'Cached Antigravity quota',
          percent: 20,
          remaining: 80,
          limit: 100,
          unit: 'requests',
          resetAt: null,
        );
        const replacementSecret =
            '{"accessToken":"new-ui-access","refreshToken":"new-ui-refresh"}';
        final oauthProvider = _ControlledAntigravityOAuthProvider(
          const AntigravityOAuthLoginResult(
            secret: replacementSecret,
            identityKey: 'new@example.com|new-account',
            projectId: 'new-ui-project',
            tier: 'enterprise',
          ),
        );
        final registry = ProviderRegistry(registerDefaults: false)
          ..register(
            FakeProviderAdapter(
              id: 'openrouter',
              name: 'OpenRouter',
              authKind: AuthKind.apiKey,
              testResult: TestResult.success(quotas: const []),
            ),
          )
          ..register(oauthProvider);
        final disabledProvider = ControlledProvider(id: 'antigravity')
          ..onFetch = (_, _) async => ProviderSnapshot(
            connectionId: existing.id,
            status: ConnectionStatus.authError,
            quotas: const [],
            balance: null,
            fetchedAt: DateTime.now().toUtc(),
            error: '401',
            failureCause: ProviderFailureCause.invalidCredential,
          );
        await connectionRepo.save(existing);
        await quotaCacheRepo.saveAll(existing.id, const [cached]);
        await store.write(existing.credentialRef, '{"accessToken":"old"}');
        final state = AppState.test(
          connectionRepository: connectionRepo,
          quotaCacheRepository: quotaCacheRepo,
          secretStore: store,
          providerRegistry: registry,
          refreshService: RefreshService.forTest(
            provider: disabledProvider,
            connectionRepository: connectionRepo,
            quotaCacheRepository: quotaCacheRepo,
            secretStore: store,
          ),
        );
        addTearDown(state.dispose);
        await tester.pumpWidget(TestConnectionsScreen(appState: state));
        await tester.pumpAndSettle();
        await state.refreshOne(existing.id);
        await tester.pump();

        expect(
          find.byKey(Key('reconnectConnection_${existing.id}')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(Key('reconnectConnection_${existing.id}')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('connectionCredentialField')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('antigravitySignInButton')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('antigravitySignInButton')));
        await tester.pumpAndSettle();

        expect(find.text('Edit Connection'), findsNothing);
        final rows = await connectionRepo.getAll();
        expect(rows, hasLength(1));
        final row = rows.single;
        expect(row.id, existing.id);
        expect(row.credentialRef, isNot(existing.credentialRef));
        expect(store.entries, {row.credentialRef: replacementSecret});
        expect(await quotaCacheRepo.getAll(existing.id), [cached]);
        expect(state.requiresReconnect(existing.id), isFalse);
      },
    );
  });
  group('ConnectionsScreen - Test-Before-Save Gate', () {
    testWidgets('Save remains disabled until a connection test succeeds', (
      tester,
    ) async {
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
      final saveBtnInitial = tester.widget<ElevatedButton>(
        find.byKey(const Key('saveConnection')),
      );
      expect(saveBtnInitial.onPressed, isNull);

      // Fill in fields
      await tester.enterText(
        find.byKey(const Key('connectionDisplayNameField')),
        'My Test Key',
      );
      await tester.enterText(
        find.byKey(const Key('connectionCredentialField')),
        'sk-bad-key',
      );
      await tester.pumpAndSettle();

      // Save button remains disabled after typing
      final saveBtnAfterTyping = tester.widget<ElevatedButton>(
        find.byKey(const Key('saveConnection')),
      );
      expect(saveBtnAfterTyping.onPressed, isNull);

      // Tap Test Connection
      await tester.tap(find.byKey(const Key('testConnectionButton')));
      await tester.pumpAndSettle();

      // Failure error message is displayed
      expect(find.text('Invalid API key'), findsOneWidget);

      // Save button is STILL disabled
      final saveBtnAfterFail = tester.widget<ElevatedButton>(
        find.byKey(const Key('saveConnection')),
      );
      expect(saveBtnAfterFail.onPressed, isNull);
    });

    testWidgets(
      'stale test completion after provider change cannot enable Save',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final started = Completer<void>();
        final gate = Completer<void>();
        final openRouter = _GatedControlledProvider(
          id: 'openrouter',
          name: 'OpenRouter',
          started: started,
          gate: gate,
          result: TestResult.success(quotas: const []),
        );
        final antigravity = ControlledProvider(
          id: 'antigravity',
          name: 'Antigravity',
        );
        final registry = ProviderRegistry(registerDefaults: false)
          ..register(openRouter)
          ..register(antigravity);

        await tester.pumpWidget(
          TestConnectionsScreen(
            connectionRepo: connectionRepo,
            quotaCacheRepo: quotaCacheRepo,
            secretStore: store,
            registry: registry,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('addConnection')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('connectionDisplayNameField')),
          'Stale completion',
        );
        await tester.enterText(
          find.byKey(const Key('connectionCredentialField')),
          'sk-stale-completion',
        );
        await tester.tap(find.byKey(const Key('testConnectionButton')));
        await tester.pump();
        await started.future;

        await tester.tap(find.byKey(const Key('connectionProviderField')));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Antigravity').last);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.byKey(const Key('antigravitySourceField')));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('language-server').last);
        await tester.pump(const Duration(milliseconds: 300));
        gate.complete();
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          tester
              .widget<ElevatedButton>(find.byKey(const Key('saveConnection')))
              .onPressed,
          isNull,
        );
        expect(find.text('Connected'), findsNothing);
      },
    );
    testWidgets('changing credential during in-flight test cannot enable Save', (tester) async {
      final started = Completer<void>();
      final gate = Completer<void>();
      final provider = _GatedControlledProvider(
        id: 'openrouter', name: 'OpenRouter', started: started, gate: gate,
        result: TestResult.success(quotas: const []),
      );
      final registry = ProviderRegistry(registerDefaults: false)..register(provider);
      await tester.pumpWidget(TestConnectionsScreen(
        connectionRepo: connectionRepo, quotaCacheRepo: quotaCacheRepo,
        secretStore: store, registry: registry,
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('addConnection')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('connectionDisplayNameField')), 'Stale');
      await tester.enterText(find.byKey(const Key('connectionCredentialField')), 'old');
      await tester.tap(find.byKey(const Key('testConnectionButton')));
      await tester.pump();
      await started.future;
      await tester.enterText(find.byKey(const Key('connectionCredentialField')), 'new');
      gate.complete();
      await tester.pumpAndSettle();
      expect(tester.widget<ElevatedButton>(find.byKey(const Key('saveConnection'))).onPressed, isNull);
      expect(find.text('Connected'), findsNothing);
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
          find.byKey(const Key('connectionDisplayNameField')),
          'OpenRouter Main',
        );
        await tester.enterText(
          find.byKey(const Key('connectionGroupField')),
          'Production',
        );
        await tester.enterText(
          find.byKey(const Key('connectionCredentialField')),
          'sk-or-v1-validsecretkey1234',
        );
        await tester.pumpAndSettle();

        // Save disabled before test
        expect(
          tester
              .widget<ElevatedButton>(find.byKey(const Key('saveConnection')))
              .onPressed,
          isNull,
        );

        // Tap Test Connection
        await tester.tap(find.byKey(const Key('testConnectionButton')));
        await tester.pumpAndSettle();

        // Connected and quota preview displayed
        expect(find.text('Connected'), findsOneWidget);
        expect(
          find.textContaining('Credits: 50.0 / 100.0 USD'),
          findsOneWidget,
        );

        // Save button is now enabled
        final saveBtnEnabled = tester.widget<ElevatedButton>(
          find.byKey(const Key('saveConnection')),
        );
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
      },
    );

    testWidgets(
      'local Antigravity source tests without credentials and persists the selected source',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final openRouter = FakeProviderAdapter(
          testResult: TestResult.success(quotas: const []),
        );
        final antigravity = FakeProviderAdapter(
          id: 'antigravity',
          name: 'Antigravity',
          authKind: AuthKind.none,
          testResult: TestResult.success(
            quotas: const [
              Quota(
                id: 'local-usage',
                label: 'Local usage',
                percent: 25,
                remaining: 25,
                limit: 100,
                unit: '%',
                resetAt: null,
              ),
            ],
          ),
        );
        final registry = ProviderRegistry(registerDefaults: false)
          ..register(openRouter)
          ..register(antigravity);

        await tester.pumpWidget(
          TestConnectionsScreen(
            connectionRepo: connectionRepo,
            quotaCacheRepo: quotaCacheRepo,
            secretStore: store,
            registry: registry,
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('addConnection')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('connectionProviderField')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Antigravity'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('antigravitySourceField')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('language-server'));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('connectionCredentialField')),
          findsNothing,
        );

        await tester.enterText(
          find.byKey(const Key('connectionDisplayNameField')),
          'Local Antigravity',
        );
        await tester.tap(find.byKey(const Key('testConnectionButton')));
        await tester.pumpAndSettle();

        expect(find.text('Connected'), findsOneWidget);

        await tester.tap(find.byKey(const Key('saveConnection')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('saveConnection')), findsNothing);
        final saved = (await connectionRepo.getAll()).single;
        expect(saved.provider, 'antigravity');
        expect(saved.authType, anyOf(isNull, 'none'));
        expect(jsonDecode(saved.providerData!), {'source': 'language-server'});
        expect(store.entries, isEmpty);
        expect(
          (await quotaCacheRepo.getAll(saved.id)).single.label,
          'Local usage',
        );
      },
    );

    testWidgets(
      'editing a local Antigravity connection preserves provider metadata without a secret store',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final existing = Connection(
          id: 'local-existing',
          provider: 'antigravity',
          displayName: 'Local Antigravity',
          group: 'Workstation',
          plan: null,
          credentialRef: '',
          enabled: false,
          authType: 'none',
          identityKey: 'local-identity',
          providerData: jsonEncode({
            'source': 'language-server',
            'port': 43123,
            'agyBin': 'C:/tools/agy.exe',
          }),
        );
        await connectionRepo.save(existing);
        final antigravity = FakeProviderAdapter(
          id: 'antigravity',
          name: 'Antigravity',
          authKind: AuthKind.none,
          testResult: TestResult.success(
            quotas: const [
              Quota(
                id: 'local-usage',
                label: 'Local usage',
                percent: 25,
                remaining: 25,
                limit: 100,
                unit: '%',
                resetAt: null,
              ),
            ],
          ),
        );
        final registry = ProviderRegistry(registerDefaults: false)
          ..register(
            FakeProviderAdapter(
              id: 'openrouter',
              name: 'OpenRouter',
              testResult: TestResult.success(quotas: const []),
            ),
          )
          ..register(antigravity);

        await tester.pumpWidget(
          TestConnectionsScreen(
            connectionRepo: connectionRepo,
            quotaCacheRepo: quotaCacheRepo,
            registry: registry,
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('editConnection_local-existing')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('connectionCredentialField')),
          findsNothing,
        );
        await tester.enterText(
          find.byKey(const Key('connectionDisplayNameField')),
          'Updated Local Antigravity',
        );
        await tester.ensureVisible(
          find.byKey(const Key('testConnectionButton')),
        );
        await tester.tap(find.byKey(const Key('testConnectionButton')));
        await tester.pumpAndSettle();

        final testedData = jsonDecode(
          antigravity.lastTestedConnection!.providerData!,
        );
        expect(testedData, {
          'source': 'language-server',
          'port': 43123,
          'agyBin': 'C:/tools/agy.exe',
        });
        await tester.ensureVisible(find.byKey(const Key('saveConnection')));
        await tester.tap(find.byKey(const Key('saveConnection')));
        await tester.pumpAndSettle();

        final saved = (await connectionRepo.getAll()).single;
        expect(saved.id, existing.id);
        expect(saved.displayName, 'Updated Local Antigravity');
        expect(saved.enabled, isFalse);
        expect(saved.authType, 'none');
        expect(saved.identityKey, 'local-identity');
        expect(jsonDecode(saved.providerData!), testedData);
        expect(
          (await quotaCacheRepo.getAll(saved.id)).single.label,
          'Local usage',
        );
      },
    );

    testWidgets(
      'local keyless edit and remove do not access empty credential ref',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        const existing = Connection(
          id: 'local-keyless-edit-remove',
          provider: 'antigravity',
          displayName: 'Local Keyless',
          group: null,
          plan: null,
          credentialRef: '',
          enabled: true,
          authType: 'none',
          identityKey: 'local-keyless',
          providerData: '{"source":"language-server"}',
        );
        await connectionRepo.save(existing);
        final guardedStore = _EmptyKeyRejectingSecretStore(store);
        final registry = ProviderRegistry(registerDefaults: false)
          ..register(
            FakeProviderAdapter(
              id: 'antigravity',
              name: 'Antigravity',
              authKind: AuthKind.none,
              testResult: TestResult.success(quotas: const []),
            ),
          );

        await tester.pumpWidget(
          TestConnectionsScreen(
            connectionRepo: connectionRepo,
            quotaCacheRepo: quotaCacheRepo,
            secretStore: guardedStore,
            registry: registry,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('editConnection_local-keyless-edit-remove')),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('connectionDisplayNameField')),
          'Edited Local Keyless',
        );
        await tester.ensureVisible(
          find.byKey(const Key('testConnectionButton')),
        );
        await tester.tap(find.byKey(const Key('testConnectionButton')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('saveConnection')));
        await tester.tap(find.byKey(const Key('saveConnection')));
        await tester.pumpAndSettle();

        final edited = (await connectionRepo.getAll()).single;
        expect(edited.credentialRef, isEmpty);
        expect(edited.displayName, 'Edited Local Keyless');

        await tester.tap(
          find.byKey(
            const Key('deleteConnection_local-keyless-edit-remove'),
          ),
        );
        await tester.pumpAndSettle();

        expect(await connectionRepo.getAll(), isEmpty);
        expect(find.text('No connections yet'), findsOneWidget);
      },
    );

    testWidgets('editing an unregistered existing provider renders the form', (
      tester,
    ) async {
      final existing = Connection(
        id: 'custom-provider',
        provider: 'custom-provider',
        displayName: 'Custom Provider',
        group: null,
        plan: null,
        credentialRef: 'custom-secret',
        enabled: true,
      );
      await connectionRepo.save(existing);
      final registry = ProviderRegistry(registerDefaults: false)
        ..register(
          FakeProviderAdapter(testResult: TestResult.success(quotas: const [])),
        );

      await tester.pumpWidget(
        TestConnectionsScreen(
          connectionRepo: connectionRepo,
          quotaCacheRepo: quotaCacheRepo,
          secretStore: store,
          registry: registry,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('editConnection_custom-provider')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('connectionProviderField')), findsOneWidget);
      expect(find.text('custom-provider'), findsNWidgets(2));
    });

    testWidgets(
      'add defaults to the first injected provider when openrouter is absent',
      (tester) async {
        final antigravity = FakeProviderAdapter(
          id: 'antigravity',
          name: 'Antigravity',
          authKind: AuthKind.none,
          testResult: TestResult.success(quotas: const []),
        );
        final registry = ProviderRegistry(registerDefaults: false)
          ..register(antigravity);

        await tester.pumpWidget(
          TestConnectionsScreen(
            connectionRepo: connectionRepo,
            quotaCacheRepo: quotaCacheRepo,
            secretStore: store,
            registry: registry,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('addConnection')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('connectionProviderField')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('antigravitySourceField')), findsOneWidget);
      },
    );

    testWidgets(
      'local schema revalidation removes quarantine marker and preserves metadata',
      (tester) async {
        final existing = Connection(
          id: 'local-schema',
          provider: 'antigravity',
          displayName: 'Schema Local',
          group: null,
          plan: null,
          credentialRef: '',
          enabled: true,
          authType: 'none',
          providerData: jsonEncode({
            'source': 'language-server',
            'port': 43125,
            'quotaSourceDisabled': true,
          }),
        );
        await connectionRepo.save(existing);
        final adapter = FakeProviderAdapter(
          id: 'antigravity',
          name: 'Antigravity',
          authKind: AuthKind.none,
          testResult: TestResult.success(
            quotas: const [],
            schemaRevalidated: true,
          ),
        );
        final registry = ProviderRegistry(registerDefaults: false)
          ..register(adapter);

        await tester.pumpWidget(
          TestConnectionsScreen(
            connectionRepo: connectionRepo,
            quotaCacheRepo: quotaCacheRepo,
            secretStore: store,
            registry: registry,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('editConnection_local-schema')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const Key('testConnectionButton')),
        );
        await tester.tap(find.byKey(const Key('testConnectionButton')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('saveConnection')));
        await tester.tap(find.byKey(const Key('saveConnection')));
        await tester.pumpAndSettle();

        final saved = (await connectionRepo.getAll()).single;
        final data = jsonDecode(saved.providerData!) as Map<String, dynamic>;
        expect(data.containsKey('quotaSourceDisabled'), isFalse);
        expect(data['source'], 'language-server');
        expect(data['port'], 43125);
      },
    );

    testWidgets(
      'local existing test does not prefer an empty stored credential',
      (tester) async {
        final existing = Connection(
          id: 'local-refresh',
          provider: 'antigravity',
          displayName: 'Local Refresh',
          group: null,
          plan: null,
          credentialRef: '',
          enabled: true,
          authType: 'none',
          providerData: jsonEncode({
            'source': 'language-server',
            'port': 43124,
          }),
        );
        await connectionRepo.save(existing);
        final adapter = ControlledProvider(id: 'antigravity');
        final registry = ProviderRegistry(registerDefaults: false)
          ..register(adapter);
        final service = RefreshService.forTest(
          provider: adapter,
          connectionRepository: connectionRepo,
          quotaCacheRepository: quotaCacheRepo,
          secretStore: MemorySecretStore(),
          providerRegistry: registry,
        );
        final state = AppState.test(
          connectionRepository: connectionRepo,
          quotaCacheRepository: quotaCacheRepo,
          secretStore: MemorySecretStore(),
          providerRegistry: registry,
          refreshService: service,
        );
        addTearDown(service.dispose);

        await tester.pumpWidget(
          MaterialApp(home: ConnectionsScreen(appState: state)),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('editConnection_local-refresh')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const Key('testConnectionButton')),
        );
        await tester.tap(find.byKey(const Key('testConnectionButton')));
        await tester.pumpAndSettle();

        expect(find.text('Connected'), findsNWidgets(2));
        expect(adapter.testCalls, 1);
      },
    );

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
          find.byKey(const Key('connectionDisplayNameField')),
          'OAuth',
        );
        await tester.enterText(
          find.byKey(const Key('connectionCredentialField')),
          'old-secret',
        );
        await tester.tap(find.byKey(const Key('testConnectionButton')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('saveConnection')));
        await tester.pumpAndSettle();

        final saved = (await connectionRepo.getAll()).single;
        expect(await store.read(saved.credentialRef), 'rotated-secret');
      },
    );

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
          find.byKey(const Key('connectionDisplayNameField')),
          'Key A',
        );
        await tester.enterText(
          find.byKey(const Key('connectionCredentialField')),
          'sk-key-first',
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('testConnectionButton')));
        await tester.pumpAndSettle();

        // Save button is enabled
        expect(
          tester
              .widget<ElevatedButton>(find.byKey(const Key('saveConnection')))
              .onPressed,
          isNotNull,
        );

        // Edit credential
        await tester.enterText(
          find.byKey(const Key('connectionCredentialField')),
          'sk-key-modified',
        );
        await tester.pumpAndSettle();

        // Save button MUST be disabled again
        expect(
          tester
              .widget<ElevatedButton>(find.byKey(const Key('saveConnection')))
              .onPressed,
          isNull,
        );
      },
    );
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
          find.byKey(const Key('connectionDisplayNameField')),
          'Fail Conn',
        );
        await tester.enterText(
          find.byKey(const Key('connectionCredentialField')),
          'sk-transient-secret-key',
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('testConnectionButton')));
        await tester.pumpAndSettle();

        // Save enabled
        expect(
          tester
              .widget<ElevatedButton>(find.byKey(const Key('saveConnection')))
              .onPressed,
          isNotNull,
        );

        // Tap Save
        await tester.ensureVisible(find.byKey(const Key('saveConnection')));
        await tester.tap(find.byKey(const Key('saveConnection')));
        await tester.pumpAndSettle();

        // Secret was rolled back and removed from secret store!
        expect(store.entries.isEmpty, isTrue);

        // The failure is reported with the caller's own copy. The exception
        // text must not reach the UI: a real storage failure carries SQL,
        // table names and driver codes (audit C-12, C-15).
        expect(find.text('Could not save this connection.'), findsOneWidget);
        expect(find.textContaining('Database write failed'), findsNothing);
      },
    );

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
        await tester.tap(
          find.byKey(const Key('editConnection_conn-replace-1')),
        );
        await tester.pumpAndSettle();

        // Masked secret is displayed
        expect(find.text('sk-...1111'), findsOneWidget);

        // Enter new secret
        await tester.enterText(
          find.byKey(const Key('connectionCredentialField')),
          'sk-or-v1-newsecretkey2222',
        );
        await tester.pumpAndSettle();

        // Save button disabled because secret changed
        expect(
          tester
              .widget<ElevatedButton>(find.byKey(const Key('saveConnection')))
              .onPressed,
          isNull,
        );

        // Test connection
        await tester.tap(find.byKey(const Key('testConnectionButton')));
        await tester.pumpAndSettle();

        // Save button now enabled
        expect(
          tester
              .widget<ElevatedButton>(find.byKey(const Key('saveConnection')))
              .onPressed,
          isNotNull,
        );

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
        expect(
          await store.read(updatedConn.credentialRef),
          'sk-or-v1-newsecretkey2222',
        );
      },
    );

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
        await tester.tap(
          find.byKey(const Key('deleteConnection_conn-to-delete')),
        );
        await tester.pumpAndSettle();

        // Connection is deleted from repository
        final conns = await connectionRepo.getAll();
        expect(conns.isEmpty, isTrue);

        // Secret is deleted from secret store
        expect(await store.read(secretRef), isNull);
        expect(store.entries.isEmpty, isTrue);

        // Screen shows empty state
        expect(find.text('No connections yet'), findsOneWidget);
      },
    );

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
        await tester.tap(
          find.byKey(const Key('editConnection_conn-mask-test')),
        );
        await tester.pumpAndSettle();

        // Masked secret (sk-...9999) is displayed
        expect(find.text('sk-...9999'), findsOneWidget);

        // Plaintext secret is NEVER revealed in the widget tree
        expect(find.text(secretValue), findsNothing);
      },
    );

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

      const reconnectConnection = Connection(
        id: 'conn-reconnect',
        provider: 'antigravity',
        displayName: 'Antigravity account',
        group: null,
        plan: null,
        credentialRef: 'secret-reconnect',
        enabled: true,
      );
      const cached = Quota(
        id: 'cached',
        label: 'Cached quota',
        percent: 20,
        remaining: 80,
        limit: 100,
        unit: null,
        resetAt: null,
      );
      final reconnectRepo = MemoryConnectionRepository([reconnectConnection]);
      final reconnectCache = MemoryQuotaCacheRepository({
        reconnectConnection.id: const [cached],
      });
      final provider = ControlledProvider(id: 'antigravity')
        ..onFetch = (_, _) async => ProviderSnapshot(
          connectionId: reconnectConnection.id,
          status: ConnectionStatus.authError,
          quotas: const [],
          balance: null,
          fetchedAt: DateTime.now().toUtc(),
          error: '401',
          failureCause: ProviderFailureCause.invalidCredential,
        );
      final reconnectState = AppState.test(
        connectionRepository: reconnectRepo,
        quotaCacheRepository: reconnectCache,
        secretStore: MemorySecretStore({'secret-reconnect': 'secret'}),
        refreshService: RefreshService.forTest(
          provider: provider,
          connectionRepository: reconnectRepo,
          quotaCacheRepository: reconnectCache,
          secretStore: MemorySecretStore({'secret-reconnect': 'secret'}),
        ),
      );
      addTearDown(reconnectState.dispose);
      await tester.pumpWidget(
        MaterialApp(home: ConnectionsScreen(appState: reconnectState)),
      );
      await tester.pumpAndSettle();
      await reconnectState.refreshOne(reconnectConnection.id);
      await tester.pump();
      expect(find.byIcon(Icons.link_off), findsOneWidget);
      expect(find.text('Reconnect'), findsOneWidget);
      expect(
        reconnectState.accounts.single.snapshot.quotas.single.label,
        'Cached quota',
      );
    });
  });

  group('AppState - Direct transaction & compensation tests', () {
    test(
      'addConnection writes secret, saves connection, and handles rollback',
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
      },
    );

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

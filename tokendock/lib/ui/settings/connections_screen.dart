import 'package:flutter/material.dart';

import 'dart:async';

import '../../providers/antigravity/antigravity_oauth.dart';

import 'dart:convert';

import '../../app/app_state.dart';
import '../../models/connection.dart';
import '../../models/test_result.dart';
import '../../providers/provider_adapter.dart';
import '../../providers/provider_registry.dart';
import '../../storage/connection_repository.dart';
import '../../storage/quota_cache_repository.dart';
import '../../storage/secret_store.dart';
import '../../services/error_copy.dart';
import '../components/status_indicator.dart';
import '../../app/theme.dart';

/// Screen for managing AI provider connections (CRUD operations).
///
/// Implements the test-before-save gate: a connection must be tested and
/// validated before it can be persisted, and credentials are saved using
/// compensation logic to prevent orphaned database records or secure storage entries.
class ConnectionsScreen extends StatefulWidget {
  const ConnectionsScreen({
    super.key,
    this.appState,
    this.connectionRepository,
    this.quotaCacheRepository,
    this.secretStore,
    this.adapter,
    this.providerRegistry,
  });

  final AppState? appState;
  final ConnectionRepository? connectionRepository;
  final QuotaCacheRepository? quotaCacheRepository;
  final SecretStore? secretStore;
  final ProviderAdapter? adapter;
  final ProviderRegistry? providerRegistry;

  @override
  State<ConnectionsScreen> createState() => _ConnectionsScreenState();
}

class _ConnectionsScreenState extends State<ConnectionsScreen> {
  late final AppState _state;
  bool _ownsState = false;

  @override
  void initState() {
    super.initState();
    if (widget.appState != null) {
      _state = widget.appState!;
      _ownsState = false;
    } else {
      _state = AppState(
        connectionRepository: widget.connectionRepository,
        quotaCacheRepository: widget.quotaCacheRepository,
        secretStore: widget.secretStore,
        providerRegistry: widget.providerRegistry,
      );
      _ownsState = true;
    }
    _state.addListener(_onStateChanged);
    _state.load();
  }

  void _onStateChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  PopupMenuButton<int> _buildRefreshIntervalMenu(BuildContext context) {
    final selected = _state.refreshIntervalMinutes;
    return PopupMenuButton<int>(
      key: const Key('refreshIntervalMenu'),
      tooltip: 'Refresh interval',
      onSelected: _setRefreshInterval,
      itemBuilder: (context) => const [
        PopupMenuItem(value: 0, child: Text('Manual')),
        PopupMenuItem(value: 1, child: Text('Every 1 minute')),
        PopupMenuItem(value: 3, child: Text('Every 3 minutes')),
        PopupMenuItem(value: 5, child: Text('Every 5 minutes')),
        PopupMenuItem(value: 10, child: Text('Every 10 minutes')),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.timer_outlined),
            const SizedBox(width: 6),
            Text(selected == 0 ? 'Manual' : '$selected min'),
          ],
        ),
      ),
    );
  }

  Future<void> _setRefreshInterval(int minutes) async {
    try {
      await _state.setRefreshIntervalMinutes(minutes);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to update refresh interval.')),
        );
      }
    }
  }

  @override
  void dispose() {
    _state.removeListener(_onStateChanged);
    if (_ownsState) {
      _state.dispose();
    }
    super.dispose();
  }

  Future<void> _openDialog(BuildContext context, {Connection? existing}) async {
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return _ConnectionFormDialog(
          existing: existing,
          appState: _state,
          secretStore: widget.secretStore ?? _state.secretStore,
          connectionRepository:
              widget.connectionRepository ?? _state.connectionRepository,
          quotaCacheRepository:
              widget.quotaCacheRepository ?? _state.quotaCacheRepository,
          adapter: widget.adapter,
          providerRegistry: widget.providerRegistry ?? _state.providerRegistry,
        );
      },
    );
  }

  Future<void> _deleteConnection(
    BuildContext context,
    Connection connection,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final warning = await _state.removeConnection(connection.id);
      if (warning != null) {
        messenger.showSnackBar(SnackBar(content: Text(warning)));
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            userSafeErrorMessage(
              e,
              fallback: 'Could not remove this connection.',
            ),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final accounts = _state.accounts;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Connections'),
        actions: [_buildRefreshIntervalMenu(context)],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('addConnection'),
        tooltip: 'Add Connection',
        onPressed: () => _openDialog(context),
        icon: const Icon(Icons.add),
        label: const Text('Add Connection'),
      ),
      body: _buildBody(context, accounts),
    );
  }

  Widget _buildBody(BuildContext context, List<AccountItem> accounts) {
    if (_state.isLoading && accounts.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    final colors = TokenDockTheme.colorsOf(context);

    if (accounts.isEmpty) {
      return FocusTraversalGroup(
        policy: ReadingOrderTraversalPolicy(),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cable, size: 48, color: colors.mutedInk),
              const SizedBox(height: 16),
              Text(
                'No connections yet',
                style: TokenDockTypography.bodyStyle(color: colors.mutedInk)
                    .copyWith(fontSize: 16, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                key: const Key('addConnectionEmpty'),
                onPressed: () => _openDialog(context),
                icon: const Icon(Icons.add),
                label: const Text('Add Connection'),
              ),
            ],
          ),
        ),
      );
    }

    return FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: ListView.separated(
        itemCount: accounts.length,
        separatorBuilder: (_, _) => Divider(color: colors.hairline, height: 1),
        itemBuilder: (context, index) {
          final account = accounts[index];
          final conn = account.connection;

          return ListTile(
            key: Key('connectionTile_${conn.id}'),
            leading: Icon(Icons.hub_outlined, color: colors.ink),
            title: Text(
              conn.displayName,
              style: TokenDockTypography.bodyStyle(color: colors.ink),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  conn.group != null && conn.group!.isNotEmpty
                      ? '${conn.provider} • ${conn.group}'
                      : conn.provider,
                  style: TokenDockTypography.captionStyle(
                    color: colors.mutedInk,
                  ),
                ),
                const SizedBox(height: 4),
                StatusIndicator(status: account.snapshot.status),
                if (_state.requiresReconnect(conn.id)) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.link_off, size: 18),
                      const SizedBox(width: 6),
                      const Expanded(
                        child: Text(
                          'Reconnect required. Cached quotas remain available.',
                        ),
                      ),
                      TextButton.icon(
                        key: Key('reconnectConnection_${conn.id}'),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Reconnect'),
                        onPressed: () => _openDialog(context, existing: conn),
                      ),
                    ],
                  ),
                ],
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  key: Key('toggleConnection_${conn.id}'),
                  value: conn.enabled,
                  onChanged: (val) {
                    _state.toggleConnectionEnabled(conn.id, val);
                  },
                ),
                IconButton(
                  key: Key('editConnection_${conn.id}'),
                  icon: const Icon(Icons.edit),
                  tooltip: 'Edit',
                  onPressed: () => _openDialog(context, existing: conn),
                ),
                IconButton(
                  key: Key('deleteConnection_${conn.id}'),
                  icon: const Icon(Icons.delete),
                  tooltip: 'Remove',
                  onPressed: () => _deleteConnection(context, conn),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ConnectionFormDialog extends StatefulWidget {
  const _ConnectionFormDialog({
    this.existing,
    required this.appState,
    this.secretStore,
    this.connectionRepository,
    this.quotaCacheRepository,
    this.adapter,
    this.providerRegistry,
  });

  final Connection? existing;
  final AppState appState;
  final SecretStore? secretStore;
  final ConnectionRepository? connectionRepository;
  final QuotaCacheRepository? quotaCacheRepository;
  final ProviderAdapter? adapter;
  final ProviderRegistry? providerRegistry;

  @override
  State<_ConnectionFormDialog> createState() => _ConnectionFormDialogState();
}

class _ConnectionFormDialogState extends State<_ConnectionFormDialog> {
  late final TextEditingController _displayNameController;
  late final TextEditingController _groupController;
  late final TextEditingController _credentialController;
  late String _providerId;
  late String _antigravitySource;

  /// Masked text shown in the credential field while editing.
  String? _initialMaskedSecret;

  bool _testSuccess = false;
  TestResult? _testResult;
  bool _isTesting = false;
  bool _isSaving = false;
  bool _isRemoteAntigravity = false;
  bool _isSigningIn = false;
  Completer<void>? _loginCancellation;
  int _loginRequestGeneration = 0;
  int _testGeneration = 0;
  String? _errorMessage;
  String? _connectedMessage;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    final registry =
        widget.providerRegistry ??
        widget.appState.providerRegistry ??
        ProviderRegistry.instance;
    final adapters = registry.getAll();
    _providerId =
        existing?.provider ??
        (adapters.any((adapter) => adapter.id == 'openrouter')
            ? 'openrouter'
            : adapters.isEmpty
            ? 'openrouter'
            : adapters.first.id);
    _antigravitySource = _sourceFromProviderData(existing?.providerData);
    _isRemoteAntigravity =
        _providerId == 'antigravity' && _antigravitySource == 'remote';
    _displayNameController = TextEditingController(
      text: existing?.displayName ?? '',
    );
    _groupController = TextEditingController(text: existing?.group ?? '');
    _credentialController = TextEditingController();

    _credentialController.addListener(_onFieldEdited);
    if (existing != null &&
        widget.secretStore != null &&
        existing.credentialRef.isNotEmpty &&
        existing.authType != AuthKind.none.name) {
      widget.secretStore!.read(existing.credentialRef).then((raw) {
        if (mounted && raw != null) {
          setState(() {
            _initialMaskedSecret = maskSecret(raw);
            _credentialController.text = _initialMaskedSecret!;
          });
        }
      });
    }
  }

  void _onFieldEdited() {
    _testGeneration++;
    if (_testSuccess) {
      setState(() {
        _testSuccess = false;
        _testResult = null;
        _connectedMessage = null;
      });
    }
  }

  @override
  void dispose() {
    _loginRequestGeneration++;
    final cancellation = _loginCancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    _loginCancellation = null;
    _isSigningIn = false;
    _credentialController.removeListener(_onFieldEdited);
    _displayNameController.dispose();
    _groupController.dispose();
    _credentialController.dispose();
    super.dispose();
  }

  ProviderRegistry get _registry =>
      widget.providerRegistry ??
      widget.appState.providerRegistry ??
      ProviderRegistry.instance;

  bool get _isLocalAntigravity =>
      _providerId == 'antigravity' && _antigravitySource != 'remote';

  String _sourceFromProviderData(String? providerData) {
    if (providerData == null) return 'remote';
    try {
      final decoded = jsonDecode(providerData);
      final source = decoded is Map ? decoded['source']?.toString() : null;
      if (source == 'language-server' ||
          source == 'agy-cli' ||
          source == 'remote') {
        return source!;
      }
    } catch (_) {}
    return 'remote';
  }

  String _providerDataWithSource() {
    final data = <String, dynamic>{};
    final existingData = widget.existing?.providerData;
    if (existingData != null) {
      try {
        final decoded = jsonDecode(existingData);
        if (decoded is Map) data.addAll(Map<String, dynamic>.from(decoded));
      } catch (_) {}
    }
    data['source'] = _antigravitySource;
    return jsonEncode(data);
  }

  void _onProviderChanged(String? value) {
    if (value == null) return;
    setState(() {
      _providerId = value;
      if (value == 'antigravity') {
        _antigravitySource = 'remote';
      }
      _isRemoteAntigravity =
          value == 'antigravity' && _antigravitySource == 'remote';
      _invalidateTestGate();
    });
  }

  List<DropdownMenuItem<String>> _providerItems() {
    final adapters = _registry.getAll();
    final items = adapters
        .map(
          (adapter) => DropdownMenuItem<String>(
            value: adapter.id,
            child: Text(adapter.name),
          ),
        )
        .toList();
    if (widget.existing != null &&
        !items.any((item) => item.value == _providerId)) {
      items.add(
        DropdownMenuItem<String>(value: _providerId, child: Text(_providerId)),
      );
    }
    return items;
  }

  void _onSourceChanged(String? value) {
    if (value == null) return;
    setState(() {
      _antigravitySource = value;
      _isRemoteAntigravity = _providerId == 'antigravity' && value == 'remote';
      _invalidateTestGate();
    });
  }

  void _invalidateTestGate() {
    _testSuccess = false;
    _testResult = null;
    _connectedMessage = null;
    _testGeneration++;
  }

  Future<void> _testConnection() async {
    final testGeneration = _testGeneration;
    setState(() {
      _isTesting = true;
      _errorMessage = null;
      _connectedMessage = null;
    });

    try {
      String secretToTest = _credentialController.text.trim();
      final existing = widget.existing;
      final store = widget.secretStore;
      if (existing != null &&
          _initialMaskedSecret != null &&
          _credentialController.text == _initialMaskedSecret &&
          existing.authType != AuthKind.none.name &&
          existing.credentialRef.isNotEmpty &&
          store != null) {
        // Read the credential back rather than keeping a plaintext copy for the
        // dialog's lifetime (audit C-30). A secret parked in a State object
        // outlives the dialog for as long as anything holds the element, and
        // `RefreshService.testAdapter` re-reads the same value from the store
        // anyway whenever `preferStoredSecret` is set, so the copy was only ever
        // reachable as a fallback for a store read that had already failed.
        final raw = await store.read(existing.credentialRef);
        if (raw != null) secretToTest = raw;
      }

      final providerId = _providerId;
      final providerData = _isLocalAntigravity
          ? _providerDataWithSource()
          : null;
      final testConn = Connection(
        id: widget.existing?.id ?? 'test-connection-id',
        provider: providerId,
        displayName: _displayNameController.text.trim(),
        group: _groupController.text.trim().isNotEmpty
            ? _groupController.text.trim()
            : null,
        plan: widget.existing?.plan,
        credentialRef: widget.existing?.credentialRef ?? '',
        enabled: true,
        authType:
            widget.existing?.authType ?? (_isLocalAntigravity ? AuthKind.none.name : null),
        identityKey: widget.existing?.identityKey,
        providerData: providerData ?? widget.existing?.providerData,
      );

      final adapter = widget.adapter ?? _registry.get(providerId);
      if (adapter == null) {
        if (!mounted) return;
        setState(() {
          _isTesting = false;
          _testSuccess = false;
          _errorMessage = 'Unknown provider: $providerId';
        });
        return;
      }

      final result = await widget.appState.testConnection(
        provider: providerId,
        displayName: testConn.displayName,
        group: testConn.group,
        secret: secretToTest,
        id: testConn.id,
        customAdapter: adapter,
        connection: testConn,
        preferStoredSecret: widget.existing != null && !_isLocalAntigravity,
      );

      if (!mounted) return;
      if (testGeneration != _testGeneration) {
        setState(() => _isTesting = false);
        return;
      }
      if (result.isSuccess) {
        setState(() {
          _isTesting = false;
          _testSuccess = true;
          _testResult = result;
          _connectedMessage = 'Connected';
          _errorMessage = null;
        });
      } else {
        setState(() {
          _isTesting = false;
          _testSuccess = false;
          _testResult = null;
          _errorMessage = result.error ?? 'Invalid API key';
          _connectedMessage = null;
        });
      }
    } catch (e) {
      if (!mounted) return;
      if (testGeneration != _testGeneration) {
        setState(() => _isTesting = false);
        return;
      }
      setState(() {
        _isTesting = false;
        _testSuccess = false;
        _testResult = null;
        _errorMessage = userSafeErrorMessage(
          e,
          fallback:
              'Could not reach the provider. Check the credential and '
              'try again.',
        );
      });
    }
  }

  Future<void> _signInWithGoogle() async {
    if (_displayNameController.text.trim().isEmpty) {
      setState(() => _errorMessage = 'Enter a display name.');
      return;
    }
    final generation = ++_loginRequestGeneration;
    final cancellation = Completer<void>();
    _loginCancellation = cancellation;
    setState(() {
      _isSigningIn = true;
      _errorMessage = null;
      _connectedMessage = null;
    });
    final provider = _registry.get('antigravity');
    if (provider is! AntigravityOAuthProvider) {
      if (mounted)
        setState(() {
          _isSigningIn = false;
          _loginCancellation = null;
          _errorMessage = 'Google sign-in is unavailable.';
        });
      return;
    }
    try {
      if (widget.existing == null) {
        await widget.appState.addAntigravityConnection(
          displayName: _displayNameController.text.trim(),
          group: _groupController.text.trim().isEmpty
              ? null
              : _groupController.text.trim(),
          provider: provider,
          cancellation: cancellation.future,
        );
      } else {
        await widget.appState.reconnectAntigravityConnection(
          widget.existing!,
          _displayNameController.text.trim(),
          _groupController.text.trim().isEmpty
              ? null
              : _groupController.text.trim(),
          provider: provider,
          cancellation: cancellation.future,
        );
      }
      if (!mounted ||
          generation != _loginRequestGeneration ||
          cancellation.isCompleted)
        return;
      Navigator.of(context).pop(true);
    } on AntigravityLoginCancelled {
      if (mounted && generation == _loginRequestGeneration) {
        setState(() {
          _isSigningIn = false;
          _loginCancellation = null;
          _errorMessage = 'Sign-in cancelled.';
        });
      }
    } on AntigravityOnboardingRequired {
      if (mounted && generation == _loginRequestGeneration) {
        setState(() {
          _isSigningIn = false;
          _loginCancellation = null;
          _errorMessage = 'Complete onboarding in Antigravity, then try again.';
        });
      }
    } catch (_) {
      if (mounted && generation == _loginRequestGeneration) {
        setState(() {
          _isSigningIn = false;
          _loginCancellation = null;
          _errorMessage = 'Unable to sign in. Please try again.';
        });
      }
    }
  }

  void _cancelSignIn() {
    final cancellation = _loginCancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
  }

  Future<void> _save() async {
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    try {
      final providerId = _providerId;
      final displayName = _displayNameController.text.trim();
      final group = _groupController.text.trim().isNotEmpty
          ? _groupController.text.trim()
          : null;
      final secretText = _credentialController.text.trim();
      final bool isSecretModified =
          widget.existing == null ||
          (_initialMaskedSecret == null || secretText != _initialMaskedSecret);
      final replacementSecret = _testResult?.replacementSecret;

      if (widget.existing == null) {
        if (_isLocalAntigravity) {
          await widget.appState.addAntigravityLocalConnection(
            displayName: displayName,
            group: group,
            source: _antigravitySource,
            initialQuotas: _testResult?.quotas ?? const [],
          );
        } else {
          await widget.appState.addConnection(
            provider: providerId,
            displayName: displayName,
            group: group,
            secret: replacementSecret ?? secretText,
            plan: _testResult?.plan,
            initialQuotas: _testResult?.quotas ?? const [],
            providerData: _providerId == 'antigravity'
                ? jsonEncode({'source': _antigravitySource})
                : null,
          );
        }
      } else if (_isLocalAntigravity) {
        await widget.appState.updateAntigravityLocalConnection(
          existing: widget.existing!,
          displayName: displayName,
          group: group,
          newQuotas: _testResult?.quotas,
          clearSchemaQuarantine: _testResult?.schemaRevalidated ?? false,
        );
      } else {
        await widget.appState.updateConnection(
          existing: widget.existing!,
          displayName: displayName,
          group: group,
          newSecret: isSecretModified ? secretText : replacementSecret,
          plan: _testResult?.plan ?? widget.existing!.plan,
          newQuotas: _testResult?.quotas,
          clearSchemaQuarantine: _testResult?.schemaRevalidated ?? false,
        );
      }

      _credentialController.clear();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSaving = false;
          _errorMessage = userSafeErrorMessage(
            e,
            fallback: 'Could not save this connection.',
          );
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = TokenDockTheme.colorsOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    key: const Key('connectionFormDialogTitle'),
                    widget.existing == null
                        ? 'Add Connection'
                        : 'Edit Connection',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: const Key('connectionProviderField'),
                    initialValue: _providerId,
                    items: _providerItems(),
                    onChanged: widget.existing == null
                        ? _onProviderChanged
                        : null,
                    decoration: const InputDecoration(
                      labelText: 'Provider',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('connectionDisplayNameField'),
                    controller: _displayNameController,
                    decoration: const InputDecoration(
                      labelText: 'Display name',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('connectionGroupField'),
                    controller: _groupController,
                    decoration: const InputDecoration(
                      labelText: 'Group',
                      border: OutlineInputBorder(),
                      hintText: 'Optional',
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_providerId == 'antigravity') ...[
                    DropdownButtonFormField<String>(
                      key: const Key('antigravitySourceField'),
                      initialValue: _antigravitySource,
                      items: const [
                        DropdownMenuItem(
                          value: 'remote',
                          child: Text('remote'),
                        ),
                        DropdownMenuItem(
                          value: 'language-server',
                          child: Text('language-server'),
                        ),
                        DropdownMenuItem(
                          value: 'agy-cli',
                          child: Text('agy-cli'),
                        ),
                      ],
                      onChanged: widget.existing == null
                          ? _onSourceChanged
                          : null,
                      decoration: const InputDecoration(
                        labelText: 'Source',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (!_isLocalAntigravity && !_isRemoteAntigravity) ...[
                    TextFormField(
                      key: const Key('connectionCredentialField'),
                      controller: _credentialController,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Credential',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (_isRemoteAntigravity) ...[
                    const SizedBox(height: 12),
                    if (_isSigningIn)
                      OutlinedButton.icon(
                        key: const Key('antigravityCancelLoginButton'),
                        onPressed: _cancelSignIn,
                        icon: const Icon(Icons.close),
                        label: const Text('Cancel sign-in'),
                      )
                    else
                      ElevatedButton.icon(
                        key: const Key('antigravitySignInButton'),
                        onPressed: _signInWithGoogle,
                        icon: const Icon(Icons.login),
                        label: const Text('Sign in with Google'),
                      ),
                  ],
                  const SizedBox(height: 12),
                  if (_isTesting)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8.0),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 8),
                          Text('Testing connection...'),
                        ],
                      ),
                    ),
                  if (_connectedMessage != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.check_circle,
                                color: colors.statusOk,
                                size: 18,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _connectedMessage!,
                                style: TokenDockTypography.bodyStyle(
                                  color: colors.statusOk,
                                ).copyWith(fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                          if (_testResult != null &&
                              _testResult!.quotas.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            const Text(
                              'Quota preview:',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 4),
                            ..._testResult!.quotas.map((quota) {
                              final remainingStr = quota.remaining != null
                                  ? quota.remaining!.toStringAsFixed(1)
                                  : '-';
                              final limitStr = quota.limit != null
                                  ? quota.limit!.toStringAsFixed(1)
                                  : '-';
                              final unitStr = quota.unit != null
                                  ? ' ${quota.unit}'
                                  : '';
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 2.0),
                                child: Text(
                                  '${quota.label}: $remainingStr / $limitStr$unitStr',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              );
                            }),
                          ],
                        ],
                      ),
                    ),
                  if (_errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: Row(
                        children: [
                          Icon(
                            Icons.error_outline,
                            color: colors.statusLimited,
                            size: 18,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _errorMessage!,
                              style: TokenDockTypography.bodyStyle(
                                color: colors.statusLimited,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                  if (!_isRemoteAntigravity)
                    OverflowBar(
                      spacing: 8,
                      overflowSpacing: 8,
                      alignment: MainAxisAlignment.end,
                      children: [
                        ElevatedButton(
                          key: const Key('testConnectionButton'),
                          onPressed: _isTesting || _isSaving
                              ? null
                              : _testConnection,
                          child: const Text('Test Connection'),
                        ),
                        TextButton(
                          onPressed: _isSaving
                              ? null
                              : () => Navigator.of(context).pop(),
                          child: const Text('Cancel'),
                        ),
                        ElevatedButton(
                          key: const Key('saveConnection'),
                          onPressed: _testSuccess && !_isSaving ? _save : null,
                          child: _isSaving
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('Save'),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

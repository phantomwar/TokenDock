import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../models/connection.dart';
import '../../models/test_result.dart';
import '../../providers/provider_adapter.dart';
import '../../providers/provider_registry.dart';
import '../../storage/connection_repository.dart';
import '../../storage/quota_cache_repository.dart';
import '../../storage/secret_store.dart';
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
          providerRegistry:
              widget.providerRegistry ?? _state.providerRegistry,
        );
      },
    );
  }

  Future<void> _deleteConnection(
      BuildContext context, Connection connection) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final warning = await _state.removeConnection(connection.id);
      if (warning != null) {
        messenger.showSnackBar(
          SnackBar(content: Text(warning)),
        );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Failed to delete connection: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final accounts = _state.accounts;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Connections'),
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
      return const Center(
        child: CircularProgressIndicator(),
      );
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
                  style:
                      TokenDockTypography.captionStyle(color: colors.mutedInk),
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
                        child: Text('Reconnect required. Cached quotas remain available.'),
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
  late final TextEditingController _providerController;
  late final TextEditingController _displayNameController;
  late final TextEditingController _groupController;
  late final TextEditingController _credentialController;

  /// Masked text shown in the credential field while editing.
  String? _initialMaskedSecret;

  /// Unmasked credential loaded for an existing connection, retained only so a
  /// re-test can run when the user leaves the masked field untouched. Never
  /// rendered; cleared with the dialog.
  String? _loadedRawSecret;

  bool _testSuccess = false;
  TestResult? _testResult;
  bool _isTesting = false;
  bool _isSaving = false;
  String? _errorMessage;
  String? _connectedMessage;

  @override
  void initState() {
    super.initState();
    _providerController = TextEditingController(
      text: widget.existing?.provider ?? 'OpenRouter',
    );
    _displayNameController = TextEditingController(
      text: widget.existing?.displayName ?? '',
    );
    _groupController = TextEditingController(
      text: widget.existing?.group ?? '',
    );
    _credentialController = TextEditingController();

    _providerController.addListener(_onFieldEdited);
    _credentialController.addListener(_onFieldEdited);

    if (widget.existing != null && widget.secretStore != null) {
      widget.secretStore!.read(widget.existing!.credentialRef).then((raw) {
        if (mounted && raw != null) {
          setState(() {
            _loadedRawSecret = raw;
            _initialMaskedSecret = maskSecret(raw);
            _credentialController.text = _initialMaskedSecret!;
          });
        }
      });
    }
  }

  void _onFieldEdited() {
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
    _providerController.removeListener(_onFieldEdited);
    _credentialController.removeListener(_onFieldEdited);
    _providerController.dispose();
    _displayNameController.dispose();
    _groupController.dispose();
    _credentialController.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    setState(() {
      _isTesting = true;
      _errorMessage = null;
      _connectedMessage = null;
    });

    try {
      String secretToTest = _credentialController.text.trim();
      if (widget.existing != null &&
          _initialMaskedSecret != null &&
          _credentialController.text == _initialMaskedSecret &&
          _loadedRawSecret != null) {
        secretToTest = _loadedRawSecret!;
      }

      final providerRaw = _providerController.text.trim();
      final providerId =
          providerRaw.toLowerCase() == 'openrouter' ? 'openrouter' : providerRaw;

      final testConn = widget.existing ??
          Connection(
            id: 'test-connection-id',
            provider: providerId,
            displayName: _displayNameController.text.trim(),
            group: _groupController.text.trim().isNotEmpty
                ? _groupController.text.trim()
                : null,
            plan: null,
            credentialRef: '',
            enabled: true,
          );

      final adapter = widget.adapter ??
          widget.providerRegistry?.get(providerId) ??
          widget.providerRegistry?.get(providerRaw) ??
          ProviderRegistry.instance.get(providerId) ??
          ProviderRegistry.instance.get(providerRaw);

      if (adapter == null) {
        if (!mounted) return;
        setState(() {
          _isTesting = false;
          _testSuccess = false;
          _errorMessage = 'Unknown provider: $providerRaw';
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
        preferStoredSecret: widget.existing != null,
      );

      if (!mounted) return;

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
      setState(() {
        _isTesting = false;
        _testSuccess = false;
        _testResult = null;
        _errorMessage = 'Test failed: $e';
      });
    }
  }

  Future<void> _save() async {
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    try {
      final providerRaw = _providerController.text.trim();
      final providerId =
          providerRaw.toLowerCase() == 'openrouter' ? 'openrouter' : providerRaw;

      final displayName = _displayNameController.text.trim();
      final group = _groupController.text.trim().isNotEmpty
          ? _groupController.text.trim()
          : null;

      final secretText = _credentialController.text.trim();
      final bool isSecretModified = widget.existing == null ||
          (_initialMaskedSecret == null || secretText != _initialMaskedSecret);
      final replacementSecret = _testResult?.replacementSecret;

      if (widget.existing == null) {
        await widget.appState.addConnection(
          provider: providerId,
          displayName: displayName,
          group: group,
          secret: replacementSecret ?? secretText,
          plan: _testResult?.plan,
          initialQuotas: _testResult?.quotas ?? const [],
        );
      } else {
        await widget.appState.updateConnection(
          existing: widget.existing!,
          displayName: displayName,
          group: group,
          newSecret: isSecretModified
              ? secretText
              : replacementSecret,
          plan: _testResult?.plan ?? widget.existing!.plan,
          newQuotas: _testResult?.quotas,
          clearSchemaQuarantine:
              _testResult?.schemaRevalidated ?? false,
        );
      }

      _credentialController.clear();

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSaving = false;
          _errorMessage = 'Failed to save connection: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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
                  widget.existing == null
                      ? 'Add Connection'
                      : 'Edit Connection',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('connectionProviderField'),
                  controller: _providerController,
                  readOnly: true,
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
                            const Icon(Icons.check_circle,
                                color: Colors.green, size: 18),
                            const SizedBox(width: 6),
                            Text(
                              _connectedMessage!,
                              style: const TextStyle(
                                color: Colors.green,
                                fontWeight: FontWeight.bold,
                              ),
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
                            final unitStr =
                                quota.unit != null ? ' ${quota.unit}' : '';
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
                        const Icon(Icons.error_outline,
                            color: Colors.red, size: 18),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 16),
                OverflowBar(
                  spacing: 8,
                  overflowSpacing: 8,
                  alignment: MainAxisAlignment.end,
                  children: [
                    ElevatedButton(
                      key: const Key('testConnectionButton'),
                      onPressed:
                          _isTesting || _isSaving ? null : _testConnection,
                      child: const Text('Test Connection'),
                    ),
                    TextButton(
                      onPressed:
                          _isSaving ? null : () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                    ElevatedButton(
                      key: const Key('saveConnection'),
                      onPressed: _testSuccess && !_isSaving ? _save : null,
                      child: _isSaving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
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

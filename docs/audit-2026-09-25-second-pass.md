# TokenDock — Auditoria de segunda passagem

**Data:** 2026-09-25 · **Branch:** `master` @ `0f5205e` · **Método:** leitura integral de `PRD.txt`, `PRODUCT.md`, 2 specs, 3 plans, 1 checkpoint, 2 docs de pesquisa; leitura de 100% de `lib/` (7.122 linhas) e inspeção de `test/`; verificação reproduzida de `flutter test` e `flutter analyze`; cálculo de contraste WCAG por script.

> Documento companions: `docs/superpowers/plans/2026-09-25-tokendock-correctness-plan.md` (plano de correção) e os 3 docs de pesquisa já existentes. Este documento **não substitui** a spec; ele registra onde a spec e o código divergem.

---

## 0. Baseline verificado (reproduzido, não aceito)

| Afirmação da documentação | Verificação |
|---|---|
| `flutter test --no-pub` 235/235 | ✅ `00:18 +235: All tests passed!` |
| `flutter analyze` 0 erros / 0 warnings / 33 infos | ✅ `33 issues found`, todas `info`, exit 1 |
| Providers registrados: `openrouter`, `antigravity` | ✅ `provider_registry.dart:17-21` |
| Segredos só como `secret_ref` no SQLite | ✅ todos os 6 `.write()` de credencial vão para `SecretStore` |
| Zero SQL injection | ✅ tudo parametrizado; única interpolação é `PRAGMA user_version = $version` com `const int` |

**Não verificado nesta sessão:** `flutter build windows --release` e `integration_test/multi_account_flow_test.dart` (exigem toolchain Windows completo). As linhas da documentação sobre essas duas continuam não reproduzidas por mim.

**A documentação de verificação é honesta e precisa.** Os números batem exatamente. Isso é raro e deve ser preservado.

---

## 1. O que está genuinamente bom (preservar)

Estes pontos foram verificados linha por linha e **não devem ser regredidos**:

- **OAuth 2.1 + PKCE correto.** `oauth_loopback.dart:240-242` gera verifier de 43 chars via `Random.secure()`; `:235-238` usa S256; `:244-248` gera `state` de 128 bits; `:153-169` valida `state` **antes** da troca de código; `:61-65` usa `127.0.0.1` literal (nunca `localhost`); nenhum `client_secret` no app; `close()` em todos os caminhos (sucesso `:175-183`, erro, cancelamento, timeout).
- **Imune a SSRF.** Todos os hosts são `static const` (`antigravity_oauth.dart:129-136`). `projectId`, `identityKey`, `code`, `code_verifier` vão **sempre no body**, nunca na URL.
- **Spawn de processo seguro.** `antigravity_local.dart:58-63` usa `List<String>` + `runInShell: false`; output limitado a 1 MiB (`:64-94`); timeout com `sigkill`; cwd temporário isolado e removido (`:543-545`).
- **Cache-first genuíno.** `refresh_service.dart:508-521` preserva `cachedQuotas` em toda falha. É o invariante mais bem testado do projeto.
- **Isolamento por conexão e cap de 4** — testados de verdade.
- **Ética documentada.** A "Deferred Antigravity note" e os Apêndices A/B rotulando explicitamente APIs não-oficiais como não-oficiais é maturidade incomum e juridicamente prudente.
- **Suíte limpa:** zero `skip:`, zero `.only`, zero testes que validam o próprio mock.

---

## 2. Registro de achados

Severidade: **P0** perda de credencial/dado/hang/app não abre · **P1** segurança ou promessa documentada quebrada · **P2** corretude/perf/manutenibilidade · **P3** código morto, drift de doc, estilo.

### P0 — Corretude destrutiva

#### C-01 · Cliente HTTP do OAuth do Antigravity não tem timeout
`lib/providers/antigravity/antigravity_oauth.dart:870-892`

```dart
final client = HttpClient();
try {
  final request = await client.postUrl(uri);      // sem .timeout()
  request.write(body);
  final response = await request.close();          // sem .timeout()
  return AntigravityOAuthHttpResponse(
    statusCode: response.statusCode,
    body: await response.transform(const Utf8Decoder()).join(),  // sem cap
```
`HttpClient.connectionTimeout` é `null` (infinito) por padrão. Nenhum dos três `await` tem `.timeout()`. Sem cap de tamanho de resposta.

O provider irmão faz certo: `openrouter_provider.dart:15,45,47-48`.

**Impacto:** um socket travado trava `_inFlight[connectionId]` **para sempre** — `refresh_service.dart:202-210` encadeia na `completion`, que nunca completa. Todos os refreshes, `testAdapter` e `runTokenOperation` futuros daquela conexão ficam enfileirados sem recuperação. Não há circuit breaker.

#### C-02 · Migrations: DDL e `user_version` fora da mesma transação
`lib/storage/migration_001.dart:52-58`, `migration_002.dart:22-24`, `migration_003.dart:22`

```dart
await db.transaction((txn) async { /* CREATE TABLE / ALTER TABLE */ });
await db.execute('PRAGMA user_version = $version');   // <- FORA da transação
```

Crash entre `COMMIT` e o `PRAGMA` → DDL aplicado, `user_version` obsoleto → próxima execução reexecuta `ALTER TABLE` → **`duplicate column name`**. `Migration002/003` não têm `IF NOT EXISTS` possível (SQLite não permite). E `main.dart:33` faz `await AppDatabase.open()` **sem guarda** → app morre antes do `runApp`, sem tela de erro, sem caminho de recuperação.

O guard `if (currentVersion >= version)` é a **única** proteção, e ele protege exatamente o caso que falha.

#### C-03 · `DateTime.parse` sem `tryParse` no caminho de leitura
`lib/storage/quota_cache_repository.dart:23-25` · `lib/storage/connection_health_repository.dart:45-46`

```dart
final resetAt = resetAtStr != null ? DateTime.parse(resetAtStr).toUtc() : null;
...
lastCheckedAt: DateTime.parse(checkedAt).toUtc(),
cooldownUntil: cooldown == null ? null : DateTime.parse(cooldown).toUtc(),
```

**Uma única linha corrompida** em `reset_at` lança `FormatException` para **todas** as conexões, num `getAll()` que é uma leitura pura. O provider layer já usa `tryParse` corretamente (`antigravity_local.dart:664`) — inconsistência interna. Zero testes cobrem `reset_at` (nenhum `db.insert` da suíte sequer escreve essa coluna).

#### C-04 · Revogação incondicional da cadeia em `invalid_grant`
`lib/providers/antigravity/antigravity_oauth.dart:646, 667-673`

```dart
final reused = _rotatedRefreshTokens.contains(refreshToken);
try {
  ...
} on StateError catch (error) {
  if (!error.toString().contains('invalid_grant')) rethrow;
  await _revokeBestEffort(refreshToken);      // <- ignora `reused`
  rethrow;
} on AntigravityTransportFailure {
  if (reused) await _revokeBestEffort(refreshToken);   // <- único uso de `reused`
  rethrow;
}
```

O flag `reused` é consultado **apenas** no branch `AntigravityTransportFailure` — justamente o caso em que não se pode inferir se o AS processou o request. O branch que realmente indica token rotacionado rejeitado (`invalid_grant`) revoga **sempre**.

**Impacto:** dois `refresh()` concorrentes benignos (o `testAdapter` **enfileira, não coalesce** — ver C-09) → o Google rotaciona, o segundo recebe `400 invalid_grant` → `_revokeBestEffort` → o endpoint `/revoke` do Google revoga o **grant**, não só o token apresentado → **o token recém-rotacionado do primeiro é morto**. Logout por corrida, não por ataque.

Agravantes: `AntigravityTransientFailure` e `AntigravitySchemaChanged` não são capturados → sinal de reuse descartado. `_rotatedRefreshTokens` (`:113`) é um `Set<String>` **sem limite, sem poda, não durável**, sobre o adapter **singleton**, guardando refresh token em texto claro.

#### C-05 · Cancelamento por "loteria" de microtask
`lib/app/app_state.dart:546-564, 582-593, 696-701, 720-723, 734`

```dart
var cancellationRequested = false;
cancellation?.then((_) => cancellationRequested = true);
...
await Future<void>.value();
if (cancellationRequested) throw const AntigravityLoginCancelled();
await Future<void>.value();
await Future<void>.value();
if (cancellationRequested) { /* delete + throw */ }
if (cancellationRequested) throw const AntigravityLoginCancelled();
```

`await Future<void>.value()` sobre um Future **já completado** cede o microtask queue **uma vez**. O cancelamento vem de um **macrotask** (tap em `_cancelSignIn`, `connections_screen.dart:670-675`; ou `dispose()`). Um yield de microtask **não** observa um cancelamento ainda na fila de eventos.

Os checks são **redundante repetidos** (`:547` e `:556` testam o mesmo sem operação intermediária) — assinatura inequívoca de quem não tinha modelo de quando a flag fica visível.

O invariante que se tenta proteger ("nunca deixar linha apontando para credencial recién borrada") **não pode** ser estabelecido por um booleano amostrado entre saltos de microtask. O certo é um **ponto de commit único**.

Nota: `antigravity_oauth.dart:171-211` faz **correto** (`Future.any` real, não poll). O defeito está só na camada de persistência que o envolve.

### P1 — Segurança e promessas documentadas

#### C-06 · Ramp dark reutiliza as status colors do light → falha WCAG AA
`lib/app/theme.dart:78-93`

```dart
static const TokenDockColors dark = TokenDockColors(
  statusNormal: Color(0xFF1769C2),   // idêntico ao light
  statusOk: Color(0xFF087A4C),        // idêntico ao light
  statusWarning: Color(0xFFA85A00),   // idêntico ao light
  statusLimited: Color(0xFFC33737),   // idêntico ao light
  statusUpdating: Color(0xFF6C6A73),  // idêntico ao light
  quotaFill: Color(0xFF8AB8FF),       // ÚNICO valor adaptado
);
```

`StatusIndicator` usa essas cores **como cor de texto** (`:63-66`, `captionStyle` 12px w400 → texto normal → exige 4,5:1). Contraste medido por script:

| Par | Razão | Veredito |
|---|---|---|
| `statusOk #087A4C` sobre `surface #1E1D23` | **3,11:1** | ✗ |
| `statusWarning #A85A00` sobre `#1E1D23` | **3,29:1** | ✗ |
| `statusLimited #C33737` sobre `#1E1D23` | **3,12:1** | ✗ |
| `statusNormal #1769C2` sobre `#1E1D23` | **3,06:1** | ✗ |
| mesmos no light (sobre `#FFFFFF`) | 5,09–5,39:1 | ✓ |

Ou seja: **só o dark está quebrado**, e a spec prometeu explicitamente "dark-mode equivalents that meet their contrast target".

#### C-07 · Cores hardcoded burlando o design system
`lib/ui/settings/connections_screen.dart:886, 892, 939, 946` (e `widget_shell.dart:37`)

```dart
const Icon(Icons.check_circle, color: Colors.green, size: 18),
Text(_connectedMessage!, style: const TextStyle(color: Colors.green, ...)),
const Icon(Icons.error_outline, color: Colors.red, size: 18),
Text(_errorMessage!, style: const TextStyle(color: Colors.red)),
```

`theme.dart:8` diz literalmente: *"Components resolve the active ramp with `TokenDockTheme.colorsOf` so they stay flat, composable content primitives with **no hardcoded colors**"* — o próprio contrato do arquivo é violado.

| Par | Razão | Veredito |
|---|---|---|
| `Colors.green #4CAF50` sobre `#FFFFFF` | **2,78:1** | ✗ falha até 3:1 |
| `Colors.red #F44336` sobre `#FFFFFF` | **3,68:1** | ✗ falha 4,5:1 |

Isto é a mensagem "✓ Connected" e **todo texto de erro** do diálogo de conexão.

**Nenhum teste e nenhum lint pega isso:** `connections_screen_test.dart` (1.559 linhas) não contém nenhuma referência a `color`/`Style`/`TokenDockTheme`. E `flutter_lints 6.0.0` **estruturalmente não detecta** constantes nomeadas de paleta — a única regra de cor, `use_full_hex_values_for_flutter_colors`, trata apenas hex abreviado dentro de `Color(...)`. `prefer_const_constructors_in_immutables` inclusive **recompensa** o padrão.

#### C-08 · "Last updated" nunca atualiza
`lib/ui/widget/token_dock_widget.dart:56-69`

```dart
static String formatRelativeAge(DateTime dateTime, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final diff = current.difference(dateTime);
  ...
}
```

Função estática pura chamada no `build` (`:242`, `:290`, `:345`) **sem timer**. Congela no primeiro build até um rebuild não relacionado. Com intervalo "manual" ou provider falhando, o usuário vê "just now" indefinidamente.

`PRODUCT.md:59` afirma que mostra `Last updated <relative age>` em compact, normal **e** expanded. `CountdownText` tem timer; este não. Os 3 testes só verificam `find.textContaining('Last updated')` — o sufixo pode estar totalmente quebrado e passam. **`formatRelativeAge` não tem nenhum teste direto** (grep: 0 hits).

#### C-09 · `runTokenOperation` é código morto → sem single-flight na troca de token
`lib/services/refresh_service.dart:225-236`

```dart
Future<String> runTokenOperation({required String connectionId, required Future<String> Function() operation}) {
  final existing = _inFlight[connectionId];
  final shared = existing?.sharedResult;
  if (shared is Future<String>) return shared;      // <- único des-duplicador real
  return runConnectionOperation(connectionId: connectionId, operation: operation).whenComplete(() {});
}
```

Único ponto do código que **compartilha resultado** de troca de token. Grep: definido em `:225`, testado em `refresh_service_test.dart:355,457`, **nunca chamado de `lib/`**. As chamadas reais em `:407` e `:439` são `await refreshable.refresh(...)` cru.

`runConnectionOperation` (`:195-223`) **serializa mas não coalesce**: o segundo chamador espera e roda mesmo assim, com secret obsoleto capturado antes. Somente `refreshOne` coalesce (`:175-191`).

Este é o elo com C-04: a race de double-refresh **não tem trava**.

#### C-10 · `_credential` engole credencial corrompida e a trata como bearer válido
`lib/providers/antigravity/antigravity_oauth.dart:808-814` (duplicado em `:861`)

```dart
static Map<String, dynamic> _credential(String raw) {
  try {
    return _map(jsonDecode(raw));
  } catch (_) {
    return {'accessToken': raw};      // <- qualquer lixo vira token válido
  }
}
```

Se o DPAPI devolver corrompido (roaming, máquina reconstruída), o JSON falha e o **conteúdo bruto é usado como access token** em vez de reportar "credencial ilegível". Também é o que faz o teste local passar: `_credential('')` → `{'accessToken': ''}` → `expiresAt` = `tryParse('')` = `null` → refresh pulado → reader local chamado. **Funciona por acidente**, e `AntigravityProvider` **não sobrescreve `test()`**.

#### C-11 · Classificador de falha usa matching frágil de mensagem — proibido pela própria spec
`lib/services/credential_events.dart:26-32`

```dart
final message = error is StateError ? error.message : error.toString();
final normalized = message.trim().toLowerCase();
if (normalized.contains('invalid_grant')) return 'invalid_grant';
if (normalized == '401' || normalized.endsWith(': 401')
    || normalized.contains('bad state: 401') || normalized.contains('http 401')
    || normalized.contains('status 401') || normalized.contains('statuscode=401')) return 'bare_401';
```

A spec diz, literalmente: *"A central `isAuthRetryable` classifier uses status + header + provider code first (**never fragile message regex**)"*. O plano de hardening §3: *"Heurísticas regex de mensagem são frágeis"*. O código faz 6 `contains` sobre mensagem lowercased — e um deles usa `=` enquanto os outros usam espaço. `isDefinitiveOAuthFailure` (`:17`) é **morta** (nunca chamada em `lib/`).

#### C-12 · Exceções cruas chegando à UI
`lib/ui/settings/connections_screen.dart:589, 742, 155`

```dart
_errorMessage = 'Test failed: $e';                 // :589
_errorMessage = 'Failed to save connection: $e';   // :742
SnackBar(content: Text('Failed to delete connection: $e'));  // :155
```

`redactSecret` é importado **apenas** por `refresh_service.dart`. Nenhum dos três arquivos Antigravity o importa. O caminho `:589` é a rota **primária** do Antigravity: `AntigravityOAuthProvider.test` chama `credential.refresh(testSecret)` em `:428` **fora de qualquer try/catch**.

`redactSecret` também não cobre token isolado: `activeSecrets` (`refresh_service.dart:389`) guarda o **blob JSON inteiro**, não valores individuais, e o regex exige prefixo `key:`/JSON válido.

#### C-13 · `_sanitizeProviderData` é cego a tokens
`lib/storage/connection_repository.dart:106-112`

```dart
if (!(entry.key as String).toLowerCase().contains('csrf'))
```

Remove **só** `*csrf*`. `log_redaction.dart:3-6` já tem o regex correto (`key|token|secret|auth|credential|cookie`) — e não é reutilizado aqui. Nenhum writer atual vaza token, então é **latente**, mas é a última linha de defesa contra um erro de plaintext-em-SQLite e está a um regex de distância.

#### C-14 · `shared: true` no bind IPv6 do loopback
`lib/services/oauth_loopback.dart:36-40`

```dart
ipv6Server = await HttpServer.bind(InternetAddress.loopbackIPv6, server.port, shared: true);
```

A spec (`:31`) e o plano de hardening exigem semântica "SO_EXCLUSIVEADDRUSE-like". `shared: true` permite que **outro processo** faça bind do mesmo `[::1]:port` e receba o `code`+`state`. Impacto limitado (sem `state` correto não injeta código), mas permite DoS local.

#### C-15 · Exceções SQLite vazam SQL cru para a UI
Não existe `DatabaseException` em `lib/` (grep: 0 hits), nenhum `try/catch` nos 4 repositories, nenhuma camada de tradução. `connections_screen.dart:742` renderiza `$e`, que inclui SQL/argumentos. `refresh_service.dart:534, 684` faz **certo** (literal, sem `$e`) — o resto do código não segue o próprio bom exemplo.

### P2 — Corretude, performance, manutenibilidade

- **C-16 · N+1 — não existe `getById`.** `ConnectionRepository` (`connection_repository.dart:6-10`) só tem `getAll/save/delete`, enquanto `ConnectionHealthRepository.get` e `QuotaCacheRepository.getAll` **aceitam chave**. 5 sítios `getAll().where(...).firstOrNull`: `app_state.dart:664, 899, 931`; `refresh_service.dart:249, 308`. O de `:308` roda **dentro do loop por conexão** → `refreshAll()` executa **1+N varreduras completas** da tabela `connections` por ciclo (default 3 min + cada clique no tray).
- **C-17 · Join perdido.** `ConnectionHealth` vive em colunas da própria tabela `connections` (`connection_health_repository.dart:18-25`), mas é re-buscada por PK no loop (`app_state.dart:291`). `getAll()` já leu essas colunas — e as **jogou fora** (`connection_repository.dart:15-34` não mapeia `last_status`/`last_checked_at`/`cooldown_until`/`last_error`).
- **C-18 · Descoberta PowerShell ilimitada.** `antigravity_local.dart:169-173`: `Process.run('powershell.exe', ...)` sem timeout e **sem cap de output** (bufferiza stdout inteiro). `Get-CimInstance Win32_Process` enumera todos os processos. Roda **inline no caminho de fetch** (`:389, 458, 497`). `jsonDecode(output)` em `:177` não está em try/catch (contido só pelo swallow em `:488-494`).
- **C-19 · Tokens tipográficos não batem com a spec.** Spec: *"11px metadata, 13px body, 15px account/provider label, 18px section heading, 22px widget heading; quota percentages use **20px semibold** tabular"*. `theme.dart:172-199`: `quotaStyle` = **13px w500**, `titleStyle` = 13px w600, `bodyStyle` = 14px, `captionStyle` = 12px. **Não existem** os degraus de 18px e 22px.
- **C-20 · A quota primária é renderizada em `mutedInk`.** `quota_row.dart:45-46` e `token_dock_widget.dart:235-238` — o número que responde *"qual conta ainda tem limite?"* (o propósito do produto) sai em cor secundária a 13px w500. Contraria `PRODUCT.md:73` *"Glance before detail: lead with the quota that determines where the user can work next"*.
- **C-21 · Tick de 1s × instâncias ilimitadas.** `countdown_text.dart:21` default `Duration(seconds: 1)`, e o texto só tem granularidade de hora/minuto. 20 conexões × 3 quotas = 60 timers/s, cada um com `setState`. `PRD.txt:1505-1509` fixa a meta "CPU próximo de 0%". Nenhum teste cobre o intervalo nem múltiplas instâncias (o teste de "many accounts" usa fixtures com `resetAt: null`, então `CountdownText` nunca é instanciado).
- **C-22 · Três builders quase idênticos.** `token_dock_widget.dart:211-367` (~150 linhas): o preâmbulo `Divider` + `Focus` + `Semantics` e o bloco `'Last updated ...'` + erro são **copiados** nos três. Divergência real já presente: **`_buildCompact` não renderiza `snapshot.error`** — e nenhum teste afirma essa assimetria.
- **C-23 · Integridade do schema.** Zero `FOREIGN KEY`/`REFERENCES` em qualquer `CREATE TABLE`; `PRAGMA foreign_keys` nunca habilitado; cascata de `quota_cache` é **manual** em 2 lugares (`connection_repository.dart:83-92`, `quota_cache_repository.dart:67-74`); `idx_quota_cache_connection` é **redundante** com a PK composta `(connection_id, quota_key)`; `quota_cache.status` é **coluna morta** (sempre `null`, nunca lida — `Quota` não tem o campo); `connections` sem índice no `ORDER BY sort_order, created_at` que roda N+1 vezes.
- **C-24 · `AppState` como `ChangeNotifier` via `Expando` estático + construtores `const`.** `app_state.dart:98-185`: `const AppState.loading()` é **canonicalizado** pelo Dart → todas as instâncias são o **mesmo objeto** → `_fallbackNotifiers[this]` (`:176-185`) é **compartilhado globalmente** → `dispose()` (`:234-239`) descarta um notifier compartilhado. `app.dart:68` usa `appState ?? const AppState.loading()`. Bug latente: "A ChangeNotifier was used after being disposed".
- **C-26 · API de redação morta.** `redactHeaders` (`log_redaction.dart:72`) e `redactUrl` (`:81`) nunca chamadas em `lib/`; `isDefinitiveOAuthFailure` (`credential_events.dart:17`) idem. O plan Task 2 mandava o refresh path usá-las.
- **C-27 · `_credential` duplicado** em `antigravity_oauth.dart:808` e `:861` — duas implementações a mantener em sincronia.
- **C-28 · `AuthKind` vs strings cruas, sem validação.** O enum existe e os adapters o declaram (`provider_adapter.dart:5`, `openrouter_provider.dart:31`, `antigravity_oauth.dart:142`), mas **a persistência usa strings** `'oauth'`/`'none'` (`app_state.dart:432, 532, 572, 683, 810`) e **nada valida que `adapter.authKind` corresponda ao `auth_type` gravado**. `AuthKind.structuredBearer` é declarado e nunca usado.
- **C-29 · `deleteSync` em `finally` mascara a exceção real.** `antigravity_local.dart:543-545`: no timeout, `:86-89` lança de dentro do `onTimeout` **antes** do `sigkill` completar → `Future.wait` em `:91` é pulado → o filho ainda vivo segura handle → `deleteSync(recursive: true)` lança `SHARING_VIOLATION` no `finally`, **substituindo** o `AntigravitySourceException('agy process timed out')` e vazando o temp dir.
- **C-30 · Segredo cru retido no widget.** `connections_screen.dart:376-385` guarda o blob JSON completo em `_loadedRawSecret` e **nunca o limpa no `dispose()`** (`:399-413`). `maskSecret` sobre o JSON dá prefixo `{"a` — ou seja, expõe 3 chars do `accessToken` e um rótulo enganoso.

### P3 — Código morto e drift de documentação

- **C-31 · "No key cap" nunca implementado.** A spec (first-goal design `:190`) exige: *"When either numeric value is null, preserve it as null and render **`No key cap`** rather than zero."* `quota_row.dart:21` renderiza **`"Unavailable"`** — que se lê como erro. Grep de `"No key cap"` em `lib/` **e** `test/`: **zero hits**. Desvio não reportado e não testado. (Note que `StatusIndicator` também usa a string `"Unavailable"`, para `ConnectionStatus.error` — colisão de vocabulário.)
- **C-32 · `AppCard` e `SectionHeader` são código morto.** Definidos (`app_card.dart:10`, `section_header.dart:6`), referenciados só em comentário de doc (`account_header.dart:11`), **nunca instanciados**. A spec listou ambos como componentes obrigatórios.
- **C-33 · `defaultRefreshIntervalMinutes` duplicado.** `settings_repository.dart:9` (top-level) e `:42` (`static` na classe). O scope da classe **ofusca** o top-level dentro do corpo. Mesmo valor, duas fontes.
- **C-34 · Drift de documentação.**

| Documento | Diz | Código / realidade |
|---|---|---|
| `PRD.txt:9` | `227/227` testes | 235 (README e PRODUCT.md corretos) |
| spec first-goal `:192` | `403 → authError` | `openrouter_response.dart:98-100` → `error` |
| spec first-goal `:151` | "dark-mode equivalents que atingem o alvo" | idênticas ao light (C-06) |
| spec first-goal `:153` | quota a 20px semibold | 13px w500 (C-19) |
| spec first-goal `:190` | `No key cap` | `Unavailable` (C-31) |
| `PRD.txt:1570` | `sk-••••••••••82AD` | `sk-...82AD` (`secret_store.dart:43-50`) |
| `tray_controller.dart:66,122` | "Stub point ... lands in a later task" | já está ligado em `main.dart:55-56` |
| `PRODUCT.md:66` | "stale-age metadata em toda densidade" | renderiza mas não atualiza (C-08) |

- **C-35 · Lacunas de teste.** Existe **exatamente 1 asserção de contraste** em todo o repositório — `theme_test.dart:89-93`, par **não-texto** `dark.quotaFill` vs `mutedSurface`, limiar 3:1. **Nenhum contraste de texto (4,5:1) em nenhum dos 3 temas.** `theme_test.dart:33-37` chama-se "high-contrast text stays usable" mas só verifica `ink != canvas` — satisfeito por 1:1,01. Não testados: `limit == 0` (guarda existe em `openrouter_response.dart:59`), `reset_at` corrompido (e **lança**), boundaries 330/550, `Quotas` com `status` erro em compact, `formatRelativeAge`, `"Unavailable"`. **Das 6 invariantes documentadas, 2 não têm nenhum teste:** "tokens nunca no SQLite" e "DPAPI" — `secret_store_test.dart` roda contra `Map<String,String>` fake, provando que o fake ecoa texto claro.
- **C-36 · Risco de flake.** 6 `Future.delayed` reais (25–130ms) em `refresh_service_test.dart:474, 1096, 1103, 1115, 1156, 1164`; timeouts de socket de **250ms** em `oauth_loopback_test.dart:134, 167, 168`. `token_dock_widget_test.dart:166` depende de `DateTime.now()` real.

---

## 3. Execução — o que foi corrigido e o que a execução revelou

Plano: `docs/superpowers/plans/2026-09-25-tokendock-correctness-plan.md`.
Cada item foi feito em RED→GREEN, com o teste visto falhar antes do fix.

| ID | Sev | Commit | Estado |
|---|---|---|---|
| C-02 | P0 | `1e144e1` | migrations atômicas e resumíveis |
| C-03 | P0 | `1e144e1` | `tryParse` no caminho de leitura |
| C-13 | P1 | `1e144e1` | sanitização por `isSensitiveKeyName` |
| C-01 | P0 | `4f79598` | timeouts + cap de resposta no transporte |
| C-09 | P1 | `a4f902c` | single-flight real, ligado nos 2 pontos de refresh |
| C-04 | P1 | `f477ac9` | revogação exige evidência positiva de reuse |
| C-25 | P1 | `f477ac9` | ledger limitado a 32 entradas |
| C-06 | P1 | `91b8840` | ramp dark com accents próprios |
| C-07 | P1 | `91b8840` | sem `Colors.*`, mais guard de código-fonte |
| C-05 | P0 | `c95b584` | compensação não mascara mais o cancelamento |
| C-14 | P1 | `daf4af0` | loopback IPv6 exclusivo |
| C-08 | P1 | `b1ba687` | idade do cache passa a contar |

**Baseline:** 235/235 → **324/324**. `flutter analyze` 0 erros / 0 warnings / 33 infos (inalterado).

### O que a execução revelou e a auditoria tinha omitido

1. **C-06 era pior que o documentado.** `statusUpdating` no dark estava em
   **3,14:1** e eu não o havia listado. O teste parametrizado o pegou. A tabela
   da §2 P1 cita quatro pares de status; são cinco.

2. **C-09 continha um deadlock que a auditoria não previu.** `runTokenOperation`
   delegava a `runConnectionOperation`, que **encadeia** quando a conexão já tem
   operação em voo. Como `_performRefreshOne` roda segurando esse slot, ligar o
   método ingenuamente faria um refresh esperar por si mesmo, para sempre. Só
   apareceu porque o teste de RED cede o event loop antes da troca de token; com
   a ordem de escrita errada, o teste passava e não provava nada.

3. **Falta de race no `test()` do provider.** `AntigravityOAuthProvider.test`
   chama `credential.refresh()` **direto**, fora do lock do serviço. O
   single-flight do serviço (A.2) não cobria esse terceiro momento de refresh
   previsto na spec. Por isso A.3 precisou de um segundo single-flight, no
   provider, com chave = segredo apresentado.

4. **C-05 estava exagerado, e o TDD refutou metade da análise.** Ver abaixo.

5. **C-05 tinha um defeito pior e não documentado.** No caminho de
   cancelamento a compensação era
   `try { await repo.delete(id); } finally { await store.delete(ref); }`.
   Um repositório que recusasse o delete reportava **"delete refused"** ao
   chamador em vez do cancelamento pedido — a UI mostraria uma falha de
   storage por um login que o usuário cancelou de propósito. É o defeito
   realmente demonstrável, e não estava no achado original.

### C-05 revisado: o que a evidência mostrou

A hipótese original era que os `await Future<void>.value()` tornavam o
cancelamento dependente de timing. O teste RED — cancelar de forma síncrona
assim que o login resolve, repetido 25 vezes — **passou contra o código antigo**.
Microtasks rodam em FIFO: quando o cancelamento é entregue antes de um `await`
real, o callback dele já está enfileirado à frente da continuação, e o check o
observa. A lacuna de determinismo era **mais estreita do que afirmei**.

O que restou de verdadeiro e verificável:

- Três checks consecutivos (`:547`, `:550`, `:556`) testavam a mesma flag sem
  nenhuma operação entre eles — código morto por construção.
- O mascaramento da compensação acima, que é o bug real.
- A ausência de um invariante declarado: agora toda saída passa por um único
  `_discardPartialConnection`, então uma conexão parcialmente commitada não
  pode sobreviver por construção, e não por sorte.

O cancelamento passou a ser observado uma vez por fronteira de commit,
imediatamente após um `await` real, que é onde a ordem é garantida.

---

## 4. Índice de severidade

| ID | Sev | Resumo | Arquivo principal |
|---|---|---|---|
| C-01 | P0 | Sem timeout HTTP no OAuth → trava conexão para sempre | `antigravity_oauth.dart:870-892` | ✅ `4f79598` |
| C-02 | P0 | DDL e `user_version` não atômicos → app não abre | `migration_00{1,2,3}.dart` | ✅ `1e144e1` |
| C-03 | P0 | `DateTime.parse` sem `tryParse` → 1 linha ruins todas | `quota_cache_repository.dart:25` | ✅ `1e144e1` |
| C-04 | P0 | Revogação incondicional → race destrói credencial | `antigravity_oauth.dart:667-670` | ✅ `f477ac9` |
| C-05 | P0 | Cancelamento: checks duplicados + compensação mascarando | `app_state.dart:546-593` | ✅ `c95b584` |
| C-06 | P1 | Status colors dark = light → 3,1:1 (AA falha) | `theme.dart:78-93` | ✅ `91b8840` |
| C-07 | P1 | `Colors.green`/`red` hardcoded → 2,78:1 | `connections_screen.dart:886-946` | ✅ `91b8840` |
| C-08 | P1 | "Last updated" nunca atualiza | `token_dock_widget.dart:56-69` | ✅ `b1ba687` |
| C-09 | P1 | `runTokenOperation` morto → sem single-flight | `refresh_service.dart:225-236` | ✅ `a4f902c` |
| C-10 | P1 | `_credential` mascar credencial corrompida | `antigravity_oauth.dart:808-814` |
| C-11 | P1 | Regex de mensagem — proibido pela spec | `credential_events.dart:26-32` |
| C-12 | P1 | `$e` cru na UI, sem redaction | `connections_screen.dart:589,742,155` |
| C-13 | P1 | Sanitizador cego a token | `connection_repository.dart:106-112` | ✅ `1e144e1` |
| C-14 | P1 | `shared: true` no loopback IPv6 | `oauth_loopback.dart:36-40` | ✅ `daf4af0` |
| C-15 | P1 | Exceções SQLite vazam SQL | `connections_screen.dart:742` |
| C-16 | P2 | N+1: `getAll()` no loop de refresh | `refresh_service.dart:308` |
| C-17 | P2 | Health re-buscada though same row | `app_state.dart:291` |
| C-18 | P2 | PowerShell sem timeout/cap no fetch | `antigravity_local.dart:169-173` |
| C-19 | P2 | Tipografia não bate com a spec | `theme.dart:172-199` |
| C-20 | P2 | Quota primária em `mutedInk` | `quota_row.dart:45-46` |
| C-21 | P2 | Tick 1s × N contra meta CPU≈0% | `countdown_text.dart:21` |
| C-22 | P2 | 3 builders duplicados + erro ausente em compact | `token_dock_widget.dart:211-367` |
| C-23 | P2 | Sem FK; índice redundante; coluna morta | `migration_001.dart` |
| C-24 | P2 | `Expando` estático + `const` → notifier compartilhado | `app_state.dart:176-185` |
| C-25 | P1 | Set ilimitado de refresh tokens em claro | `antigravity_oauth.dart:113` | ✅ `f477ac9` |
| C-26 | P2 | `redactHeaders`/`redactUrl` mortas | `log_redaction.dart:72,81` |
| C-27 | P2 | `_credential` duplicado | `antigravity_oauth.dart:808,861` |
| C-28 | P2 | `AuthKind` vs strings sem validação | `app_state.dart:432,810` |
| C-29 | P2 | `deleteSync` mascara timeout | `antigravity_local.dart:543-545` |
| C-30 | P2 | Segredo cru retido no widget | `connections_screen.dart:376-385` |
| C-31 | P3 | "No key cap" → "Unavailable" | `quota_row.dart:21` |
| C-32 | P3 | `AppCard`/`SectionHeader` mortos | `app_card.dart:10` |
| C-33 | P3 | `defaultRefreshIntervalMinutes` duplicado | `settings_repository.dart:9,42` |
| C-34 | P3 | Drift de documentação (8 itens) | ver tabela §2 P3 |
| C-35 | P3 | 1 asserção de contraste; 2 invariantes sem teste | `theme_test.dart` |
| C-36 | P3 | Flake: sleeps reais + sockets de 250ms | `refresh_service_test.dart` |

# TokenDock — Plano de Correção (Correctness & Claims Integrity)

**Data:** 2026-09-25 · **Branch:** `master` @ `0f5205e` · **Origem:** `docs/audit-2026-09-25-second-pass.md`
**Gate por fase (PRD §87):** implementação + loading/error state + persistência quando aplicável + teste + UI final.
**Gate global por fase:** `flutter test --no-pub` verde (baseline **235/235**), `flutter analyze` **0 erros / 0 warnings**, `dart format` limpo.

> **Ordem deliberada:** Fase A (P0) antes de qualquer coisa, porque C-01/C-04/C-09 formam uma cadeia — um socket travado *ou* um race de refresh destroi credencial. Nada de refactor cosmético antes de parar a perda de credencial.

---

## Fase A — Parar a perda de credencial (P0)

### A.1 · Timeout no cliente HTTP do OAuth · **C-01**

**Files:** `lib/providers/antigravity/antigravity_oauth.dart:870-892` · **Test:** `test/providers/antigravity_oauth_test.dart`

**Interface:** `_HttpClientRunner` ganha `connectionTimeout` / `responseTimeout` e um limite de tamanho de resposta, espelhando `openrouter_provider.dart:15,20-21,45,47-48`.

- [ ] Teste que falha: runner com socket que nunca responde → `test()` completa com snapshot `error`/`Timeout` em < 20s, em vez de pendurar.
- [ ] `_client.connectionTimeout = const Duration(seconds: 10)`.
- [ ] `.timeout(Duration(seconds: 15))` em `postUrl`, `close()` e no `join()` do corpo.
- [ ] Cap de resposta: abortar acima de 256 KiB (o `loadCodeAssist` é pequeno; `join()` sem cap é um vetor de exaustão de memória).
- [ ] Teste: corpo maior que o cap → falha limpa, sem OOM.

**Risco:** baixo. **Verificar:** teste de timeout novo + `antigravity_oauth_test.dart` completo.

---

### A.2 · Single-flight real na troca de token · **C-09**

**Files:** `lib/services/refresh_service.dart:407, 439, 225-236` · **Test:** `test/services/refresh_service_test.dart`

- [ ] Teste que falha: dois `refreshOne()` concorrentes no **mesmo** `connectionId` de Antigravity → o HTTP runner registra **1** POST a `/token`, não 2.
- [ ] `testAdapter` deixa de *enfileirar* e passa a **coalescer** via `runTokenOperation` (que hoje está morto).
- [ ] Os dois `await refreshable.refresh(...)` (`:407` e `:439`) passam por `runTokenOperation(connectionId: ..., operation: ...)`.
- [ ] Teste: `testAdapter` durante `refreshOne` em voo **compartilha** o resultado em vez de rodar de novo com secret obsoleto.

**Risco:** médio — muda semântica de concorrência. Mitigação: `runTokenOperation` já existe e já tem testes; o trabalho é **ligar**, não inventar.

**Por que antes de A.3:** A.3 corrige *o que acontece quando* o double-refresh ocorre. A.2 impede que ele ocorra. Juntos fecham C-04.

---

### A.3 · Detecção correta de reuso de refresh token · **C-04**

**Files:** `lib/providers/antigravity/antigravity_oauth.dart:113, 640-685` · **Test:** `test/providers/antigravity_oauth_test.dart:564-605`

- [ ] Teste que falha: **dois** `refresh()` concorrentes com o mesmo secret; o segundo recebe `invalid_grant`; **o `/revoke` NÃO é chamado** (porque o token não é realmente reuse — é uma corrida benigna) e o refresh token do primeiro **sobrevive**.
- [ ] Teste que falha: refresh token **realmente** rotacionado (presente em `_rotatedRefreshTokens`) + rejeitado → revoga a cadeia.
- [ ] `invalid_grant` só revoga quando `reused == true`; caso contrário propaga como falha transitória.
- [ ] Limitar `_rotatedRefreshTokens` a um `LinkedHashMap` com teto (ex.: 32) por conexão, removendo o mais antigo — hoje é um `Set` **ilimitado e não durável** que guarda refresh token em texto claro no singleton (C-25).
- [ ] Capturar `AntigravityTransientFailure` e `AntigravitySchemaChanged` no `refresh()` para não descartar o sinal de reuse.

**Risco:** médio. **Verificar:** testes de reuse **e** de corrida — ambos devem passar.

---

### A.4 · Ponto de commit único para cancelamento · **C-05**

**Files:** `lib/app/app_state.dart:502-603, 636-769` · **Test:** `test/app/app_state_test.dart`

**Substituir:** os 7+ `await Future<void>.value()` intercalados com checks de `cancellationRequested`.

**Por:** um booleano amostrado entre saltos de microtask não observa um cancelamento de macrotask. E `:547`/`:556` testam o mesmo sem operação intermediária.

- [ ] Teste que falha: cancelar **depois** do `loginWithLoopback` resolver mas **antes** do `store.write` → hoje a conexão é persistida; o correto é abortar e **não** deixar linha nem segredo.
- [ ] Introduzir um pequeno valor explícito de commit, ex.: `bool committed = false;` marcado imediatamente **após** `repo.save(connection)` ser confirmado, e a compensação (`store.delete` / `repo.delete`) dirigida por **uma única** decisão.
- [ ] Manter os checks de cancelamento **só** nos pontos onde importam (depois de cada `await` de escrita real), removendo os que cercam no-ops.
- [ ] Teste: nenhum caminho deixa `secret_ref` órfão nem linha apontando para credencial apagada.

**Risco:** médio-alto (é a área mais delicada). **Mitigação:** `antigravity_oauth.dart:171-211` já faz certo com `Future.any` — usar como referência de desenho.

---

### A.5 · Migrations atômicas + boot resiliente · **C-02**

**Files:** `lib/storage/migration_001/002/003.dart`, `lib/storage/database.dart`, `lib/main.dart:33`

- [ ] Teste que falha: banco em `user_version = 1` **com as colunas de 002 já aplicadas** (simula o crash entre COMMIT e PRAGMA) → hoje `duplicate column name`; o correto é recuperar.
- [ ] Mover `PRAGMA user_version = N` para **dentro** do mesmo `db.transaction` que aplica o DDL (`txn.execute`).
- [ ] Envolver cada `ALTER TABLE` em guarda de coluna: consultar `PRAGMA table_info(connections)` e só adicionar o que falta (idempotência real, já que SQLite não oferece `ADD COLUMN IF NOT EXISTS`).
- [ ] `AppDatabase.open`: `try/catch` → em falha de migration, **não** morrer; registrar e mostrar estado recuperável (usuário pode renomear/remover o `.db`).
- [ ] `main.dart:33`: guardar a abertura do banco; `runApp` com estado de erro em vez de crash pré-janela.

**Risco:** baixo-médio. **Verificar:** `repositories_test.dart` + novo teste de crash recovery.

---

### A.6 · Leitura defensiva de timestamps · **C-03**

**Files:** `lib/storage/quota_cache_repository.dart:23-25`, `lib/storage/connection_health_repository.dart:45-46`

- [ ] Teste que falha: inserir `reset_at = 'lixo'` → hoje `FormatException` em `getAll()`; o correto é `resetAt == null` e a linha aindarenderizando os demais campos.
- [ ] `DateTime.parse` → `DateTime.tryParse` com fallback `null` nos dois repositórios.
- [ ] Teste: `last_checked_at` corrompido → `get()` devolve `null` em vez de lançar.
- [ ] Alinhar com o provider layer, que **já** usa `tryParse` (`antigravity_local.dart:664`).

**Risco:** muito baixo. Ganho alto: uma linha podre deixa de derrubar todas as conexões.

---

**Gate da Fase A:** `flutter test` ≥ 235 verde · `analyze` 0/0 · 6 testes novos, todos vermelhos antes do fix.

---

## Fase B — Integridade das promessas documentadas (P1, baixo risco / alto ganho)

### B.1 · Ramp dark com status colors próprios · **C-06**

**Files:** `lib/app/theme.dart:78-93` · **Test:** `test/ui/theme_test.dart`

Derivar as status colors do dark ramp para ≥ 4,5:1 sobre `surface #1E1D23` e `mutedSurface #29272F`. Manter os **mesmos** matizes semânticos (verde/âmbar/vermelho/azul) para não quebrar o reconhecimento de status; só Clarear.

- [ ] **Parametrizar** o teste de contraste existente (`theme_test.dart:70-94`) para percorrer as **3 ramps × todos os pares texto/fundo em uso real** (status, ink, mutedInk, quotaFill, lime/limeInk) com limiar 4,5:1 para texto e 3:1 para não-texto.
- [ ] Verificar que o teste **falha** com os valores atuais (prova de que a lacuna era real).
- [ ] Ajustar o dark ramp até verde.
- [ ] Manter a identidade de matiz: um teste que verifique que `dark.statusOk` é **diferente** de `light.statusOk` **e** ainda verde.

### B.2 · Remover cores hardcoded · **C-07**

**Files:** `lib/ui/settings/connections_screen.dart:886, 892, 939, 946, 768, 902, 924` · `lib/ui/widget/widget_shell.dart:37`

- [ ] Teste que falha: sob `TokenDockTheme.light`, a mensagem "Connected" e a mensagem de erro devem usar `statusOk` / `statusLimited` — hoje usam `Colors.green` / `Colors.red`.
- [ ] Substituir por `TokenDockTheme.colorsOf(context).statusOk` / `.statusLimited`.
- [ ] Trocar `const TextStyle(color: ...)` hardcoded por `TokenDockTypography.*` + cor do ramp.
- [ ] `widget_shell.dart:37` `Color(0x0F000000)` → token de sombra.
- [ ] **Adicionar um guard de lint** para impedir regressão: `analysis_options.yaml` não pega `Colors.*`; a opção durável é um teste que varra `lib/` e falhe se encontrar `Colors.` fora de `theme.dart` (assert estático simples, sem toolchain nova).

### B.3 · "Last updated" que atualiza · **C-08**

**Files:** `lib/ui/widget/token_dock_widget.dart:56-69, 242, 290, 345` · **Test:** `test/ui/token_dock_widget_test.dart`

- [ ] Teste que falha: `fetchedAt` fixo, `pump(Duration(minutes: 5))` → o texto deve virar "5m ago". Hoje permanece "just now".
- [ ] Extrair um `RelativeAgeText` com timer próprio, ou **reusar o tick já existente** do `CountdownText` (melhor: 1 timer por conta, não 2).
- [ ] Testes diretos de `formatRelativeAge` cobrindo os 4 ramos: `just now`, `Nm ago`, `Nh ago`, `Nd ago` (hoje: **zero** testes).

### B.4 · Credencial corrompida vira erro, não bearer · **C-10**

**Files:** `lib/providers/antigravity/antigravity_oauth.dart:808-814, 861`

- [ ] Separar `_credential` (parse tolerante, para o blob JSON) de um parse **estrito** usado quando o segredo é lido do `SecretStore`.
- [ ] Teste que falha: segredo no store que não é JSON válido → snapshot `error` "Credential not readable" (não um 401 silencioso com o lixo como token).
- [ ] `AntigravityProvider` **sobrescrever `test()`** para fontes locais, em vez de depender do `try/catch` de `_credential` para que `''` funcione por acidente (C-10).
- [ ] Deduplicar as duas cópias de `_credential` (C-27).

### B.5 · Classificador por status, não por regex · **C-11**

**Files:** `lib/services/credential_events.dart:26-32`

A spec **proíbe** matching de mensagem. Tentar eliminar, não só reduzir.

- [ ] Subir `401` como `AntigravityTransportFailure(statusCode: 401)` e classificar por `statusCode`/header.
- [ ] Manter a regex de mensagem **apenas** para o corpo do token endpoint (`invalid_grant`), que é spec-defined e não tem status por si só — e **documentar** essa exceção.
- [ ] Teste: `StateError('Bad state: 401')` **não** deve mais ser tratado como `bare_401` (o teste deve provar que o comportamento mudou).
- [ ] Remover `isDefinitiveOAuthFailure` (morta) ou ligar onde pertence.

### B.6 · Redação em toda fronteira de erro · **C-12, C-13, C-15**

**Files:** `lib/ui/settings/connections_screen.dart:589, 742, 155` · `lib/storage/connection_repository.dart:106-112` · `lib/services/log_redaction.dart`

- [ ] Criar `StorageFailure` e translating no repository layer; nenhuma exceção SQLite crua chega à UI.
- [ ] Trocar os 3 `'$e'` por um mapper `describeError(e)` que **nunca** interpola a exceção bruta.
- [ ] Teste que falha: repositório que lança `DatabaseException` com SQL no mensaje → a UI mostra texto user-safe, sem `SELECT`/`INSERT`/nomes de tabela.
- [ ] **Provar** as 2 invariantes hoje sem teste: (a) "tokens nunca no SQLite" — varrer todas as colunas de `connections`/`quota_cache`/`settings` após o fluxo OAuth e afirmar ausência de material secreto; (f) DPAPI — teste de integração real de `SecureSecretStore` (hoje só existe fake).
- [ ] `_sanitizeProviderData` passa a usar o regex de `log_redaction.dart:3-6` (`key|token|secret|auth|credential|cookie`) em vez de só `*csrf*` (C-13).
- [ ] `redactSecret`: cobrir token **isolado** (sem prefixo de chave) — o `activeSecrets` deve conter os valores individuais, não só o blob (C-12).
- [ ] `redactHeaders`/`redactUrl`: ou ligar no caminho de erro, ou remover (hoje mortas, C-26).

### B.7 · Loopback exclusivo · **C-14**

**Files:** `lib/services/oauth_loopback.dart:36-40`

- [ ] `shared: true` → `shared: false` no bind IPv6, com fallback para v4-only no `SocketException` (já tratado em `:41-42`).
- [ ] Teste: um segundo bind na mesma porta IPv6 **falha** enquanto a sessão está ativa.

---

**Gate da Fase B:** contraste parametrizado verde nos 3 temas · `Colors.*` ausente de `lib/` (exceto `theme.dart`) · teste de "Last updated" avançando com `pump` · 2 invariantes de segurança agora **testadas**.

---

## Fase C — Corretude, performance, limpeza (P2)

### C.1 · Eliminar o N+1 · **C-16, C-17**

**Files:** `lib/storage/connection_repository.dart` (+ interface) · `lib/app/app_state.dart:285-304` · `lib/services/refresh_service.dart:249, 308` · `lib/app/app_state.dart:664, 899, 931`

- [ ] Adicionar `Future<Connection?> getById(String id)` à interface; implementar em `SqliteConnectionRepository` e nos fakes de teste.
- [ ] Teste que falha: um contador de queries em `refreshAll()` com 20 conexões deve ver **O(1)** leituras de `connections`, não 21.
- [ ] `load()`: mapear `last_status`/`last_checked_at`/`cooldown_until`/`last_error` no **mesmo** `getAll()` (a coluna já está na tabela — hoje `getAll()` a lê e descarta) e eliminar o `get()` por PK no loop.
- [ ] `quota_cache`: um `WHERE connection_id IN (...)` em vez de N queries.
- [ ] Índice em `connections(sort_order, created_at)` para o `ORDER BY`.

### C.2 · Corrigir a paridade das densidades e a hierarquia visual · **C-20, C-22**

**Files:** `lib/ui/widget/token_dock_widget.dart:211-367` · `lib/ui/components/quota_row.dart:45-46`

- [ ] Extrair o preâmbulo comum (`Divider` + `Focus` + `Semantics`) e o rodapé comum (`Last updated` + erro) num widget único; os 3 builders passam a diferir **só** pelo miolo.
- [ ] Decidir explicitamente: compact **deve** mostrar erro? Se sim, adicionar + teste. (Hoje não mostra, e nenhum teste afirma a assimetria.)
- [ ] Promover a quota primária: `quotaStyle` em `colors.ink` e não `mutedInk` — é o número que responde a pergunta central do produto.
- [ ] Teste: os 3 build paths produzem a mesma paridade de conteúdo.

### C.3 · Tipografia e countdown conforme a spec · **C-19, C-21**

**Files:** `lib/app/theme.dart:172-199` · `lib/ui/widget/countdown_text.dart:21`

- [ ] Alinhar a rampa com a spec (`15px` label, `20px w600` quota figures, degraus `18px`/`22px`).
- [ ] `tickInterval` 1s → 30s (o texto só tem granularidade de hora/minuto) ou alinhar ao próximo minuto.
- [ ] Teste: 20 `CountdownText` montados não geram 20 timers de 1s (afirmar o intervalo configurado).
- [ ] Testes para os ramos não cobertos de `formatRemaining`: dias, hora exata, minuto exato.

### C.4 · Integridade de schema e custódia · **C-23, C-25, C-28, C-30**

- [ ] Declarar `FOREIGN KEY (connection_id) REFERENCES connections(id) ON DELETE CASCADE` em `quota_cache`; `PRAGMA foreign_keys = ON` via `onConfigure` do `openDatabase` (hoje **nunca** habilitado).
- [ ] Remover o índice redundante `idx_quota_cache_connection` (coberto pela PK composta).
- [ ] Dropear a coluna morta `quota_cache.status` (sempre `null`, nunca lida).
- [ ] Migrar `auth_type` de string para derivado de `AuthKind` (ou validar na escrita que `adapter.authKind.name == authType`), eliminando a representação dupla (C-28).
- [ ] Limpar `_loadedRawSecret` no `dispose()` do diálogo (C-30).
- [ ] `deleteSync` do temp dir: tolerar `SHARING_VIOLATION` e não mascarar a exceção original (C-29).
- [ ] Descoberta PowerShell com `timeout` + cap de output (C-18).

### C.5 · `AppState` sem `Expando` · **C-24**

- [ ] `AppState` passa a **estender** `ChangeNotifier` (ou a expor um `Listenable` real). Remover o `_StateNotifier` paralelo e o `static final Expando`.
- [ ] Teste que falha: dois `const AppState.loading()` independentes; descartar um não pode afetar o outro.

---

## Fase D — Fechar a documentação (P3)

- [ ] **C-31** — implementar `No key cap` para quota sem limite (spec first-goal `:190`) **ou** corrigir a spec e update os testes. Escolher explicitamente; hoje o usuário vê "Unavailable" numa key **sem** limite, que se lê como erro. Colisão extra: `StatusIndicator` também usa `"Unavailable"`.
- [ ] **C-32** — `AppCard` e `SectionHeader` são código morto. Ou compor, ou remover e atualizar a spec que os lista como obrigatórios.
- [ ] **C-33** — unificar `defaultRefreshIntervalMinutes`.
- [ ] **C-34** — sincronizar: `PRD.txt` 227→235 · `403` mapping na spec · ramp dark · tipografia · formato do masking (`sk-...82AD` vs `sk-••••••••••82AD`) · comentários "stub" obsoletos em `tray_controller.dart:66,122`.
- [ ] **C-35** — testes que faltam: `limit == 0` · `reset_at` corrompido (já coberto em A.6) · boundaries 330/550 · `formatRelativeAge` (já em B.3) · string `Unavailable` · paridade entre densidades.
- [ ] **C-36** — trocar `Future.delayed` reais por `fakeAsync`/`pump`; subir o budget de socket de 250ms para 2s.
- [ ] Atualizar `PRODUCT.md` §Implementation Status e `tokendock/README.md` com a contagem real e com uma nota de que **nenhuma integração real** foi exercida.

---

## Ordem de execução sugerida

```text
A.1 timeout          ─┐
A.2 single-flight    ─┼─→ fecha C-01 + C-04 (cadeia de perda de credencial)
A.3 reuse detection  ─┘
A.4 commit único        fecha C-05
A.5 migrations         fecha C-02 (app não abre)
A.6 tryParse           fecha C-03 (1 linha derruba tudo)

B.1 dark ramp     ─┐
B.2 sem hardcode  ─┼─→ fecha as 2 falhas WCAG medidas
B.3 Last updated  ─┤
B.4 credencial    ─┤
B.5 sem regex     ─┼─→ fecha C-10..C-15
B.6 redação       ─┤
B.7 loopback      ─┘

C.*  performance, paridade, schema
D.*  documentação e lacunas de teste
```

**Sequenciamento interno:** B.1 e B.2 são 30 minutos cada e transformam 2 reprovações medidas em verde. Fazer **primeiro** se o objetivo for recuperar credibilidade das promessas de acessibilidade com o menor risco possível. A.1 e A.4 são as únicas tarefas deste plano que **não** devem ser delegadas nem paralelizadas — tocam concorrência e compensação de escrita.

---

## Definição de pronto (consolidada)

Uma fase só fecha quando, **tudo** isto é verdade:

1. `flutter test --no-pub` verde, contagem ≥ baseline + testes novos da fase.
2. `flutter analyze` com **0 erros e 0 warnings**.
3. Todo teste novo **foi visto falhar** antes do fix (vermelho → verde).
4. Nenhuma afirmação em `PRODUCT.md` / `README.md` / specs que não tenha teste correspondente.
5. Nenhum achado P0/P1 desta auditoria permanece aberto sem uma nota explícita de decisão.

**Não faz parte deste plano** (já estava deferred e continua): installer, release 0.1, notificações, grupos, drag-and-drop, auto-start, histórico/gráficos, MiniMax (bloqueado por schema oficial), OpenCode Go (sem API pública), scaling do servidor. Este plano **não adiciona nenhuma dependência**.

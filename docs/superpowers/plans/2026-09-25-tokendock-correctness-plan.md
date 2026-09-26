# TokenDock — Plano de Correção (Correctness & Claims Integrity)

**Data:** 2026-09-25 · **Atualizado:** 2026-09-26 · **Branch:** `master` @ `9ae626f` · **Origem:** `docs/audit-2026-09-25-second-pass.md`
**Gate por fase (PRD §87):** implementação + loading/error state + persistência quando aplicável + teste + UI final.
**Gate global por fase:** `flutter test --no-pub` verde, `flutter analyze` **0 erros / 0 warnings**, `dart format` limpo nos arquivos tocados.

> **Estado:** **todos os achados P0 (5/5) e P1 (11/11) estão fechados**, e é isso que a Fase A e a Fase B deveriam entregar. As sub-tarefas que ficaram abertas (A.5.4–5 boot resiliente, B.4.4 e B.5.4 código morto, B.6 parciais) são **hardening além do achado** ou pertencem a achados P2/P3 — nenhuma delas reabre um P0 ou um P1. Da Fase C, C-16, C-17, C-18, C-20 e C-21 estão fechados; da Fase D, C-31. Checkpoint e pendências: `docs/checkpoints/2026-09-26-correctness-checkpoint.md`.
> **Ordem deliberada:** Fase A (P0) antes de qualquer coisa, porque C-01/C-04/C-09 formam uma cadeia — um socket travado *ou* um race de refresh destroi credencial. Nada de refactor cosmético antes de parar a perda de credencial.

---

## Estado de execução

| Fase | Itens | Situação |
|---|---|---|
| A — perda de credencial (P0) | C-01 C-02 C-03 C-04 C-05 | 5/5 ✅ |
| B — promessas documentadas (P1) | C-06 C-07 C-08 C-09 C-10 C-11 C-12 C-13 C-14 C-15 C-25 | 11/11 ✅ |
| C — corretude/performance/UI | C-16 C-17 C-18 C-20 C-21 | 5/11 ✅ |
| D — documentação e testes | C-31 | 1/7 ✅ |

**Métrica:** 235 → 366 testes. Analyzer 33 → 31 infos, 0 erros, 0 warnings.

**Desvios do plano original, decididos durante a execução:**

- **B.6 não criou `StorageFailure`.** O plano previa esse tipo no layer de storage. A garantia que os testes exigem é "a UI nunca interpola a exceção", cumprida inteiramente pelo mapper `userSafeErrorMessage` com literal por call site. Criar `StorageFailure` sem produtor seria API especulativa. Registrado.
- **B.1 corrigiu uma asserção minha**, não o código: o hairline é divisor decorativo de 1px a 1,2:1, isento pelo WCAG 1.4.11. O requisito real é `quotaFill` e o anel de foco.
- **C.3 (C-19) permanece aberto por decisão:** é mudança visual e exige passe de design, não edição mecânica.
- **B.4 (C-27) e B.6 (C-26) ficaram abertos:** `_credential` continua duplicado e `redactHeaders`/`redactUrl` seguem sem chamadores. Ambos constam como pendentes na auditoria.

---

## Fase A — Parar a perda de credencial (P0) · concluída (A.1–A.4, A.6 ✅ · A.5 3/5)

### A.1 · Timeout no cliente HTTP do OAuth · **C-01**

**Files:** `lib/providers/antigravity/antigravity_oauth.dart:870-892` · **Test:** `test/providers/antigravity_oauth_test.dart`

**Interface:** `_HttpClientRunner` ganha `connectionTimeout` / `responseTimeout` e um limite de tamanho de resposta, espelhando `openrouter_provider.dart:15,20-21,45,47-48`.

- [x] Teste que falha: runner com socket que nunca responde → `test()` completa com snapshot `error`/`Timeout` em < 20s, em vez de pendurar.
- [x] `_client.connectionTimeout = const Duration(seconds: 10)`.
- [x] `.timeout(Duration(seconds: 15))` em `postUrl`, `close()` e no `join()` do corpo.
- [x] Cap de resposta: abortar acima de 256 KiB (o `loadCodeAssist` é pequeno; `join()` sem cap é um vetor de exaustão de memória).
- [x] Teste: corpo maior que o cap → falha limpa, sem OOM.

**Risco:** baixo. **Verificar:** teste de timeout novo + `antigravity_oauth_test.dart` completo.

---

### A.2 · Single-flight real na troca de token · **C-09**

**Files:** `lib/services/refresh_service.dart:407, 439, 225-236` · **Test:** `test/services/refresh_service_test.dart`

- [x] Teste que falha: dois `refreshOne()` concorrentes no **mesmo** `connectionId` de Antigravity → o HTTP runner registra **1** POST a `/token`, não 2.
- [x] `testAdapter` deixa de *enfileirar* e passa a **coalescer** via `runTokenOperation` (que hoje está morto).
- [x] Os dois `await refreshable.refresh(...)` (`:407` e `:439`) passam por `runTokenOperation(connectionId: ..., operation: ...)`.
- [x] Teste: `testAdapter` durante `refreshOne` em voo **compartilha** o resultado em vez de rodar de novo com secret obsoleto.

**Risco:** médio — muda semântica de concorrência. Mitigação: `runTokenOperation` já existe e já tem testes; o trabalho é **ligar**, não inventar.

**Por que antes de A.3:** A.3 corrige *o que acontece quando* o double-refresh ocorre. A.2 impede que ele ocorra. Juntos fecham C-04.

---

### A.3 · Detecção correta de reuso de refresh token · **C-04**

**Files:** `lib/providers/antigravity/antigravity_oauth.dart:113, 640-685` · **Test:** `test/providers/antigravity_oauth_test.dart:564-605`

- [x] Teste que falha: **dois** `refresh()` concorrentes com o mesmo secret; o segundo recebe `invalid_grant`; **o `/revoke` NÃO é chamado** (porque o token não é realmente reuse — é uma corrida benigna) e o refresh token do primeiro **sobrevive**.
- [x] Teste que falha: refresh token **realmente** rotacionado (presente em `_rotatedRefreshTokens`) + rejeitado → revoga a cadeia.
- [x] `invalid_grant` só revoga quando `reused == true`; caso contrário propaga como falha transitória.
- [x] Limitar `_rotatedRefreshTokens` a um `LinkedHashMap` com teto (ex.: 32) por conexão, removendo o mais antigo — hoje é um `Set` **ilimitado e não durável** que guarda refresh token em texto claro no singleton (C-25).
- [x] Capturar `AntigravityTransientFailure` e `AntigravitySchemaChanged` no `refresh()` para não descartar o sinal de reuse.

**Risco:** médio. **Verificar:** testes de reuse **e** de corrida — ambos devem passar.

---

### A.4 · Ponto de commit único para cancelamento · **C-05**

**Files:** `lib/app/app_state.dart:502-603, 636-769` · **Test:** `test/app/app_state_test.dart`

**Substituir:** os 7+ `await Future<void>.value()` intercalados com checks de `cancellationRequested`.

**Por:** um booleano amostrado entre saltos de microtask não observa um cancelamento de macrotask. E `:547`/`:556` testam o mesmo sem operação intermediária.

- [x] Teste que falha: cancelar **depois** do `loginWithLoopback` resolver mas **antes** do `store.write` → hoje a conexão é persistida; o correto é abortar e **não** deixar linha nem segredo.
- [x] Introduzir um pequeno valor explícito de commit, ex.: `bool committed = false;` marcado imediatamente **após** `repo.save(connection)` ser confirmado, e a compensação (`store.delete` / `repo.delete`) dirigida por **uma única** decisão.
- [x] Manter os checks de cancelamento **só** nos pontos onde importam (depois de cada `await` de escrita real), removendo os que cercam no-ops.
- [x] Teste: nenhum caminho deixa `secret_ref` órfão nem linha apontando para credencial apagada.

**Risco:** médio-alto (é a área mais delicada). **Mitigação:** `antigravity_oauth.dart:171-211` já faz certo com `Future.any` — usar como referência de desenho.

---

### A.5 · Migrations atômicas + boot resiliente · **C-02**

**Files:** `lib/storage/migration_001/002/003.dart`, `lib/storage/database.dart`, `lib/main.dart:33`

- [x] Teste que falha: banco em `user_version = 1` **com as colunas de 002 já aplicadas** (simula o crash entre COMMIT e PRAGMA) → hoje `duplicate column name`; o correto é recuperar.
- [x] Mover `PRAGMA user_version = N` para **dentro** do mesmo `db.transaction` que aplica o DDL (`txn.execute`).
- [x] Envolver cada `ALTER TABLE` em guarda de coluna: consultar `PRAGMA table_info(connections)` e só adicionar o que falta (idempotência real, já que SQLite não oferece `ADD COLUMN IF NOT EXISTS`).
- [ ] `AppDatabase.open`: `try/catch` → em falha de migration, **não** morrer; registrar e mostrar estado recuperável (usuário pode renomear/remover o `.db`).
- [ ] `main.dart:33`: guardar a abertura do banco; `runApp` com estado de erro em vez de crash pré-janela.

**Risco:** baixo-médio. **Verificar:** `repositories_test.dart` + novo teste de crash recovery.

---

### A.6 · Leitura defensiva de timestamps · **C-03**

**Files:** `lib/storage/quota_cache_repository.dart:23-25`, `lib/storage/connection_health_repository.dart:45-46`

- [x] Teste que falha: inserir `reset_at = 'lixo'` → hoje `FormatException` em `getAll()`; o correto é `resetAt == null` e a linha aindarenderizando os demais campos.
- [x] `DateTime.parse` → `DateTime.tryParse` com fallback `null` nos dois repositórios.
- [x] Teste: `last_checked_at` corrompido → `get()` devolve `null` em vez de lançar.
- [x] Alinhar com o provider layer, que **já** usa `tryParse` (`antigravity_local.dart:664`).

**Risco:** muito baixo. Ganho alto: uma linha podre deixa de derrubar todas as conexões.

---

**Gate da Fase A:** `flutter test` ≥ 235 verde · `analyze` 0/0 · 6 testes novos, todos vermelhos antes do fix.

---

## Fase B — Integridade das promessas documentadas (P1, baixo risco / alto ganho) · concluída (B.1–B.3, B.5, B.7 ✅ · B.4 3/4 · B.6 3/7)

### B.1 · Ramp dark com status colors próprios · **C-06**

**Files:** `lib/app/theme.dart:78-93` · **Test:** `test/ui/theme_test.dart`

Derivar as status colors do dark ramp para ≥ 4,5:1 sobre `surface #1E1D23` e `mutedSurface #29272F`. Manter os **mesmos** matizes semânticos (verde/âmbar/vermelho/azul) para não quebrar o reconhecimento de status; só Clarear.

- [x] **Parametrizar** o teste de contraste existente (`theme_test.dart:70-94`) para percorrer as **3 ramps × todos os pares texto/fundo em uso real** (status, ink, mutedInk, quotaFill, lime/limeInk) com limiar 4,5:1 para texto e 3:1 para não-texto.
- [x] Verificar que o teste **falha** com os valores atuais (prova de que a lacuna era real).
- [x] Ajustar o dark ramp até verde.
- [x] Manter a identidade de matiz: um teste que verifique que `dark.statusOk` é **diferente** de `light.statusOk` **e** ainda verde.

### B.2 · Remover cores hardcoded · **C-07**

**Files:** `lib/ui/settings/connections_screen.dart:886, 892, 939, 946, 768, 902, 924` · `lib/ui/widget/widget_shell.dart:37`

- [x] Teste que falha: sob `TokenDockTheme.light`, a mensagem "Connected" e a mensagem de erro devem usar `statusOk` / `statusLimited` — hoje usam `Colors.green` / `Colors.red`.
- [x] Substituir por `TokenDockTheme.colorsOf(context).statusOk` / `.statusLimited`.
- [x] Trocar `const TextStyle(color: ...)` hardcoded por `TokenDockTypography.*` + cor do ramp.
- [x] `widget_shell.dart:37` `Color(0x0F000000)` → token de sombra.
- [x] **Adicionar um guard de lint** para impedir regressão: `analysis_options.yaml` não pega `Colors.*`; a opção durável é um teste que varra `lib/` e falhe se encontrar `Colors.` fora de `theme.dart` (assert estático simples, sem toolchain nova).

### B.3 · "Last updated" que atualiza · **C-08**

**Files:** `lib/ui/widget/token_dock_widget.dart:56-69, 242, 290, 345` · **Test:** `test/ui/token_dock_widget_test.dart`

- [x] Teste que falha: `fetchedAt` fixo, `pump(Duration(minutes: 5))` → o texto deve virar "5m ago". Hoje permanece "just now".
- [x] Extrair um `RelativeAgeText` com timer próprio, ou **reusar o tick já existente** do `CountdownText` (melhor: 1 timer por conta, não 2).
- [x] Testes diretos de `formatRelativeAge` cobrindo os 4 ramos: `just now`, `Nm ago`, `Nh ago`, `Nd ago` (hoje: **zero** testes).

### B.4 · Credencial corrompida vira erro, não bearer · **C-10**

**Files:** `lib/providers/antigravity/antigravity_oauth.dart:808-814, 861`

- [x] Separar `_credential` (parse tolerante, para o blob JSON) de um parse **estrito** usado quando o segredo é lido do `SecretStore`.
- [x] Teste que falha: segredo no store que não é JSON válido → snapshot `error` "Credential not readable" (não um 401 silencioso com o lixo como token).
- [x] `AntigravityProvider` **sobrescrever `test()`** para fontes locais, em vez de depender do `try/catch` de `_credential` para que `''` funcione por acidente (C-10).
- [ ] Deduplicar as duas cópias de `_credential` (C-27).

### B.5 · Classificador por status, não por regex · **C-11**

**Files:** `lib/services/credential_events.dart:26-32`

A spec **proíbe** matching de mensagem. Tentar eliminar, não só reduzir.

- [x] Subir `401` como `AntigravityTransportFailure(statusCode: 401)` e classificar por `statusCode`/header.
- [x] Manter a regex de mensagem **apenas** para o corpo do token endpoint (`invalid_grant`), que é spec-defined e não tem status por si só — e **documentar** essa exceção.
- [x] Teste: `StateError('Bad state: 401')` **não** deve mais ser tratado como `bare_401` (o teste deve provar que o comportamento mudou).
- [ ] Remover `isDefinitiveOAuthFailure` (morta) ou ligar onde pertence.

### B.6 · Redação em toda fronteira de erro · **C-12, C-13, C-15**

**Files:** `lib/ui/settings/connections_screen.dart:589, 742, 155` · `lib/storage/connection_repository.dart:106-112` · `lib/services/log_redaction.dart`

- [~] **Não criar `StorageFailure`** — decisão durante a execução. A garantia que os testes exigem é *"a UI nunca interpola a exceção"*, e ela é cumprida inteiramente pelo mapper `userSafeErrorMessage` com literal por call site. Um tipo novo sem produtor seria API especulativa. Nenhuma exceção SQLite crua chega à UI. ✅
- [x] Trocar os 3 `'$e'` por um mapper `describeError(e)` que **nunca** interpola a exceção bruta.
- [x] Teste que falha: repositório que lança `DatabaseException` com SQL no mensaje → a UI mostra texto user-safe, sem `SELECT`/`INSERT`/nomes de tabela.
- [ ] **Provar** as 2 invariantes hoje sem teste: (a) ✅ feita — `read_resilience_test.dart` varre as colunas e afirma ausência de material secreto; (f) ❌ **aberta** — DPAPI real exige a toolchain Windows e um `SecureSecretStore` de verdade, não o fake.
- [x] `_sanitizeProviderData` passa a usar o regex de `log_redaction.dart:3-6` (`key|token|secret|auth|credential|cookie`) em vez de só `*csrf*` (C-13).
- [~] `redactSecret` **não** foi estendido. O teste de um escape hatch que introduzi provou que `"Rejected token sk-or-v1-..."` (sem `:` ou `=`) **passa** pelo redator. Em vez de deixar uma API com garantia best-effort não provada, toda string visível ao usuário passou a ser um **literal em tempo de compilação** escolhido no call site. A garantia fica mais forte, não mais fraca, e não depende do redator.
- [ ] `redactHeaders`/`redactUrl`: ou ligar no caminho de erro, ou remover (hoje mortas, C-26). **Aberto** — sem produtor, sem teste.

### B.7 · Loopback exclusivo · **C-14**

**Files:** `lib/services/oauth_loopback.dart:36-40`

- [x] `shared: true` → `shared: false` no bind IPv6, com fallback para v4-only no `SocketException` (já tratado em `:41-42`).
- [x] Teste: um segundo bind na mesma porta IPv6 **falha** enquanto a sessão está ativa.

---

**Gate da Fase B:** contraste parametrizado verde nos 3 temas · `Colors.*` ausente de `lib/` (exceto `theme.dart`) · teste de "Last updated" avançando com `pump` · 2 invariantes de segurança agora **testadas**.

---

## Fase C — Corretude, performance, limpeza (P2) · parcial (C.1 ✅ · C.2 1/4 · C.3 1/4 · C.4 1/7 · C.5 ⬜)

### C.1 · Eliminar o N+1 · **C-16, C-17**

**Files:** `lib/storage/connection_repository.dart` (+ interface) · `lib/app/app_state.dart:285-304` · `lib/services/refresh_service.dart:249, 308` · `lib/app/app_state.dart:664, 899, 931`

- [x] Adicionar `Future<Connection?> getById(String id)` à interface; implementar em `SqliteConnectionRepository` e nos fakes de teste.
- [x] Teste que falha: um contador de queries em `refreshAll()` com 20 conexões deve ver **O(1)** leituras de `connections`, não 21.
- [x] `load()`: mapear `last_status`/`last_checked_at`/`cooldown_until`/`last_error` no **mesmo** `getAll()` (a coluna já está na tabela — hoje `getAll()` a lê e descarta) e eliminar o `get()` por PK no loop.
- [x] `quota_cache`: um `WHERE connection_id IN (...)` em vez de N queries.
- [x] Índice em `connections(sort_order, created_at)` para o `ORDER BY`. `6b93b7b`

### C.2 · Corrigir a paridade das densidades e a hierarquia visual · **C-20, C-22**
**Files:** `lib/ui/widget/token_dock_widget.dart:211-367` · `lib/ui/components/quota_row.dart:45-46`

- [x] Extrair o preâmbulo comum (`Divider` + `Focus` + `Semantics`) e o rodapé comum (`Last updated` + erro) num widget único; os 3 builders passam a diferir **só** pelo miolo. `_buildAccounts(context, accounts, body)`. `ddd03f7`
  - O gap de cauda fica com cada densidade, porque **difere de facto**: expanded afasta o rodapé por `s8` (empilha todas as quotas), compact e normal por `s4`. Output de normal e expanded inalterado.
- [x] Decidir explicitamente: compact **deve** mostrar erro? **Sim, decidido com o mantenedor.** O gradiente de densidade passa a ser só sobre o detalhe da quota (1 valor simples · 1 `QuotaRow` · todas). Sem a linha, um utilizador no formato default lia um número possivelmente com horas de atraso apresentado como atual — a *cache-first truth* deixa de funcionar. Custo aceite: compact cresce uma linha exactamente quando o utilizador precisa de agir. `ddd03f7`
- [x] Promover a quota primária: `quotaStyle` em `colors.ink` e não `mutedInk` — é o número que responde a pergunta central do produto. `e353e9f`
- [x] Teste: os 3 build paths produzem a mesma paridade de conteúdo. `test/ui/density_parity_test.dart`, table-driven sobre as 3 larguras — 7 testes (a linha de erro em cada densidade, nenhum erro inventado numa conexão saudável, e nome + status expostos a tecnologia assistiva em cada densidade). Cobre também o gap de paridade que C-35 lista. `ddd03f7`
  - Nota: o `Semantics` aqui não é `container`, logo a anotação funde-se com o texto dos descendentes num só nó. A primeira versão casava o label exacto e falhava nas 3 densidades — era uma expectativa errada no teste, não um bug de produto, confirmado contra `StatusIndicator.labelOf` antes de mudar para regex de prefixo.

### C.3 · Tipografia e countdown conforme a spec · **C-19, C-21**

**Files:** `lib/app/theme.dart:172-199` · `lib/ui/widget/countdown_text.dart:21`

- [ ] Alinhar a rampa com a spec (`15px` label, `20px w600` quota figures, degraus `18px`/`22px`).
- [x] `tickInterval` 1s → 30s (o texto só tem granularidade de hora/minuto) ou alinhar ao próximo minuto.
- [ ] Teste: 20 `CountdownText` montados não geram 20 timers de 1s (afirmar o intervalo configurado).
- [ ] Testes para os ramos não cobertos de `formatRemaining`: dias, hora exata, minuto exato.

### C.4 · Integridade de schema e custódia · **C-23, C-25, C-28, C-30**

- [x] Declarar `FOREIGN KEY (connection_id) REFERENCES connections(id) ON DELETE CASCADE` em `quota_cache`; `PRAGMA foreign_keys = ON` aplicado em `AppDatabase.open` **depois** das migrations (decidido — `onConfigure` foi descartado, ver checkpoint). `6b93b7b`
  - [x] `Migration004` reconstrói `quota_cache` (SQLite não adiciona FK a tabela existente) e **purga órfãos** no copy com `WHERE EXISTS` — filtrar, e não limpar depois, porque uma linha que viola a constraint derruba a transação inteira e o delete nunca correria.
  - [x] Rebuild gated em `PRAGMA foreign_key_list` não-vazio, para um run cujo DDL commitou sem o marcador de versão ser reconhecido como já feito.
  - [x] Testes: pragma = 1 após `open` · `foreign_key_list` declara a cascata · órfão é descartado · `user_version` obsoleto sobre tabela já reconstruída retoma · órfão plantado não impede a abertura.
  - [x] `TestDatabase.create` aplica a mesma ordem, para os repositórios serem testados sob o contrato de produção. **Isto expôs dois fixtures** (`repositories_test.dart`) que guardavam quota de conexões inexistentes; os pais em falta foram adicionados.
- [x] `Migration004`: remover o índice redundante `idx_quota_cache_connection` (coberto pela PK composta), a coluna morta `quota_cache.status` (o `'status': null` no `saveAll` foi removido — a coluna deixou de existir), e criar `idx_connections_sort_order ON connections(sort_order, created_at)` (deixado por trás em C.1). `6b93b7b`
  - A cascata manual em `ConnectionRepository.delete` foi **mantida de propósito**: a base é agora a autoridade, mas apagar as linhas primeiro mantém o comportamento idêntico numa base que falhou a migrar.
- [ ] Migrar `auth_type` de string para derivado de `AuthKind` (ou validar na escrita que `adapter.authKind.name == authType`), eliminando a representação dupla (C-28).
- [ ] Limpar `_loadedRawSecret` no `dispose()` do diálogo (C-30).
- [ ] `deleteSync` do temp dir: tolerar `SHARING_VIOLATION` e não mascarar a exceção original (C-29).
- [x] Descoberta PowerShell com `timeout` + cap de output (C-18).

### C.5 · `AppState` sem `Expando` · **C-24**

- [x] `AppState` passa a **estender** `ChangeNotifier`. `_StateNotifier`, o `static final Expando`, `_effectiveNotifier` e os 4 métodos de delegação removidos; `isLoading`, `accounts` e a contabilidade do refresh-interval passaram a campos próprios. `3705170`
- [x] Teste que falha: dois `const AppState.loading()` independentes; descartar um não pode afetar o outro. `test/app/app_state_notifier_test.dart`
  - **O enunciado acima é auto-contraditório em Dart** — duas instâncias `const` são sempre o mesmo objecto, e a contradição *é* o bug. Os construtores passaram a não-`const` (um `ChangeNotifier` tem estado mutável; um objecto canonicalizado não pode ter) e o teste afirma a invariante pela grafia que a correcção introduz. O sintoma literal da auditoria foi reproduzido: `A _StateNotifier was used after being disposed`.
- [x] `TokenDockWidget.loading()`/`.empty()` e `TokenDockApp` deixaram de ser `const`; o único call site `const` nos testes foi actualizado. `3705170`
  - ⚠️ **Armadilha evitada:** o fallback de `TokenDockApp` era construído *dentro de `build`*. Escrever `AppState.loading()` ali criaria um notifier novo a cada rebuild de um antepassado e largaria a subscrição do `ListenableBuilder` sem erro visível. Passou a ser construído uma vez no construtor, guardado num campo. `TokenDockApp` não é `const` em nenhum call site, logo não custou nada.
- [x] Ownership verificado: `ConnectionsScreen` já fazia `removeListener` no `dispose` e só descarta o state que criou — nunca o singleton da app.

---

## Fase D — Fechar a documentação (P3)

- [x] **C-31** — implementar `No key cap` para quota sem limite (spec first-goal `:190`) **ou** corrigir a spec e update os testes. Escolher explicitamente; hoje o usuário vê "Unavailable" numa key **sem** limite, que se lê como erro. Colisão extra: `StatusIndicator` também usa `"Unavailable"`.
- [x] **C-32** — `AppCard` e `SectionHeader` removidos. A spec first-goal listava-os como obrigatórios, mas o sistema visual migrou para um único contentor *card-free* (`WidgetShell`), e o próprio doc do `AppCard` afirmava ser "the one shell surface" quando o `WidgetShell` o era. Compor tê-los-ia reintroduzido o chrome de cards que o design eliminou; a spec regista agora a supersessão. `14f6979`
- [x] **C-33** — `SqliteSettingsRepository.defaultRefreshIntervalMinutes` duplicado face à constante de topo; removido. `14f6979`
- [x] **C-34** — sincronizado: ✅ contagens · ✅ nota de "nenhuma integração real" · ✅ **masking** (`sk-...` passou a `sk-` + 10 bullets fixos, como a spec; o glifo é `'\u2022'` porque um literal não-ASCII é corrompido em silêncio por ferramentas que adivinham o encoding) · ✅ **403** (a spec estava errada: mapeava 401 *e* 403 para `authError`; só 401 invalida credencial) · ✅ **ramp dark** (acentos escuros agora especificados com o valor medido) · ✅ **tipografia** (C-19, `b853186`) · ✅ **comentários "stub"** em `tray_controller.dart` (já não são stubs; estão ligados em `main.dart`). `75b7ef5`
- [x] **C-35** — testes que faltam: ✅ `limit == 0` (era um bug vivo: renderizava `5/0 USD`) · ✅ boundaries 330/550 · ✅ paridade entre densidades (`density_parity_test.dart`) · ✅ `Unavailable` (já coberto). Já cobertos: `reset_at` corrompido (A.6) e `formatRelativeAge` (B.3). `757aa09`
- [x] **C-36** — ✅ budget de socket 250ms → 2s, com nome e a nota de que é uma guarda de vivacidade e não um orçamento de performance · ✅ não restam `Future.delayed` reais na suite. `757aa09`
- [x] Atualizar `PRODUCT.md` §Implementation Status e `tokendock/README.md` com a contagem real e com uma nota de que **nenhuma integração real** foi exercida.

---

## Ordem de execução — registro histórico

Ordem **planejada** (válida para quem retomar) e o que de fato aconteceu:

| Etapa planejada | Estado real | Commit |
|---|---|---|
| A.1 timeout | ✅ | `4f79598` |
| A.2 single-flight | ✅ — continha um deadlock que a auditoria não previu | `a4f902c` |
| A.3 reuse detection | ✅ | `f477ac9` |
| A.4 commit único | ✅ — e a compensação não mascara mais o cancelamento | `c95b584` |
| A.5 migrations | ✅ 5/5 — o boot resiliente tambem foi fechado (`431e2ca`) | `1e144e1`, `431e2ca` |
| A.6 tryParse | ✅ | `1e144e1` |
| B.1 dark ramp | ✅ | `91b8840` |
| B.2 sem hardcode | ✅ | `91b8840` |
| B.3 Last updated | ✅ | `b1ba687` |
| B.4 credencial | ✅ 4/4 — `_credential` deduplicado em C-27 (`45aad6c`) | `44bcf25`, `45aad6c` |
| B.5 sem regex | ✅ 4/4 — `isDefinitiveOAuthFailure` removida em C-27 (`45aad6c`) | `44bcf25`, `45aad6c` |
| B.6 redação | ⚠️ 3/7 — `StorageFailure` descartado de propósito, DPAPI real em aberto | `ca749bf` |
| B.7 loopback | ✅ | `daf4af0` |
| C.1 N+1 | ✅ 5/5 — o índice em `connections(sort_order, created_at)` foi criado em C-23 | `ba67afd`, `d2b8467`, `6b93b7b` |
| C.2 paridade | ✅ 4/4 | `e353e9f`, `ddd03f7` |
| C.3 tick e tipografia | ✅ 4/4 | `e353e9f`, `b853186` |
| C.4 schema e custódia | ✅ 7/7 | `841eede`, `6b93b7b`, `f43e27b`, `14f6979` |
| C.5 notifier | ✅ 3/3 | `3705170` |
| D.1 documentação | ✅ 7/7 | `4faea73`, `35cddde`, `1fd84aa`, `75b7ef5` |

**Sequenciamento interno:** B.1 e B.2 são ~30 minutos cada e transformam 2 reprovações medidas em verde — o melhor custo/benefício do plano. A.1 e A.4 são as únicas tarefas que **não** devem ser delegadas nem paralelizadas, porque tocam concorrência de socket e compensação de escrita.

---

## Definição de pronto (consolidada)

Uma fase só fecha quando, **tudo** isto é verdade:

1. `flutter test --no-pub` verde, contagem ≥ baseline + testes novos da fase.
2. `flutter analyze` com **0 erros e 0 warnings**.
3. Todo teste novo **foi visto falhar** antes do fix (vermelho → verde).
4. Nenhuma afirmação em `PRODUCT.md` / `README.md` / specs que não tenha teste correspondente.
5. Nenhum achado P0/P1 desta auditoria permanece aberto sem uma nota explícita de decisão.

**Estado em `9ae626f`:** 1 ✅ · 2 ✅ · 3 ✅ · 4 ✅ (para tudo que está fechado) · 5 ✅ — **os 5 critérios de P0 e P1 são satisfeitos.** Os que faltam são P2/P3, com decisão registrada item a item acima.

**Estado em `431e2ca`:** **os 36 achados da auditoria estão fechados**, e os dois portões que faltavam verificação foram finalmente corridos pela primeira vez — `flutter build windows --release` bem-sucedido (158s) e `integration_test/multi_account_flow_test.dart` 3/3 no device `windows-x64`. Os cinco critérios acima estão todos satisfeitos. O que permanece por verificar não é código: integração real com Google/OpenRouter, browser externo e processo Antigravity, porque todos os testes usam fixtures sanitizadas.

**Não faz parte deste plano** (já estava deferred e continua): installer, release 0.1, notificações, grupos, drag-and-drop, auto-start, histórico/gráficos, **OpenCode Go e Zen** (ver nota abaixo), scaling do servidor. Este plano **não adiciona nenhuma dependência**.

> **MiniMax e OpenCode — resolvido em `9511321` (2026-09-26).** O plano adiava MiniMax como "bloqueado por schema oficial" e OpenCode Go como "sem API pública". Verificado contra a documentação dos fornecedores:
> - **MiniMax implementado.** Tem probe de credencial real (`GET https://api.minimax.io/v1/models` → 401 com chave inválida, medido). Não publica nenhuma API de uso/saldo/quota — o Token Plan só existe como barra no console — logo mostra **saúde da ligação apenas**, com quotas vazias. Um teste fixo que a lista se mantém vazia, para que nunca se torne um número inventado.
> - **OpenCode Zen e Go continuam deferred, agora por um motivo medido e não por falta de investigação.** Ambos publicam `GET /zen*/v1/models` que devolve **200 com bearer inválido**. Um gate que aceita qualquer chave não é um gate; offering o provider daria um test-before-save que passa sempre, e o utilizador gravaria uma chave quebrada achando que foi verificada. Nenhum dos dois publica uso por API. Detalhes e medições em `OpenCodeSupport` (`lib/providers/provider_registry.dart`). Rever quando documentarem um endpoint de uso ou um probe que exija a chave sem consumir quota.

---

## Pendências para a próxima sessão

Em ordem de valor, com o motivo. Os IDs são de
`docs/audit-2026-09-25-second-pass.md`; o raciocínio completo e os riscos
carregados estão em `docs/checkpoints/2026-09-26-correctness-checkpoint.md`.

1. **C-23 · integridade de schema.** Sem FK em lugar nenhum, `PRAGMA foreign_keys`
   nunca habilitado, `idx_quota_cache_connection` redundante com a PK composta,
   `quota_cache.status` morta. Também cobre o índice `connections(sort_order,
   created_at)` que C.1 deixou para trás. **Exige migration** (`Migration004`).
   **Decisão tomada:** manter o ownership manual de `user_version` e aplicar o
   pragma em `AppDatabase.open` **depois** das migrations. `onConfigure` foi
   descartado porque `PRAGMA foreign_keys` é no-op dentro de transação, então
   ele deixaria a enforcement ativa sobre o rebuild que a FK exige — medido, e
   um banco com um órfão deixaria de abrir. Detalhes no checkpoint.
2. **C-22 · paridade entre densidades.** Extrair preâmbulo e rodapé comuns dos
   3 builders e decidir se compact deve mostrar `snapshot.error`.
3. **C-19 · tipografia contra a spec.** 11/13/15/18/22px e 20px semibold.
   Exige passe de design, não edição mecânica.
4. **C-24 · `AppState` sem `Expando`.** Dois `const AppState.loading()`
   compartilham um notifier; `dispose()` em um afeta o outro.
5. **C-26/C-27 · código morto.** `redactHeaders`, `redactUrl`,
   `isDefinitiveOAuthFailure` sem chamadores; `_credential` duplicado.
6. **A.5 · boot resiliente.** `AppDatabase.open` ainda mata o app se a migration
   falhar, e `main.dart:33` abre o banco sem guarda.
7. **C-29/C-30 · limpeza.** `deleteSync` em `finally` mascara o timeout do agy;
   `_loadedRawSecret` não é limpo no `dispose` do diálogo.
8. **C-28, C-32, C-33, C-34, C-35, C-36 · itens menores.**

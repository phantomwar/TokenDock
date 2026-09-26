# Auth: o que aprender com oh-my-pi e 9router

Pesquisa de 2026-09-23 sobre autenticação/credenciais em dois repos de referência,
focada no que é adaptável ao TokenDock na hora de autenticar (API keys hoje,
OAuth amanhã: MiniMax, Antigravity multi-account).

> **Status (2026-09-23):** pesquisa de referência mantida como snapshot histórico. A implementação posterior está registrada em `docs/auth-quota-hardening-plan.md`, `docs/superpowers/specs/2026-09-23-tokendock-login-adaptation-design.md` e no checkpoint `docs/checkpoints/2026-09-23-login-adaptation-checkpoint.md`.
>
> **Actualizado 2026-09-26 (MiniMax e OpenCode).** Esta pesquisa recomendou `minimax=api-key` no registro. Verificado contra a documentação dos fornecedores: **MiniMax tem probe de credencial real** (`GET https://api.minimax.io/v1/models` → 401 com chave inválida) e está implementado. Mas **não publica nenhuma API de uso, saldo ou quota** — o Token Plan é "shown as a usage bar in the console" — logo o provider mostra só saúde da ligação, com a lista de quotas vazia em vez de um número inventado. **OpenCode Zen e Go não foram adicionados**: ambos publicam `GET /zen*/v1/models` que devolve **200 mesmo com bearer inválido** (medido), portanto não sustentam o gate test-before-save; e nenhum dos dois publica uso por API. O raciocínio completo e as medições estão em `OpenCodeSupport` em `lib/providers/provider_registry.dart`, fixados por `test/providers/provider_registry_test.dart`.

- `can1357/oh-my-pi` — harness Oh My Pi (TS+Bun+Rust). Auth centralizada em
  `AuthStorage` (`packages/ai/src/auth-storage.ts`, ~8k linhas) sobre
  `AuthCredentialStore` com implementação SQLite default
  (`packages/ai/src/auth/sqlite-credential-store.ts`) e variante remota
  auth-broker. Identidade confirmada via `gh repo view`.
- `decolua/9router` — roteador LLM 40+ providers (JS, MIT, ~29.6k stars).
  Auth por conexão (linhas em `providerConnections` SQLite). Identidade
  confirmada via `gh repo view`.

Estado do TokenDock na data da pesquisa (para calibrar as adaptações):
`ProviderAdapter.test()/fetch()` (`lib/providers/provider_adapter.dart`),
registro só com `openrouter` (`lib/providers/provider_registry.dart`),
`SecretStore` + `generateSecretRef` UUIDv4 + `maskSecret`
(`lib/storage/secret_store.dart`), DPAPI via flutter_secure_storage v11
(`lib/storage/secure_secret_store.dart`), tabela `connections`
(`Migration001`: `secret_ref` + `auth_type` + `sort_order`, sem `secret_ref`
jamais com segredo), `RefreshService` (≤4 concorrentes, coalescência, timer
1/3/5/10/manual), gate test-before-save
(`lib/ui/settings/connections_screen.dart`), mapeamento de erro OpenRouter
(`lib/providers/openrouter/openrouter_response.dart`).

## 1. O que os dois concordam (fazer primeiro)

1. **Validar-antes-de-salvar com probe barato por tipo de credencial.**
   oh-my-pi: `validateOpenAICompatibleApiKey` / `validateAnthropicCompatibleApiKey` /
   `validateApiKeyAgainstModelsEndpoint` (`packages/ai/src/registry/api-key-validation.ts`,
   `VALIDATION_TIMEOUT_MS=15000`, flag `tolerateModelDenied`).
   9router: `POST /api/providers/validate` — API key via `GET /models`
   (fallback chat `max_tokens:1`, válido = status != 401/403), OAuth via probe
   dedicada com tentativa de refresh antes de declarar inválido; import_token só
   checa formato (`src/app/api/providers/validate/route.js`,
   `src/app/api/providers/[id]/test/testUtils.js:testSingleConnection`).
   TokenDock já tem o gate (`connections_screen.dart` + `ProviderAdapter.test()`);
   o que falta é **padronizar o probe por tipo de auth** e persistir
   `testStatus/latencyMs/lastError`. Esforço S. Risco baixo (probes mínimos;
   cuidado para não queimar quota — preferir `GET /models`-like ao invés de
   chamada com custo).
2. **Conta esgotada ≠ conta morta: cooldown + volta sozinha.**
   9router: `rateLimitedUntil` + cooldown exponencial 2s→5min (cap 30min) +
   model locks (`modelLock_<model>`) + soft-success (ex.: 402 spending-limit
   mantém active com warning); reset no primeiro sucesso ou reativação manual
   (`open-sse/services/accountFallback.js`, `open-sse/config/errorConfig.js:
   ERROR_RULES/BACKOFF_CONFIG`).
   oh-my-pi: tabela reason→backoff — `QUOTA_EXHAUSTED=30min` (rotaciona),
   `RATE_LIMIT_EXCEEDED=30s` (mesma credencial), `CONCURRENT_LIMIT=5s`,
   `MODEL_CAPACITY=45s+jitter`, `SERVER_ERROR=20s`; `markUsageLimitReached`
   retorna `{switched, retryAtMs, blockedUntilMs}` para a UI decidir esperar vs
   trocar (`packages/ai/src/error/rate-limit.ts`, `auth-storage.ts`).
   Alvo: `lib/services/refresh_service.dart` (backoff por reason + cooldown por
   conta) + `lib/app/app_state.dart` (status ok/cooldown/quota com `retryAt`).
   Esforço M. Risco médio: distinguir **quota** (troca de conta) de
   **throttle** (mesma conta, backoff) — errar queima conta saudável.
3. **Higiene de segredos: o TokenDock já faz melhor que o 9router — manter.**
   9router guarda segredos em **plaintext na coluna `data` do SQLite**
   (`src/lib/db/schema.js:TABLES.providerConnections`) — GAP explícito.
   TokenDock guarda só `secret_ref` + DPAPI: não regredir.
   Adotar dos dois: listagens nunca retornam segredo (9router `safeConnections`
   stripa `apiKey/accessToken/refreshToken/idToken` em `GET /api/providers`);
   redação de logs por substring (`key|token|secret|auth|credential|cookie` →
   `[redacted]`, query string stripada); nunca dumpar request em 401/403/429/5xx
   (oh-my-pi `http-inspector.ts:redactHeaders`, `shouldDumpRejectedRequest` só
   400/413); fingerprint SHA-256 do bearer para atribuição em vez dos bytes
   (oh-my-pi `fingerprintOAuthBearer`, 9router `maskApiKey` 8 chars + `***`).
   Alvo: camada de log em `lib/services/refresh_service.dart` + `lib/providers/*`.
   Esforço S. Auditar `print`/`debugPrint` atuais.
4. **Refresh OAuth em 3 momentos + single-flight por conexão** (desenhar agora,
   plugar quando Antigravity chegar).
   9router `oauthCredentialManager.js`: proativo (`expiresAt-now < refreshLeadMs`
   por provider), reativo (401 → refresh → 1 retry) e no teste; merge preserva
   `refreshToken`/`idToken` ausentes no response; lock por `provider:connectionId`;
   `refreshable:false` (Qoder 403 no refresh, Cursor sem endpoint) → exigir
   re-login (`open-sse/services/tokenRefresh.js:REFRESH_HANDLERS`,
   `withCredentialRefreshLock`).
   oh-my-pi: skew 60s local (`OAUTH_REFRESH_SKEW_MS`), broker varre a cada 60s
   com skew 5min; `invalid_grant`/bare-401 → soft-disable com tombstone
   (causa+identidade, sem token) + evento `CredentialDisabledEvent` → banner
   re-login; writes via CAS para não clobberar rotação de peer.
   Alvo: `lib/services/refresh_service.dart` (coalescência já existe — acoplar
   lock por conexão + refresh proativo) + `SecureSecretStore` (update atômico
   do par rotativo; rotação single-use estilo Codex exige merge em transação).
   Esforço M.

## 2. Modelo de dados (Migration002)

- **Declarar `AuthKind` por provider no registro**: `api-key | oauth |
  structured-bearer | keyless/none`, com `getApiKey()` que monta o bearer na
  hora em vez de guardar string pronta; OAuth expirado → recusar uso e exigir
  refresh (nunca POSTar sentinel). oh-my-pi:
  `auth-storage.ts:ApiKeyCredential|OAuthCredential|getOAuthApiKey`,
  `registry/types.ts:ProviderDefinition`. Alvo:
  `lib/providers/provider_adapter.dart` (enum `AuthKind` + `buildAuthHeader`) +
  `lib/providers/provider_registry.dart` (openrouter=api-key, minimax=api-key,
  antigravity=oauth-multi). Esforço M, risco baixo.
- **Colunas de saúde por conexão**: `priority/is_active/test_status/last_error/
  rate_limited_until` + `providerSpecificData` JSON + `identity_key` estável
  (email|account|project|org) para dedup e seleção. 9router:
  `connectionsRepo.js:createProviderConnection` (dedup: oauth por
  email+username/chatgptAccountId, apikey por name, access_token **nunca**
  dedup — Codex com mesmo email mas `chatgptAccountId` distinto = contas
  distintas, senão refresh tokens rotativos single-use colapsam).
  oh-my-pi: `resolveCredentialIdentityKey`, `auth_credential_blocks` com merge
  MAX, seleção session-sticky (hash xxHash32, 30d) ou round-robin sem session.
  Maior ganho: Antigravity multi-account. Esforço M (Migration002).

## 3. Retry/erro (quando houver 2ª conta do mesmo provider)

- Classificador central `isAuthRetryableError` + retry a/b/c limitado:
  inicial → refresh-same (1x) → rotate-sibling (1x); 403/usage-limit pula
  refresh e rota direto; 429 transitório fica no backoff sem queimar sibling;
  cap de tentativas (oh-my-pi `AUTH_RETRY_MAX_ATTEMPTS=64`;
  `packages/ai/src/error/auth-classify.ts`, `auth-retry.ts:withAuth`).
- Base de erro tipada: `ProviderHttpError{status,headers,code}` +
  `OAuthError` (12 kinds: timeout/polling=transitório, resto=falha de auth) +
  envelopes OpenAI/Anthropic parseados com timeout (`auth-classify.ts`,
  `rate-limit.ts:parseRateLimitReason`, incluindo ramos CN e Google ErrorInfo).
  Para o TokenDock: portar só o esqueleto + mensagens reais de
  OpenRouter/MiniMax; heurísticas regex de mensagem são frágeis.
- Reescritas por provider na UI: Copilot 401=re-login vs 403=plano/policy (não
  remove credencial); ClinePass 400=subscrição/org/modelo. Padrão: mapear
  status→ação+copy em `openrouter_response.dart:mapHttpStatus` e futuros
  `*_response.dart`, nunca apagar cache no erro (PRD §55).

## 4. Fluxos OAuth (referência futura, Antigravity)

oh-my-pi define contrato `OAuthController {onAuth, onPrompt, onManualCodeInput?,
onBrowserSession, signal, fetch}` com 5 fluxos:
loopback callback server (porta preferida + fallback aleatória, `/callback` +
`/launch` 302, dual-bind IPv4+IPv6, timeout 300s), device-code RFC8628
(`slow_down`, deadline `expires_in`), paste-code, browser-session cookie
handoff, provisioning/entitlement pós-troca (Antigravity `loadCodeAssist` +
`onboardUser` polling 30s/1s).
9router detalha por provider: Antigravity = auth-code Google (client público
embutido) + userinfo + `loadCodeAssist`/`onboardUser` guardando
`projectId`/`tierId` (`open-sse/providers/antigravity.js`); Kiro = 4 métodos
(device-code SSO OIDC, social google/github, import token `aorAAAAAG...`,
Cursor `state.vscdb`); Cursor = import_token sem refresh público.
Nota Flutter/Windows: loopback server e device-code são os fluxos viáveis no
desktop; `POST` de validação OpenAI-compatível com `max_tokens:1` serve de
probe barato.

## 5. Testes sem chaves reais (adotar já)

oh-my-pi (`bun:test`): `fetch`/`signal`/`now` injetáveis,
`CompletionProbe` injetável no `checkCredentials`, timeouts via
`AbortSignal.timeout(15s)`, erros construídos via `ProviderHttpError`/
`OAuthError` com status em vez de HTTP, fixtures como objetos literais
(`auth-retry.test.ts`, `auth-broker-snapshot-cache.test.ts`).
9router: sem suite (dirs `test/` gitignored) — estratégia é test-before-save +
test sob demanda (`POST /validate`, `POST /[id]/test`, `POST /test-batch` com
summary passed/failed por grupo).
TokenDock já segue essa linha (fixtures sanitizadas em
`tokendock/test/fixtures/`, providers fake em `test/support/`); manter e
adicionar `test-batch`-like quando houver N contas do mesmo provider.

## 6. O que NÃO copiar

- Segredos em plaintext no SQLite (9router) — TokenDock/DPAPI é superior.
- Client secrets OAuth públicos no repo (9router `shared.js`) — ok para clientes
  públicos Google, mas documentar como tal.
- `exportDb`/`importDb` carregando segredos juntos em JSON — se o TokenDock
  fizer bulk import, importar só metadados e pedir o segredo por conta
  (test individual → N `secret_ref`).
- Bulk-add OAuth "mass-add" (gsuite2router): é repetir authorize+exchange por
  conta Google, sem código dedicado — para Antigravity multi-account repetir o
  fluxo por conta, 1 refreshToken+projectId cada.
- Pool de N API keys com rotação em runtime (nós openai-compatible do 9router)
  — fora do escopo: TokenDock é 1 credencial por conexão, fallback é trocar de
  conexão, não de key dentro da conexão.

## 7. Ordem de adaptação sugerida

1. S — Redação de logs + strip de segredos (auditoria, sem migração).
2. S — Probe por `AuthKind` + persistir `testStatus/latencyMs/lastError`.
3. M — Cooldown/backoff por reason (`rateLimitedUntil`) sem apagar cache.
4. M — `AuthKind` no registro + `Migration002` (saúde + `identity_key`).
5. M — Single-flight por conexão + refresh proativo/reativo (interface
   `Refreshable` agora, OAuth depois).
6. M — Retry refresh-same → switch-sibling quando existir 2ª conta do provider.
7. OAuth Antigravity (device-code ou loopback) só após 1–6 estáveis.

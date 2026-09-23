# Plano: hardening de auth, segredos e quota — TokenDock

Data: 2026-09-23. Correlaciona três fontes: (1) estado atual do TokenDock
(`PRODUCT.md`, código em `tokendock/`); (2) relatório prévio
`docs/auth-research-oh-my-pi-9router.md` (oh-my-pi + 9router); (3) tendências
2025–2026 pesquisadas hoje (OAuth desktop, segredos no Windows, rate-limit —
scouts `OAuthTrends`, `WinSecrets`, `RateLimit`, fontes primárias datadas no
final).

Restrições inegociáveis (de `PRODUCT.md`): um processo local, um SQLite, sem
servidor/cloud; contratos de provider saídos de documentação oficial, nunca
adivinhados; cache-first (falha nunca apaga valor); SQLite só com `secret_ref`.

## 1. Onde estamos (base)

- Login adaptation and final-review recovery are implemented in the current worktree: `AuthKind` distinguishes `apiKey`, `oauth`, `structuredBearer`, and `none`; the registry exposes `openrouter` and `antigravity`; `Migration001` creates `auth_type`; `Migration003` adds `identity_key` and `provider_data` and sets SQLite `user_version = 3`.
- OpenRouter hardening remains implemented: 401/402/403/429/503 classification, `Retry-After` seconds/HTTP-date for 429/503, per-connection cooldown/health persistence, cache preservation, and named credential-field redaction.
- Antigravity Appendix A is backend/test-only, explicit opt-in local read-only quota. `AntigravityProvider` dispatches only `language-server` and `agy-cli` to `AntigravityLocalReader`; absent/`remote` source remains remote OAuth. CSRF is supplied only through in-memory runtime configuration and stripped from SQLite `provider_data`. The Connections UI is not wired to select local mode.
- Antigravity Appendix B is backend/test-only per-account remote OAuth: external loopback + PKCE, form-encoded Google token requests, least scopes, typed failure causes, selected-account guard, quota retrieval, onboarding prompt, per-connection test-time locking, rotated-token reuse revocation, bounded Full Jitter retries, and durable schema quarantine preserving cache. The Connections UI is not wired to launch login; definitive credential failures do surface a Reconnect action while cached quotas remain available.
- Refreshable credentials use per-connection single-flight coordination and rotate/delete the current credential reference. Invalid-grant/reuse deletes the local pair best effort and forces interactive re-login while preserving quota cache.
- Current evidence: the recorded focused command passes 98 tests; full `flutter test --no-pub` passes 197 tests. `flutter analyze` reports 0 errors and 0 warnings with 7 pre-existing informational diagnostics and exits nonzero. No real Google integration, external browser launch, or Antigravity process was exercised; fixtures are sanitized. Windows integration remains blocked by symlink support/Developer Mode.
- MiniMax remains blocked because its official FAQ does not publish a response schema. OpenCode Go remains deferred because no verified public subscription-quota API exists. The three-provider product target is still unmet because only OpenRouter and Antigravity are registered.

## 2. O que 2026 confirma, corrige ou acrescenta ao relatório prévio

**Confirma (fazer como planejado):** probe barato por tipo de credencial antes de
salvar; conta esgotada com cooldown e volta sozinha; segredo fora do SQLite
(TokenDock/DPAPI já é superior ao 9router-plaintext — não regredir); redação de
logs; refresh OAuth em 3 momentos + single-flight; `AuthKind` por provider;
`Migration002` com saúde por conexão.

**Corrige (muda o plano prévio):**

1. Device-code vs loopback: o relatório dizia "ambos viáveis". 2026 diz
   **loopback + browser externo é o padrão** (RFC 8252 reafirmado; Google
   Policies 2026-08-05 proíbem embedded UA com `disallowed_useragent`);
   device-code (RFC 8628) só como fallback se o provider exigir segundo
   dispositivo. Nada de webview/WebView2, nada de OOB copy-paste (removido pelo
   Google em 2022), nada de implicit/password grants (removidos no OAuth 2.1).
2. DPoP (RFC 9449): opt-in por AS — Google suporta opcional no `/token`,
   GitHub nem documenta. **Adiar**: desenhar `SecureSecretStore` para par de
   chaves futuro, não implementar agora.
3. Backoff: trocar a tabela fixa herdada (2s→5min) pelo consenso 2025–2026 —
   **Full Jitter** (`sleep=random(0, min(cap, base*2^n))`, base ~1s, ×2,
   cap 30–60s) + **honrar `Retry-After` como piso mínimo** (nunca subtrair
   jitter). Quota esgotada = cooldown longo / esperar reset, não loop de retry.
4. Headers `RateLimit`/`RateLimit-Policy`: ainda Internet-Draft em 2026
   (draft-ietf-httpapi-ratelimit-headers-11, expira 24/11/2026), **nem
   OpenRouter nem MiniMax os usam**. Parsear defensivamente como hint, nunca
   depender no caminho feliz.
5. Credential Locker/PasswordVault como alternativa: descartado — o backend
   Windows do FSS grava arquivos DPAPI desde 2.0.0 (não usa Locker), e Locker
   tem isolamento fraco entre apps desktop do mesmo usuário. Ficar no DPAPI
   user-scope.
6. SQLCipher: só se um dia quiser cifrar o DB inteiro; exige passphrase
   guardada em DPAPI + tempstore em memória. **Adiar** — `secret_ref` + DPAPI
   cobre a v0.1.
7. Windows Hello: só como **gate/desbloqueio** (consentimento antes de
   revelar/usar), nunca como cofre — chaves morrem com reset de PIN/dispositivo.
8. DPAPI com prompt interativo (`CRYPTPROTECT_PROMPTSTRUCT`): deprecated,
   remoção em fev/2027 — operações novas sempre não-interativas (FSS já é).

**Acrescenta (detalhe oficial novo, acionável já):**

- OpenRouter hoje (docs oficiais, acesso 2026-09-22): separa **crédito (402)**
  vs **taxa (429)**. `GET /api/v1/key` expõe `limit/limit_remaining/limit_reset`
  + `free_model_daily_requests`. 402 com `limit_source=openrouter_in_flight_budget`
  **e** `Retry-After` = transitório (esperar + retry); 402 sem header = ação
  humana (recarga, subir key limit). 429 de plataforma traz
  `X-RateLimit-Limit/Remaining/Reset` + `Retry-After`; 429 upstream traz
  `provider_code` + fallback automático; 429 mid-stream chega como SSE
  `finish_reason:error` (status já 200). **Sucesso nunca traz `X-RateLimit-*`.**
  Doc manda retry com exponential backoff honrando `Retry-After`.
- MiniMax hoje (docs oficiais): limites RPM+TPM por modelo e tipo de conta, compartilhados master+sub; erros são códigos numéricos no body (1002 frequência, 2045 rajada, 1041 conexões, 1039 tokens, 1008 saldo, 2056 Token Plan); sem `Retry-After` documentado. Token Plan usa janelas rolling de 5h + semanal e o endpoint oficial `GET /v1/token_plan/remains`; a FAQ não publica o schema JSON da resposta.
- Escopo da pausa: **só a conta/chave afetada, nunca global** (Azure
  per-principal, Graph por client-app, OpenRouter `limit_source`).
- Semântica: 429 = transitório (retry + backoff); 402 sem `Retry-After` e
  403 (guardrail/moderation) = **nunca retry automático**; 429 **nunca**
  cachear (`MUST NOT be stored by a cache`, RFC 6585).
- Polling eficiente: monitoração proativa (`GET /api/v1/key`,
  `/v1/token_plan/remains`) em vez de inferir quota de falhas; intervalos
  adaptativos (alongar sob 429, encurtar gradualmente em sucesso); conditional
  requests (ETag/304) quando o provider oferecer.

## 3. Fases

Definição de pronto por fase (PRD §87): implementação + loading/error states +
persistência quando aplicável + teste + UI final.

### Fase 0 — Higiene de segredos e decisão documentada (S)

- Novo helper de redação (ex. em `lib/storage/secret_store.dart` ou
  `lib/services/log_redaction.dart`): strip de `Authorization`/Bearer e query
  string, regra por substring `key|token|secret|auth|credential|cookie` →
  `[redacted]`; auditar `print`/`debugPrint` em `lib/services/` e
  `lib/providers/`; regra: nunca dumpar body em 401/403/429/5xx (só 400/413,
  sem segredo).
- Documentar no README/Security: DPAPI **user-scope** (`CryptProtectData`,
  mesmo usuário+máquina, exceção só roaming em domínio); export futuro = só via
  re-cifragem opt-in explícita, nunca cópia de blob.
- Aceite: teste unitário de redação (header, URL, body); nenhum log com segredo;
  `flutter test`, `flutter analyze`.

### Fase 1 — Taxonomia de erro + `Retry-After` no OpenRouter (S/M)

- Estender `openrouter_response.dart:mapHttpStatus`/`mapError`:
  - 429 → `rate_limit` transitório; distinguir `error.metadata.error_type`
    (`rate_limit_exceeded`) de `provider_code` upstream; parsear `Retry-After`
    (segundos; http-date como fallback) como espera mínima; nota: mid-stream
    429 como SSE `finish_reason:error` (sem ação nova — só não quebrar o parse).
  - 402 → bifurcar: com `limit_source=openrouter_in_flight_budget` **e**
    `Retry-After` = transitório; sem header = `quota_action_needed`
    (recarga/limite da key, copy pede ação do usuário, sem retry).
  - 403 → `forbidden` (guardrail/permissão), sem retry.
  - 503 → transitório com backoff.
  - 429/402/403 nunca alimentam o cache como valor (preservar último valor,
    PRD §55).
- Helper compartilhado de backoff Full Jitter (base 1s, ×2, cap 30–60s,
  `Random.secure`) em `lib/services/` para reuso das fases 2+.
- Aceite: fixtures novas (`openrouter_429_retry_after.json`,
  `openrouter_402_inflight.json`, `openrouter_402_credits.json`,
  `openrouter_403.json`); testes de mapeamento + parse de `Retry-After`;
  suite verde.

### Fase 2 — Cooldown por conta + polling adaptativo (M)

- `Migration002` (`user_version = 2`): colunas em `connections` (ou tabela
  `connection_health` 1:1 — preferir colunas, menos join):
  `rate_limited_until` (epoch ms, NULL = livre), `last_error` (copy
  user-safe), `test_status` (`active|error`), `latency_ms`, `identity_key`
  (reservada p/ fase 5; pode nascer NULL).
- `RefreshService`: mapa conta→`notBefore`; refresh pula conta em cooldown
  (registra `skipped`, não erro); reset do cooldown no primeiro sucesso ou
  reativação manual; cooldown sobrevive a restart (lido do DB no `load`).
- Polling adaptativo: alongar intervalo efetivo após 429/transitório, recuperar
  gradualmente em sucessos; manter timer único e opções 1/3/5/10/manual.
- `AppState` + widget: estado por conexão `ok|cooldown|quota_action_needed|error`
  com `retryAt` ("aguardar ~N min" / "recarregar créditos"); nunca só cor.
- Aceite: testes de cooldown (pula, expira, reseta no sucesso, restaura após
  restart); UI mostra cooldown sem apagar cache; notificações futuras (§58)
  consomem esse estado.

### Fase 3 — `AuthKind` + probes por tipo + MiniMax (S/M)

- `provider_adapter.dart`: `enum AuthKind { apiKey }` (+ `oauth`,
  `structuredBearer` reservados, sem uso); cada adapter declara `authKind` e
  `buildAuthHeader(secret)` (monta `Bearer` na hora, nunca guarda pronta).
- `provider_registry.dart`: declarar auth por provider
  (`openrouter=apiKey`, `minimax=apiKey` quando existir).
- Persistir `test_status/latency_ms/last_error` no gate test-before-save
  existente (`connections_screen.dart`); gate continua bloqueando save inválido.
- MiniMax (provider novo, contrato **só** da doc oficial): mapear códigos do
  body — 1002/2045 → `rate_limit` (cooldown fixo ~60s, sem `Retry-After`);
  1041/1039 → transitório curto; 1008/2056 → `quota_action_needed` com copy
  "aguardar reset de janela" (5h/semanal); monitorar via
  `GET /v1/token_plan/remains`. Implementação do adapter MiniMax é item PRD
  próprio; aqui fica o contrato de auth/erro + fixtures.
- Aceite: matriz de probe por `AuthKind` com HTTP fake; fixtures MiniMax
  sanitizadas; save continua exigindo `test()==ok`.

### Fase 4 — Single-flight total + interface `Refreshable` (M)

- A coalescência por conexão do `RefreshService` passa a cobrir também refresh
  proativo futuro: lock por `connectionId` (um refresh/token-op por vez).
- Nova interface `RefreshableCredential` (`expiresAt`, `refreshLead`,
  `refresh()`), **sem implementação OAuth ainda** — API keys a ignoram; serve
  para Antigravity plugar sem remodelar (teste do relatório §85: "sem mudança
  arquitetural").
- `SecretStore`: operação de troca atômica do par rotativo (write-novo +
  delete-antigo em ordem segura; documentar invariante para rotação single-use
  futura). Sem mudança de comportamento para API keys.
- Desenho tombstone/soft-disable: `disabled_cause` (só causa+identidade, sem
  token) + evento `credential-disabled` → banner "Reconectar" na
  `connections_screen` (UI pode nascer só na fase 6; deixar o hook).
- Aceite: testes de lock (2 refreshes concorrentes = 1 chamada), de troca
  atômica e do evento; nada muda para API keys.

### Fase 5 — Retry entre contas irmãs (M, só quando houver 2ª conta do provider)

- Classificador `isAuthRetryable` (esqueleto + mensagens reais OpenRouter/
  MiniMax, sem regex frágil): quota → trocar de conta irmã; throttle/429 →
  mesma conta em backoff; 403 guardrail e 402-sem-`Retry-After` → sem retry;
  cap de tentativas; reset no sucesso.
- `identity_key` (fase 2) passa a valer: API key dedup por nome/identificador
  estável (nunca hash do segredo em disco; fingerprint só em memória se preciso);
  regra Codex-like para OAuth futuro: access_token colado nunca dedup.
- `test-batch`-like: testar todas as contas de um provider com summary
  passed/failed (base para segunda meta funcional do PRD §85).
- Aceite: testes com 2 contas fake (quota numa → usa a outra; throttle →
  espera na mesma); sem queima de conta saudável.

### Fase 6 — OAuth Antigravity por último (L)

Só após fases 0–5 estáveis. Pré-requisito: confirmar fluxo na doc oficial do
provider antes de codar (restrição `PRODUCT.md`).

- Fluxo: authorization-code + PKCE S256 em **browser externo do SO** com
  redirect **loopback** (`127.0.0.1`/`[::1]`, porta aleatória,
  `SO_EXCLUSIVEADDRUSE`-like) — RFC 8252 §7.3; device-code só se o provider
  exigir segundo dispositivo.
- Public client: **sem `client_secret` no app**; `code_verifier` 43–128 chars
  (32 octetos aleatórios) + `code_challenge` S256 por tentativa; `state` por
  sessão; `redirect_uri` exact-match; rejeitar `code_verifier` sem challenge
  (anti-downgrade OAuth 2.1); auth codes ~1–10 min; `expires_in` como dica, não
  garantia; refresh com rotation + reuse detection (cadeia revogada ao ver
  token já girado); DPoP só se o AS suportar.
- Tokens (access+refresh) em `SecureSecretStore`/DPAPI user-scope; provisioning
  pós-troca (estilo `loadCodeAssist`/`onboardUser`, a confirmar na doc) guardando
  `projectId`/`tier` como metadados (não segredo).
- Falha definitiva (`invalid_grant`/bare-401) → tombstone + banner re-login;
  transitória → backoff das fases 1–2; `refreshable:false` → exigir re-login.
- Aceite: login loopback end-to-end, refresh proativo/reativo/ no teste,
  multi-account (1 refreshToken+projectId por conta), suite sem chave real.

## 4. O que NÃO fazer (com fonte)

- Webview/WebView2/iframe para login — RFC 8252 §8.12 + Google Policies 2026
  (`disallowed_useragent`).
- Implicit flow, password grant, OOB copy-paste — BCP RFC 9700 + OAuth 2.1
  draft-13; OOB removido pelo Google desde 2022.
- `client_secret` embutido — RFC 8252 §8.5 (public client).
- Retry cego em 402-sem-`Retry-After`/403; retry storm sem jitter; pausar todas
  as contas num 429 de uma (Azure Throttling 2026-05-29, OpenRouter
  `limit_source`).
- Depender de `RateLimit-*` no caminho feliz (draft, ninguém relevante usa);
  cachear 429 (RFC 6585 proíbe).
- Plaintext no SQLite; DPAPI machine-scope para segredo de usuário (Learn
  2026-07-22: só servidor sem usuários não-confiáveis); export de blob DPAPI
  cru (não abre em outro PC); Hello como cofre (reset de PIN = perda total);
  SQLCipher agora (custo sem benefício na v0.1).
- Pool de N keys com rotação em runtime dentro da conexão — fora do modelo
  (1 credencial por conexão; fallback troca de conexão).

## 5. Verificação global

Por fase: `flutter test` + `flutter analyze` (0 errors) + fixtures novas sem
chave real; fases 2/3/5: `integration_test` estendido (cooldown, 2 contas);
fase 6: `flutter build windows --release` + login real manual uma vez.
Critério final: segunda meta do PRD (§85: 7 conexões/3 providers/1 widget) sem
mudança arquitetural — se exigir remodelar, a fase 4 falhou.

## 6. Fontes (2026)

- OAuth: RFC 9700 (BCP 240, 2025-01-01, https://www.rfc-editor.org/rfc/rfc9700);
  draft-ietf-oauth-v2-1-13 (2025-05-28,
  https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1-13); RFC 8252
  (BCP 212, https://www.rfc-editor.org/rfc/rfc8252); Google OAuth Policies
  (mod. 2026-08-05,
  https://developers.google.com/identity/protocols/oauth2/policies) + Native-app
  docs; MS Entra auth-code flow (2026-01-09,
  https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow);
  RFC 9449 DPoP (https://www.rfc-editor.org/rfc/rfc9449); RFC 8628 device grant
  (https://www.rfc-editor.org/rfc/rfc8628); GitHub Authorizing OAuth Apps
  (https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps).
- Segredos: FSS CHANGELOG develop (v11.2.0 2026-09-16,
  https://raw.githubusercontent.com/mogol/flutter_secure_storage/develop/flutter_secure_storage/CHANGELOG.md);
  FSS-windows CHANGELOG (4.2.2); Learn `CryptProtectData` (upd 2026-05-15),
  `ProtectedData` (.NET, 2026-07-22), CNG DPAPI-NG, `PasswordVault`,
  Windows Hello + `KeyCredentialManager` (upd 2026-03-30), `Handling Passwords`
  (2026-07-16), Packaging overview (2026-08-29); SQLCipher Design
  (https://www.zetetic.net/sqlcipher/design/).
- Rate-limit: draft-ietf-httpapi-ratelimit-headers-11 (2026-05-23,
  https://datatracker.ietf.org/doc/draft-ietf-httpapi-ratelimit-headers/);
  RFC 6585 §4 + RFC 9110/9111; AWS Exponential Backoff and Jitter
  (https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/);
  Azure Throttling Pattern (2026-05-29,
  https://learn.microsoft.com/en-us/azure/architecture/patterns/throttling);
  MS Graph throttling (2025-01-14); OpenRouter Limits + Errors
  (https://openrouter.ai/docs/api-reference/limits,
  https://openrouter.ai/docs/api-reference/errors-and-debugging); MiniMax
  rate-limits + errorcode + token-plan
  (https://platform.minimaxi.com/docs/guides/rate-limits).
- MiniMax Token Plan FAQ (`GET /v1/token_plan/remains`, quotas e janelas; schema de resposta ausente): https://platform.minimax.io/docs/token-plan/faq.
- Antigravity CLI Model Quotas (`/usage` e `/quota`, painel TUI): https://antigravity.google/docs/cli/commands/usage/.
- Google OAuth desktop/native-app protocol (fluxo OAuth genérico; não documenta recurso de quota Antigravity): https://developers.google.com/identity/protocols/oauth2/native-app.
- Repos: `can1357/oh-my-pi` (`AuthStorage`, `sqlite-credential-store`,
  `auth-classify`, `rate-limit`, `auth-retry`, `http-inspector`);
  `decolua/9router` (`providerConnections`, `accountFallback`, `errorConfig`,
  `oauthCredentialManager`, `tokenRefresh`, `usageRepo`, `testUtils`).

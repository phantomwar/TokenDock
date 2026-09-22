# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Stack

Flutter desktop application targeting Windows 10/11 x64. The first release does not enable web, mobile, macOS, or Linux targets.

## Users

People who maintain multiple paid AI subscriptions, local accounts, and API keys and need to identify the account with remaining quota without opening each provider dashboard.

## Product Purpose

TokenDock is a lightweight always-available desktop widget that shows the current quota, reset time, connection health, and cached state for several AI-provider accounts. Success is a trustworthy at-a-glance answer to: “Which of my subscriptions still has limit?”

## Positioning

A local, single-process Windows widget that aggregates independently authenticated AI accounts while keeping credentials outside its SQLite database.

## Operating Context

The app is opened from the Windows tray, then remains visible beside everyday work. Users add, test, refresh, edit, enable, or remove provider connections. The app starts from local cache and refreshes in the background, including when a provider is temporarily unavailable.

## Capabilities and Constraints

- Initial functional slice: up to three independent OpenRouter API-key connections; compact, normal, and expanded widget modes; tray behavior; SQLite cache; DPAPI-backed credential storage; manual and periodic refresh. OpenCode Go remains deferred because it has no verified public subscription-quota API.
- One local process, one local SQLite database, no server, cloud service, analytics, or plugin system.
- The UI must preserve prior cached values after a fetch failure and must never rely on color alone for status.
- Provider endpoints and response contracts must be established from official provider documentation before implementation; they are not guessed from product requirements.

## Brand Commitments

- The user-provided references in `docs/imagens/` are binding visual evidence: quiet, high-contrast operational interfaces; warm off-white surfaces; near-black anchors; rounded modules; sparse but intentional vivid green/lime emphasis; restrained semantic status color; clean sans-serif typography.
- The interface must stay desktop-native, readable at a glance, and calm enough to remain on-screen all day. It must not become a generic analytics dashboard or a neon/gamified AI interface.

## Evidence on Hand

- Product requirements: `PRD.txt`.
- Approved technical design: `docs/superpowers/specs/2026-09-22-tokendock-first-functional-goal-design.md`.
- Visual references: `docs/imagens/windows-tray-dashboard.png`, `docs/imagens/HS0mcVHagAAQYiG.jpg`, `docs/imagens/HS0mbP5agAEg0nP.png`, `docs/imagens/HSzxw_Sb0AARFwe.png`, and `docs/imagens/HSzxv9UaIAAOXbw.jpg`.
- No production screenshots, provider fixtures, user research, commercial claims, or final brand assets exist yet.

## Product Principles

1. Cache-first truth: a usable last-known value is more valuable than an empty card during a provider failure.
2. Independent accounts: a connection's credential, result, error, and cache never leak into another connection.
3. Glance before detail: lead with the quota that determines where the user can work next.
4. Local by default: credentials are references in SQLite and values in platform-backed secure storage.
5. Calm operational clarity: visual emphasis marks action or risk, not decoration.

## Accessibility & Inclusion

Meet WCAG 2.2 Level AA contrast for text and essential controls; expose a visible keyboard focus state and logical tab order; retain text and icon/symbol status labels alongside color; honor Windows text scaling, contrast themes, and reduced-motion preferences; keep all core flows keyboard-operable.

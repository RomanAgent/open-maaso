# open-maaso development guide

Read current code before changing it, preserve unrelated work, and keep changes scoped.
Start with README.md, docs/architecture.md and docs/open-source-scope.md.

- Keep service dependency registration in lib/main.dart in dependency order.
- Use existing Riverpod providers and appServices injection.
- Keep one AgentRuntime turn active; model output stays JSON reply/actions.
- Extend AvatarRuntime before renderer-specific behavior; TTS owns mouth motion.
- Keep recognition on VAD-ended segments and preserve TTS queue/barge-in semantics.
- Reuse the shared BLE transport and product facades.
- Authored web surfaces remain browser content; native authority requires existing gates.
- Keep account, privacy, permission and consequential-action confirmation boundaries.
- Register skills and navigable destinations in existing catalogs.
- Add boundary tests; dart format changed Dart files; run git diff --check.
- Run public-export and Gitleaks checks before publishing; never commit local credentials.
- Do not add proprietary characters, scenes, model weights, or Unity exports without verified redistribution rights.

The default entry is the original MaasoApp/router in lib/main.dart. Local
edition flags adapt its existing service graph; never replace the original
pages with a simplified app. Read docs/offline-edition.md and preserve page
layouts, navigation and interactions. The original Settings model panel is the
API-key entry. Keep credentials in account-scoped secure storage and retain
runtime cancellation, account mount and teardown fences. The free VRM has its
own license. Native compilation and device acceptance are separate gates.

# Contributing to open-maaso

Contributions that make the companion runtime easier to understand, configure and test are welcome. Start with the [release scope](docs/open-source-scope.md), [README](README.md) and [third-party notices](THIRD_PARTY_NOTICES.md). Confirm that a proposed change fits the client source release rather than assuming a production backend or bundled avatar is available.

## Make a focused change

1. Open an issue for a substantial feature or architecture change, describing the user behavior and intended acceptance checks.
2. Create a branch and read the current code path before editing. Preserve unrelated work.
3. Reuse existing Riverpod ownership, `appServices` injection and shared services. Add tests at the boundary being changed.
4. Explain the resulting behavior, verification and any remaining limitations in the pull request.

Keep a single runtime turn active at a time. The assistant output contract remains JSON: `{"reply":"...","actions":[...]}`. Model-visible actions must match their parser, executor and protocol tests. UI code should not choose cloud versus local answers or create a second BLE stack. Avatar work belongs behind `AvatarRuntime`; speech owns mouth movement.

Generated browser works may use ordinary HTML, CSS, JavaScript and external dependencies. Their source does not receive native account or device authority. Keep permission checks, consequential-action confirmation and account-lifecycle fencing in trusted application code.

## Validate the boundary you change

Run `flutter pub get` with a compatible Flutter SDK, format changed Dart files, then run relevant tests:

```sh
dart format path/to/changed.dart
flutter test test/agent_action_protocol_test.dart test/turn_policy_test.dart test/turn_policy_wiring_test.dart
git diff --check
```

Choose the focused suite for avatar, surface, voice, BLE or navigation work instead of assuming the example covers every change. Native platform, Unity and hardware changes require appropriate platform checks. Clearly report unavailable dependencies, baseline failures and tests you did not run. Do not claim an independent device launch from an installation receipt or a debugger-attached run.

## Protect credentials and asset provenance

Use example configuration and ignored local files. Never commit API keys, tokens, signing certificates, keystores, provisioning profiles, service-account JSON, real account data or production logs. Do not put provider secrets in a shipped client binary; build-time defines are not a secret vault. Review every staged file and run the repository's secret checks before pushing.

Do not post a live credential or private conversation in an issue. If a secret is exposed, revoke it first and notify the maintainer privately; deleting the visible line does not remove copies from history or logs. See [SECURITY.md](SECURITY.md) for the reporting policy.

Include the source, version or revision, hash and license for any new third-party asset or vendored code. Preserve upstream attribution. A model conversion or generated cover does not grant redistribution rights to the underlying character. Keep large weights, purchased models and build exports out of source control.

## License

By submitting original code intentionally for inclusion, you agree to contribute it under this project's MIT license. Identify third-party material explicitly and retain its original license and notices. Do not submit material you are not authorized to share.

# Security policy

Do not post credentials, private logs, personal conversations, or exploit details in public issues.
Use GitHub's private vulnerability reporting on this repository when available. If it is not enabled,
open an issue containing only a request for a private contact channel; do not include vulnerability details.
There is no guaranteed response SLA for this developer source release.

## Configuration and credentials

- Public client configuration belongs in `config/development.example.json`. Copy it to the ignored `config/local.json` before editing.
- Build-time Dart defines are readable from application binaries. Never put provider or server secrets in them.
- Firebase files, service-account credentials, signing keys/profiles, local environment files, device data, and build output must stay untracked.
- Enter optional direct-provider credentials through the existing secure-storage settings; never hardcode them.
- A suspected exposed credential must be revoked at its issuer. Removing it from a file or rewriting Git history is not revocation.

## Public export checks

Run `python3 tool/check_public_export.py`, its unit tests, and a current Gitleaks scan before publishing changes.
The scanner configuration preserves default rules and narrowly documents reviewed false positives.
A clean automated scan is supporting evidence, not proof that every possible secret has been detected.

Browser-authored content must not gain native account, BLE, storage, or action authority from model output.
Preserve runtime confirmation, account retirement, and sandbox boundaries when adding capabilities.

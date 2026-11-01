# Public source checks

The initial public export starts a new Git history. It excludes the original
Firebase project configurations, signing material, private environment files,
build products, internal marketing/verification receipts, and unreviewed model
assets. Bring your own service configuration and credentials.

## Run the checks

From this repository root, after staging intended new source files:

```sh
python3 -m unittest discover -s tool -p 'test_check_public_export.py'
python3 tool/check_public_export.py
gitleaks dir --redact --config .gitleaks.toml .
gitleaks git --redact --config .gitleaks.toml --log-opts=--all .
git diff --check
```

The lightweight checker reads Git-tracked working files, including staged new
files. It reports path, line and category without printing matched values.
Untracked files are deliberately outside that check; the directory scanner
checks them too. The history scanner is a separate release check. Run both
Gitleaks modes before publishing. Redact logs and keep scan reports outside
the public repository.

The checker rejects private configuration paths, signing inputs, personal
machine paths, common token formats, and unreviewed binary model assets. The
MIT-licensed Silero VAD is explicitly permitted only at its reviewed path and
SHA256; see the third-party notices. A clean scan is evidence from these checks,
not a guarantee that every possible secret format has been detected.
One fabricated token in `test/action_audit_log_test.dart` is excepted by its
exact path and complete source line in the lightweight checker. Changing the
value or putting it in another file triggers the check; regression tests cover
both cases. Gitleaks continues applying its own rules independently.
The privacy logger test also has exact-line exceptions for fabricated local
paths used to exercise log redaction; real machine paths elsewhere still fail.
The checker rejects an empty index to avoid reporting a scan with no source.

## Reviewed Gitleaks exceptions

Gitleaks 8.30.1's default rules reported 123 initial `generic-api-key` findings.
Every finding was inspected in source before adding these narrow exceptions:

| Count | Location | Why it is public data |
| ---: | --- | --- |
| 107 | Two `third_party/webview_flutter_*/UPSTREAM_SOURCE.json` files | SHA256 file provenance digests, in a strict JSON string-to-64-hex-digest format |
| 1 | `ios/Podfile.lock` | The exact reviewed `VolcApiEngine` CocoaPods checksum |
| 1 | `lib/src/core/services/local_llm_service.dart` | The exact public Qwen model option identifier |
| 10 | `test/avatar_selection_outbox_test.dart` | Exact deterministic compensation/idempotency test identifiers |
| 3 | `test/avatar_selection_coordinator_test.dart` | Exact deterministic compensation assertions and fixture |
| 1 | `test/maaso_tts_utterance_test.dart` | An exact fabricated marker testing that utterance text is never logged |

`.gitleaks.toml` extends the complete default rule set. Each exception applies
only to `generic-api-key` and requires **both** the named path and its reviewed
line/value pattern. Neither `lib/` nor `test/` is excluded. Provider-specific
rules remain active at these same locations. `.gitleaksignore` intentionally
contains no fingerprints: a line-only suppression could hide a later change
on that line. Any new finding needs source review rather than a broad baseline.

The initial exception review was also checked against Gitleaks itself: the
eight affected source files scan clean with this configuration. Adding
synthetic GitHub PAT and generic API-key canaries to the same excepted model
service file produces both expected findings. The public-export checker has
eight boundary tests, including exact fixture scope, untracked versus staged
inputs, altered model bytes, token detection, and nested-checkout rejection.

Configuration syntax follows the [Gitleaks 8.30.1 documentation](https://github.com/gitleaks/gitleaks/blob/v8.30.1/README.md#configuration).

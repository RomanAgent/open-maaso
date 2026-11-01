# Public source verification

Verified locally on 2026-11-01. This record describes the independent public client
snapshot, not a certification of the original commercial application or a hosted service.

## Checks completed

| Boundary | Result |
| --- | --- |
| Configuration, realtime configuration, action protocol, turn policy and navigation | 141 tests passed across nine focused Flutter test files |
| Custom test/production backend build defines | 5 tests passed |
| Static analysis of the changed environment service and its new tests | No issues |
| Public-export safety checker | 2,956 staged files checked; no findings |
| Safety-checker unit tests | 8 passed |
| Original placeholder assets | All 107 outputs passed deterministic regeneration and image/dimension checks |
| Bundled Silero VAD | Byte-for-byte match to official download; SHA-256 and MIT notice retained |
| Gitleaks 8.30.1 | Final staged source snapshot scanned with redacted reporting; no leaks found |
| False-positive exceptions | Exact rules/paths/content reviewed; injected synthetic PAT and API-key probes still detected |
| Patch whitespace | git diff --check and staged check passed; upstream notice/Unity metadata whitespace preserved by attributes |

Toolchain: Flutter 3.47.2 / Dart 3.13.2. The package lock was preserved from the source snapshot.

The focused Flutter command is recorded in `.github/workflows/source-checks.yml`.
Custom-origin verification used `MAASO_TEST_BASE_URL=https://test.example.com` and
`MAASO_PRODUCTION_BASE_URL=https://production.example.com` with the environment tests.
Scanner steps and narrowly scoped exceptions are documented in [security-scan.md](security-scan.md).

## Graph review

The initial import touches 49,906 indexed symbols and 591 execution flows. The
complete scope=all check reported critical breadth, as expected for an initial
client source import. Its listing hit the tool's fixed 1,000-symbol cap, so it was
not treated as an untruncated check. An additional 68 staged-file partitions
covered all 2,956 exact staged files, all 49,906 symbols and all 591 flows; every
partition returned partial=false and truncated=false. The real index, staged
blob IDs and working files were unchanged by this audit. This review establishes
coverage of the import, not native runtime acceptance.

## Scope not verified

No macOS app was launched. No native application build, iOS install/cold launch,
Unity player rebuild, BLE hardware session, live backend authentication, or cloud
provider operation was performed for this public snapshot. The full inherited test
suite was not run; some original source-contract tests expect internal documents,
artwork or Unity content deliberately excluded from this release.

GitHub Actions is supplied for future changes. Local results above do not imply
that a hosted workflow has already completed successfully. Backend deployment and
redistributable avatar/scene integration remain separate milestones.

Automated scanning is supporting evidence, not a guarantee that every possible
secret has been detected. The public repository starts from new history and does
not inherit the private project's commits, signing files, Firebase project files,
user data, or operational records.

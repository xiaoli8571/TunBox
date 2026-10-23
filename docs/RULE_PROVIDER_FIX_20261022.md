# Profile rule-provider merge fix (2026-10-22)

## Failure and cause

With ad blocking enabled and the local HyperAD asset present, the generated overlay
contains both the `hyper-adrules` provider and its `RULE-SET` reference. The profile
merger previously replaced all overlay providers with the subscription's providers
but retained overlay rules. A subscription without that provider therefore produced
`rule set [hyper-adrules] not found`, and the core could not start. Missing heartbeat
and unreachable API diagnostics were consequences of this configuration error.

## Change

- Merge overlay and profile rule-provider entries into one top-level mapping.
- Preserve overlay entries on name collisions, consistent with the generator's
  priority for app-owned HyperAD and custom `rs-*` providers.
- Deduplicate complete blocks and retain nested payload/header indentation.
- Preserve the existing file-readiness and enablement decisions. This fix adds no
  downloads, reconnect timers, or background polling.

## Validation

`scripts/verify-flclash-profile.mjs` regenerates its harness from current production
source on every run. The regression reproduced 11 failed assertions before the fix.
After the fix, 68 assertions pass, including 16 real runtime-builder combinations
(tunnel/test, profile/no profile, local file present/absent, ads enabled/disabled).
Only the platform DNS boundary is stubbed for those builder checks.

The initial 16 selected regression groups covering ad rules, routing, configuration,
foreground session adoption, keepalive, power refresh, and build-profile hygiene
passed. At that build a standalone mihomo CLI was unavailable, so the optional real
core `-t` check was explicitly skipped. Phone acceptance is still required.

The corrected test package keeps versionName `0.5.3` and increases versionCode to
`518` for replacement installation. Previous power and session fixes are retained.

## Follow-up: real core validation and required release gate

The downloaded official Windows-compatible mihomo v1.19.33 was subsequently
verified against the official archive digest and its extracted executable, then
used for real `-t` parsing. The test now submits all 23 valid merge/builder fixtures
to the executable. A 24th negative control deletes the provider declaration while
retaining its reference and must be rejected with the exact missing-rule-set error.
All 24 checks passed, in addition to the original 68 production-source assertions.

Use `MIHOMO_BIN` to select the standalone executable, then run:

```text
node scripts/verify-flclash-profile.mjs --require-mihomo
node scripts/verify-all.mjs --strict --only flclash-profile
```

The strict runner passes the required-core option through the test's child-process
restart. A missing executable must fail the release check; a deliberately absent
executable was tested and the strict runner returned exit code 1. An explicit but
invalid `MIHOMO_BIN` is also an error instead of silently using another candidate.

Each parser invocation uses an isolated temporary home and a bounded timeout.
Successful fixture directories are removed after verifying their absolute boundary;
unexpected failures retain their configuration evidence. `-t` starts no VPN or
listeners. Official Windows-core parsing does not replace acceptance against the
phone's customized core. These follow-up changes affect tests only, so the already
delivered 0.5.3/code518 HAP does not need rebuilding.

---
name: moviebox-reliability-engineering
description: Evidence-first workflow for MovieBox playback, torrent, cache, addon, and Android release changes.
---

# MovieBox Reliability Engineering

Use this workflow for any MovieBox bug or feature touching playback, torrent streaming, addon discovery, cache, persistence, or Android packaging.

## Before editing
- Read the relevant code path and its caller/callee chain; inspect current PR base and CI.
- Identify state ownership, async boundaries, disposal paths, platform-channel contracts, and persistence effects.
- State a concrete reproduction and expected behavior. If reproduction is unavailable, label the hypothesis and do not claim a confirmed root cause.

## Test-first
- Add the narrowest regression test first.
- Cover success, failure, timeout, cancellation, duplicate callback, stale state, and lifecycle transition where applicable.
- For native/codec/network behavior, separate deterministic unit tests from emulator/device integration evidence.

## Implementation rules
- Keep retries bounded and cancellable; use backoff where appropriate.
- Never leak tokens, signed URLs, headers, or personal data into logs or fixtures.
- Do not treat a magnet/torrent identifier as an HTTP media URL.
- Do not bypass DRM or provider access controls.
- Preserve user-visible failure diagnostics without exposing secrets.

## Verification and report
Run formatting, static analysis, unit/widget tests, then the relevant integration checks. Report exact commands, outcomes, and untested dimensions. Build success alone is not playback qualification.

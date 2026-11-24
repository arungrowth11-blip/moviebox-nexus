# ECC integration — MovieBox Nexus

## Integration model
This repository uses ECC as an optional engineering assistant layer, not as a runtime dependency of the Android application. The app does not import ECC packages and production playback does not depend on an AI service.

The repository-specific instructions and skill in `AGENTS.md` and `.agents/skills/moviebox-reliability-engineering/SKILL.md` remain useful as project guidance. If the operator installs the official ECC Codex plugin, its general TDD, verification, security-review, and code-review skills complement these project-specific constraints.

## Safe Codex setup
Use the official source only: https://github.com/affaan-m/ECC

For Codex CLI versions supporting the native plugin flow, follow the official ECC `.codex-plugin/README.md`:
```sh
codex plugin marketplace add affaan-m/ECC
codex plugin add ecc@ecc
codex plugin list --json
```
Install once per active CODEX_HOME. Do not combine the native plugin with the deprecated legacy sync flow. Restart Codex and inspect the plugin registration. Review hooks in `/hooks` and explicitly trust only the hooks you understand; plugin registration does not mean every hook is trusted. No additional MCP server or API key is required for this repository's project-local guidance.

## Mandatory release gates
- Reproduce and regression-test each defect.
- `flutter pub get`
- `dart format --set-exit-if-changed lib test`
- `flutter analyze`
- `flutter test`
- Release candidate: `flutter build apk --release`, APK signature verification, emulator integration, and physical-device playback/seek/background-resume/exit tests.
- No APK promotion, signing-key changes, publication, or deployment from an agent without explicit operator approval.

## Evidence and limitations
CI success proves only the checks actually run by CI. It does not establish provider uptime, DRM entitlement, codec compatibility, peer availability, or playback reliability on every Android device. Record exact tested commit, device/API level, source type, network conditions, and test result for device claims.

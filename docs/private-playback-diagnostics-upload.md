# Private playback diagnostics upload

MovieBox stores playback failure reports locally first. Reports remain in the app-private
`filesDir/playback-diagnostics` directory and are capped at five reports, seven days,
and 256 KiB per report. Only a sanitized JSON report is sent to GitHub; raw logcat,
provider URLs, info-hashes, credentials, and full device dumps are not uploaded.

## One-time GitHub setup

1. Create a dedicated **private** GitHub repository for handset diagnostics. Do not use
   the public MovieBox source repository as the destination.
2. Create a GitHub App for MovieBox diagnostics. Enable **Device Flow** in the app's
   optional features. Do not create or ship a client secret or private key for the APK.
3. Give the GitHub App repository permission **Contents: Read and write**. Install it
   only on the dedicated private diagnostics repository.
4. Add these two Actions repository variables to the MovieBox source repository under
   **Settings → Secrets and variables → Actions → Variables**:
   - `MOVIEBOX_GITHUB_APP_CLIENT_ID`: the GitHub App's public Client ID.
   - `MOVIEBOX_DIAGNOSTICS_REPOSITORY`: the private destination as `owner/repository`.

These two values are public configuration, not credentials. Do not create a Personal
Access Token (PAT), and do not put an access token, refresh token, client secret, or
private key in source code, build arguments, or the APK.

## First phone connection

On the phone, open a torrent playback failure panel and tap **Upload sanitized
diagnostics to GitHub**. MovieBox opens GitHub's device authorization page in the
browser and shows a one-time user code. Sign in to GitHub, enter that code, review and
approve the requested GitHub App access, then return to MovieBox and tap
**I authorized GitHub**.

GitHub returns short-lived user access and refresh tokens. MovieBox keeps these in
Android encrypted storage, refreshes the access token when needed, and never writes
tokens to diagnostic reports or logs. A newly captured failure report is automatically
uploaded after authorization; existing latest reports are uploaded on the next player
start. Uploaded report IDs are remembered locally to avoid duplicate writes.

## Scope and verification

The uploader checks that the destination repository is private before each write and
fails closed if it is public or inaccessible. Each report is size-limited, schema-checked,
and scanned again for URLs, hashes, credentials, IPv6 addresses, and Android private
storage paths before upload. GitHub App installation permissions restrict writes to the
selected private diagnostics repository.

GitHub Actions emulator diagnostics are a separate workflow artifact. Handset diagnostic
reports are not part of those artifacts. Physical phone and Android TV playback acceptance
(first frame, sustained playback, seek, exit/cleanup, and background/resume) remains a
separate release gate.

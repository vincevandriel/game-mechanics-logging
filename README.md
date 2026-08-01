# Adventure Bar Encounter Logger

Adventure Bar Encounter Logger is a single-purpose, offline-first SwiftUI iPhone app for manually recording the number of successful tile movements between random encounters in the Nintendo Switch version of *Adventure Bar Story*. Tap `+` once for each successful tile movement, then tap **Submit** when an encounter begins. A move into a wall and time spent standing still are not successful tile movements and should not be counted.

The app stores raw observations exactly as entered. It deliberately contains no statistics, charts, probability calculations, encounter-rate estimates, clustering, rounding, correction, or model fitting. Export the raw CSV or JSON and analyze it separately on a computer.

## Platform and toolchain

- Swift and SwiftUI, Apple system frameworks only
- iPhone deployment target: iOS 15.0
- Designed for iOS 15 through iOS 26
- Verified toolchain: stable Xcode 26.6 (build 17F113), Swift 6.2 compiler in Swift 5 language mode, iOS 26.5 SDK
- Bundle identifier: `com.vincent.adventurebarencounterlogger`
- No packages, pods, app extensions, unusual entitlements, accounts, or network dependency for logging

[Apple's Xcode 26 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes) document the Swift 6.2/iOS 26 SDK toolchain and deployment support for older OS versions.

You do not need to own a Mac to build this project. The included manual GitHub Actions workflow runs the Xcode build, XCTest suite, unsigned Release build, IPA packaging, and archive verification on a GitHub-hosted macOS runner. It then makes the verified IPA downloadable from a Windows browser. Windows still cannot compile an iOS `.app` locally because Apple does not provide Xcode or the iOS SDK for Windows; the cloud runner supplies that required compilation environment.

This repository was assembled on Windows and then compiled and tested by the included macOS cloud workflow. The verified release run completed 62 XCTest cases with zero failures, built the unsigned generic-device Release app with Xcode 26.6, packaged the IPA, and independently verified the required archive path. The workflow and packaging script fail closed; rerun them after any source change before treating a replacement IPA as verified.

## What is included

- A conventional SwiftUI app with Counter, Records, Export, and Settings tabs
- A versioned, atomic Codable JSON store with recovery from its previous valid backup
- Exactly-once first-run seed insertion and a separate new-data session
- Session management, raw record editing with audit history, deletion recovery, and robust undo
- RFC 4180 CSV and lossless JSON export/import
- Files document export and the iOS share sheet
- Optional local CSV/JSON snapshots after each submission
- Optional authenticated transfer to a standard-library Python receiver on a LAN or manually configured public port
- Deterministic XCTest coverage and Python companion-tool tests
- `build_ipa.sh`, which creates and validates an unsigned IPA for LiveContainer

### Project structure

```text
AdventureBarEncounterLogger/
  AdventureBarEncounterLogger.xcodeproj/   Xcode project and shared scheme
  AdventureBarEncounterLogger/             SwiftUI app entry point, views, assets, plist, privacy manifest
  Core/Models/                              Sessions, observations, audit, settings, counter, seed, validation
  Core/Services/                            Store, persistence, CSV/JSON, import, snapshots, PC transfer
  AdventureBarEncounterLoggerTests/         Deterministic XCTest target
.github/workflows/build-ios.yml              Windows-triggerable macOS/Xcode build, test, and artifact job
build_ipa.sh                                Release device build and IPA packager
tools/adventurebar_receiver.py              Optional standard-library PC receiver
tools/test_receiver.py                      Receiver unit/loopback tests
tools/safari_logger.py                      Optional temporary mobile Safari logger
tools/test_safari_logger.py                 Safari logger store/loopback tests
README.md                                   Build, transfer, restore, and usage guide
```

## First launch and the supplied data

On first database initialization, the app inserts these 40 values exactly once:

```text
68, 40, 34, 87, 33, 47, 12, 27, 201, 54, 22, 138, 41, 32, 32, 42, 33, 20, 187, 112, 12, 64, 56, 38, 48, 16, 172, 28, 16, 105, 71, 38, 18, 21, 47, 150, 24, 47, 38, 12
```

They belong to **Initial Manual Walking Sample** with:

- movement mode `Walking`
- game version `Nintendo Switch`
- uncertainty `±1`
- source `Manually counted before app creation`
- sequence numbers 1 through 40

Their integrity checks are 40 observations, a total raw step count of 2,283, first value 68, last value 12, all Walking, and contiguous sequence numbers 1–40. This total is only a deterministic seed-integrity assertion; it is not an in-app analytical feature.

The initializer also creates and selects **Adventure Bar Encounter Test 1** for new observations. A persistent seed/database-version marker prevents the supplied sample from being inserted on later launches or upgrades. New records are not added to the historical sample unless the user deliberately makes it active.

## Normal use

1. In **Counter**, leave the selector on **Walking** or choose **Running**.
2. Tap `+` once for every successful tile movement. Use `−` to correct a tap; the value never goes below zero.
3. Tap **Submit** when the encounter begins.
4. The observation is committed, the counter returns to zero, the Walking/Running selection stays in place, and counting can resume immediately on the same screen.

Every counter or mode change is persisted immediately. The unfinished count, selected mode, active session, and durable undo state survive tab changes, suspension, and relaunch. Haptics are lightweight and can be disabled. Sound is optional and off by default.

Submitting zero is treated as exceptional. When zero confirmation is enabled, **Submit** shows a warning and requires an explicit second choice before a zero observation is stored.

### Changing movement mode during an interval

Changing Walking/Running at zero changes the selector normally. Changing it while the count is nonzero asks whether to:

- cancel;
- reset the count and switch; or
- preserve the count and switch.

Preserving a partially counted interval marks the next submission `Mixed/Uncertain`; it is never silently labeled Walking or Running. The visible selector still determines the starting mode for the following interval.

### Undo

**Undo** removes the most recently submitted observation in the active session and restores its exact step count and movement mode to the live counter. If the counter is already nonzero, the confirmation offers:

- replace the unfinished count with the restored observation; or
- add the unfinished count to it.

For example, undoing a submitted 38 after four more steps can restore 42. Undo never merely deletes the record and leaves the counter at zero. The removed record is retained in durable pending-undo state so the operation can be reversed where the interface offers that action. Actions that would make the pending history ambiguous invalidate it. Undo is disabled when the active session has no eligible submitted observation.

## Sessions and records

The **Records** tab owns all lists and editing UI so the Counter stays uncluttered. It supports session creation, renaming, activation, archiving/restoring, confirmed deletion, and per-session export. Sessions may contain a game version, dungeon/location, map-area description, testing-condition notes, general notes, and timestamps.

Observation rows show encounter number, exact raw step count, movement mode, timestamp, and a questionable-data indicator. Records can be searched, filtered by mode, and sorted by encounter number, timestamp, count, or movement mode. Editing may change count, mode, uncertainty, note, or questionable status/reason. A count/mode edit appends an audit entry containing the previous and new values, timestamp, and optional reason, so the original raw value remains recoverable. Deletion requires confirmation, and the temporary deletion history can restore a record when still compatible.

Encounter sequence numbers are assigned within a session. Imports and edits preserve source identifiers and raw values instead of normalizing or renumbering them silently.

## Settings

The Settings tab includes:

- haptic feedback
- optional sound feedback (off by default)
- keep the display awake only while Counter is visible and the app is active
- default measurement uncertainty
- zero-value confirmation
- confirmation before Undo replaces a nonzero counter
- export snapshot creation after every submission
- last-used export format
- PC receiver address, port, shared secret, HTTP/HTTPS choice, automatic-transfer option, and connection test
- active session
- system, light, or dark appearance

Disabling screen-awake mode, leaving Counter, or backgrounding the app restores normal iOS idle-timer behavior.

## Local persistence and data-loss protection

The app uses a versioned Codable JSON document in `Library/Application Support/AdventureBarEncounterLogger/AdventureBarEncounterLoggerStore.json`. The previous valid primary is `AdventureBarEncounterLoggerStore.backup.json` in the same directory. The unfinished interval is additionally stored after every Plus, Minus, or mode change in the tiny atomic `AdventureBarCounterCheckpoint.json`; its previous compatible value is `AdventureBarCounterCheckpoint.backup.json`. During a normal launch, the checkpoint must match the exact full-store revision and active session it overlays, so a stale pre-Submit checkpoint cannot resurrect a count after the observation has been committed. If the primary full store itself is corrupt and the app explicitly recovers its previous valid full-store backup, a valid checkpoint from a non-older revision may restore the unfinished count only when its active session still exists and is not archived in that recovered backup. Before a replacement import, a timestamped `AdventureBar_PreImport_*.json` recovery copy is written inside the same protected Application Support directory. It intentionally retains the device-local receiver credential and is not exposed through Files; create a redacted complete-backup export separately for portable recovery. The full document includes sessions, observations and audit histories, unfinished counter state, selected/base and pending mixed mode, active session, pending undo/deletion state, settings, schema version, and seed-initialization version.

Full-state mutations are encoded and validated before replacement. Counter-only changes use the small checkpoint so rapid taps do not repeatedly encode the entire observation history. Both stores use atomic file replacement and retain compatible previous valid bytes as backups. At launch, the app validates the primary full store, attempts its backup if needed, and then overlays the newest compatible valid counter checkpoint. Import replacement also creates a safety backup before it changes the live store.

Do not treat the app container as the only copy of valuable data. Export regular complete JSON backups, especially before updating/removing LiveContainer, changing guest containers, or deleting the guest app. Removing a LiveContainer guest or its data container can make its internal files unavailable.

When **Create Export Snapshot After Every Submission** is enabled, current raw exports are rewritten locally after a successful commit as:

```text
AdventureBar_CurrentData.csv
AdventureBar_CurrentData.json
```

These are convenience snapshots in Documents, not the authoritative database. Encoding and predictable-filename writes run away from the Counter UI after the local commit. Refreshes are serialized and generation-checked so an older slow export cannot overwrite a newer snapshot. Snapshot failure does not roll back or delete the already committed local observation and does not interrupt subsequent counting.

## Export to Files or the share sheet

1. Open **Export**.
2. Select active session, another session, or all sessions.
3. Select observations only, observations plus session metadata, or complete backup.
4. Choose CSV or JSON where the selected content allows it.
5. Create the timestamped export.
6. Choose **Save to Files** for a document picker, or **Share** for the standard iOS share sheet.

Export never changes or deletes local records. Files export and snapshots work offline. With file sharing enabled, Documents may also appear under the app in Finder/device file sharing, subject to LiveContainer's container handling.

To save to Google Drive without an SDK or OAuth integration:

1. Install and sign in to the Google Drive iOS app.
2. Enable Google Drive as a Files location if iOS asks.
3. In this app, create an export and choose **Save to Files** or **Share**.
4. Select a Google Drive-backed Files folder and save.

Logging never depends on Google Drive or any other network service. If a guest document picker does not appear correctly, long-press this guest in LiveContainer, open its settings, and enable **Fix File Picker**, a compatibility control documented by LiveContainer.

## CSV format

CSV output is UTF-8 with one observation per record and RFC 4180 quoting: fields containing commas, quotes, CR, or LF are enclosed in double quotes, internal quotes are doubled, and records use CRLF. Timestamps are ISO 8601. Empty optional values are empty fields. No cell contains multiple step counts.

Columns, in order:

```text
session_id,session_name,observation_id,encounter_number,step_count,movement_mode,submitted_at,last_edited_at,measurement_uncertainty,source,questionable,questionable_reason,note
```

When **Observations + Session Metadata** is selected, these columns follow the required columns:

```text
session_created_at,session_last_modified_at,game_version,dungeon,map_area_description,testing_condition_notes,session_notes,session_archived
```

`movement_mode` is `Walking`, `Running`, or `Mixed/Uncertain`; `questionable` and `session_archived` are Boolean text values. `step_count` and `measurement_uncertainty` are stored raw integer fields. CSV is an observation interchange format and does not carry the complete settings or audit graph; use complete JSON backup for full-fidelity restore.

## JSON format

JSON exports are UTF-8 and use ISO 8601 dates plus UUID strings. A complete backup preserves:

- `schemaVersion`, optional `fullStoreRevision`, source-store UUID/mutation sequence, and export timestamp
- `sessions`
- `observations`, including notes, source, uncertainty, questionable flags/reasons, and `auditHistory`
- active session identifier
- application settings except the PC receiver upload secret, which is deliberately redacted from every export
- unfinished counter and mode state
- pending undo/deletion information when present
- seed/database initialization version

Observation-only JSON has the export envelope and raw observations required for interchange; metadata export also includes the referenced sessions. Complete backup is the only format intended to round-trip counter/undo/deletion state, portable settings, and every audit entry. Device-local receiver credentials are the documented exception. Future readers must check `schemaVersion` before decoding rather than assuming a layout.

The export-envelope keys are `schemaVersion`, optional `fullStoreRevision`, `sourceStoreID`, `sourceMutationSequence`, `exportFormatVersion`, `exportedAt`, `content`, `sessions`, `observations`, `activeSessionID`, and `settings`. A complete backup additionally includes `counter`, `pendingUndo` when present, `deletedObservations`, `seedDataVersion`, and `storeLastModifiedAt`. Optional values whose value is `nil` may be absent. These revision/source fields are persistence and transfer-ordering metadata, not analytical values. Ordinary full-store commits retain the source UUID and increase its sequence; applying an import rotates to a new source UUID so a delayed pre-import request cannot become current again.

Session objects use `id`, `name`, `createdAt`, `lastModifiedAt`, `gameVersion`, `dungeon`, `mapAreaDescription`, `testingConditionNotes`, `notes`, and `isArchived`. Observation objects use `id`, `sessionID`, `encounterNumber`, `stepCount`, `movementMode`, `submittedAt`, `lastEditedAt`, `measurementUncertainty`, `source`, `note`, `isQuestionable`, `questionableReason`, and `auditHistory`. Movement modes encode as `walking`, `running`, or `mixed_uncertain`.

Each audit entry uses `id`, `previousStepCount`, `newStepCount`, `previousMovementMode`, `newMovementMode`, `editedAt`, and optional `reason`. Complete-backup settings, counter state, and pending undo/deletion state use their Swift model property names. In every portable JSON file, `pcReceiverUploadSecret` is empty and `automaticallySendSnapshotToPC` is `false`; the app never sends the shared authentication key inside the payload it authenticates. Restoring into an already provisioned installation preserves its existing local receiver scheme, host, port, credential, and automatic-send preference as one device-local tuple. A fresh/reinstalled container has no credential to preserve, so re-enter the separately retained secret and deliberately enable automatic transfer again.

## Import and restore

The Export tab's import action accepts an app-created complete JSON backup, compatible observation JSON, or a UTF-8 CSV with the documented columns.

1. Pick the file from Files.
2. The app decodes and validates it without changing live data.
3. Review the preview count of accepted sessions/observations and every rejected row/message.
4. Choose **Merge** or **Replace**.
5. Replacement presents a destructive confirmation and writes a backup of current data first.

Merge compares observation UUIDs and does not insert a second copy of an existing UUID. Malformed rows are not silently ignored: the preview/error report identifies them. A valid row is not rounded, grouped, corrected, or analytically processed. Replacement is unavailable until explicit confirmation. Keep the pre-replacement safety backup until the restored data have been inspected and exported again.

## Optional authenticated PC receiver

`tools/adventurebar_receiver.py` is a Python 3.10+ companion that uses only standard-library modules. It exposes an unsigned `GET /health` reachability check and accepts a raw JSON or CSV body at `POST /upload`. It validates content type and basic schema, limits request size, sanitizes filenames, never silently overwrites a file, and can require an HMAC-SHA256 signature shared only by the receiver and iPhone app.

Every accepted upload is retained unchanged under `AdventureBarUploads/raw_uploads/` with a unique timestamped name. Parsed session/observation rows are also committed to `AdventureBarUploads/AdventureBarReceiver.sqlite3` by default. Schema version 4 has `schema_metadata`, `uploads`, `sessions`, `observations`, `upload_observations`, `observation_membership_events`, `authoritative_snapshot_watermarks`, `snapshot_sources`, and `auth_nonces` tables. Observation UUIDs prevent duplicate current rows while upload membership, membership events, and the original accepted files preserve history. For the phone's latest authoritative state, query `observations WHERE is_current = 1`; a later full app JSON snapshot tombstones managed UUIDs that are absent, while CSV/partial uploads never erase unrelated rows. Source UUID plus mutation sequence prevents a delayed older/equal or retired-source snapshot from rolling membership backward; legacy exports fall back to `storeLastModifiedAt`, then `exportedAt`. Every such stale upload is still retained and its `uploads.membership_decision` records why it did not change current membership. Existing older databases migrate in place and pre-migration rows remain current but unmanaged until seen in a full snapshot. This storage is raw collection and indexing only—the receiver performs no statistical analysis. `--output-dir` and `--database-path` can place both stores elsewhere.

The iPhone store remains authoritative and local-first. A submission is committed on the phone before any optional transfer begins. A timeout, rejected signature, unavailable PC, or other transfer failure never deletes or rolls back local data. There is no automatic retry queue: create/send another export later if a transfer fails.

### Shared-secret authentication

For any router-exposed receiver, authentication must be enabled. In **Settings → PC Receiver**, tap **Generate Upload Secret**, then **Copy Upload Secret**. The value is 32 random bytes represented by exactly 64 hexadecimal characters. Transfer that value to the PC through a private temporary note or file, then delete the temporary copy. Alternatively, generate it on the PC and paste the same value into the app:

```powershell
python -c "import secrets; print(secrets.token_hex(32))"
```

The app normalizes the secret to lowercase and retains it only in its internal local store. Every CSV/JSON export—including a complete backup—redacts the secret, and portable JSON forces automatic sending off. A restore in the same provisioned installation preserves its existing local receiver credential; a fresh container requires the separately retained secret to be entered again. The app never sends the shared authentication key inside the payload it authenticates.

For each signed upload, the app hashes the exact body and signs this UTF-8 canonical request with no trailing line feed:

```text
ABES1
POST
/upload
UNIX_TIMESTAMP
NONCE
CONTENT_TYPE
FILENAME
BODY_SHA256
```

`CONTENT_TYPE` is normalized to `application/json` or `text/csv`, and `FILENAME` is the trimmed value sent as `X-Filename`. The request includes `X-Adventure-Timestamp`, `X-Adventure-Nonce`, `X-Adventure-Content-SHA256`, and `X-Adventure-Signature: v1=<64-lowercase-hex-digits>`. The receiver verifies the body hash, signature, timestamp window (300 seconds by default), and one-time nonce. Accepted nonces are recorded in SQLite to reject replay. `GET /health` deliberately remains unsigned and proves only that the receiver is reachable; use an actual upload to verify that both sides have the same secret.

This proves possession of the shared key; it is not Apple device attestation and cannot prove which executable produced a request. In practice, a correctly protected secret limits accepted uploads to the configured app and any administrator who possesses that key. Generate a replacement on both sides if the secret may have been disclosed.

HMAC authenticates uploads but does not encrypt them. Over plain HTTP, someone able to observe the connection can read the CSV/JSON and request metadata, although they cannot create a new accepted upload without the secret. This LiveContainer-targeted build permits user-configured cleartext HTTP so a direct public-IP receiver can work without a certificate; the app makes network requests only to the address you save. Use HTTPS with a valid certificate when confidentiality or public-internet reliability matters. The standard-library receiver itself serves HTTP; HTTPS normally requires a TLS reverse proxy with a DNS hostname and valid certificate in front of it.

### Start the receiver on Windows

Run the receiver from an ordinary, non-administrator PowerShell; only the optional firewall-rule command below needs elevation. The receiver can create a secret file with exclusive creation—it refuses to overwrite an existing file and applies owner-only permissions where the operating system supports them. Keep the credential outside the source checkout. From the repository root:

```powershell
$receiverConfigDir = Join-Path $env:LOCALAPPDATA 'AdventureBarEncounterLogger'
New-Item -ItemType Directory -Force -Path $receiverConfigDir | Out-Null
$receiverSecretPath = Join-Path $receiverConfigDir 'receiver.secret'
python tools/adventurebar_receiver.py --generate-secret-file $receiverSecretPath
Get-Content -Raw $receiverSecretPath
python tools/adventurebar_receiver.py --bind 0.0.0.0 --port 8765 --output-dir AdventureBarUploads --require-auth --auth-secret-file $receiverSecretPath
```

Copy the one displayed 64-character value into the app's upload-secret field, save the receiver settings, and clear the terminal if desired. On later starts, set `$receiverSecretPath` to the same existing file and run only the final receiver command; do not run `--generate-secret-file` again unless intentionally rotating the secret on both devices.

An environment variable is an alternative for a secret generated in the app. The default variable name is `ADVENTUREBAR_RECEIVER_SECRET_HEX`:

```powershell
$env:ADVENTUREBAR_RECEIVER_SECRET_HEX = 'PASTE_THE_64_HEX_CHARACTER_SECRET_HERE'
python tools/adventurebar_receiver.py --bind 0.0.0.0 --port 8765 --output-dir AdventureBarUploads --require-auth
Remove-Item Env:\ADVENTUREBAR_RECEIVER_SECRET_HEX
```

Run `Remove-Item` only after the receiver has stopped because the running server already holds the key in memory. `--auth-secret-env NAME` selects a different environment-variable name. `--timestamp-skew-seconds N` changes the default 300-second window; keep the Windows and iPhone clocks synchronized. `--max-upload-mb` changes the request-size limit. The receiver refuses authenticated startup when the supplied secret is missing or invalid.

Unsigned compatibility mode remains available for a trusted LAN by omitting `--require-auth` and every secret option:

```powershell
python tools/adventurebar_receiver.py --bind 0.0.0.0 --port 8765 --output-dir AdventureBarUploads
```

Do not expose unsigned mode through a router. Anyone who can reach it can submit schema-compatible data. File-format obscurity is not an authentication mechanism.

Run the deterministic receiver tests from the repository root with:

```powershell
python -m unittest -v tools.test_receiver
```

### Configure a same-network connection

The iPhone and computer must be on the same private Wi-Fi/LAN, with wireless client isolation disabled.

- Windows: run `ipconfig` and use the active Wi-Fi/Ethernet adapter's **IPv4 Address**, commonly `192.168.x.x` or `10.x.x.x`.
- macOS Wi-Fi: run `ipconfig getifaddr en0`. If empty, inspect `ifconfig` for the active interface.
- Linux: run `hostname -I` and use the private LAN address.

Do not enter `127.0.0.1`, `0.0.0.0`, or the router's address in the app. In **Settings → PC Receiver**, select **HTTP**, enter the PC's private address without `http://`, enter `8765`, enter the same secret if authenticated mode is running, and tap **Save Receiver Settings**. **Test PC Connection** calls unsigned `GET /health`; it does not validate the secret. A manual signed upload is the end-to-end authentication test.

When Windows asks whether Python may accept connections, allow it on **Private networks only**. If no prompt appears, open an administrator PowerShell and add a narrowly scoped private-profile rule manually:

```powershell
New-NetFirewallRule -DisplayName "Adventure Bar Receiver" -Direction Inbound -Protocol TCP -LocalPort 8765 -Action Allow -Profile Private
```

Remove the rule when no longer wanted:

```powershell
Remove-NetFirewallRule -DisplayName "Adventure Bar Receiver"
```

Neither the app nor receiver changes Windows Firewall, router settings, UPnP, or port forwarding. On macOS, allow the selected Python executable under **System Settings → Network → Firewall → Options** if prompted. On Linux, use the distribution firewall tool to permit only the desired source network.

### Optional access through a public IPv4 address

This is a user-managed networking option, not a requirement for logging or export. Keep `--require-auth` enabled, reserve the PC's private IPv4 address in the router's DHCP settings, and manually create a TCP port-forward from a chosen external port (for example `48765`) to `PC_PRIVATE_IP:8765`. A high external port reduces background scanner noise but is not a security control. The Windows firewall rule above must still permit the receiver on the active network profile.

Find the router's WAN/public IPv4 address in its administration page. If that address is private, is in `100.64.0.0/10`, or differs from the public address reported for the connection, the ISP may use carrier-grade NAT (CGNAT); ordinary inbound port forwarding will not work unless the ISP supplies a public IPv4 address. A dynamically assigned public IP can change, so update the app's host when it does or use a dynamic-DNS hostname. Some routers do not support NAT loopback, so test the public endpoint from iPhone cellular data rather than the home Wi-Fi.

In the app, enter the public IP/hostname without a URL path, select **HTTP**, enter the external port, and save the same 64-character secret used by the receiver. The included LiveContainer build permits that direct cleartext connection. A more confidential configuration uses a valid HTTPS DNS hostname terminating TLS at a reverse proxy, with that proxy forwarding `/health` and `/upload` to the locally bound Python receiver; select **HTTPS** and its external TLS port in the app. Failed public setup never affects on-phone logging.

### Transfer behavior

For a manual transfer, create the desired CSV or JSON in **Export**, tap the PC send action once, and confirm both the in-app result and receiver's printed saved path. The receiver stores raw bytes before they are used for local database indexing.

**Automatically Send Current Data to PC** is off by default and can be enabled only after saving a receiver address and valid upload secret. When enabled, the app first commits locally, then attempts to send an all-sessions JSON snapshot containing observations and session metadata, without opening a share sheet or interrupting Counter. It sends after submission and refreshes after an undo, edit, deletion/restoration, import, or session-data change so PC `is_current` membership can catch up even if logging stops immediately afterward. Changing appearance, haptics, or other ordinary settings does not transmit the dataset. A newer data change supersedes an older in-flight automatic snapshot. It does not continuously transmit in the background. Settings retains the last automatic/manual PC-transfer result and time across later counter taps. A failed automatic attempt leaves the observation, local database, and local export functionality intact; because there is no retry queue, use a later manual export when delivery must be confirmed.

## Optional temporary Safari logger on Windows

`tools/safari_logger.py` is a separate, mobile-first fallback that can be used before the native IPA has been compiled. It is not the iPhone app and is not packaged into the IPA. It hosts a minimal Walking/Running counter, Submit, and Undo page on the PC's private LAN, checkpoints the unfinished interval in Safari and PC-side SQLite, and provides raw CSV/JSON download links. It performs no analysis and uses only Python's standard library.

From the repository root, substitute the PC's active private IPv4 address from `ipconfig` and run:

```powershell
python tools/safari_logger.py --bind 0.0.0.0 --port 8787 --public-host 192.168.178.250 --data-dir SafariLoggerData
```

The first run creates `SafariLoggerData/access.token`, prints a tokenized `http://...` URL, and stores data in `SafariLoggerData/AdventureBarSafariLogger.sqlite3`. Open the exact printed URL in Safari while the iPhone is on the same LAN. Treat it as a secret bearer link: anyone who has it and can reach the PC can use the logger. HTTP is not encrypted, so do not port-forward this temporary service to the public internet. If Windows Firewall blocks it, add a Private-profile-only rule while running an administrator PowerShell:

```powershell
New-NetFirewallRule -DisplayName "Adventure Bar Safari Logger" -Direction Inbound -Protocol TCP -LocalPort 8787 -Action Allow -Profile Private
```

Stop the foreground server with Ctrl+C. Remove the firewall rule when the fallback is no longer needed:

```powershell
Remove-NetFirewallRule -DisplayName "Adventure Bar Safari Logger"
```

Run its deterministic store and loopback HTTP tests with:

```powershell
python -m unittest -v tools.test_safari_logger
```

## Build and download the IPA using only Windows

The recommended Windows-only route is the manual workflow in `.github/workflows/build-ios.yml`. It uses GitHub's hosted `macos-26` runner, selects the newest installed stable Xcode 26 release, runs every test, builds the unsigned device app, creates the case-sensitive `Payload` archive, verifies it, and uploads the result. No Apple Developer account or signing certificate is needed for this LiveContainer-targeted unsigned package.

GitHub provides standard hosted-runner use without charge for public repositories. Private repositories use the account's included Actions allowance and may incur charges after that allowance, so check [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions) before running. A public repository exposes the source to everyone; choose a private repository if that is not acceptable.

### 1. Put this project in a GitHub repository

Create an empty repository at [github.com/new](https://github.com/new). Do not initialize it with a README, `.gitignore`, or license because this checkout already contains project files. Then open PowerShell in the project directory and run the following, replacing the identity and repository placeholders:

```powershell
Set-Location 'C:\Users\vince\Documents\Codex\2026-07-29\create-a-complete-iphone-application-named'
git init
git config user.name 'YOUR NAME'
git config user.email 'YOUR EMAIL'
git add --all
git commit -m 'Add Adventure Bar Encounter Logger'
git branch -M main
git remote add origin 'https://github.com/YOUR_ACCOUNT/YOUR_REPOSITORY.git'
git push -u origin main
```

If this checkout already has an `origin`, inspect it with `git remote -v` and use `git remote set-url origin 'https://github.com/YOUR_ACCOUNT/YOUR_REPOSITORY.git'` only if it points to the wrong repository. Git may open a browser for GitHub authentication. GitHub Desktop can be used instead: add this existing local repository, commit all files, select **Publish repository**, and ensure `main` is the default branch.

### 2. Run the cloud build

1. Open the repository on GitHub and select **Actions**.
2. If prompted, enable Actions for the repository.
3. Select **Build and verify iOS IPA** in the workflow list.
4. Select **Run workflow**, leave the branch set to `main`, and confirm **Run workflow**.
5. Open the new run and wait for **XCTest and unsigned IPA** to turn green.

The workflow is manual and does not run merely because data are logged on the iPhone. Its build log records the exact Xcode and SDK versions used. It performs these release gates:

1. selects a stable Xcode 26.x installation on macOS 26;
2. validates the Xcode project and runs the Python receiver and Safari-fallback tests;
3. boots the newest available iPhone simulator and runs the complete XCTest suite;
4. calls `build_ipa.sh` for the unsigned generic-device Release build;
5. verifies the ZIP and exact `Payload/AdventureBarEncounterLogger.app/Info.plist` member; and
6. calculates SHA-256 and uploads the IPA artifact.

If a step fails, open that step's log. The workflow also uploads **AdventureBarEncounterLogger-build-diagnostics** when diagnostic files exist. Do not use an IPA from a failed run.

### 3. Download and verify it on Windows

At the bottom of the successful workflow-run page, select the **AdventureBarEncounterLogger-IPA** artifact. GitHub downloads an artifact ZIP. Extract that outer ZIP once; it contains:

```text
AdventureBarEncounterLogger.ipa
AdventureBarEncounterLogger.ipa.sha256
```

The workflow retains the IPA artifact for 30 days and failure diagnostics for 14 days. Download the successful artifact promptly and keep your own copy; GitHub artifacts are build outputs, not permanent data storage.

The `.ipa` is already the final app archive. Do not extract or rename it before importing it into LiveContainer. From PowerShell in the extracted directory, compare the two hashes and inspect the required member:

```powershell
(Get-FileHash '.\AdventureBarEncounterLogger.ipa' -Algorithm SHA256).Hash.ToLowerInvariant()
(Get-Content '.\AdventureBarEncounterLogger.ipa.sha256' -Raw).Split()[0].ToLowerInvariant()
tar -tf '.\AdventureBarEncounterLogger.ipa' | Select-String '^Payload/AdventureBarEncounterLogger.app/Info.plist$'
```

The two hash lines must match, and the last command must print `Payload/AdventureBarEncounterLogger.app/Info.plist`. Copy the IPA to iCloud Drive, another Files-accessible location, or the iPhone by cable, then follow **Install in LiveContainer** below.

### Why the cloud compile is still necessary

An IPA is a ZIP archive whose case-sensitive top-level folder is `Payload`; `build_ipa.sh` creates exactly that layout and gives the resulting archive an `.ipa` extension. However, `Payload` must contain the Xcode-compiled `AdventureBarEncounterLogger.app`, including its iOS Mach-O executable and processed resources. Zipping Swift source or the Xcode project on Windows would create a right-looking filename but not a runnable iPhone application. The cloud job first produces the real `.app`, then performs the simple Payload ZIP packaging.

## Optional: build with Xcode on macOS

Install full Xcode 26 from Apple, launch it once to install components, and select it:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -version
```

From the repository root, list the shared scheme:

```sh
xcodebuild -list -project AdventureBarEncounterLogger/AdventureBarEncounterLogger.xcodeproj
```

Build a debug simulator app:

```sh
xcodebuild \
  -project AdventureBarEncounterLogger/AdventureBarEncounterLogger.xcodeproj \
  -scheme AdventureBarEncounterLogger \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' \
  build
```

If that simulator model is not installed, run `xcrun simctl list devices available` and substitute an available iPhone name. In Xcode, the equivalent is to open `AdventureBarEncounterLogger/AdventureBarEncounterLogger.xcodeproj`, select the app scheme and an iPhone simulator, then press Command-B or Command-R.

For a signed physical-device build, select the app target in Xcode, open **Signing & Capabilities**, choose your development team, keep the bundle ID unique if your team requires it, select the device, and build. Signing is not required for the unsigned LiveContainer package made by the script below.

## Optional: run XCTest locally on macOS

Boot or select an installed iOS 26 simulator, then run:

```sh
xcodebuild \
  -project AdventureBarEncounterLogger/AdventureBarEncounterLogger.xcodeproj \
  -scheme AdventureBarEncounterLogger \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' \
  test
```

The suite covers first-run integrity/idempotence, counter and mode persistence, submit/zero handling, undo variants, mixed intervals, sessions, RFC 4180 escaping, CSV/JSON export, JSON/CSV import validation and duplicate handling, atomic-store recovery, audit preservation, snapshots, and network failure without local data loss. A release should not be distributed unless this command exits zero.

## Optional: package the unsigned IPA locally on macOS

On macOS, from the repository root:

```sh
chmod +x build_ipa.sh
./build_ipa.sh
```

The script uses `set -euo pipefail`, removes any earlier file at the documented output path before building so a failed run cannot leave a stale IPA there, builds Release for `generic/platform=iOS` with signing disabled, uses a private temporary DerivedData/staging directory, creates and verifies a clean `Payload`, and only then moves the verified archive to:

```text
dist/AdventureBarEncounterLogger.ipa
```

It then inspects the ZIP directory and fails unless these exist:

```text
Payload/AdventureBarEncounterLogger.app
Payload/AdventureBarEncounterLogger.app/Info.plist
```

An independent check is:

```sh
unzip -Z1 dist/AdventureBarEncounterLogger.ipa | grep '^Payload/AdventureBarEncounterLogger.app/'
```

The IPA is unsigned. LiveContainer may sign or bypass-sign guest code according to its configured mode. Do not install this raw package directly through normal iOS installation mechanisms.

## Install in LiveContainer

Use only the official open-source [LiveContainer project](https://github.com/LiveContainer/LiveContainer) and follow its [current installation guide](https://livecontainer.github.io/docs/installation). Current upstream requirements are iOS/iPadOS 15 or later; the standalone build currently requires AltStore 2.2.1+ or SideStore 0.6.2+.

1. Transfer the downloaded/extracted `AdventureBarEncounterLogger.ipa` into Files on the iPhone. For a local Mac build, this is `dist/AdventureBarEncounterLogger.ipa` (use AirDrop, iCloud Drive, cable, or another private method).
2. Open LiveContainer.
3. Tap `+` at the top right and select the IPA.
4. If LiveContainer asks to sign/re-sign the guest, allow its configured signer to process it.
5. Choose **Adventure Bar Encounter Logger** as the app to open on the next launch, then launch it.
6. Confirm first launch shows Counter at zero in **Adventure Bar Encounter Test 1**, and Records contains the separate 40-row initial sample.

The exact `+` import flow is from LiveContainer's official **Installing Apps** documentation. Long-press the guest in LiveContainer to manage its settings/container. If import reports an invalid package, first rerun `build_ipa.sh` and its archive check; LiveContainer documents malformed IPA structure and signer incompatibility as common causes. If its JIT-less diagnostics pass but the signature remains invalid, use the guest's force re-sign action as described in [LiveContainer's signing FAQ](https://livecontainer.github.io/docs/faq/installing-livecontainer).

This conventional native SwiftUI app has no app extension and does not request JIT. Guest entitlements/extensions are limited by LiveContainer, which is why this project avoids both. LiveContainer guest data isolation and file-picker behavior differ from a normally installed iOS app; export a complete backup before changing its container.

## Release verification checklist

Use either the Windows-triggered GitHub workflow or the equivalent local macOS commands:

1. Confirm the run reports stable Xcode 26.x and an iOS 26 SDK.
2. Confirm the Debug simulator build and complete XCTest suite exit zero.
3. Review build output and resolve compiler errors and meaningful warnings.
4. Confirm `build_ipa.sh` exits zero.
5. Confirm `AdventureBarEncounterLogger.ipa` is nonempty and its downloaded SHA-256 matches.
6. Confirm the archive contains `Payload/AdventureBarEncounterLogger.app/Info.plist`.
7. Import into the target LiveContainer/iOS version and launch.
8. Verify seed/session integrity, a submit/undo round-trip, Files CSV/JSON export, complete-backup restore preview, relaunch persistence, and receiver failure without data loss.

## Known limitations

- Counting is manual and may carry the stated human uncertainty (normally ±1). The app cannot observe or control the Nintendo Switch.
- It cannot determine whether a player actually moved, hit a wall, walked, or ran; the user supplies every tap and mode.
- There is intentionally no in-app analysis.
- Files/Google Drive availability and UI depend on installed iOS providers and LiveContainer's file-picker compatibility.
- The PC receiver's HMAC mode authenticates uploads but does not encrypt plain HTTP. This LiveContainer build deliberately permits cleartext connections to the receiver address configured by the user; use a valid HTTPS endpoint when transport confidentiality matters.
- The receiver secret is persisted in the app's internal JSON state rather than the iOS Keychain. Portable exports redact it, but anyone with access to the LiveContainer guest data may be able to read it; rotate it if that container is exposed.
- Public inbound transfer depends on a manually maintained Windows firewall rule, router forwarding, a reachable public IPv4 address, and current address/DNS information; CGNAT can make it unavailable.
- There is no transfer retry queue. iOS may suspend a transfer when the app backgrounds, but failure never deletes local data; retry with a manual export.
- The PC receiver has no automatic retention policy. Raw uploads and SQLite storage grow until the user archives or removes them; keep independent PC backups before doing so.
- LiveContainer manages guest signing, permissions, and containers differently from normal iOS installation. Its current upstream documentation is authoritative.
- Windows cannot run Xcode or XCTest locally. The included GitHub workflow supplies the macOS/Xcode environment, but regenerating a verified IPA requires a GitHub repository, internet access, available Actions usage, and a manual workflow run.
- A green cloud build verifies compilation, automated tests, and package structure; final LiveContainer import and an on-device smoke test still require the user's iPhone.

The logging loop itself remains fully offline: `+` for each successful tile movement, **Submit** at encounter, and immediately continue.

# ImmichVault

ImmichVault is a macOS application for uploading your Apple Photos library to an [Immich](https://immich.app) server with idempotent, never-re-upload protection and a built-in video optimizer. It supports local ffmpeg transcoding and cloud provider integration (CloudConvert, Convertio, FreeConvert), a rules engine for automated optimization, and a full activity log with export. Every upload and transcode operation is tracked in a local SQLite database with a strict state machine to guarantee reliability.

## Requirements

- macOS 13+ (Ventura)
- An Immich server with API access
- For building from source: Xcode 16+, [xcodegen](https://github.com/yonaskolb/XcodeGen)

## Quick Start

1. Download `ImmichVault.dmg` from the `dist/` directory (or build from source).
2. Drag `ImmichVault.app` to your Applications folder.
3. Launch the app and complete the 3-step onboarding: enter your Immich server URL, paste your API key, and test the connection.
4. Grant Photos library access when prompted by macOS.

## Building from Source

Prerequisites: Xcode 16+, xcodegen (`brew install xcodegen`).

```bash
# Download ffmpeg/ffprobe static binaries (~80MB)
./scripts/download_ffmpeg.sh

# Generate Xcode project and build Release configuration
./scripts/build_release.sh

# Package into a distributable DMG
./scripts/package_dmg.sh
```

The output DMG will be at `dist/ImmichVault.dmg`.

### Running Tests

```bash
xcodegen generate
xcodebuild -project ImmichVault.xcodeproj -scheme ImmichVault test
```

There are 362 unit and integration tests covering database migrations, state machine transitions, upload/transcode pipelines, provider mock tests, metadata validation, filter logic, rules engine evaluation, cost ledger aggregation, and more.

## Features

### Photos Upload

Connect to your macOS Photos library via PhotoKit and upload images and videos to Immich. Supports comprehensive filtering: start date, album include/exclude, media type toggles (photos, videos, Live Photos), favorites, hidden assets, screenshots, and shared library exclusion. iCloud placeholder assets are detected and clearly displayed with a "needs download" status. The never-re-upload guarantee means that once an asset is successfully uploaded, it will not be uploaded again even if deleted from Immich -- only an explicit Force Re-Upload (with confirmation and audit log) can override this. Every skipped asset shows an "Explain Why Skipped" breakdown with the exact rule that caused the skip.

### Video Optimizer

Find oversized videos in your Immich library by setting a size threshold and date range, then transcode them to save storage while preserving quality. The review list shows each candidate with file size, codec, resolution, bitrate, and duration. Transcoding uses configurable presets (codec, CRF, audio settings, container format) and supports both local ffmpeg and cloud providers. Metadata validation is a hard gate: if the transcoded output does not match the source metadata (creation date, GPS, orientation, duration within tolerance), the replace operation is blocked and the job is marked as permanently failed.

### Cloud Providers

Three cloud transcoding providers are supported alongside local ffmpeg:

- **CloudConvert** -- Task-graph API with multipart upload, cost: (1 + ceil(minutes)) x $0.02/min
- **Convertio** -- Simple upload/convert API, cost: $0.10/min
- **FreeConvert** -- Task-graph API similar to CloudConvert, cost: $0.008/min

Each provider has health checks, configurable timeouts, retry with exponential backoff, per-provider concurrency limits, and a cost ledger that tracks spending by day, week, month, and all-time.

### Rules Engine

Define conditional rules that automatically select transcode presets for matching videos. Each rule consists of AND-combined conditions (file size, date range, codec, resolution, duration, bitrate, filename pattern) and maps to a preset and provider. Rules are evaluated by priority (lower number wins). Built-in preset packs are included:

- **iPhone Default** -- H.265, CRF 24, optimized for iPhone video
- **GoPro** -- H.265, CRF 22, higher quality for action footage
- **Screen Recording** -- H.264, CRF 28, aggressive compression for screen captures

Custom rules can be created, edited, reordered, and toggled in the Rules Editor UI.

### Optimizer Mode

A continuous background scanning mode that automatically discovers optimization candidates and queues transcode jobs based on matching rules. Runs only while the app is open. Configurable with:

- Scan interval (how often to check for new candidates)
- Maintenance window scheduling (time range and days of week)
- Bandwidth caps and rate limiting

### Safety

- All API keys (Immich, CloudConvert, Convertio, FreeConvert) stored in macOS Keychain
- Log messages automatically redacted to remove secrets
- User-adjustable rate limiting and bandwidth caps
- Concurrency limits per CPU and per provider
- Maintenance window scheduling restricts when optimization runs
- Data loss prevention: originals are never deleted by default; opting in requires typed confirmation ("DELETE ORIGINALS")

### Database

SQLite via GRDB.swift with versioned migrations (v1 through v4). The database tracks every asset's upload state, transcode jobs, cost records, transcode rules, and activity log entries. Features include:

- Reveal database file in Finder
- Export database snapshot (uses `VACUUM INTO` for a clean, self-contained copy)
- Import snapshot with schema version validation and automatic migration
- Seamless migration between Macs

### Activity Log

A filterable activity log stored in SQLite with support for level (debug, info, warning, error), category (general, upload, transcode, metadata, immich-api, photos, database, keychain, scheduler), date range, search text, and per-asset filtering. Export to JSON or CSV at any time.

## Architecture

ImmichVault compiles as a single Xcode target with source organized by directory:

```
ImmichVault/
  App/                    SwiftUI entry point, AppState, navigation
  Views/                  10 SwiftUI views (Dashboard, Photos Upload, Optimizer,
                          Jobs, Logs, Settings, Onboarding, Inspector, Rules Editor,
                          Main Navigation)
  ViewModels/             6 view models driving each screen
  Resources/              Info.plist, entitlements, Binaries/ (ffmpeg/ffprobe)

Sources/
  Core/                   Database models (AssetRecord, TranscodeJob, TranscodeRule,
                          ActivityLogRecord), DatabaseManager with migrations,
                          StateMachine, AppSettings, KeychainManager, LogManager,
                          UploadEngine, TranscodeOrchestrator, OptimizerScheduler,
                          RulesEngine, RuleCondition, CostLedger, AssetHasher,
                          DesignSystem
  ImmichClient/           ImmichClient (connection test, upload, replace, search,
                          download, asset details)
  PhotosScanner/          PhotoKit integration, iCloud placeholder detection,
                          ScanFilterEngine
  TranscodeEngine/        TranscodeProvider protocol, TranscodePreset,
                          LocalFFmpegProvider, CloudTranscodeProvider protocol,
                          CloudConvertProvider, ConvertioProvider, FreeConvertProvider,
                          CloudJobStatus, CloudProviderHelpers
  MetadataEngine/         VideoMetadata, MetadataValidationResult, MetadataEngine
                          (ffprobe extraction, ffmpeg metadata copy, validation)

Tests/
  CoreTests/              Database, state machine, hashing, filters, rules, logs,
                          upload pipeline
  ImmichClientTests/      Connection, upload, search, replace (mock URLProtocol)
  TranscodeEngineTests/   Presets, pipeline, metadata, cloud providers, cost ledger
```

### Key Technical Decisions

- **GRDB.swift** chosen over SQLite.swift for its richer query DSL, built-in migration support, and `DatabasePool` for concurrent reads.
- **No App Sandbox** -- required for Photos library access and execution of bundled ffmpeg binaries.
- **Ad-hoc code signing** -- notarization requires an Apple Developer Program membership.
- **Structured concurrency** (async/await) throughout, with `@MainActor` view models.
- **State machine** with explicit states for both uploads and transcode jobs, ensuring no operation is lost or duplicated.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+1 | Dashboard |
| Cmd+2 | Photos Upload |
| Cmd+3 | Optimizer |
| Cmd+4 | Jobs |
| Cmd+5 | Logs |
| Cmd+6 | Settings |
| Cmd+R | Scan / Refresh in active view |
| Cmd+I | Toggle Inspector panel |
| Cmd+, | Settings |

## Manual Verification Checklist

- [ ] **Photos permission** -- App requests Photos access on first launch, works correctly when granted, shows an explanatory message when denied
- [ ] **Start Date filter** -- Assets with a creation date before the configured start date show status "Skipped: Before start date" with correct reasoning in the inspector
- [ ] **Never re-upload** -- Delete an asset from Immich, then scan again in ImmichVault; confirm the app does NOT re-upload the deleted asset
- [ ] **Force re-upload** -- Right-click an asset and select "Force Re-Upload"; confirm the upload occurs, the confirmation dialog appears, and an audit log entry is created
- [ ] **iCloud placeholders** -- Assets stored only in iCloud display an iCloud icon and "needs download" status; the "Download from iCloud then upload" option works when selected
- [ ] **Optimizer candidates** -- The review list correctly shows only videos exceeding the size threshold within the specified date range
- [ ] **Metadata preservation** -- Spot-check a transcoded video with a metadata viewer (e.g., `exiftool` or `mdls`); verify creation date, GPS coordinates, and orientation match the source
- [ ] **Metadata validation gate** -- Intentionally corrupt metadata on a transcoded file; confirm the app refuses to call replaceAsset and marks the job as permanently failed
- [ ] **Bandwidth limit** -- Set a bandwidth limit in Settings, start an upload batch, and verify the transfer speed is throttled appropriately
- [ ] **Maintenance window** -- Enable a maintenance window, set it to a time outside the current time; verify the optimizer scheduler does not run until the window opens
- [ ] **Keychain storage** -- Verify no plaintext API keys exist in UserDefaults (check `defaults read com.immichvault.app`), log files, or any on-disk file outside the Keychain
- [ ] **Log redaction** -- Add an API key to the Immich settings, trigger some API calls, then inspect the activity log; confirm the key is replaced with `[REDACTED]`
- [ ] **DB export/import** -- Export a database snapshot, reset the app to fresh state, import the snapshot; verify data integrity, schema version, and that all records are present
- [ ] **Dark mode** -- Toggle macOS appearance between Light and Dark; verify all screens render correctly with proper contrast and no missing colors
- [ ] **Keyboard navigation** -- Tab through UI elements on each screen; verify focus rings are visible and all interactive elements are reachable
- [ ] **VoiceOver** -- Enable VoiceOver, navigate each screen; verify all elements are announced with meaningful labels

## Known Limitations

- **No App Sandbox** -- Required for direct Photos library access and execution of the bundled ffmpeg binary. This means the app cannot be distributed via the Mac App Store.
- **Ad-hoc code signing only** -- Notarization requires an Apple Developer Program account ($99/year). Users may need to right-click and select "Open" on first launch, or allow the app in System Settings > Privacy & Security.
- **Optimizer mode runs only while the app is open** -- There is no LaunchAgent or background daemon; the optimizer scheduler stops when the app quits.
- **ffmpeg/ffprobe binaries (~80MB) must be downloaded separately** -- Run `./scripts/download_ffmpeg.sh` before building. The binaries are not checked into version control due to their size.
- **Cloud provider API keys must be obtained independently** -- CloudConvert, Convertio, and FreeConvert each require their own account and API key.
- **App icon uses system default** -- No custom icon artwork has been created; the app uses the default macOS application icon.
- **Live Photo pairing** -- Live Photos are detected and handled as paired assets, but the pairing heuristic depends on PHAsset metadata consistency.
- **Immich replaceAsset endpoint** -- The replace endpoint used for video optimization is marked as deprecated in the Immich API but remains functional as of Immich v1.x.

## Tech Stack

| Component | Technology |
|-----------|-----------|
| Language | Swift 6.0 |
| UI Framework | SwiftUI |
| Database | GRDB.swift 7.10.0 (SQLite) |
| Networking | URLSession |
| Photos Access | PhotoKit (PHAsset) |
| Video Transcoding | ffmpeg 7.1 (static binary) |
| Secrets | Keychain Services |
| Build System | xcodegen + xcodebuild |
| Minimum OS | macOS 13.0 (Ventura) |

## License

This project is provided as-is for personal use.

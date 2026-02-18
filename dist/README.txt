================================================================================
  ImmichVault for macOS
  Version 1.0.0
================================================================================

ImmichVault uploads your Apple Photos library to an Immich server with
idempotent, never-re-upload protection. It also includes a video optimizer
that transcodes oversized videos (locally via ffmpeg or via cloud providers)
and replaces them in Immich while preserving all metadata.

REQUIREMENTS
  - macOS 13 (Ventura) or later
  - An Immich server with API access

QUICK START
  1. Drag ImmichVault.app to /Applications.
  2. Launch the app. You may need to right-click > Open on first launch
     (the app is ad-hoc signed, not notarized).
  3. Complete the onboarding: enter your Immich server URL and API key,
     then click "Test Connection."
  4. Grant Photos library access when macOS prompts you.

FEATURES
  - Photos Upload: Scan your Photos library with filters (start date,
    albums, media types, favorites, hidden, screenshots). Idempotent
    never-re-upload guarantee. Force re-upload with confirmation and audit.
  - Video Optimizer: Find oversized videos by size threshold and date range.
    Transcode with configurable presets. Metadata validation gate ensures
    replaceAsset is only called when output metadata matches the source.
  - Cloud Providers: CloudConvert, Convertio, and FreeConvert supported
    with cost tracking (daily/weekly/monthly/all-time).
  - Rules Engine: Conditional rules (file size, date, codec, resolution,
    duration, bitrate, filename) map to presets. Built-in packs for
    iPhone, GoPro, and Screen Recording.
  - Optimizer Mode: Continuous background scanning with maintenance window
    scheduling and bandwidth caps. Runs while the app is open.
  - Safety: Keychain for all API keys, automatic log redaction, rate
    limiting, concurrency caps, maintenance windows, data loss prevention.
  - Database: SQLite with versioned migrations (v1-v4), export/import
    snapshots, Finder reveal.
  - Activity Log: Filterable by level/category/date/search. Export to
    JSON or CSV.

MANUAL VERIFICATION CHECKLIST
  [ ] Photos permission flows work correctly
  [ ] Start Date filter skips assets before configured date
  [ ] Delete asset from Immich -> app does NOT re-upload on next scan
  [ ] Force re-upload via context menu -> uploads and creates audit entry
  [ ] iCloud placeholder assets show "needs download" status
  [ ] Optimizer review list matches size/date filters
  [ ] Transcoded video metadata matches source (creation date, GPS, orientation)
  [ ] Bandwidth limit in Settings throttles upload speed
  [ ] Maintenance window prevents optimizer from running outside schedule
  [ ] No plaintext API keys in UserDefaults, logs, or disk files
  [ ] API keys appear as [REDACTED] in activity log
  [ ] DB export/import preserves data integrity and schema version
  [ ] All screens render correctly in both Light and Dark mode
  [ ] Keyboard navigation reaches all interactive elements
  [ ] VoiceOver announces all elements with meaningful labels

KNOWN LIMITATIONS
  - No App Sandbox (required for Photos access and ffmpeg execution)
  - Ad-hoc signed only; notarization requires Apple Developer account
  - Optimizer mode runs only while the app is open (no LaunchAgent)
  - ffmpeg/ffprobe binaries (~80MB) downloaded separately via script
  - Cloud provider API keys obtained from their respective services
  - App icon uses macOS system default (no custom artwork)

BUILDING FROM SOURCE
  Prerequisites: Xcode 16+, xcodegen (brew install xcodegen)

  ./scripts/download_ffmpeg.sh    # Download ffmpeg binaries
  ./scripts/build_release.sh      # Build Release app
  ./scripts/package_dmg.sh        # Create DMG in dist/

  Run tests:
  xcodegen generate
  xcodebuild -project ImmichVault.xcodeproj -scheme ImmichVault test

TECH INFO
  Swift 6.0 / SwiftUI / GRDB.swift 7.10.0 / URLSession / PhotoKit
  ffmpeg 7.1 / Keychain Services / macOS 13.0+ / 362 tests

================================================================================

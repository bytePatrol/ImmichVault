# ImmichVault (macOS) — Claude Code Execution Plan (NO SKIPPED STEPS)

You are Claude Code. Build a production-quality macOS app named **ImmichVault** with a **10/10 GUI** and rock-solid reliability. You MUST use the **frontend-design** skill for the entire UI/UX (layout, typography, spacing, empty states, animations, accessibility, dark mode, responsiveness). Do not ship a “developer UI.” This must feel like a premium native macOS app.

## Non-Negotiables
- NO steps skipped. Every phase must end with working code + tests + manual verification checklist executed.
- Idempotency everywhere (uploads, replaces, retries) and a local SQLite state machine.
- “Never re-upload” behavior is absolute unless user explicitly Force Re-Uploads.
- Secrets in Keychain only (Immich API key and provider keys).
- Provide a final **DMG** containing the signed (ad-hoc is ok) app bundle, plus a README and a sample config export.
- Logging must redact secrets.
- The UI must always be truthful: show “why skipped,” show progress, show errors with actionable resolution.

## Inputs / References
- Immich API docs: https://api.immich.app/
- Replace asset endpoint: https://api.immich.app/endpoints/assets/replaceAsset
- CloudConvert API: https://cloudconvert.com/api/v2#
- Convertio API: https://developers.convertio.co/api/docs/
- FreeConvert API: https://www.freeconvert.com/api/v1/#create-job
- Existing reference code (for Photos -> Immich upload behavior): https://github.com/bytePatrol/Immich_Replace_Transcoded_Videos

You may use the repo above for patterns, but this is a new app with the full feature set below.

---

# 0) Tech Stack & Architecture (Decide + Implement)
### Target
- macOS 13+ (Ventura) minimum unless there’s a strong reason to change.
- Swift 5.9+ / SwiftUI
- Concurrency: async/await + structured concurrency
- SQLite: use GRDB.swift (preferred) or SQLite.swift (pick one; justify in README)
- Networking: URLSession (no heavy dependencies unless needed)
- Keychain: Keychain Services wrapper
- Photos access: PhotoKit (PHAsset)
- Local transcoding: ffmpeg embedded in app bundle
- Metadata: implement robust metadata copy + validation
  - Strategy must preserve:
    - create date, GPS, filename
    - rotation/orientation, make/model, timezone offsets
    - sidecars if present (if Photos exposes them)
  - Must validate output metadata matches source (within reasonable tolerance).
  - If metadata mismatch: fail safe and do NOT replace asset in Immich.

### Modules (must be separate folders / targets if helpful)
- App (SwiftUI)
- Core (DB models, state machine, hashing, scheduling, retry/backoff)
- ImmichClient (API, auth, idempotency keys)
- PhotosScanner (PHAsset enumeration, filtering, placeholder handling)
- TranscodeEngine (provider interface + implementations)
- MetadataEngine (read/write/verify)
- DMGPackager (build script)
- Tests (unit + integration)

---

# 1) Features — Must Implement Exactly

## 1A) Photos → Immich Upload (Idempotent + Never Re-Upload)
App connects to macOS Photos, lists media, and uploads images/videos to Immich via its documented API.

### Rules
- Must only upload each asset ONE time.
- If an asset was uploaded and later deleted from Immich, ImmichVault MUST NOT re-upload it automatically.
- A user-defined **Start Date**: ALL media prior to this date is ignored by default.
- Must support media types: images + videos; handle Live Photos consistently (paired assets).
- “Edits & variants policy” options:
  1) Upload originals only
  2) Upload edited versions only
  3) Upload both
- Must handle:
  - iCloud placeholders (asset not fully local): show as “needs download” and allow “Download from iCloud then upload” (with user opt-in).
  - Burst, HDR, HEVC variations, slo-mo, screen recordings.

### Duplicate detection & Never-Reupload
You MUST implement a local “source of truth” SQLite index keyed by **PHAsset.localIdentifier**.
Each row must track:
- localIdentifier (primary key)
- assetType (photo/video/livePhoto)
- hashes:
  - original hash (stable) and rendered hash (if applicable)
- immichAssetId (nullable)
- uploadAttemptCount
- uploadTimestamps (firstUploadedAt, lastAttemptAt)
- neverReuploadFlag (bool)
- neverReuploadReason (string enum: uploadedOnce, manuallySuppressed, userMarkedNever, etc.)
- state machine fields (see below)
- lastError (string), lastErrorAt, retryAfter, backoffExponent
- metadata snapshot for validation (dateTaken, GPS present, duration/resolution for videos, etc.)

Never re-upload means:
- If DB indicates this PHAsset was uploaded once (success) OR user marked it never reupload, it must be skipped even if Immich returns 404 later.
- ONLY the “Force Re-Upload” pathway can override this (explicit user action + confirmation + audit log).

### Upload State Machine
Implement explicit states:
- idle
- queuedForHash
- hashing
- queuedForUpload
- uploading
- verifyingUpload
- doneUploaded
- skipped (with reason)
- failedRetryable
- failedPermanent

Uploads must be resumable and retry-safe:
- Use client-generated idempotency keys per asset upload attempt.
- If network drops, resume without duplicating work.

### Filters (quality-of-life)
In addition to Start Date:
- include-only albums
- exclude albums
- exclude hidden
- exclude screenshots
- exclude shared library
- include/exclude favorites
- media type toggles (photos/videos/live photos)

### UI requirement for this feature
- A “Photos Library” screen:
  - filter panel + Start Date picker
  - scan button + progress
  - results table with columns: thumbnail, type, date, size (estimated), status, reason
  - per-item context menu: Upload now, Mark never upload, Force re-upload, Reveal in Photos
- An “Explain why skipped” inspector panel with exact rule breakdown.

---

## 1B) Video Optimizer / Transcode + Replace in Immich
Find videos over a preset size within a date range and transcode to save disk space while minimizing quality loss, then replace the asset in Immich using the replaceAsset endpoint.

### Core UX flow
- User sets:
  - size threshold (e.g., 300MB+)
  - date range (e.g., 01/01/2026–02/15/2026)
  - transcode preset (codec, CRF, audio, container)
  - provider: Local ffmpeg OR CloudConvert OR Convertio OR FreeConvert
  - optional: specific Immich userId to force transcode (scope)
- App scans Immich library (and/or local DB mapping) to find candidates.
- BEFORE starting:
  - Show a review list of videos that WILL be transcoded.
  - Display details per video: file size, codec, resolution, bitrate, duration.
  - Show estimated output size + estimated time (learning model based on prior jobs).
  - Show estimated cost for cloud providers + monthly/weekly/daily spend tracking.

### Provider plug-in interface
Implement a normalized contract:
- submit(job) -> providerJobId
- poll(providerJobId) -> progress/status
- download(providerJobId) -> local file URL
- verify(downloaded) -> checksum, container, duration match tolerance
- finalize -> return output file URL + metadata

Providers:
A) Local ffmpeg embedded
B) CloudConvert
C) Convertio
D) FreeConvert

Provider requirements:
- health check
- timeouts
- retries with backoff
- per-provider concurrency limits
- cost estimator + cost ledger (daily/weekly/monthly)

### Metadata preservation (must “hold up”)
- Preserve: create date, GPS, filenames
- Also: rotation/orientation, make/model, timezone offsets
- Sidecars if present
- Use robust strategy:
  1) Extract metadata from source
  2) Apply to output
  3) Validate output matches (report differences)
- If validation fails: mark job failedPermanent and DO NOT call replaceAsset.

### Replace behavior
- Use Immich replaceAsset endpoint to replace original with transcoded file.
- Ensure file names preserved where possible.
- Preserve last modified timestamps locally (for local artifacts) and keep Immich metadata consistent.

### Optimizer Mode (premium differentiator)
Add optional “Optimizer mode”:
- continuously scans for oversized videos and queues optimization
- strict safety checks + maintenance window scheduling (overnight)
- bandwidth caps + rate limiting

### Rules engine (premium differentiator)
Implement a minimal rules engine:
- IF size > X AND date between A/B AND not favorited AND not in album X -> preset Y
Ship with preset packs:
- iPhone default
- GoPro
- Screen recording
- (and allow custom presets)

---

## 1C) Force Re-Upload (Drag & Drop)
UI supports drag & drop of photo/video files to force upload even if duplicate / never-reupload.
- Must show a confirmation modal:
  - explains it overrides duplicate protection
  - requires checkbox: “I understand this may create duplicates in Immich”
- Must log action in audit log.
- Must update DB state accordingly.

---

# 2) Observability / Trust
Must include:
- Activity log (filterable) + export JSON/CSV
- Per-asset history timeline (hashing/upload/verify/replace)
- Dashboard:
  - queued, active, throughput, failures by reason
  - last successful run
- “Explain why skipped” UI for every skipped asset with explicit rule + data.

---

# 3) Safety Rails
- Rate limiting + bandwidth caps (user adjustable)
- Maintenance window scheduling (time range + days of week)
- Concurrency limits per:
  - CPU
  - GPU (if used later)
  - provider
- Data loss prevention defaults:
  - Never delete originals by default
  - If user opts in: require typed confirmation (“DELETE ORIGINALS”)

---

# 4) Security
- All API keys stored in Keychain
- Logs redact secrets automatically
- Least privilege permissions where possible
- App must clearly request Photos permission and explain why

---

# 5) Database Portability
- UI to reveal DB file in Finder
- Export DB snapshot + Import snapshot
- Must support seamless migration between Macs
- Import must validate schema version and run migrations

---

# 6) GUI — frontend-design Skill Requirements
You MUST:
- Provide a cohesive design system: spacing scale, typography scale, color tokens, icons
- Use native macOS patterns:
  - Sidebar navigation
  - Toolbar actions
  - Inspector panel
  - Table views with sorting
  - Context menus
- Excellent empty states, skeleton loading, error states
- Accessibility: VoiceOver labels, Dynamic Type where applicable, keyboard navigation
- Dark mode polish
- Micro-interactions: subtle animations for status changes
- Everything must look intentional (no default padding soup)

Deliver key screens:
1) Onboarding / Setup (Immich URL + API key test)
2) Photos Upload (scan, filters, queue)
3) Optimizer (rules, date/size, provider, review list)
4) Jobs (active/completed, per-job detail)
5) Dashboard (health, stats, costs)
6) Settings (keys, limits, schedules, presets, DB export/import)
7) Logs (search, export)

---

# 7) Testing — MUST BE THOROUGH
You must implement tests and run them.

## Unit tests (XCTest)
- DB migrations + schema versioning
- State machine transitions
- Retry/backoff scheduling (with jitter)
- Hashing correctness and stability
- Filter logic (start date + album/include/exclude rules)
- Provider interface mock tests (submit/poll/download/verify/finalize)
- MetadataEngine verify logic (detect mismatch)

## Integration tests (can be “developer-run”)
- ImmichClient against a mock server (URLProtocol) verifying:
  - idempotency keys used
  - retries don’t duplicate
  - replaceAsset only called after verify passes
- TranscodeEngine local ffmpeg:
  - transcode sample video -> output validated
- End-to-end “happy path” script:
  - scan small set of local test assets
  - upload -> verify -> mark done
  - transcode candidate -> verify -> replace
  - log export

## Manual verification checklist (must be included in README)
- Photos permission flows
- Start Date skip behavior
- Delete asset from Immich -> confirm app does NOT re-upload
- Force re-upload via drag/drop -> confirm it uploads and logs
- iCloud placeholder behavior
- Optimizer review list correctness
- Metadata preserved (spot-check with metadata viewer output)
- Bandwidth limit + maintenance window enforcement
- Keychain storage (no plaintext keys)

---

# 8) Build & Packaging (DMG)
You must add scripts:
- `scripts/build_release.sh`:
  - builds Release
  - embeds ffmpeg binaries correctly
  - produces `ImmichVault.app`
- `scripts/package_dmg.sh`:
  - creates a DMG with:
    - /Applications symlink
    - ImmichVault.app
    - README.txt
    - sample-export.json
- Output to `dist/ImmichVault.dmg`

---

# 9) Implementation Phases (Do in Order, No Skips)
## Phase 1 — Skeleton + UI Foundation
- Project setup + module folders
- Navigation shell + design system
- Settings + Keychain storage
- Immich connection test screen

Acceptance:
- App launches, looks premium, settings saved, Immich test works.

## Phase 2 — SQLite Index + State Machine + Logs
- DB schema + migrations
- state machine engine
- activity log + export
- DB reveal/export/import UI

Acceptance:
- Tests pass, DB migrations verified, export/import works.

## Phase 3 — Photos Scan + Filters + Queue UI
- PhotoKit integration
- start date + filters + explain-why-skipped
- iCloud placeholder detection + UI states

Acceptance:
- Scan results correct, skipped reasons accurate, UI polished.

## Phase 4 — Upload Engine (Idempotent + Never-Reupload)
- hashing + upload + verify
- never-reupload enforcement
- retries/backoff/resume
- per-item actions: upload now, mark never, force reupload

Acceptance:
- Delete from Immich does not cause reupload; force reupload works; tests pass.

## Phase 5 — Transcode Engine (Local ffmpeg first)
- candidate discovery view
- review list + stats
- local ffmpeg transcode + metadata copy + validation
- replaceAsset integration

Acceptance:
- Sample video transcodes, metadata validated, replace works safely.

## Phase 6 — Cloud Providers (A–D)
- provider contract
- CloudConvert + Convertio + FreeConvert implementations
- cost estimates + ledger
- health checks, timeouts, concurrency caps

Acceptance:
- Provider flows work (with mocked tests); UI shows costs and progress.

## Phase 7 — Rules Engine + Optimizer Mode + Scheduling
- rules builder UI
- optimizer mode background schedule (only while app running unless you add LaunchAgent)
- maintenance window + bandwidth enforcement

Acceptance:
- Rules correctly select candidates; scheduling works; safety rails enforced.

## Phase 8 — Final Polish + DMG
- performance pass, UI pass, accessibility pass
- README with setup and verification checklist
- DMG packaging scripts

Acceptance:
- `dist/ImmichVault.dmg` produced; manual checklist completed; all tests passing.

---

# 10) Output Expectations
When you finish, provide:
- Repo structure summary
- How to run tests (exact commands)
- Where DMG is located
- Any known limitations clearly stated (no hand-waving)

DO NOT claim completion until:
- All acceptance criteria met for all phases
- Tests passing
- DMG created
- Manual verification checklist executed and documented

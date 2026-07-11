# MANTA TODO — Next Steps

Status snapshot (2026-07-10): capture (LiDAR + photogrammetry), on-device
reconstruction, world alignment (fiducial / ICP / depth-assisted), EGI 128/256
layout loading, and CSV/SFP/ELP/BIDS export are all implemented and tested.
The electrode detection pipeline is still a mock. The critical path is real
detection → label assignment → validation on the 256-channel net.

## 1. Real electrode detection (critical path)

**Strategy: OCR-first.** Every disk on the HydroCel net is silk-screened with
its channel number (cardinals are black disks with white text; regulars are
white with a silver center). So we *read* labels with Vision text recognition
rather than solving anonymous point-cloud correspondence, and use the template
+ neighbor graph only to validate reads and infer occluded disks.

- [x] Back-projection geometry: `PinholeCamera` (project/unproject as exact
      inverses) in `MANTA/Services/PinholeCamera.swift`, unit-tested.
- [x] Multi-frame fusion: `ElectrodeObservationAggregator` (group by label,
      reject outliers, robust quality-weighted center, confidence from count +
      spread) in `MANTA/Services/ElectrodeObservationAggregator.swift`,
      unit-tested.
- [x] Redesign the `ElectrodeDetectionPipeline` protocol to take a
      `DetectionContext` (layout + observations + frame/image/depth provider)
      instead of just the layout; `MockElectrodeDetectionPipeline` kept for
      previews. In `MANTA/Services/ElectrodeDetectionContext.swift`.
- [x] Vision OCR stage: `VisionTextRecognizer` runs `VNRecognizeTextRequest`
      per frame; `ElectrodeLabelParser` maps pure-digit reads to `E{n}`
      (ignores 10-20 names, drops ambiguous reads). Portable
      `OCRElectrodeDetectionPipeline` orchestrates OCR -> back-project -> fuse
      -> annotate. Unit-tested via a stub recognizer.
- [x] Sample LiDAR depth at each read: `CaptureArtifactFrameProvider` +
      `DepthGridSampler` decode the stored depth/confidence, scale image px ->
      depth px, reject low-confidence, and back-project via `PinholeCamera`.
- [x] Wire the real pipeline into `ScanSessionViewModel.runInitialDetection`
      (default is `ElectrodeDetectionFactory.makeDefaultPipeline()`); review/
      export UI unchanged.
- [x] Synthetic scan harness: `SyntheticScanGenerator` projects the real
      templates through orbiting cameras, emits noisy/dropout/misread reads, and
      runs them through the real pipeline; `SyntheticScanHarnessTests` measures
      recovered-vs-truth error. Runs for **both 128 and 256 nets**
      (parametrized). Regression bed + threshold-tuning tool that needs no
      device. (Zero-noise: <1 mm, all read labels recovered. Realistic noise:
      mean <5 mm, >85% of channels recovered. Misreads rejected by fusion.)
- [ ] **Tune on a real capture (device work).** Confirm ARKit sign
      conventions in `PinholeCamera` against a real scan; tune
      `minimumTextHeight`, recognition orientation, and depth confidence
      threshold; measure how many of 256 disks read per scan. Use the
      synthetic harness to set aggregator thresholds before then.
- [ ] Associate each read with the disk *center* via contour/circle detection
      (currently uses the text bounding-box center as a proxy).
- [x] Validate reads with the neighbor graph: `ElectrodeNeighborValidator`
      compares detected inter-electrode distances to the coordinate template
      (rigid-invariant; only a global scale is estimated), flags geometrically
      inconsistent labels, and the builder marks them `.needsReview`. Wired into
      `OCRElectrodeDetectionPipeline` (`validatesNeighbors`). Works for 128 and
      256 (reads the active layout's graph/priors); unit-tested on both, and the
      synthetic harness confirms misreads surviving fusion are caught (zero
      gross errors left as confident detections).
- [ ] *Repair* (not just flag) validated misreads by reassigning to the correct
      label from neighbor context; interpolate fully-occluded disks. (Overlaps
      §2 template fit.)
- [ ] Fall back to ray-cast against the scene mesh where per-pixel depth is
      missing.
- [x] Convert fused world positions into the fiducial-anchored head frame for
      export — done in §3 (`HeadCoordinateFrame`, applied at export time once
      fiducials are placed). Detections remain ARKit world meters internally;
      the export layer converts to head-frame mm.

### How to capture and hand off a real session (for tuning/validation)

A single real scan unblocks the device-only work: confirming the `PinholeCamera`
sign conventions, tuning the OCR/depth thresholds, and verifying the raycast
fiducial placement + head-frame export. Since the subject library + in-app export
bundle landed, hand-off is now a share-sheet, no Xcode required.

**A. Record the scan on the LiDAR device (Pete's iPad Pro)**

1. Build/run MANTA on the iPad from Xcode (scheme MANTA, target the device, not
   the simulator — the simulator has no LiDAR/camera).
2. Tap **Subjects** ▸ enter a subject/MRN (optional) ▸ **Start** to create the
   session. In the sidebar set **Mode = Both** and **Layout = 256** (or 128).
3. Put the net on a head/phantom in good, even lighting (avoid glare on the
   disks — the printed numbers must be legible to the eye).
4. Tap **Start**, then **Auto Sample**. Slowly orbit the head ~30–60 cm away so
   every disk is seen sharply from a few angles; keep Tracking = "Normal" and
   Depth = "On". Aim for **40+ frames** (watch the "AR Samples" count).
5. (Optional but useful for §3) Arm **Nasion/LPA/RPA** under Fiducials and tap
   each landmark on the scan.
6. Tap **Stop Auto**, then **Pause**. (Running "Reconstruct & Fuse" is optional
   for detection tuning — the per-frame images + depth are what matter.)

The session auto-saves to the app's Documents folder as
`MANTA Sessions/<SESSION_UUID>/`:
  - `assets/camera_<obs>.jpg`            — RGB frame (OCR input)
  - `assets/depth_<obs>.f32.zlib`        — raw metric depth (back-projection)
  - `assets/confidence_<obs>.u8.zlib`    — depth confidence
  - `assets/depth_<obs>.png`             — depth preview (not needed by code)
  - `diagnostics.json`                   — per-frame camera intrinsics + poses
  - `session.json`                       — full session (labels, fiducials, …)
  - `reconstruction/` (only if you ran Reconstruct)

`diagnostics.json` + `session.json` + the `assets/` folder contain everything
the detector needs.

**B. Get the session off the iPad**

1. **In-app export (recommended, no Xcode).** Tap **Subjects**, swipe (or
   long-press) the session ▸ **Export** ▸ share the `<subject>_<timestamp>.zip`
   via AirDrop / Save to Files / Mail. The zip is the whole session folder.
2. **Files app / Finder (no Xcode).** File sharing is enabled, so: Files ▸ On My
   iPad ▸ **MANTA** ▸ `MANTA Sessions/<UUID>/` — long-press to compress/share, or
   drag it out via Finder ▸ iPad ▸ Files. Good for grabbing the raw folder
   without exporting.
3. **Xcode container download (fallback).** Xcode ▸ Window ▸ Devices and
   Simulators ▸ iPad ▸ **MANTA** ▸ ⋯ ▸ **Download Container…** ▸ show package
   contents ▸ `AppData/Documents/MANTA Sessions/<UUID>/`.

**C. Drop it where I can read it**

Unzip and copy the session folder into the repo under
`Fixtures/RealCaptures/<SESSION_UUID>/` (or tell me another path). Then I can
verify the back-projection against real depth and tune the OCR in one pass.

- [x] `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` = YES so
      `MANTA Sessions/` is browsable in the Files app / Finder file sharing.
      Added via a merged `MANTA-Info.plist` (repo root, `INFOPLIST_FILE`) since
      `UIFileSharingEnabled` isn't an `INFOPLIST_KEY_` build setting; kept at repo
      root to avoid the synchronized-group resource-copy collision.

## 2. Label assignment for the 256-channel net

- [x] Template fit (fill-missing): `ElectrodeTemplateFitter` fits the coordinate
      template to the confident detections via a **similarity** transform
      (rigid + uniform scale, Horn's method reusing `AbsoluteOrientation`) and
      predicts unread electrodes' positions, added as needs-review. Detected
      positions are never moved. Wired into `OCRElectrodeDetectionPipeline`
      (`fillsMissingFromTemplate`). Works for 128 and 256; unit-tested plus a
      front-only synthetic scan that fills back-of-head disks within ~1 cm.
- [ ] Upgrade the fit to **affine** (fall back from similarity) if real-head
      residuals are too high — same entry point in `ElectrodeTemplateFitter`.
- [x] Cap orientation + fit-reliability gate: `ElectrodeCapOrientation` fits the
      template to the confident detections (similarity), reports orientation +
      scale + residual, checks anchor spread and cardinal consistency, and
      exposes `isReliable`. `fillMissing` only fills when the fit is reliable, so
      a sparse/clustered scan doesn't emit garbage predicted labels. Tested on
      128 and 256 (well-spread → reliable & recovers transform; clustered →
      unreliable → fill declined). NB: OCR-first means orientation is a
      robustness/validation aid, not needed to assign labels.
- [ ] Surface orientation/reliability in the UI (e.g. warn when the fit is
      unreliable and fills were skipped) and use placed fiducials (nasion/LPA/
      RPA) as additional anchors once §3 wires world-frame fiducial placement.
- [ ] Flag ambiguous/missing electrodes (occluded by hair, low confidence)
      for the manual review flow; target ≥240/256 auto-labeled on a good scan.
      (Filled electrodes are already surfaced as needs-review.)

## 3. Fiducial workflow

- [x] Head coordinate frame: `HeadCoordinateFrame` builds a right-handed RAS
      frame from nasion/LPA/RPA (origin = LPA/RPA midpoint, +x→RPA, +y→nasion,
      +z up) and converts a session's electrodes + fiducials into it, scaled to
      **millimeters**. Unit-tested incl. the key invariance-to-world-pose
      property and degenerate rejection.
- [x] Exports use the head frame: `ScanSessionViewModel.exportSession` applies
      the conversion when all three fiducials are placed (else falls back to raw
      world coords). Low-level `ElectrodeExporters` stay frame-agnostic. UI shows
      a "Head frame" badge when active.
- [x] In-app live-scan placement: `ARScanViewModel.raycastToWorld` +
      `LiveARScanView` tap gesture + `armFiducialPlacement`/`handleScanTap`;
      `FiducialControlsView` arms Nasion/LPA/RPA and tapping the scan places the
      world-frame landmark. Removed the old template-frame placeholder seeding
      that would otherwise corrupt the head-frame conversion.
- [ ] **Not yet exercised on device** — the raycast/tap placement and the
      head-frame badge compile and are wired, but need a real LiDAR device to
      verify (simulator has no AR raycast).
- [ ] Per-format units/axes: currently mm + RAS for all formats. Confirm each
      consumer (MNE `.sfp`, BESA `.elp`, BIDS) wants mm vs m and the axis order;
      ship a BIDS `_coordsystem.json` declaring units + the fiducial RAS frame.
- [ ] Keep the model-space fiducial picker (`ModelFiducialPickerView`, used for
      photogrammetry alignment) consistent with live placement.

## 4. Validation (needed before lab use)

- [ ] Accuracy study vs. ground truth: same net digitized with an existing
      system (e.g., Polhemus/Geoscan) or measured on a phantom head with
      known marker positions. Report mean/max localization error; target
      <5 mm mean.
- [ ] Repeatability: repeated scans of the same subject/session, same-day.
- [ ] Compare the three alignment strategies (fiducial vs ICP vs
      depth-assisted) on real scans and pick a default.
- [ ] Test across conditions: hair color/volume, lighting, gel sheen, subject
      motion, iPad vs iPhone LiDAR.

## 5. Capture & subject library (defer processing / reprocess later)

Goal: capture with the patient in the room, then run detection/reconstruction
later — and re-run improved models on old captures. The raw capture already
supports this; what's missing is subject identity, reloadable sessions, and a
browser.

**Already true (no work needed):**
- Every frame is persisted per session to `MANTA Sessions/<UUID>/`: RGB
  (`camera_*.jpg`), lossless metric depth (`depth_*.f32.zlib`), depth
  confidence (`confidence_*.u8.zlib`), and per-frame intrinsics + world pose
  (`diagnostics.json`). Sessions are UUID-keyed and timestamped (`createdAt`).
- Detection reads from these persisted artifacts (`CaptureArtifactFrameProvider`),
  not the live AR session, so capture and detection/reconstruction are already
  decoupled and re-runnable on old data.

**To build:**
- [x] Subject identity on `ScanSession`: editable `subjectLabel` (name/MRN)
      paired with the immutable `createdAt`. Naming is structural — `timestampName`
      (`yyyy-MM-dd_HHmmss`) is always derived from `createdAt`; `displayName`
      pairs label + timestamp; `fileSafeName` keeps the timestamp at the end.
      The timestamp can't be stripped by renaming. Unit-tested.
- [x] Persist the full `ScanSession` (Codable) as `session.json` next to the
      assets (`CaptureArtifactStore.writeSession/loadSession`, exact numeric-date
      round trip). Saved after sampling, detection, review, alignment, rename.
- [x] Load path: `ScanSessionViewModel.openSession(id:)` rehydrates a saved
      session; `startNewSession(subjectLabel:)` begins a fresh (unsaved-until-
      first-action) one.
- [x] Session library UI (`SessionLibraryView`): browse subjects sorted by
      date/time (newest first), each row leading with the capture date/time and
      subject label; open, rename (timestamp preserved), delete; "Subjects"
      button in the header. Backed by `listSessionSummaries()`. Supersedes the
      old "session management" bullet.
- [ ] Re-run detection / reconstruction on a loaded session — the pipeline reads
      persisted artifacts, so wire explicit "Re-detect" / "Re-reconstruct"
      actions (currently detection re-runs via the existing button on whatever
      session is open).
- [ ] Stamp each detection/reconstruction run with a pipeline **version** so
      reprocessing keeps history instead of silently overwriting; lets you
      compare an old scan under old vs improved models.
- [x] In-app **export session bundle**: `CaptureArtifactStore.exportSessionBundle`
      zips the whole session folder (via `NSFileCoordinator .forUploading`, no
      dependency) to `<fileSafeName>.zip`; the library exposes Export (swipe +
      context menu) and presents a share sheet (AirDrop/Files/Mail). Store logic
      unit-tested. Still pair with `UIFileSharingEnabled` (§1) for Files-app
      access without sharing.
- [ ] Storage view + archival policy: raw depth + RGB run tens of MB per
      session; surface per-subject usage and allow offloading raw frames while
      keeping results. Keep raw frames whenever possible — they are what makes
      reprocessing under better models possible.
- [ ] Decide whether to auto-present the library on launch (currently opened via
      the header "Subjects" button; app still boots into a fresh session).

**Note:** the model + persistence layer is unit-tested; the SwiftUI library flow
compiles and is wired but has not been exercised on-device/simulator yet.

## 6. Capture UX hardening

- [ ] Guided capture: coverage feedback (which head regions still need
      frames), motion-blur/tracking-quality gating before a frame is sampled,
      auto-sampling cadence instead of manual taps.
- [ ] Progress/failure UI for the (slow) on-device photogrammetry step;
      consider the open decision of offloading dense reconstruction to a Mac.

## 7. Housekeeping

- [ ] Add a CLAUDE.md / README covering build, test, and device requirements
      (LiDAR-equipped iPad/iPhone Pro, iOS 17+ for Object Capture).
- [ ] CI: run the pure-Swift test targets (layout loading, alignment,
      exporters) on every push.
- [ ] Decide MRI/scanner transform source (manual fiducials vs imported MRI
      scalp surface) — affects export schema, worth settling before the
      first lab pilot.

## 8. macOS receiver app (hardened-environment hand-off)

Many hospitals block AirDrop via MDM — and usually the same policy also blocks
AWDL (so **Multipeer Connectivity is out too**), cloud egress, and often
client-to-client traffic on the corporate Wi-Fi (client/AP isolation) and even
Bluetooth/USB-data. So the robust designs use a **link we create between the two
devices**, not the hospital network or peer-to-peer radios.

Goal: a small **"MANTA Receiver" macOS app** that receives exported session
bundles (the `<subject>_<timestamp>.zip` from §5) without AirDrop/cloud.

### Transport options (ranked for a hardened site)

- **USB-C Ethernet, point-to-point (recommended primary).** iPad USB-C→Ethernet
  adapter, cable to the Mac. Link-local `169.254.x.x` self-assigns; no radios, no
  infrastructure, most IT-acceptable. ~1 Gbps.
- **USB data channel (usbmuxd / peertalk).** Same channel Xcode uses; Mac↔iOS
  over the cable, no network. Needs a Mac-side helper.
- **Mac-hosted private Wi-Fi + HTTP.** Mac Internet Sharing; iPad joins; upload to
  the Mac. Sidesteps hospital Wi-Fi but may trip rogue-AP policies.
- **Save-to-Files → USB flash drive (zero code).** Export zip → external drive →
  walk it over. iPadOS already writes to external drives; may solve some sites
  today with no build at all.
- **Bluetooth LE — discovery/handshake only, NOT bulk.** BLE realistically moves
  tens–hundreds of MB in many minutes; classic Bluetooth speeds aren't reachable
  from iOS public APIs. Mirror AirDrop: use BLE to discover, hand bulk to
  Wi-Fi/USB. Avoid as the sole bulk transport.
- **Shared-LAN HTTP.** Simplest, but corporate client isolation usually kills it.
- **Optical/QR chain.** Only viable for a tiny manifest, not raw frames.

### Recommended architecture

- [ ] macOS **MANTA Receiver** app: `Network.framework` `NWListener` HTTP server
      that saves incoming bundles to a chosen folder. Same server code works over
      USB-C Ethernet *or* a Mac-hosted Wi-Fi unchanged.
- [ ] **Discovery:** advertise `_manta._tcp` via Bonjour/mDNS; iPad finds it with
      `NWBrowser`. Fallback: Receiver shows its IP + a 6-digit code; type the IP
      on the iPad when mDNS is filtered.
- [ ] **Pairing + security (non-optional — bundles contain PHI: MRN + head
      imagery):** short PIN shown on the Mac, entered on the iPad, authenticates
      the POST and pins a self-signed TLS cert. Receiver logs what it received
      (audit).
- [ ] **Integrity/resume:** manifest with SHA-256; chunked upload so a dropped
      link resumes instead of restarting a large transfer.
- [ ] iOS side: **"Send to Receiver"** action next to Export — reuses the zip we
      already build, browses `_manta._tcp`, uploads. (~150 lines.)

### Bigger payoff: shared detection core → Mac doubles as a reprocessing station

- [ ] Factor the pure-Swift detection core (`PinholeCamera`,
      `ElectrodeObservationAggregator`, `ElectrodeDetectionContext`,
      `ElectrodeNeighborValidator`, `ElectrodeTemplateFitter`,
      `ElectrodeCapOrientation`, `HeadCoordinateFrame`, `HydroCelLayoutLoader`,
      exporters) into a **shared Swift package**. It already has no ARKit
      dependency and compiles for macOS, so the Receiver can unzip and **re-run
      detection/export on the Mac** — directly serving the §5 "reprocess old
      captures under better models" goal.

### Project structure: one project, shared package, macOS target

Decision: keep **one repo / one `MANTA.xcodeproj`** and add the receiver as a
**second app target**, not a separate project — because the shared-core goal
above makes a cross-project package reference (workspace/submodule) needless
friction. Not a Multiplatform single target: the receiver is a *different* app,
not the iOS app on macOS.

Target structure:
```
MANTA.xcodeproj
├─ MANTACore  (local Swift Package)   ← pure, platform-agnostic core
├─ MANTA          target  (iOS app)   → depends on MANTACore
└─ MANTA Receiver target  (macOS app) → depends on MANTACore
```

Why a package (not shared target file-membership): clean module boundary, and its
tests run on the **Mac host directly (`swift test`)** — much faster than the
current xcodebuild-on-simulator loop. App-specific code (ARKit/RealityKit
capture, SwiftUI views) stays in the app targets; Foundation-only IO like
`CaptureArtifactStore` can move into the package so the Receiver reuses the same
session layout.

Trade-offs accepted: bigger pbxproj + more schemes, and a bad shared change can
touch both apps — worth it for zero-friction code sharing. (A separate project
would only win if the receiver were owned/released independently.)

Incremental migration (each step compiles on its own):
- [x] Create the `MANTACore` local Swift package and wire the iOS app + test
      targets to depend on it (hand-edited pbxproj:
      `XCLocalSwiftPackageReference` + `XCSwiftPackageProductDependency`). Done
      entirely outside Xcode; `xcodebuild` resolves it as `MANTACore @ local`.
- [~] Move the pure files one cluster at a time.
      **Cluster 1 done:** `PinholeCamera`, `ElectrodeObservationAggregator`
      (+ `LabeledDetection`, `AggregatedElectrode`).
      **Cluster 2 done:** `WorldAlignment` (`AbsoluteOrientation`, ICP,
      `WorldAlignmentSolver`/`Input`/`Result`, `WorldAlignmentStrategy`,
      `AlignmentSeed`) — self-contained simd math; `CoarseAlignment`/`ICP`/
      `JacobiEigen` kept internal (package tests use `@testable import
      MANTACore`); made `WorldAlignmentResult: Sendable` for Swift 6 strict
      concurrency. Full app build + `MANTATests` green; package `swift test` = 18.
      **Cluster 3 done:** `ModelPointCloudLoader` (ModelIO + simd, no model
      types); its only consumer already imported `MANTACore`.
      **Everything else is blocked on the models pass — see Cluster 4 below.**
- [ ] **Cluster 4: the models pass** (next session — the big one).
- [x] Migrate the moved cluster's tests into the package test target
      (`import MANTACore`) — they run on the **Mac host via `swift test`** in
      ~1 ms each, no simulator.
- [ ] Add the macOS **MANTA Receiver** app target (empty SwiftUI app) to the
      existing project.
- [ ] Build the Receiver against `MANTACore` so it can reprocess captures.
- [ ] Ensure ARKit/RealityKit are linked only by the iOS target (the package
      split enforces this naturally; `MANTACore` is already ARKit/UIKit-free).

macOS target needs its own bundle ID, App Sandbox entitlements (incoming network
connections + local-network usage description for Bonjour), and notarization —
independent of the iOS app.

### Cluster 4 plan: the models pass (do this next)

Goal: move the foundational model types into `MANTACore` so the remaining
algorithm files can follow. This is the widely-referenced, higher-risk step —
**start with a git commit checkpoint** so it's easy to revert.

Move into `MANTACore`:
- `MANTA/Models/ScanModels.swift` — `Coordinate3D`, `Coordinate2D`,
  `ElectrodeRole`, `AnnotationState`, `ElectrodeAnnotation`, `FiducialKind`,
  `FiducialAnnotation`, `ElectrodeDefinition`, `CaptureMode`, `ElectrodeLayout`,
  `ScanSession`.
- `MANTA/Models/CaptureModels.swift` — `ImageResolution`, depth/confidence
  format+summary structs, `CaptureObservation`. (`LiveScanStatus` is used by the
  ARKit view models — consider leaving it app-side or moving it too; it's plain
  data.)

Then, in the same pass, move the now-unblocked algorithm files:
`ElectrodeDetectionContext` (parser/builder/pipeline), `ElectrodeNeighborValidator`,
`ElectrodeTemplateFitter`, `ElectrodeCapOrientation`, `HeadCoordinateFrame`,
`HydroCelLayoutLoader` (ships the layout XML/JSON — either add them as package
resources via `.copy`, or keep `Bundle.main` loading and leave the loader
app-side for now), and `ElectrodeExporters`.

Mechanics per type (same recipe as Clusters 1–3):
- Make the type + the members used across the module `public`; add `public init`s
  where app code constructs them (memberwise inits are internal by default).
- Mark value types used in `static let`/globals `Sendable` (Swift 6 strict
  concurrency in the package — this bit us with `WorldAlignmentResult`).
- Add `import MANTACore` to every app/test file that references a moved type
  (expect this to touch most of `MANTA/` and `MANTATests/`).
- Move each type's tests into `Tests/MANTACoreTests` (`import MANTACore`, or
  `@testable import MANTACore` if they reach internals); keep app-only tests in
  `MANTATests`.

Verify: `cd MANTACore && swift test`, then the full app
`xcodebuild test … -only-testing:MANTATests`. `ScanSession` already depends on the
moved `WorldAlignmentStrategy`/`AlignmentSeed`, so that edge is ready.

### Effort / notes

- Receiver v1 (HTTP + Bonjour + PIN + save-to-folder): a few hundred lines,
  ~1–2 days; notarize for distribution.
- iOS "Send to Receiver": ~half a day (reuses the zip).
- Shared-package refactor: ~1 day, low risk (code already portable).

### Open questions that pick the transport

- [ ] Is **USB data** (not just power) allowed iPad↔Mac at the worst-case site?
- [ ] Are **USB flash drives** allowed? (If yes, sneakernet may need no build.)
- [ ] Can IT **deploy/notarize a Mac app** on those machines?
- [ ] Confirm the bundle counts as **PHI** for compliance (assume yes) → drives
      the encryption/audit requirements above.

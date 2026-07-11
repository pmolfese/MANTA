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
- [ ] **Tune on a real capture (device work).** Confirm ARKit sign
      conventions in `PinholeCamera` against a real scan; tune
      `minimumTextHeight`, recognition orientation, and depth confidence
      threshold; measure how many of 256 disks read per scan.
- [ ] Associate each read with the disk *center* via contour/circle detection
      (currently uses the text bounding-box center as a proxy).
- [ ] Validate/repair reads with the `sensorLayout_256.xml` neighbor graph
      (catch OCR misreads); flag or interpolate occluded disks.
- [ ] Fall back to ray-cast against the scene mesh where per-pixel depth is
      missing.
- [ ] Convert fused world positions into the fiducial-anchored head frame for
      export (depends on section 3; detections are currently in ARKit world
      meters).

### How to capture and hand off a real session (for tuning/validation)

A single real scan unblocks the device-only work above (confirming the
`PinholeCamera` sign conventions and tuning the OCR/depth thresholds). Do this:

**A. Record the scan on the LiDAR device (Pete's iPad Pro)**

1. Build/run MANTA on the iPad from Xcode (scheme MANTA, target the device, not
   the simulator — the simulator has no LiDAR/camera).
2. In the sidebar set **Mode = Both** and **Layout = 256**.
3. Put the 256 net on a head/phantom in good, even lighting (avoid glare on the
   disks — the printed numbers must be legible to the eye).
4. Tap **Start**, then **Auto Sample**. Slowly orbit the head ~30–60 cm away so
   every disk is seen sharply from a few angles; keep Tracking = "Normal" and
   Depth = "On". Aim for **40+ frames** (watch the "AR Samples" count).
5. Tap **Stop Auto**, then **Pause**. (Running "Reconstruct & Fuse" is optional
   for detection tuning — the per-frame images + depth are what matter.)

Each sampled frame writes, into the app's Documents folder:
`MANTA Sessions/<SESSION_UUID>/`
  - `assets/camera_<obs>.jpg`            — RGB frame (OCR input)
  - `assets/depth_<obs>.f32.zlib`        — raw metric depth (back-projection)
  - `assets/confidence_<obs>.u8.zlib`    — depth confidence
  - `assets/depth_<obs>.png`             — depth preview (not needed by code)
  - `diagnostics.json`                   — per-frame camera intrinsics + poses
  - `reconstruction/` (only if you ran Reconstruct)

`diagnostics.json` plus the `assets/` folder together contain everything the
detector needs, so hand off the **entire session folder**.

**B. Get the session folder off the iPad**

Pick whichever is available; option 1 is the most reliable:

1. **Xcode container download (recommended).**
   Xcode ▸ Window ▸ Devices and Simulators ▸ select the iPad ▸ under Installed
   Apps select **MANTA** ▸ the gear/"⋯" ▸ **Download Container…** ▸ save the
   `.xcappdata` bundle. Right-click it ▸ Show Package Contents ▸
   `AppData/Documents/MANTA Sessions/<SESSION_UUID>/` is the folder.

2. **Files app (only if file sharing is enabled).**
   Requires `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` = YES
   in Info.plist (not currently set — see the note below). If enabled: Files ▸
   On My iPad ▸ MANTA ▸ compress `MANTA Sessions` ▸ share the zip.

3. **Finder (macOS).** With file sharing enabled (as above), connect the iPad ▸
   Finder ▸ iPad ▸ Files tab ▸ MANTA ▸ drag the folder out.

**C. Drop it where I can read it**

Copy the session folder (or its zip) into the repo under
`Fixtures/RealCaptures/<SESSION_UUID>/` (or tell me another path). Then I can
verify the back-projection against real depth and tune the OCR in one pass.

- [ ] (Optional, to enable option B/3) Add `UIFileSharingEnabled` and
      `LSSupportsOpeningDocumentsInPlace` = YES to the app Info.plist so sessions
      are reachable from the Files app without Xcode.

## 2. Label assignment for the 256-channel net

- [ ] Estimate cap orientation from fiducials (nasion/LPA/RPA) + cardinal
      electrode detections.
- [ ] Non-rigid or affine fit of the EGI 256 coordinate prior
      (`coordinates_256.xml`) to the detected cloud; assign labels by nearest
      correspondence (Hungarian/greedy with neighbor-graph consistency from
      `sensorLayout_256.xml`).
- [ ] Flag ambiguous/missing electrodes (occluded by hair, low confidence)
      for the manual review flow; target ≥240/256 auto-labeled on a good scan.
- [ ] Unit-test label assignment against synthetic perturbations of the
      256 template (jitter, dropout, partial coverage).

## 3. Fiducial workflow

- [ ] In-app placement of nasion/LPA/RPA on the live scan (ray-cast tap on
      the mesh) in addition to the existing model-space picker.
- [ ] Convert exports into a fiducial-anchored head coordinate system (RAS or
      ALS per format convention); decide mm vs m per format and document it.

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

## 5. Capture UX hardening

- [ ] Guided capture: coverage feedback (which head regions still need
      frames), motion-blur/tracking-quality gating before a frame is sampled,
      auto-sampling cadence instead of manual taps.
- [ ] Session management: resume, delete, storage budget for artifacts
      (raw depth + snapshots grow quickly at 256 channels).
- [ ] Progress/failure UI for the (slow) on-device photogrammetry step;
      consider the open decision of offloading dense reconstruction to a Mac.

## 6. Housekeeping

- [ ] Add a CLAUDE.md / README covering build, test, and device requirements
      (LiDAR-equipped iPad/iPhone Pro, iOS 17+ for Object Capture).
- [ ] CI: run the pure-Swift test targets (layout loading, alignment,
      exporters) on every push.
- [ ] Decide MRI/scanner transform source (manual fiducials vs imported MRI
      scalp surface) — affects export schema, worth settling before the
      first lab pilot.

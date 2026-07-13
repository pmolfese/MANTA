# MANTA Roadmap

Last updated: 2026-07-11.

This file is the prioritized queue. Completed design context lives in
[Architecture](ARCHITECTURE.md), the proposed interchange contract in
[Capture format](CAPTURE_FORMAT.md), and the evidence plan in
[Validation](VALIDATION.md). Privacy classification and safeguards are in
[Data privacy](DATA_PRIVACY.md). The repository overview and build instructions
are in the root [README](../README.md).

## Now: versioned capture interchange

- [ ] Confirm real-device RGB orientation, camera transform, intrinsics, and
  depth registration conventions before freezing schema 1.0.0.
- [ ] Resolve the open version-1 decisions listed in `CAPTURE_FORMAT.md`.
- [x] Define shared coordinate-frame, unit, identifier, and persisted capture
  types in `MANTACore`. Solved/head coordinates are canonically millimeters;
  capture remains meters; EGI layout priors declare centimeters; `LiveScanStatus`
  remains app-side. Required spatial metadata deliberately has no pre-release
  legacy decoding fallback.
- [~] Add JSON Schemas for manifest, capture, subject, layout, run, and review;
  manifest, capture, and change-log schemas are in place.
- [~] Add minimal 128/256 fixtures plus invalid/corrupt/malicious fixtures;
  the minimal 128 fixture and programmatic corruption cases are in place.
- [x] Implement read-only logical-directory bundle loading and validation in
  `MANTACore`.
- [x] Add bounded `.manta` archive extraction with traversal, collision,
  symlink, CRC, structural, and resource-limit defenses followed by logical
  bundle validation.
- [x] Define immutable snapshot lineage, required `log_manta.json` validation,
  and PHI-free UTC `yyyyMMdd_HHmmss.manta` filenames.
- [x] Implement deterministic encoding, hashing, validation, immutable archive
  creation, and bundle finalization.
- [x] Make iOS **Export** finalize the current working session as `.manta`; keep
  the most recently exported bundle ID so subsequent exports form a logged
  lineage without exposing Save As in the iOS UI.
- [x] Switch iOS export to versioned `.manta` bundles.
- [ ] Add immutable processing-run provenance and separate user reviews.

## Next: finish the shared core

- [x] Create the local `MANTACore` package and wire the application/test targets.
- [x] Move and test `PinholeCamera` and `ElectrodeObservationAggregator`.
- [x] Move and test world alignment and point-cloud loading.
- [x] Move persisted domain/capture models after the format vocabulary is set;
  temporary app type aliases keep the source refactor incremental without
  promising persisted-format compatibility.
- [x] Move neighbor validation, template fitting, cap orientation, head-frame
  conversion, layout parsing/loading, portable detection orchestration, and
  typed SFP/ELP/BIDS/EGI exporters into `MANTACore`. Bundle/resource discovery,
  Vision, CoreGraphics images, and artifact decoding remain application adapters.
- [x] Add hardened portable `.manta` archive extraction/import while keeping
  iOS-only camera and depth encoding in the application target.
- [ ] Keep ARKit, RealityKit, UIKit, and SwiftUI out of solver targets.
- [ ] Run `MANTACore` tests in CI on every push.

## Critical empirical work

- [ ] Before participant use, document and verify encrypted storage, controlled
  access, approved transfer, backup, retention/deletion, and incident-response
  controls for raw working sessions and `.manta` bundles.
- [ ] Treat raw captures as potentially identifiable; do not claim anonymization
  or de-identification based only on removing names or using PHI-free filenames.

- [ ] Capture and retain an approved real-device convention fixture.
- [ ] Tune Vision orientation, `minimumTextHeight`, depth confidence, and fusion
  thresholds on real 128- and 256-channel scans.
- [ ] Refine OCR regions to disk centers with contour/circle detection.
- [ ] Replace single-pixel depth lookup with robust neighborhood sampling.
- [ ] Add scene-mesh raycast fallback when per-pixel depth is absent.
- [ ] Repair geometrically validated label errors; preserve correction evidence.
- [ ] Surface fit orientation, reliability, missingness, and inferred status in
  the review UI.
- [ ] Exercise live fiducial placement and model-space fiducials on device.

## macOS receiver

- [x] Add a separate SwiftUI macOS receiver target to `MANTA.xcodeproj`.
- [~] Import, validate, and inspect local `.manta` files before adding networking;
  local file import now preserves the source archive in app-managed storage,
  performs hardened extraction/validation, and shows capture metadata, saved
  camera frames with projected annotations, an interactive LiDAR/ObjectCapture
  surface with solution markers, and the manifest inventory. A persistent
  import library and depth/confidence previews remain.
- [ ] Keep imported `.manta` snapshots read-only on macOS and expose **Save As…**
  for derived MANTA snapshots.
- [ ] Run offline detection, reconstruction, comparison, review, and export using
  `MANTACore`.
- [ ] Add point-to-point USB-C Ethernet receipt using Network.framework.
- [ ] Add Bonjour discovery plus manual address/code fallback.
- [ ] Threat-model and implement TLS authentication, resumable chunks, duplicate
  handling, integrity validation, and PHI-safe audit records.
- [ ] Confirm site policy for USB data, flash drives, app deployment/notarization,
  local networking, and PHI handling.

## Detection and capture UX

- [ ] Add explicit re-detect/reconstruct actions for loaded sessions.
- [~] Guided capture coverage feedback. Live azimuth/elevation sector counts and
  participant-release coverage advisories are implemented; a graphical head map
  awaits real captures.
- [~] Score blur, exposure, pose novelty, mapping, depth coverage, and confidence
  for every saved frame. Thresholds are advisory until pilot data are available;
  hard rejection remains intentionally deferred.
- [~] Add progress, cancellation, and failure UI for reconstruction. Progress
  and failures exist; skipped samples, automatic downsampling, ordering,
  sensitivity, detail, and input count are now persisted.
- [ ] Add storage usage and archival/offload policy while retaining raw inputs.
- [ ] Decide whether the subject library opens by default.
- [ ] Consider affine template fitting only if real-head similarity residuals
  justify it.

## Validation before lab use

- [ ] Complete the independent ground-truth accuracy study.
- [ ] Complete same-day and cross-device repeatability studies.
- [ ] Compare fiducial, ICP, and depth-assisted alignment on real captures.
- [ ] Test lighting, hair, glare/gel, motion, operator, and device conditions.
- [ ] Confirm units/axes for CSV, MNE SFP, BESA ELP, and BIDS; add BIDS
  `_coordsystem.json`.
- [~] Add EGI electrode-coordinate XML export. A real `coordinates_mff` XML/SFP
  pair, conversion metadata, label mappings, centimeter convention, and
  regression tests are in place; exporter implementation remains.
- [ ] Decide the MRI/scanner transform source before the first lab pilot.

## Deferred product decisions

- [ ] Decide whether direct USB data or USB flash drive is the required fallback.
- [ ] Define deployment, signing, sandbox, notarization, and update policy for the
  macOS receiver.
- [ ] Define retention, de-identification, encryption-at-rest, access-control,
  and audit policy for captures containing PHI.

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
- [x] Preserve one immutable, validated RAW archive and one mutable directory-backed
  PROCESSED package. Reconstruction, alignment, fiducial review, and later solves
  replace only their changed assets/JSON and append to a lightweight audit log.
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

## Reflective Assist and mesh-raycast localization

- [ ] Prototype optional Reflective Assist capture using paired ambient and
  flash-illuminated AR frames; retain the flash frame only as detection evidence
  and explicitly exclude it from photogrammetry reconstruction inputs.
- [ ] Verify on target iOS 26 LiDAR devices that customized high-resolution AR
  capture fires the flash as requested, preserves usable camera intrinsics and
  pose, and determine whether the returned frame includes scene depth.
- [ ] Persist each ambient and flash image as a separately calibrated observation
  linked by a capture-group ID, with illumination, image purpose, flash-requested,
  and flash-fired provenance.
- [ ] Collect normal/flash pairs from real HydroCel 128- and 256-channel nets
  under varied lighting, range, viewing-angle, hair, gel/moisture, and motion
  conditions before selecting detection thresholds.
- [ ] Detect flash-responsive disk candidates using exposure-normalized local
  contrast, connected components, and plausible disk geometry; measure false
  responses from cables, hair, skin, moisture, glasses, and nearby equipment.
- [ ] Use flash response to seed the electrode region, then refine the physical
  disk center from the ambient image using rim/contour or ellipse fitting rather
  than treating the OCR text center as the electrode center.
- [ ] Add `PinholeCamera.ray(through:)` so any calibrated image pixel can produce
  a world-space camera origin and direction.
- [ ] Add a reusable electrode spatial localizer that tries robust depth-neighborhood
  sampling first, falls back to the nearest LiDAR mesh intersection, and records
  the selected method and confidence with every result.
- [ ] Use mesh raycasting to localize flash detections when the flash observation
  has no usable depth, and associate ambient OCR and flash disk evidence in ARKit
  world space instead of requiring exact pixel registration between the pair.
- [ ] Reject or reduce confidence for reflective candidates whose rays miss the
  reconstructed head, land outside the cap region, disagree materially with
  synchronized depth, or intersect the surface at a grazing angle.
- [ ] Define whether exported electrode coordinates represent the visible disk
  center, sensor housing center, scalp contact, or projection onto the head
  surface; validate any surface-normal offset on real hardware before applying it.
- [ ] Separate position provenance from label provenance so a directly observed
  disk with a geometrically inferred identity remains distinguishable from both
  an OCR-labeled observation and a wholly template-predicted electrode.
- [ ] Fuse repeated raycast hits across views, favoring sharp frames, strong
  reflection evidence, high-confidence depth, and near-normal surface incidence.
- [ ] Benchmark the existing brute-force triangle raycaster for full-session
  electrode detection; add a cached BVH/AABB acceleration structure if candidate
  count and mesh size prevent responsive live or offline solving.
- [ ] Add an operator-controlled Reflective Assist toggle and conservative flash
  cadence, capability/thermal fallback, exposure-settling behavior, and participant
  comfort guidance; do not implement continuous strobing.
- [ ] Validate the feature by reporting disk precision/recall, center error,
  directly localized electrode yield, final 3D error, and any effect on capture
  time, thermal state, participant comfort, and reconstruction quality.

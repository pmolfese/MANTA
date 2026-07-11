# MANTA Roadmap

Last updated: 2026-07-11.

This file is the prioritized queue. Completed design context lives in
[Architecture](ARCHITECTURE.md), the proposed interchange contract in
[Capture format](CAPTURE_FORMAT.md), and the evidence plan in
[Validation](VALIDATION.md). The repository overview and build instructions are
in the root [README](../README.md).

## Now: versioned capture interchange

- [ ] Confirm real-device RGB orientation, camera transform, intrinsics, and
  depth registration conventions before freezing schema 1.0.0.
- [ ] Resolve the open version-1 decisions listed in `CAPTURE_FORMAT.md`.
- [ ] Define shared coordinate-frame, unit, identifier, and persisted capture
  types in `MANTACore`; keep `LiveScanStatus` app-side.
- [ ] Add JSON Schemas for manifest, capture, subject, layout, run, and review.
- [ ] Add minimal 128/256 fixtures plus invalid/corrupt/malicious fixtures.
- [ ] Implement read-only bundle loading and validation in `MANTACore`.
- [ ] Implement deterministic encoding, hashing, and bundle finalization.
- [ ] Add a legacy importer for the current `session.json` folder/ZIP format.
- [ ] Switch iOS export to versioned `.manta` bundles.
- [ ] Add immutable processing-run provenance and separate user reviews.

## Next: finish the shared core

- [x] Create the local `MANTACore` package and wire the application/test targets.
- [x] Move and test `PinholeCamera` and `ElectrodeObservationAggregator`.
- [x] Move and test world alignment and point-cloud loading.
- [ ] Move persisted domain/capture models after the format vocabulary is set.
- [ ] Move neighbor validation, template fitting, cap orientation, head-frame
  conversion, layout loading, exporters, and portable detection orchestration.
- [ ] Separate portable artifact decoding from iOS-only capture encoding and ZIP
  presentation.
- [ ] Keep ARKit, RealityKit, UIKit, and SwiftUI out of solver targets.
- [ ] Run `MANTACore` tests in CI on every push.

## Critical empirical work

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

- [ ] Add a separate empty SwiftUI macOS target to `MANTA.xcodeproj`.
- [ ] Import, validate, and inspect local `.manta` files before adding networking.
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
- [ ] Guided capture coverage feedback.
- [ ] Reject blurred frames and poor tracking before sampling.
- [ ] Add progress, cancellation, and failure UI for reconstruction.
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
- [ ] Decide the MRI/scanner transform source before the first lab pilot.

## Deferred product decisions

- [ ] Decide whether direct USB data or USB flash drive is the required fallback.
- [ ] Define deployment, signing, sandbox, notarization, and update policy for the
  macOS receiver.
- [ ] Define retention, de-identification, encryption-at-rest, access-control,
  and audit policy for captures containing PHI.

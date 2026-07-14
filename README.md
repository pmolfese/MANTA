# MANTA

<p align="center">
  <img src="Docs/Assets/MANTA-Icon.png" alt="MANTA icon: a manta ray carrying an EEG net" width="240">
</p>

MANTA is a research toolkit for capturing and processing EGI HydroCel 128- and
256-channel EEG nets. It combines an iPhone/iPad capture app, a macOS receiver,
and a shared Swift package to preserve calibrated RGB-D evidence, reconstruct a
head surface, locate electrodes and fiducials, review the result, and export
coordinates for downstream analysis.

MANTA is work in progress. It has not been validated for clinical use, and raw
captures may contain identifiable imagery or PHI.

## What is implemented

### iPhone and iPad capture

- LiDAR, photogrammetry, and combined capture modes with live coverage and
  quality guidance.
- Persisted lossless RGB, depth, confidence, camera intrinsics, camera poses,
  device metadata, full LiDAR meshes, optional head crops, and reconstruction
  diagnostics.
- EGI HydroCel 128/256 layouts plus a head-mesh-only workflow.
- OCR-first electrode detection, multi-frame depth fusion, neighbor validation,
  template fitting for missing observations, and explicit measured versus
  predicted electrode state.
- Guided nasion/LPA/RPA placement in the live AR view or on the 3D model, with
  plausibility checks and fiducial-anchored head-RAS coordinates.
- On-device photogrammetry reconstruction, world alignment, interactive camera,
  mesh, depth-point, electrode, and fiducial review, and a persisted session
  library.
- Versioned RAW and paired RAW/solved `.manta` export, plus generation and
  in-app previews for CSV, MNE SFP, BESA ELP, BIDS `electrodes.tsv`, and EGI
  `coordinates.xml` coordinates.

### MANTA Receiver for macOS

- Drag-and-drop or file import of immutable RAW `.manta` archives and editable
  PROCESSED `.manta` directory packages.
- Hardened extraction and validation, including manifest inventory, file sizes,
  SHA-256 hashes, CRC checks, path safety, resource limits, capture relationships,
  and bundle lineage.
- Inspection of capture metadata and saved camera frames with projected
  electrode/fiducial annotations, alongside an interactive combined LiDAR,
  photogrammetry, fused-depth, and solution viewer.
- Offline Object Capture reconstruction with disk-space preflight, quality
  selection, progress/cancellation, temporary previews, and PROCESSED output.
- Automatic and manual model-to-world alignment using fiducials, ICP, or hybrid
  strategies; RGB-D image clicks and model-surface picks can be reviewed before
  saving, with diagnostics and explicit plausibility overrides.
- Non-destructive fiducial correction and audited PROCESSED-package updates. The
  imported RAW acquisition is never modified.
- Surface export as PLY/STL, fused-depth point-cloud export as PLY, and coordinate
  export as CSV, MNE SFP, or EGI XML in ARKit-world or fiducial-derived head-RAS
  coordinates.

### Shared core and capture format

`MANTACore` is a platform-independent Swift package used by both applications.
It owns the versioned bundle models and schemas, deterministic ZIP creation,
bounded archive import, coordinate/unit types, projection and alignment,
point-cloud utilities, layout loading, detection/validation/template fitting,
and scientific exporters.

The version 1 interchange separates two roles:

- **RAW** is an immutable, hashed acquisition snapshot transferred as a `.manta`
  ZIP archive.
- **PROCESSED** is a mutable `.manta` directory package derived from RAW. Receiver
  edits replace only changed artifacts and append to `log_manta.json` while
  preserving the original acquisition and lineage.

See [Capture format](Docs/CAPTURE_FORMAT.md) for the complete contract.

## Repository layout

```text
MANTA/                 iPhone and iPad application
MANTAReceiver/         macOS Receiver application
MANTACore/             shared, platform-independent Swift package
MANTATests/            application tests and synthetic scan harness
MANTAUITests/          iOS UI tests
Fixtures/              EGI layouts and capture-format fixtures
Docs/                  architecture, format, privacy, validation, and roadmap
MANTA.xcodeproj/       MANTA and MANTA Receiver application targets
```

Additional design and project documentation:

- [Architecture](Docs/ARCHITECTURE.md)
- [Capture format](Docs/CAPTURE_FORMAT.md)
- [Data privacy](Docs/DATA_PRIVACY.md)
- [Validation](Docs/VALIDATION.md)
- [Roadmap](Docs/TODO.md)

## Requirements

- Xcode with the iOS 26 and macOS 14 SDKs used by the project.
- iOS/iPadOS 26+ for the `MANTA` app.
- macOS 14+ for `MANTA Receiver` (`MANTACore` itself supports macOS 13+).
- A LiDAR-equipped iPhone Pro or iPad Pro for LiDAR capture. Photogrammetry can
  run without LiDAR, while combined capture needs a supported LiDAR device.

The simulator can exercise session management, review, persistence, detection,
and export flows, but it cannot validate camera capture, LiDAR, or AR raycasting.

## Build and test

Open `MANTA.xcodeproj` in Xcode and select one of the application schemes:

- `MANTA` for iPhone/iPad (choose a LiDAR device for real capture).
- `MANTA Receiver` for macOS.

Run the portable package tests on the Mac host:

```sh
cd MANTACore
swift test
```

Run the application unit tests with an installed iPad simulator, adjusting the
destination to one available locally:

```sh
xcodebuild test \
  -project MANTA.xcodeproj \
  -scheme MANTA \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' \
  -only-testing:MANTATests \
  CODE_SIGNING_ALLOWED=NO
```

Real-device capture guidance and fixture hand-off instructions are in
[Validation](Docs/VALIDATION.md).

## Remaining work

The main gaps before lab use are real-device convention and accuracy validation,
robust disk-center localization and depth-neighborhood sampling, completion of
processing-run/review provenance, persistent Receiver import management, and a
secure authenticated transfer path. Direct USB-C Ethernet/Bonjour transfer is
planned but is not implemented.

Privacy, retention, encryption, access-control, and incident-response policy
must also be established for each deployment; PHI-free filenames do not make a
capture de-identified.

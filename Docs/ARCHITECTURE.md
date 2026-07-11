# MANTA Architecture

## Product boundary

MANTA has two complementary applications:

- The iOS/iPadOS app owns ARKit capture, on-device processing, review, and
  export.
- The planned macOS Receiver owns hardened-environment transfer, bundle
  inspection, archival, offline solving, comparison, and export.

Both applications consume the same versioned session bundle and use the same
domain, geometry, solver, and export semantics.

```text
MANTA.xcodeproj
├─ MANTACore local Swift package
├─ MANTA iOS target          -> MANTACore
└─ MANTA Receiver macOS target -> MANTACore
```

A separate macOS project and a single multiplatform application target were
rejected. The receiver is a distinct application, while a local package gives
the two targets a real module boundary and fast host-side tests.

## Dependency direction

The intended dependency direction is:

```text
Application UI and capture adapters
              ↓
Artifact repositories and platform adapters
              ↓
Domain models and solver interfaces
              ↓
Geometry and numerical algorithms
```

ARKit, RealityKit, UIKit, and SwiftUI must stay outside the solver/domain
layers. Vision and CoreGraphics may be Apple-platform adapters, but the solver
should consume recognized observations rather than own a particular OCR API.

The package may remain one public library product while using several internal
targets:

- `MANTADomain`: identifiers, coordinate frames, units, layouts, sessions, and
  bundle schema.
- `MANTAGeometry`: projection, transformations, orientation, and alignment.
- `MANTASolver`: fusion, validation, template fitting, and head-frame conversion.
- `MANTAArtifacts`: bundle validation, portable decoding, and repositories.
- `MANTAVision`: optional Apple Vision OCR adapter.

This subdivision is a direction, not a prerequisite for the current models
migration. Avoid adding targets until a dependency boundary makes one useful.

## Coordinate systems and units

Captured detections are stored in the ARKit world frame in meters. The frame is
arbitrary but internally consistent within a capture because every observation
stores its camera-to-world pose.

Photogrammetry models have their own source frame. A persisted column-major 4x4
transform maps model coordinates into the ARKit world frame.

Reviewed exports may be transformed into a right-handed fiducial-anchored RAS
head frame:

- Origin: midpoint of LPA and RPA.
- +X: origin toward RPA.
- +Y: origin toward nasion, orthogonalized against +X.
- +Z: right-handed superior direction.

The bundle format must identify the frame, units, matrix order, image origin,
and camera convention explicitly. A coordinate must never rely on an implicit
unit or frame.

## Capture and solving flow

1. The iOS app records immutable RGB, depth, confidence, camera intrinsics,
   camera poses, device metadata, and optional meshes/models.
2. A versioned manifest inventories and hashes the capture.
3. Either application opens the capture through `MANTACore`.
4. A processing run recognizes labels, refines disk centers, back-projects
   observations, fuses positions, validates geometry, and optionally predicts
   unobserved electrodes.
5. Results, parameters, metrics, and software versions are stored as an
   immutable processing run in a working copy.
6. Manual review is layered over a run so reprocessing never destroys prior
   results or corrections.
7. Export converts reviewed data into the requested frame and format. On iOS,
   **Export** creates an immutable `.manta` snapshot even when newly applied
   models are included. On macOS, **Save As…** creates a derived immutable
   `.manta` snapshot with a new bundle ID, the same session ID, its parent bundle
   ID, and `log_manta.json`; neither operation modifies an earlier snapshot.

The platform terminology is intentional:

- iPhone/iPad captures and edits a live working session, then exports snapshots.
- macOS imports a finalized snapshot read-only, performs work in a separate
  working representation, and must use Save As… to persist another `.manta`.
- CSV, BESA ELP, MNE SFP, BIDS, and EGI electrode-coordinate XML are terminal
  scientific exports and do not modify or replace the source `.manta`.

Measured and inferred electrode positions are distinct scientific data. A
template-filled electrode must never be reported as directly observed or be
included as an observed point in accuracy calculations.

## Persistence responsibilities

The current `CaptureArtifactStore` mixes session persistence, image/depth
encoding, reconstruction preparation, and ZIP creation. The intended split is:

- Capture encoders: iOS-only CoreVideo/UIKit conversion.
- Bundle codec: shared manifest and metadata encoding/decoding.
- Bundle validator: paths, schema, sizes, hashes, and required relationships.
- Session repository: application-selected storage and indexing.
- Archive transport: ZIP import/export without domain decisions.

An imported macOS bundle should not need to masquerade as an iOS Documents
folder.

## macOS receiver and transfer

The first receiver milestone is local file import, validation, inspection, and
offline solving. This makes Files/USB-drive transfer useful before networking is
implemented.

The preferred direct transport for hardened hospital environments is
point-to-point USB-C Ethernet. A receiver can listen with `Network.framework`,
advertise over Bonjour when available, and expose a manual address/code
fallback. The transfer layer must provide TLS authentication, integrity,
resumption, duplicate handling, and audit records because bundles may contain
PHI and identifiable head imagery.

The transport carries the bundle unchanged. It must not define a second session
serialization.

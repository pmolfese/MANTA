# MANTA Thin Vertical Slice

> Historical design snapshot. This document describes the initial application
> slice and is no longer the current implementation status. See the repository
> [README](../README.md), [Architecture](ARCHITECTURE.md), and
> [Roadmap](TODO.md) for current information.

## Goal

Build an iPhone Pro and iPad Pro LiDAR workflow that detects dark or reflective EEG electrodes on a visible cap, anchors them to nasion/LPA/RPA fiducials, allows relabeling and review, and exports electrode labels plus 3D coordinates.

## First App Slice

1. Capture a LiDAR-backed scan session.
2. Detect candidate electrodes from camera imagery and depth.
3. Assign labels from a supported electrode layout.
4. Place or confirm nasion, LPA, and RPA.
5. Review low-confidence detections and relabel mistakes.
6. Export CSV, SFP, ELP, and BIDS-compatible `electrodes.tsv`.

## Architecture

- `Models`: coordinate, fiducial, electrode, layout, and scan session types.
- `Services`: HydroCel layout loading, detection pipeline protocol, and export formatting.
- `ViewModels`: scan session state and review workflow logic.
- `Views`: capture/review/export interface.

The current detection service is a mock pipeline. It exists so the app can develop the review and export workflows while ARKit, Vision, and LiDAR reconstruction are wired in behind the same protocol.

## Layout Fixtures

MANTA uses EGI coordinate XML files for 3D coordinate priors and EGI `sensorLayout` XML files for 2D display positions and neighbor graphs. The app does not depend on HydroCel `netModel` template XML files. Cardinal electrodes and fiducial-to-sensor hints are owned in `HydroCelLayoutMetadata.json`.

## Detection Plan

1. Use ARKit world tracking and scene reconstruction for device pose, mesh, and depth.
2. Run image-space candidate detection for electrode stickers using color and reflectance cues.
3. Back-project candidates through depth into AR world coordinates.
4. Cluster repeated observations across frames to stabilize electrode positions.
5. Use cardinal electrode colors plus the selected cap layout to estimate orientation and assign labels.
6. Gate exports behind fiducial review and low-confidence detection review.

## Open Decisions

- Exact supported layouts and label order.
- Sticker colors for cardinal and regular electrodes.
- Whether coordinates should export in millimeters or meters for each format.
- MRI/scanner transform source: manual fiducials only, imported MRI scalp surface, or external registration file.
- Whether reconstruction remains on-device or can offload dense photogrammetry to a Mac.

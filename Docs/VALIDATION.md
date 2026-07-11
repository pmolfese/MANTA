# MANTA Validation Plan

MANTA is not ready for clinical use. Synthetic consistency tests are valuable,
but validation must establish localization accuracy, repeatability, robustness,
and format reproducibility using independent evidence.

## Acceptance questions

- Can the complete capture bundle be decoded identically on iOS and macOS?
- Are stored camera poses, intrinsics, RGB orientation, and depth pixels mutually
  consistent on a real device?
- How many electrodes are directly observed and correctly labeled?
- What is the localization error of directly observed electrodes?
- How accurate are inferred electrodes, reported separately?
- Are results repeatable across operators, devices, sessions, and conditions?
- Do exported coordinate frames and units match each consuming tool?

## Test layers

### Unit and synthetic tests

Continue testing 128- and 256-channel layouts, projection/unprojection,
aggregation, alignment, neighbor validation, fitting, head-frame conversion,
and exporters. Synthetic generation proves internal consistency but does not
independently validate ARKit conventions because generation and solving share
the same camera model.

Add versioned bundle fixtures, schema validation, compatibility migrations,
binary byte-count tests, hash corruption cases, and hostile archive tests as
specified in [Capture format](CAPTURE_FORMAT.md).

### Real-capture convention fixture

The first real fixture should establish:

- Stored JPEG orientation relative to camera intrinsics.
- ARKit camera convention and camera-to-world matrix direction/order.
- RGB-to-depth pixel mapping.
- Depth units, byte order, confidence mapping, and missing-value behavior.
- Photogrammetry/model-to-world alignment relationships.
- Fiducial raycast and head-frame behavior.

Use visible targets at independently measured locations where possible. Retain
a sanitized subset in the repository so convention regressions are testable.

### Accuracy study

Digitize the same net with an accepted reference system such as Polhemus or
Geoscan, or use a phantom with known marker positions. Pre-register the matching
and exclusion procedure. Report at least:

- Directly observed electrode count and correct-label rate.
- Inferred electrode count, never pooled silently with observed points.
- Mean, median, RMS, 95th percentile, and maximum Euclidean error.
- Per-region and per-electrode error.
- Fiducial error and alignment residual.
- Failed scans and review burden.

The current provisional goal is less than 5 mm mean localization error. A final
acceptance threshold must be tied to the intended research/clinical use and must
specify whether it applies only to observed electrodes.

### Repeatability and robustness

Repeat same-subject scans on the same day and test:

- Operator and repositioning variability.
- iPad versus iPhone LiDAR.
- 128 versus 256 nets.
- Hair color/volume, lighting, gel sheen, glare, and subject motion.
- Fiducial, ICP, and depth-assisted alignment strategies.

Track failure rates and missingness, not only successful-scan accuracy.

## Detection metrics

For each run record:

- Frames attempted/decoded and reasons for rejection.
- OCR candidates, accepted labels, ambiguous reads, and label conflicts.
- Depth availability/confidence and spatial refinement method.
- Supporting frames per electrode and fused spread.
- Neighbor-validation findings.
- Template-fit anchors, spatial coverage, scale, residual, and reliability.
- Observed, inferred, manually placed, reviewed, and missing counts.

The target of at least 240 automatically labeled channels on a good 256 net is
aspirational until real captures establish feasibility. Filled template
positions do not count as automatically observed labels.

## Real capture procedure

1. Build the `MANTA` scheme to a LiDAR-equipped iPhone/iPad, not the simulator.
2. Create a subject/session, select `Both`, and choose the 128 or 256 layout.
3. Use even lighting and avoid glare; keep printed numbers visibly sharp.
4. Orbit the head approximately 30–60 cm away, maintaining normal tracking and
   scene depth. Capture at least 40 well-distributed frames.
5. If testing fiducials, place nasion, LPA, and RPA in the live scan.
6. Stop sampling and pause. Reconstruction is optional for OCR/depth testing.
7. Export the complete session from the Subjects library or copy it from the
   Files app/Finder file sharing.
8. Sanitize as required and place an approved fixture under
   `Fixtures/RealCaptures/<session-uuid>/`.

Expected legacy artifacts are RGB JPEGs, compressed raw metric depth and
confidence, `diagnostics.json`, `session.json`, and optional reconstruction
files. New captures will transition to the versioned format in
[Capture format](CAPTURE_FORMAT.md).

## Export validation

Confirm units, axis order, fiducial labels, and coordinate-system declarations
against each consumer:

- MNE SFP
- BESA ELP
- EGI electrode-coordinate XML
- BIDS `electrodes.tsv` plus `_coordsystem.json`
- Generic CSV

Round-trip representative exports through an independent parser where the
format permits it.

The EGI XML exporter must be checked against
`Fixtures/EGI/GeoScanDerived128/coordinates.xml`. Its coordinates must be
converted explicitly from MANTA head-frame millimeters to the fixture's
centimeter convention, and its derived SFP coordinates must agree within the
fixture's observed 0.000005 rounding tolerance.

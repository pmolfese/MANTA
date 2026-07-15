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

Add versioned bundle fixtures, schema validation, binary byte-count tests, hash
corruption cases, and hostile archive tests as specified in
[Capture format](CAPTURE_FORMAT.md). Compatibility fixtures begin when a schema
is actually released; pre-release working-session models are not supported.
The archive importer is exercised against traversal, normalized/case-colliding
paths, symlinks, CRC corruption, extraction limits, and cleanup after rejection.

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
- Unlabeled classical-CV cup proposals, per-frame false positives, multi-view
  cluster support/spread, and the fraction rejected before assignment.
- Depth availability/confidence and spatial refinement method.
- Per-frame 3D-to-image reprojection error and electrode-to-surface distance;
  report systematic registration offsets separately from individual detection
  errors.
- Supporting frames per electrode and fused spread.
- Neighbor-validation findings.
- Template-fit anchors, spatial coverage, scale, residual, and reliability.
- Observed, inferred, manually placed, reviewed, and missing counts.
- Globally assigned visual cups and assignment distance, kept separate from
  OCR-labeled observations and template-only guesses.

The target of at least 240 automatically labeled channels on a good 256 net is
aspirational until real captures establish feasibility. Filled template
positions do not count as automatically observed labels.

## Real capture procedure

1. Build the `MANTA` scheme to a LiDAR-equipped iPhone/iPad, not the simulator.
2. Create a subject/session, select `Both`, and choose the 128 or 256 layout.
3. Confirm adequate free storage, normal tracking, scene depth, even lighting,
   and a stationary participant before starting auto-sampling.
4. Collect a horizontal pass around the complete net, followed by a higher
   counter-direction pass aimed toward the crown. Stay approximately 30–60 cm
   away, move slowly, and preserve overlapping views.
5. Capture deliberate sharp views of the frontal/nasion, left temporal/LPA,
   right temporal/RPA, posterior, and crown/reference regions. Capture at least
   40 well-distributed frames and over-capture initial pilot sessions.
6. Watch the live coverage-sector count and quality advisories. Advisories are
   recorded rather than used as hard rejection thresholds until pilot data can
   tune them.
7. Place and review nasion, LPA, and RPA while the participant remains present.
8. Stop sampling and pause. Pausing persists the complete world-space LiDAR PLY
   mesh with triangle topology independently of photogrammetry.
9. Review the participant-release advisories: frame count, coverage, depth,
   mesh persistence, sharpness, and fiducials. Repeat weak regions before the
   participant leaves.
10. Run quick OCR/detection and attempt reconstruction when supported.
    Reconstruction uses sequential samples and high feature sensitivity and
    records skipped samples and automatic downsampling. Reconstruction success
    is not required for raw-capture completeness.
11. Export `.manta`. Export snapshots the mesh again, finalizes the immutable
    archive, then immediately re-imports and validates it before sharing.
12. Sanitize as required and place an approved fixture under
   `Fixtures/RealCaptures/<session-uuid>/`.

Expected `.manta` artifacts include RGB JPEGs, compressed raw metric depth and
confidence, per-frame quality/coverage metadata, camera poses/intrinsics, the
full LiDAR PLY mesh when available, and optional reconstruction model, poses,
and diagnostics. See [Capture format](CAPTURE_FORMAT.md).

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

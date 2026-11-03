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

## Stage 1 pilot agreed on 2026-11-03

Capture hardware: iPad Pro M5, running iPadOS 27 or later. Processing hardware:
Mac Studio M3 Ultra running macOS 26 (user-reported). The reference system
is GeoScan, used on the same participant wearing the same net. The initial
coordinate target is the visible disc/cup center. Record any difference between
that target and the point GeoScan actually digitizes; do not silently interpret
these coordinates as scalp-contact locations.

### Paired capture procedure

1. Record anonymized session identity, net layout, iPad model/OS build, MANTA
   version/build, GeoScan version/export format, and acquisition order.
2. Keep the net in place between acquisitions. Record adjustment, visible slip,
   motion, or fiducial changes; exclude affected pairs according to a rule agreed
   before scoring, and retain the exclusion reason.
3. Capture MANTA evidence and GeoScan coordinates with the same electrode labels
   and independently identified nasion/LPA/RPA. Confirm how GeoScan represents
   the visible cup center versus its own digitization target.
4. Preserve both original exports. Normalize units explicitly and align using a
   rigid transform from corresponding fiducials. Do not fit scale or optimize
   the primary comparison over all electrode coordinates, which could conceal
   systematic scale/localization errors. Report fiducial residuals separately.
5. Score only common, directly observed electrodes in the primary result.
   Report missing, inferred, visually assigned, and manually corrected channels
   separately, including wrong-label counts and review time.
6. Report count, mean, median, RMS, 95th percentile, and maximum distance, plus
   regional errors and failed scans. Account for uncertainty in GeoScan and the
   point-definition mismatch when interpreting disagreement.
7. Repeat MANTA capture without moving the net to measure repeatability. Reserve
   entire sessions for held-out evaluation; do not split adjacent frames across
   training/tuning and validation sets.

This comparison measures end-to-end agreement, not absolute ground truth. A
separate controlled-target fixture remains required for image orientation,
gravity, depth registration, and camera-convention checks.

### OCR benchmark preparation

Use a versioned annotation JSON with a dataset ID and split assignment. For each
image record its source bundle/observation ID, relative image path, SHA-256,
native dimensions, stored orientation, and an array of visible labels. Each
label annotation should include the exact electrode ID (or explicit ambiguous/
unreadable status), a native-image bounding box, and an optional visible disc
center. Declare the image-coordinate origin and units once in the dataset.
Record annotator/reviewer decisions rather than replacing ambiguous labels with
layout-derived guesses. Include empty/background examples to measure false
positives. Keep raw images outside source control unless approved for inclusion.

Stratify examples by rotation, glare, blur, image-edge location, and confusable
labels. Compare exact-label precision/recall, missed labels, duplicate detections,
and disc-center error. Freeze annotations and session-level splits before
comparing algorithms. Hardware, image permissions, dataset size, and numerical
promotion thresholds must be established before claiming benchmark coverage.

### Stage 1 software progress

The PCA alignment failure was traced to basis handedness: requiring a
right-handed source basis does not guarantee a proper rotation when the sorted
target eigenbasis is left-handed. The solver now checks the determinant of the
actual rotation. The existing scale tolerance is unchanged, with additional
checks on seed determinant and residual.

Receiver detection and Receiver/CLI reconstruction now attach versioned run provenance with
source bundle ID, input manifest hashes, OS/build string, and available app
version/build. Detector evidence also records its OCR configuration and explicitly
selects Vision revision 3. This does not freeze OS-provided model weights.
Existing evidence can omit these optional fields.

Remaining Stage 1 work includes a complete shared processing configuration,
hardware/source-revision identity, stage metrics and benchmark runner, labelled
images, controlled convention capture, and the paired GeoScan study. These
initial metadata additions do not constitute a complete reproducibility report.

## GeoScan sample review and export contract — 2026-11-03

The supplied `S05_GeoScan-output_20220428-160651.txt` and `S05_coordinates.sfp`
each contain 260 points: E1–E256, Cz, FidNz, FidT9, and FidT10. The source TXT
uses `ElectrodeName X Y Z Estimated`, a `LabellingTemplate = ...` line, and
comment headers. Its header defines positions as reflective-marker locations,
with 0 indicating measured and 1 estimated. It does not explicitly declare units
or the anatomical placement of FidT9/FidT10. The user subsequently confirmed
that these were placed at the left/right preauricular landmarks, so they map to
LPA/RPA. Source units remain unconfirmed. The landmark separation is 13.43973
file units, consistent with centimeters for a human head, but this anatomical
plausibility is not unit verification. Confirm units from acquisition settings,
GeoScan documentation, or an independently measured distance before quantitative
accuracy scoring. Preserve original values and require an explicit source-unit
selection when reference import is implemented; do not silently infer units.

The supplied SFP is not a rigid re-expression of the raw points. For example,
FidT9–FidT10 is approximately 13.43973 in both files, while E1–E2 changes from
2.55211 to 2.27098. Pairwise distance ratios across all points range approximately
0.5356–1.1308. Retain the raw TXT as the reference evidence. Do not use the
converted SFP as independent accuracy ground truth.

The supplied conversion scripts are exploratory references, not a validated
conversion contract. Their fiducial method uses the triangle centroid rather
than MANTA's LPA/RPA midpoint; the `ALS` branch flips one axis rather than
performing a proper RAS-to-ALS rotation. Other branches contain guessed scaling
or fit anisotropic scales to examples. Those operations must not be introduced
into MANTA's accuracy comparison. The supplied files and scripts remain outside
the repository and are not executed or modified by the export implementation.

MANTA now provides:

- Existing meter-based SFP, unchanged for existing consumers.
- Explicit centimeter SFP, with units in the exported filename because the
  four-column file itself has no unit/frame declaration.
- GeoScan-style five-column TXT in centimeters, retaining the selected MANTA
  frame and declaring that frame and units in comment headers. This is syntax
  compatibility with the supplied example, not a recreation of scanner axes or
  a claim of acceptance by GeoScan software. The template entry is a basename;
  it is not an invented installation path.

GeoScan-style exports include cardinal fiducials with FidNz/FidT9/FidT10 aliases
and retain Cz as an electrode. The current app adapters conservatively write
Estimated=1: Reviewed/Detected state alone does not establish immutable direct-
measurement provenance. The shared writer supports explicit measured flags for
future verified provenance. Missing electrodes are omitted from TXT. Preserve
MANTA/CSV evidence when richer provenance is needed; SFP has no estimated column.

The Receiver offers these formats in its coordinate export panel, using the
selected ARKit-world or fiducial-derived head frame. The iPad offers SFP/TXT
preview and file sharing, using its existing export-session frame selection
(head RAS when available, otherwise world). No empirical scaling, scanner-axis
rotation, or subject-specific learned transform is applied during serialization.

## GeoScan importer and comparison harness

`MANTACore` now has a strict `GeoScanImporter` and `GeoScanComparison` engine.
The `manta-compare` executable in `MANTAReconstructCLI` consumes raw GeoScan TXT
and MANTA GeoScan-style TXT exports with explicitly selected units. See the CLI
README for invocation and report fields. Raw coordinate values and Estimated
flags survive import; unit conversion to millimeters occurs only for comparison.

The synthetic tests cover rigid rotation/translation with different input units,
scale mismatch that cannot be fitted away, a known 5 mm electrode displacement,
measured/estimated separation, missing labels, invalid flags, conflicting units,
duplicate labels, nonfinite coordinates, and missing/collinear fiducials.
This verifies the comparison machinery, not acquisition accuracy. The original
S05 file is used only for a local parsing/self-comparison smoke test; no historical
subject coordinates are checked into the repository.

## iPad provenance and paired-session increment

The iPad sidebar now includes **Paired GeoScan Validation**: a reference session
ID, acquisition order, and net-movement notes. Use a study/session code rather
than a participant name. These fields persist in acquisition context and travel
with the capture. Capture-start events include hardware, OS/build, app version,
and requested camera configuration for reproducible device testing.

New detection outputs carry coordinate provenance separately from review state.
Direct image/depth observations can now produce Estimated=0 in TXT and primary
comparison metrics. Template predictions, layout-assigned visual points, synthetic
data, manual placements, and old records without provenance do not become direct
measurements simply by marking them Reviewed. No old sessions are backfilled.
Earlier notes that all MANTA points are necessarily Estimated=1 apply only to
records without explicit direct-observation provenance. Estimated=0 does not
validate localization accuracy or label identity.

This increment does not implement best-frame selection, high-resolution stills,
smudge checks, or hardware convention validation. Those require the planned M5
capture experiments; build/unit-test success is not a physical-device result.

## M5 capture experiments

The iPad sidebar's **M5 Capture Experiments** section provides three opt-in tools:

- **Select best recent frame:** automatic samples choose a retained candidate no
  older than 0.9 seconds, scored at most once every 0.15 seconds. The provisional
  score combines sharpness, inter-frame angular speed, and novelty relative to
  the last saved pose. Candidates require normal tracking and, in LiDAR modes,
  scene depth. At most one candidate ARFrame is retained. Manual normal samples
  continue to use the current frame; an empty/stale window falls back to current.
- **High-resolution stills:** set before starting capture to request ARKit's
  recommended still-capture format. Use the manual still button or auto-sampling
  (at most one request per five seconds, with normal tracking). Stills may arrive
  without depth; they preserve their own pose, intrinsics, timestamp, orientation,
  dimensions, and any returned depth. No nearby video-frame depth is substituted.
  Requests are serialized, skipped at serious/critical thermal state, and discarded
  on cancellation, pause/restart, session switching, or orientation change during
  the request. Unsupported formats and request failures are reported.
- **Check Lens:** explicitly runs Vision lens-smudge revision 1 on a current
  frame. Its provisional 0.5 threshold only displays advice. Confidence and request
  failures are logged; capture is never blocked. A low score does not certify a
  clean lens. Device/model support is handled through request failure reporting.

Best-frame selection and high-resolution stills default off. Options are locked
while capture runs because changing camera format requires restarting the session.
Do not change modes midway through a quantitative paired scan: collect separate
sessions for each condition. These are device-independent capability checks, not
an assumption that every M5 configuration supports simultaneous depth and stills.

### Physical M5 trial

1. Collect a baseline session with both experiments off, then separate comparable
   sessions with best-frame selection and still capture enabled individually.
2. Confirm requested versus delivered camera sizes, FPS, tracking status, depth
   presence, actual still dimensions, and timestamps in acquisition events.
3. Inspect stored images and image/depth/projection overlays in portrait and both
   landscape orientations. Verify that a still uses its own calibration.
4. Compare usable sharp-image yield, viewpoint coverage, label legibility, storage,
   sample latency, heat, and failure rates. Do not assume higher-resolution means
   exactly 4K or that all formats preserve scene depth.
5. Stop/pause/change sessions during a still request and confirm no observation
   is attached to the wrong session. Check unsupported/thermal/error advisories.
6. Run the lens check under normal, blurred, and genuinely smudged conditions;
   measure false warnings before considering automatic use or a default threshold.

RGB-only stills are useful stored reconstruction evidence, but the existing
Receiver electrode detector still requires depth per input frame. Supporting
RGB-only rays remains the roadmap's localization work; these capture changes
alone do not make such stills contribute to electrode detection. No on-device
accuracy, simultaneous-depth guarantee, or performance improvement is claimed
until this hardware trial is complete.

## RGB-only Receiver localization checks

Receiver now accepts calibrated RGB-only frames. Save a model-to-world alignment,
then Detect Sensors to use nearest triangle intersections; without alignment or
valid scene depth, candidates are retained as pending 2D evidence. Save Sensors
also saves such evidence-only runs, preserving existing coordinates. Source images
remain immutable and can be processed again after reconstruction/alignment.

`imageMeshObserved` identifies a direct image observation localized against the
reconstructed mesh; it exports Estimated=0, but does not imply an independently
measured surface or calibrated accuracy. `depthSource=alignedMesh` uses no fabricated
LiDAR confidence (the legacy numeric confidence slot is 0). Missing depthSource in
older evidence retains the legacy scene-depth interpretation. Estimated optical-
axis depth is distinguished from distance along an oblique ray.

Synthetic tests exercise RGB-only triangle interiors, off-axis depth/projection,
mesh/scene-depth preference and disagreement fallback, behind-camera surfaces,
missing geometry, invalid depth, and invalid pixels. Physically verify that a
cup's visible center is represented by the reconstructed surface. Inspect silhouette
hits and bad alignment; nearest-surface visibility alone does not prove a hit is
the intended electrode. Current mesh queries scan triangles, so profile runtime
on full-detail meshes. The 4096-pixel OCR cap preserves more still detail but is
not full-resolution tiling. Unlocalized candidates have no 3D export coordinates.

## Pre-participant capture safeguards

Before ending a visit, use **Paired GeoScan Validation → Check Before Participant
Release**. This stops automatic sampling, saves the current mesh, pauses AR,
checkpoints the session, and runs the existing deep receipt checks over saved
images/depth/confidence/calibration/mesh evidence. It shows file status, image
counts, camera-direction coverage bins, blur warnings, and paired-study reminders.
Coverage bins are camera directions, not anatomically registered scalp regions;
inspect overlays before deciding where to repeat views. Export status means the
archive was prepared, not that a destination copy or transfer was verified.

Confirm **GeoScan export received** and **Separate repeat MANTA pass collected**
only after doing those tasks. These operator confirmations persist in acquisition
context. Results clear when sampling, changing sessions, or editing study context.
The receipt is a data-integrity check, not an accuracy certificate.

### Recovery and coordinate worlds

Each completed frame's metadata is atomically checkpointed under
`acquisition/observations/<UUID>.json` after writing its artifacts. The full session
is persisted before acquisition and immediately after each observation. Reopening
in the iPad merges these checkpoint records by observation ID in capture-time
order, recovering a frame saved before the last session.json update. It does not
invent metadata for partially written frames lacking a checkpoint. Decode failures
surface rather than silently treating a corrupt checkpoint as complete data.

Reopened captures are review-only. AR failures or interruptions invalidate further
acquisition in the current world and show a prominent warning; create a NEW session
for subsequent acquisition. Ordinary pause/resume within the same live session
reuses the existing AR configuration without resetting tracking. Camera-option
changes require a new session once frames have been collected. This conservative
policy avoids silently mixing coordinate worlds; it does not claim relocalization
has been validated.

### Frame-selection comparison mode

Enable **Save cadence comparison frames** together with **Select best recent
frame** before beginning a validation session. Each automatic sample retains the
selected candidate and the cadence-time frame, using each frame's own calibration
and depth. Identical timestamps are stored once. A `frame-comparison-pair` event
links the observation IDs for offline analysis. This mode uses additional storage;
it does not save the whole video stream. Pair logs and original images must be
retained when constructing a benchmark. Stills are not paired with cadence frames.

### High-resolution fallback

Missing depth under the experimental format and limited tracking produce visible
capture warnings. Keep the RGB evidence, then start a separate baseline session
with stills disabled to collect the depth pass. The app does not silently switch
camera formats/reset the world during a scan. Still completion events record
request latency and thermal state. Confirm actual delivered depth and tracking
on the M5 bench trial before enrolling a participant.

Validation for this increment: core tests run on the Mac; the unsigned iPad app
and test bundle compile. Checkpoint recovery has an app test, but executing it and
interruption/format-switch scenarios requires an iOS 27 runtime or physical device;
only iOS 26.x simulator runtimes were installed during implementation.

## Calibration extraction and benchmark validation

Both Mac reconstruction front ends request Object Capture poses with stable sample
IDs. `poses.json` retains source calibration and adds estimated pose, optional
intrinsics/distortion, and per-sample status. The shared adapter is in the
`MANTAProcessing` target, separate from portable geometry. Tests verify source
preservation, optional calibration serialization, missing/rejected ID handling,
and rejection of duplicate IDs. Live reconstruction output and pixel/axis/gravity
conventions still require real acquisition validation before using estimated
calibration in scientific localization.

`manta-benchmark` runs labelled image OCR and coordinate-comparison cases from a
versioned manifest. The example at `Docs/BENCHMARK_MANIFEST.example.json` uses
placeholder paths, not participant data. Unit tests cover exact TP/FP/FN scoring;
local end-to-end tests exercised generated E1/E2 text, a blank image, a deliberate
missing image, and a synthetic 5 mm coordinate error. The runner continued after
case failure and refused to overwrite a report. Vision needs access to macOS
system services; running within a restrictive process sandbox can produce an OCR
request error, which is retained in the report rather than scored as a valid miss.

This harness scores exact numeric or E-prefixed OCR tokens. It is not yet a batch
version of the full Receiver geometry/cup-detection pipeline and does not provide
pixel-center or reprojection accuracy. Freeze annotations and hold out sessions
before interpreting improvements on real net images.

## Capture presets and storage reserve

The iPad's **Capture Presets & Experiments** section offers:

- **Baseline RGB-D:** Both mode, ordinary cadence, best-frame selection off,
  comparison frames off, and experimental high-resolution stills off.
- **Validation experiments:** Both mode, best-frame selection on, paired ordinary
  cadence frames on, and high-resolution stills on. The experimental camera format
  may lack scene depth; acquire the baseline in a separate session first.

A persistent capture overlay shows the settings used when capture started; the
sidebar also shows settings before starting. Manual combinations are marked Custom.
Modes and experiment controls lock while running and after the first saved frame.
Pause/resume preserves the original configuration and coordinate world; changing
presets after saving evidence requires a new session. Reopened sessions stay
review-only. Requested settings and comparison retention are recorded in acquisition
logs; delivered depth availability remains separately recorded.

Storage is checked at start, every two seconds while running (independent of camera
frame delivery), and before each RGB/depth observation write, including manual,
comparison, fiducial-evidence, and high-resolution samples. Below 3 GB the app warns;
at or below 1 GB it pauses AR and automatic sampling, discards pending frame work,
and retains saved evidence. Unknown capacity also pauses acquisition. State changes
are logged, not every polling tick. Capacity uses the session volume's important-usage
availability estimate; these decimal thresholds are conservative headroom, not a
reservation against concurrent writes by other apps or an assurance of export space.
Metadata/checkpoints can still be saved. Free space and explicitly resume capture;
there is no automatic restart. Existing tracking-interruption restrictions still apply.

Before a participant session, use a bench object to check both presets, the active
summary, and settings locks after pause. Confirm delivered depth in the baseline
pass and receipt/export integrity. For low-storage testing, inject capacity readings
through `storageCapacityProvider` in a development build rather than filling the
actual device: 4 GB → 2 GB → 1 GB → 4 GB, plus nil. Expect warning, pause, no further
samples, and explicit resume only. Test with a still in flight and ordinary sampling;
verify saved observation checkpoints remain readable and the final receipt completes.

Verification: 96 core tests pass, including threshold boundaries, unknown capacity,
recovery, and preset naming. iPad integration tests cover warning/pause/no automatic
restart and preset locking; the app and test bundle compile, but execution requires
an iOS 27 device/runtime. Physical M5 camera/depth and storage-pressure behavior are
not yet validated.

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
aggregation, alignment, neighbor validation, fitting, head-frame conversion,wehn we
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
selected ARKit-world or fiducial-derived head frame. The iPad offers SFP
preview and file sharing; GeoScan TXT is available on the Mac only. SFP uses its
existing export-session frame selection
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

As of H1/H2, GeoScan comparison belongs to Receiver on macOS. The iPad has no
paired-study controls, GeoScan release reminders, or GeoScan export choice. Legacy
reference IDs, acquisition order, and confirmations remain readable and travel with
existing captures; removal of collection UI does not erase them. General capture /
movement notes remain available. Capture-start events include hardware, OS/build,
app version, and requested camera configuration for reproducible device testing.

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

Best-frame selection and automatic high-resolution stills default off. Manual
high-resolution stills default on (updated 2026-11-05). Options are locked
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

Before ending a visit, open **Head readiness and review** (head-only) or **Review and
recapture** (net). Tracking continues during review. Collect missing evidence, then
use **Save and inspect head surface** to pause, drain writes, save, and inspect the
model. Resume only if the head and tracking world remain valid; movement requires a
new pass. Run **Final integrity / release check** to verify saved files and persist
an advisory review snapshot. Neither this check nor a view-sector count certifies
complete geometry. Export status means an archive was prepared, not that transfer
was verified. GeoScan is handled separately in Receiver, without iPad reminders.

### Recovery and coordinate worlds

Each completed frame's metadata is atomically checkpointed under
`acquisition/observations/<UUID>.json` after writing its artifacts. The full session
is persisted before acquisition; A2 batches automatic-capture metadata at ten completed
frames or five seconds on the next completion, and flushes at stop/finalization.
Meaningful non-observation mutations still persist immediately. Reopening
in the iPad merges these checkpoint records by observation ID in capture-time
order, recovering a frame saved before the last session.json update. As of 2026-11-05,
iPad reopening and Mac RAW-directory recovery use the same `MANTAWorkingSessionLoader`.
Existing full-session observations take precedence over checkpoints with the same ID;
equal capture timestamps are ordered by observation ID. Missing checkpoint directories
remain compatible with legacy sessions, but unreadable directories are errors. It does not
invent metadata for partially written frames lacking a checkpoint. Decode failures
surface rather than silently treating a corrupt checkpoint as complete data.

Reopened captures are review-only. AR failures or interruptions invalidate further
acquisition in the current world and show a prominent warning; create a NEW session
for subsequent acquisition. Ordinary pause/resume within the same live session
reuses the existing AR configuration without resetting tracking. Camera-option
changes require a new session once frames have been collected. This conservative
policy avoids silently mixing coordinate worlds; it does not claim relocalization
has been validated.

### Acquisition milestone A1: timing and recovery bench acceptance

The acquisition gate is A1–A5 in `MANTA_ROADMAP.md`. An available iPad Pro M5 is the
bench target. These checks remain outstanding until physically executed; compilation
and synthetic fixtures are not device acceptance.

- Capture a bench head/net object with the baseline and validation presets. Inspect
  `capture-frame-selected` events for `imageWriteDurationMs`, `depthWriteDurationMs`,
  `checkpointWriteDurationMs`, and `artifactSaveDurationMs`. These use monotonic
  uptime. In A2 the artifact total covers the worker storage check through checkpoint
  commit; it excludes main-actor buffer copying, queue wait, metadata/diagnostics,
  event logging, and live processing. Depth timing includes summary/quality work.
- A2 `sample-saved.saveDurationMs` covers queue admission through checkpoint commit
  for one observation, including queue wait. `bufferCopyDurationMs` and
  `queueWaitDurationMs` separate copying and waiting. Regular frames, cadence pairs,
  and stills each emit their own save event. `still-delivered.latencySeconds` remains
  the AR request latency. Older A1 logs used sample-save timing for a synchronous
  regular sample including subsequent metadata and a possible cadence pair; do not
  compare these totals without accounting for the implementation version.
- Compare early and late scan timings, actual saved cadence, tracking, and heat.
  Record distributions and outliers, not just averages. Use this evidence for A2.
- Terminate after completed checkpoints but before a metadata refresh, then reopen
  on iPad and recover the copied working directory on Mac. Compare observation IDs,
  calibration, image/depth/confidence references, and file integrity. Original files
  must remain unchanged. Repeat with partially written artifacts lacking checkpoints;
  they must not become observations. Corrupt checkpoints must surface as errors.
- In the experimental format, compare regular/still RGB and depth at known edges
  and distances using each frame's own calibration. Record missing depth, misalignment,
  actual dimensions/FOV, tracking changes, still latency, and thermal behavior. Select
  the one-pass design only if these results support it; otherwise retain explicit
  separate-pass fallback with no automatic coordinate-world merge.

Recovery does not infer missing fiducials, settings, or events from frame checkpoints.
Those state changes still require their own persistence.

### Acquisition milestone A2: responsive capture bench acceptance (pending)

A2 code and automated checks can proceed ahead of the deferred combined M5 trial.
No responsiveness, thermal, or accuracy improvement has yet been measured on device.

- The serial worker accepts at most three frame jobs, including the active job. RGB,
  depth, and confidence are copied into app-owned pixel-buffer pools before submission;
  calibration/timestamps come from that same frame. Cached pools are bounded across
  format changes. Queue-full candidates are dropped before buffer copying and logged
  as `capture-queue-full`; manual requests show a busy message too.
- A queued observation is not counted as saved, sent to live processing, or included
  in session metadata until artifacts and its checkpoint commit. Pair events identify
  *queued* observations; confirm both save events before treating a pair as complete.
- Full metadata and diagnostics remain serialized on the main actor, but are batched
  during auto capture. This avoids stale asynchronous metadata overwriting later
  fiducial/settings edits. Image/depth encoding and checkpoint I/O run off the main
  actor. Profile remaining metadata/event overhead on long scans in the M5 trial.
- Stop prevents new admission and invalidates outstanding still deliveries, then
  finishes accepted owned frames. End/release/export await this drain. A switch or
  deletion attempted while saving asks for retry afterward. Pause retains accepted
  evidence; a write failure pauses capture, preserves completed frames and a visible
  error, and records the failed observation. Explicit resume clears the prior error.
- Backgrounding requests limited iOS background time to drain and flush. OS suspension
  or termination can still interrupt it: only checkpointed frames are recoverable.
  Force-quit recovery must not invent queued or partially written observations.
- On M5, run both presets long enough to see queue saturation/thermal effects. Check
  UI responsiveness, actual regular/still cadence, peak memory, pool reuse, independent
  still requests, and timing distributions. Exercise stop/pause, storage reserve,
  immediate end/export, attempted session switch/deletion, background/foreground,
  interruption during a still request, and write failure. Match saved event IDs to
  checkpoint and exported observation IDs; reject cross-session leakage.

Software checks: core queue tests cover bounded admission, off-main execution,
completion order, failure followed by later work, and cancellation-safe draining.
iPad buffer tests cover planar/nonplanar independent copies, propagated calibration-
relevant image attachments, and pool allocation limits; these are compiled but require
an iOS runtime/device to execute. A2 remains physically unvalidated.

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

## Receiver triangulation and advisory integrity checks

Triangulation mode resolves image landmarks only from valid forward camera-ray
intersections (or an explicitly enabled archived device landmark). Insufficient,
nonfinite, degenerate, or behind-camera intersections stay unresolved. Required
landmarks block landmark-seeded solves; optional unresolved Cz is omitted. The UI
reports missing views or unstable rays. Switching resolution modes clears temporary
click evidence so pixel-only placeholders cannot later become depth/mesh targets.
Per-click triangulation evidence omits `worldPoint`; the combined solution is stored
in the target-landmark diagnostics. A one-degree minimum ray-pair separation is a
conservative geometry gate, not a clinical or metrological accuracy threshold.

Bundle SHA-256 and size mismatches are warnings, as are absent/malformed checksums.
Otherwise readable legacy ZIP CRC mismatches also warn. Receiver shows these under
Imported Capture and the reconstruction CLI prints them; they do not disable
processing/export. The audit never changes source bytes or rewrites hashes to hide
a mismatch. Structural metadata/path checks remain enforced. An unreadable image
can still fail its later processing step; advisory integrity does not repair data.

Directory-package and mutable PROCESSED workflows remain intact. Hashing reads
64 KiB at a time with 64-bit file sizes; it never builds a ZIP or loads the whole
payload into memory. Fresh finalization/recovery skips a redundant hash pass, and
processed-package edits do not trigger full scans. Regression tests cover clean,
missing, malformed, mismatched hashes and sizes, imported legacy ZIP warnings, and
a sparse 2 GiB + 16-byte file with an independently computed checksum. The latter
checks bytes after the signed 32-bit boundary, not just file-size metadata.

## Paused head review on iPad

Pressing Pause stops sampling, saves the current LiDAR surface, and opens Head Model.
The viewer frames the captured region once and enables manual orbit/zoom. It does not
resume following the device after the five-second idle interval while paused.
Starting scanning or automatic sampling again restores the pre-pause view selection.
If no mesh/depth points were collected, the viewer explains that no surface is available;
RGB-only captures still require reconstruction. This is the captured surface preview,
not a newly computed textured photogrammetry model.

Device check: acquire a head-region mesh, pause from Camera/Split/Head Model in both
iPad orientations, rotate/zoom and wait more than five seconds, then resume. Confirm
framing happens once, manual inspection stays put, and scanning returns to the previous
view without resetting the capture. Also pause before any surface is available and
confirm the empty-state message. The unsigned iPad app and test bundle compile; this
interaction still needs verification with captured LiDAR geometry on the device.

## Named sessions and mesh checkpoints (2026-11-04)

MANTA presents a session screen at launch. A new capture requires a nonblank
subject/session label, which is saved immediately with its timestamp and UUID.
The last active session is offered on relaunch; sessions with world-space evidence
are review-only after relaunch. A named session with no world-space evidence can
still begin its first scan. Opening the Current library row leaves its live AR
world intact. Changing the net before capture preserves the label, timestamp, UUID,
and context; changing it after samples, a saved mesh, or electrode results requires
an explicit new session.

Stop Auto checkpoints the full ARKit mesh, the head crop when available, and session
metadata while leaving tracking active. Pause checkpoints and stops tracking.
Switching to another saved session or starting a new one checkpoints before clearing
live anchors. Entering the background stops automatic sampling and checkpoints;
this is best-effort protection, not a guarantee against force-quit or power loss.
Mesh write failures are shown and prevent session switching. Atomic mesh writes
preserve the prior file if replacement fails. Deleting the current session deliberately
discards it and returns to naming without recreating its folder.

Regression coverage in `CaptureSessionLifecycleTests`: stop/pause identity and
mesh persistence, switching saves the previous mesh, restore after relaunch, layout
identity/evidence preservation, retry after an actual filesystem failure, and deletion.
Device acceptance: name a session, scan, Stop Auto, resume, Pause, resume, then switch
sessions. Confirm the original session has its full/cropped PLY and unchanged label,
UUID, observations and landmarks. Relaunch and verify review of the saved surface.

## Receiver conversion destination permissions (2026-11-04)

**Superseded for native folders on 2026-11-05:** iPad working folders and existing
logical packages now open in place. Only legacy ZIP archives prompt for an
extraction destination. A selected capture folder grants access to its own
`derivatives/` subtree; access to its parent is not assumed. Archive extraction
still uses collision-safe names and keeps security-scoped access active.

Receiver shows the current opening stage, current file, byte-weighted progress for
indexing/integrity checking, and elapsed time. Metadata parsing, ZIP extraction, and
viewer preparation use an indeterminate indicator rather than a fabricated percent.
Work runs off the main actor and forwards only the newest progress update.

Acceptance: open a finished native session directly, inspect camera/depth/mesh data,
save a head-box edit, reopen, and confirm the new crop and metadata are confined to
`derivatives/receiver/`. Verify every original file is byte-identical. Reopening must
retain derivative identity and history. Repeat with a logical RAW package and a
legacy root-level PROCESSED package. Cancel a legacy archive destination choice and
confirm the previously opened capture remains.

Verification for these changes: Receiver's macOS target builds successfully. On the
iPad Pro (M5) iOS 27.2 simulator, all 19 selected session/persistence tests and the
launch/name/relaunch UI test pass. The export-provenance test now validates the
existing directory-package output instead of sending it to the legacy ZIP importer.
Actual LiDAR collection and Finder drag/drop with sandbox grants still require the
device/Mac acceptance steps above.

## Explicit acquisition completion (2026-11-05)

Hold Pause (or Resume/Start while paused), slide onto **Save and End Session**, and
release to select the native context-menu action. Releasing outside the menu cancels.
A normal tap continues to pause/resume. The action is available in landscape and
portrait iPad controls and the compact phone bar. The native menu is also accessible
through standard accessibility context-menu interaction.

Ending stops automatic samples and AR tracking, invalidates pending still requests,
saves full/cropped mesh and metadata, and writes the capture receipt off the main
thread. Receipt findings are advisory and shown in the completion message; they do
not claim metrological validity or prevent an operator from ending a short/test pass.
A mesh, metadata, or receipt write failure leaves acquisition paused and unfinished
for retry. Only after successful writes does the session receive an optional `endedAt`
timestamp and an acquisition event. Legacy sessions decode without this field.

Ended sessions remain named and open for review, processing, and export. Their capture
controls are disabled, including after relaunch, and the library marks them Ended.
A new explicit session is required to collect more data. Ending does not create an
export, transfer files, or run photogrammetry. Later export uses the saved final mesh;
backgrounding/export cannot overwrite it with residual live anchors.

Pause/resume now retains the existing AR configuration even before the first RGB/depth
sample. The tracking-world lifetime is separate from the observation count; only New
Session resets that lifetime. Capture settings require a new session once tracking
has begun, so resuming cannot silently replace the coordinate world.

Acceptance: acquire a surface, tap Pause and Resume, then hold Pause and slide off the
menu (capture remains active). Hold again and slide onto Save and End Session. Check
for the saved PLY, completion timestamp, receipt, and disabled acquisition controls;
verify review/export and relaunch. Also scan a surface before saving any samples,
pause/resume, and confirm the head box and mesh retain their coordinate frame.

Verification: the iPad and Receiver targets build. All 24 selected session, persistence,
and capture-safeguard tests pass. The iPad UI test also passes a continuous hold/slide
selection, cancellation before selection, completion, and relaunch with acquisition
still disabled. The receipt worker and its value types are explicitly nonisolated;
validation runs off the UI thread. Real LiDAR pause/resume before the first sample
still needs the on-device acceptance check above.

## Acquisition A3: motion safeguards (software implemented; physical tests pending)

Define the head region and scan the stationary head before using **Freeze Stable Head
Reference** in the capture settings. This freezes at most 2,048 cropped mesh points;
it is not a continuously updated reference. Each candidate sample compares sparse
high-confidence depth in that region against the frozen points. Missing depth,
changed bounds, limited tracking, too few points, or poor overlap produces an
insufficient-evidence message. A consistent residual is not proof of no movement.

Use **Subject Moved** immediately when movement is observed. Suspected geometric
movement also stops the pass. Existing and queued evidence is retained, live
annotations/mesh guidance are hidden, and a new named session/pass is required.
Segment IDs are separate from ARKit tracking state. No transforms or automatic
registration are invented. A durable `acquisition/motion-stop.json` protects the
movement flag across checkpoint recovery before full metadata catches up. Quality
metadata travels in exported observations. Automatic iPad processing and Receiver/CLI
reconstruction, Receiver detection, and depth fusion reject known suspect evidence or
multiple head segments rather than merging them silently. RAW export/review remains
available. Review and selective salvage are later A6 work.

Bench acceptance, deferred until the combined acquisition trial:

1. Freeze a well-covered stationary head-object reference; move only the camera.
   Measure false alerts, residuals, processing time, and insufficient-overlap frequency.
2. Translate and rotate the object by independently measured amounts. Record misses
   as well as detections. Test smooth/symmetric areas, edge views, occlusion, low depth
   confidence, and the head leaving its bounding box. Large movement may be unknown.
3. Verify manual marking during queued writes and a pending still request. Confirm
   no subsequent capture resumes in that session, no stale guidance returns, and the
   next session receives a different segment ID. Re-place fiducials on the new pass.
4. Terminate after movement marking but before metadata refresh. Recover on iPad and
   Mac; confirm flagged observations remain rejected by automatic processing.
5. Verify that all source images/depth remain available for later reviewed salvage.

Current algorithm limits: checks run on sampled frames, not every video frame; an
operator-frozen reference can itself be incomplete or contaminated. The provisional
25 mm median threshold and 60 mm correspondence radius are not millimetre motion
accuracy. Subtle motion, rotation on symmetric geometry, and deformation may be
missed. Automatic alerts stop conservatively; the operator can always use a separate
repeat pass. Threshold promotion requires the physical tests above.

A3 software validation (2026-11-05): 121 core tests pass, including consistency versus
known displacement, insufficient overlap, motion metadata round-trip, rejection of
mixed/suspect segments, and recovery from a durable movement marker plus newer frame
checkpoints. Unsigned iPad integration tests compile and the reconstruction CLI builds.
Physical checks and iOS runtime execution remain deferred.

## Acquisition A4: sharp views and label coverage (physical acceptance pending)

Recommended workflow for the combined M5 trial: start one tracking/depth session,
then pause the camera at front, left, right, back, and top views for sharp label
photos while the participant remains still. Continue tracking and depth acquisition
throughout; use continuous sampling between those views and revisit unread areas.
These five views are a starting checklist, not evidence of complete net coverage.
The ordered checklist/recapture UI is A5 work. Each still retains its own calibration
and pose; RGB-only stills need not have depth to contribute label sightings. A3 still
requires a separate pass if the head moves. Verify concurrent hi-res/depth behavior
before promoting this one-session workflow on the device.

- Automatic still capture: experimental high-resolution mode, normal tracking, cool
  enough device, at least five seconds between requests, at least 0.3 seconds of
  camera steadiness (angular speed <=5 degrees/s and translation <=0.02 m/s), sharpness
  >=0.025, and a camera-direction sector with no successfully saved sharp still.
  Freshness is checked and a blurred delivered still is rejected. Manual **Take Label
  Photo** bypasses novelty/hold gates for difficult views; thermal/storage/world guards
  remain. The operator sees a hold-iPad-steady prompt. It does not measure head stability.
- Adaptive sampling is opt-in and locked at start. The existing timer remains the
  minimum opportunity interval; novelty (2 cm or 5 degrees), an unseen camera direction,
  or a three-second maximum gap admits a sharp frame. The maximum gap never overrides
  the blur gate. Presets retain conservative adaptive-off settings. Sectors describe
  camera orientation, not validated anatomical coverage.
- Live OCR prioritizes stills and considers every third eligible regular frame,
  keeping at most one pending frame with priority for stills. Low-confidence/non-numeric
  text does not complete coverage. Duplicate label detections within an image and
  geometric suspects remain ambiguous. Distinct-view support requires separate image
  IDs and at least 2 cm translation or 5 degrees optical-axis change. OCR confidence
  is not calibrated label accuracy, and repeated misreads remain possible.
- RGB-only or motion-unassessed images can establish unverified label sightings;
  missing depth/insufficient motion evidence cannot produce trusted live 3D detections.
  Counts distinguish read, supported, ambiguous, localized, and not-yet-read labels.
  Inferred coordinates are hidden during live tracking. Coverage resets on session
  changes/movement and does not claim to restore a completed survey from a saved session.
- Advisory sightings are saved under `acquisition/live-labels/<observation UUID>.json`
  with label, confidence, native-image center, and ambiguity. Available sidecars travel
  in exports/recovery. Live OCR can skip frames under load; the Mac recomputes final
  results from all original images. An export is a snapshot of completed sidecars.

Bench tests: verify steady/blurred/manual still behavior, thermal and queue fallback,
saved-sector retries after write failure, adaptive overlap and maximum-gap behavior,
RGB-only label readings, duplicate/confused labels, independent-view support, and
memory/latency over a full 256-channel scan. Confirm five initial views do not hide
unread electrodes, and compare live sightings against manually annotated images.
Software thresholds are experimental; no measured yield or accuracy gain is claimed.

A4 software validation (2026-11-05): all 125 core tests pass. Added coverage for
minimum-gap/novelty/blur gates, fresh steady-view still gating, distinct-view support,
duplicate/ambiguous labels, invalid poses/low confidence, and inclusion of optional
live-label sidecars in recovered RAW bundles. The unsigned iPad app/integration tests
compile. No iOS execution, physical yield, or thermal validation has been performed.

## Acquisition A5: review, recapture, then release (physical acceptance pending)

Open **Review coverage / recapture** (or the checklist icon) without stopping the
session. The panel updates from live OCR while tracking/sampling continue. Select
front/participant-left/participant-right/back/top to return to the camera with a
named photo action. A checkbox requires a successfully written, sharp high-resolution
photo with that operator-assigned view tag. Untagged automatic/general photos are
still valid evidence; view tags neither alter calibration nor prove label coverage.
With hi-res disabled, use regular target frames; they do not satisfy a hi-res checkbox.

Choose an unread, ambiguous, or single-view label as a recapture target. Find it
visually on the net, reduce glare, and obtain another angle. No inferred target is
projected into the camera until head alignment and visibility can be validated.
Target identity is operator intent, never forced OCR ground truth. A target clears
only after live feedback has unambiguous distinct-view support; ambiguity may require
later manual review. If live OCR is disabled or has processed no frames, coverage is
unknown, not complete. Reopened sessions do not reconstruct the live coverage state.

Choose **Final integrity / release check** only after collecting missing evidence.
The confirmation states that capture will pause. The check stops admission, drains
accepted writes and the bounded live OCR backlog, saves a `captureReview` snapshot in
acquisition context, then pauses tracking and verifies files. The report includes
missing optional view tags, unread/ambiguous/single-view labels, processed live-frame
count, movement flags, and existing reference/export reminders. It is not an accuracy
certificate or proof that a destination copy has been received. Additional frames
invalidate the review and prior export IDs; checkpoint recovery applies the same rule.

Combined M5 acceptance (still outstanding):

1. Start one named capture with continuous sampling. Open review mid-scan; confirm
   tracking identity and sampling remain active. Visit five views and capture tagged
   stills. Exercise queue-full, write failure, blur, and an untagged automatic still;
   none may falsely complete a view checkpoint.
2. Deliberately miss several labels. Select unread and single-view targets, capture
   additional views, and verify feedback against manual image inspection. Test live
   OCR disabled, busy, empty, and ambiguous cases. Five checked views must not imply
   all labels were read.
3. Trigger A3 movement during a target request. Confirm stale guidance clears, targets
   cannot resume the invalid world, and the next pass has independent evidence.
4. Run the final check with queued frames/OCR. Verify it waits, pauses, reports gaps,
   and persists the snapshot. Resume a valid live session and add a frame; confirm old
   review/export status clears. Repeat with termination before session metadata flush.
5. Finalize/export, verify the destination copy, and reopen on Mac. Inspect original
   RGB/depth/calibration, optional view/target metadata, and the acquisition review.

Software checks cover saved/queued/blurred/untagged/suspect checklist cases, optional
metadata round-trips, and stale-review/export invalidation after checkpoint recovery.
An iPad integration test asserts that review/target selection does not pause tracking
or replace session identity; it is compiled, not yet executed on iOS. Device workflow,
layout, recognition yield, and transfer checks remain pending.

A5 software validation (2026-11-05): 128 core tests pass; the unsigned iPad app and
integration-test bundle compile. The combined A1–A5 physical M5 rehearsal remains
outstanding before another subject. Precise camera overlays and Receiver offline
view-tag editing are explicitly deferred, not claimed as implemented.

## A6: reviewed stable-segment recovery (experimental; physical acceptance pending)

Use the [Mac recovery workflow](SEGMENT_RECOVERY.md). Select overlapping stable
intervals explicitly; record matched landmarks in each source world. Report-only is
the default. Derived output requires every segment and individual depth-frame check
to pass, and never overwrites inputs or a previous output. Low fit residuals are not
independent accuracy measurements.

Software regression coverage includes known rigid rotation/translation, metric scale
preservation, degenerate geometry, scale mismatch, inadequate overlap, transformed
camera/ray consistency, correction provenance, mixed/invalid correction rejection,
and explicit Object Capture rejection for recovered inputs. End-to-end tests build
two synthetic depth packages, derive and reopen a valid merged package, confirm
source metadata remains unchanged and suspect flags retained, reject changed derived
camera poses, and exercise inconsistent individual frames, missing stable review,
RGB-only stills without nearby depth, report-only output, and overwrite protection.

Physical acceptance remains required:

1. Acquire stationary head-phantom controls and camera-only movement. Split reviewed
   stable intervals, and verify recovery introduces no measurable localization loss
   relative to a single pass and independent reference coordinates.
2. Move the rigid head phantom by independently measured translations and rotations
   between passes; reacquire overlapping views. Evaluate transform errors and final
   electrode errors against reference measurements, including held-out landmarks.
3. Include a moved frame inside an otherwise stable interval. Test poor overlap,
   smooth/symmetric regions, incorrect landmarks, background inclusion, low confidence,
   occlusion, blur, deformation, and net slippage. Record false accepts and rejects.
   A small geometric residual must never be reported as an electrode-error bound.
4. Inspect preserved high-resolution photos, recomputed depth and image rays in the
   common reference frame. Check RGB-only timestamp association at the one-second
   boundary. Place final fiducials on the rebuilt surface; do not reuse stale source
   meshes, solutions, or coverage.
5. Import a derived package in Receiver, rebuild depth and rerun detection. Confirm
   original suspect passes still block automatic processing, malformed/mixed
   correction metadata fails, and both Receiver/CLI Object Capture reject recovered
   packages until masking and pose handling are implemented and validated.

Select/freeze thresholds from these measurements. No physical M5 testing or
independent recovery-accuracy validation has been performed. Automatic interval
selection, per-frame correction, estimated-camera integration, and Receiver selection
UI remain open A6 work; no continuous-motion acquisition capability is claimed.

A6 software validation (2026-11-05): all 134 core tests pass, all Mac CLI targets
build, Receiver builds, and the unsigned iPad app/integration-test bundle compiles.
CLI smoke checks pass for help, missing/unknown arguments, malformed JSON, and the
selection size limit without creating output on errors. `git diff --check` passes.
Existing app/Receiver concurrency, unused-value, and orientation deprecation warnings
remain; no physical device or Receiver interaction tests were performed in this pass.

## H1/H2: head-only readiness and honest geometry review

Use **No Net / Head Mesh Only**. In **Head readiness and review**, set a head region
from the live camera, scan enough stationary geometry, then freeze the reference.
Collect overlapping views of the front, sides, rear, crown, and behind the ears;
optional photo tags do not require five discrete capture sessions. Fiducials remain
optional. Changing the head region clears the prior motion reference and cached
crop/review/export references, preserving raw frames and the full environment mesh.

**Save and inspect head surface** pauses admission/tracking, drains accepted writes,
and saves the current surface before opening the manually orbitable model. It does
not end the session or declare the surface complete. Inspect for missing regions,
holes, and doubled surfaces. A suspect pass stays flagged and requires a separate
pass; opening review does not clear that flag.

**View coverage** counts camera-position sectors relative to the selected head
center in capture-world axes. It is unknown without a head region. Repeated views,
blur warnings, unknown sharpness, suspect motion, invalid poses, and unsaved frames
do not inflate it. It is not surface area, anatomical coverage, or localization
accuracy; even 24/24 cannot certify a complete head.

The evidence panel separately reports recorded depth/confidence frames, head-crop
and full-mesh references, blur warnings/unknown sharpness, and motion assessment
counts. Recorded file references are not decoding checks. RGB-only stills remain
valid image evidence and no longer trigger a blanket missing-depth percentage
warning. The final review stores this summary in optional `captureReview.geometry`;
legacy reviews without it still decode. Receipt checks continue to validate files.

Bench acceptance before a head-only person trial:

1. Start head-only and net sessions; confirm no GeoScan controls, reminders, or
   export choice appear. Import a legacy session and confirm reference metadata
   survives saving/export for Receiver.
2. Set/change/clear the head region, freeze a reference, and repeat. Confirm a region
   change requires a new reference and invalidates the old crop/review status.
3. Collect repeated views and omit the crown/rear deliberately. Confirm view count
   cannot substitute for manual surface inspection. Without bounds it reads Unknown.
4. Exercise RGB-only photos, depth without confidence, blur, missing quality, and
   unknown/suspect motion. Inspect saved evidence counts and final review JSON.
5. Save and inspect with pending writes; verify the saved crop opens, tracking pauses,
   and session identity is unchanged. Resume a valid pass; flag movement and confirm
   a new pass is required. Reopen exported data on the Mac.

Progression: bench object/head phantom with known dimensions → two stationary
head-only person passes → separate movement-recovery experiment → net/label trial.
Do not promote geometry or recovery accuracy from compilation or synthetic tests.

H1/H2 software validation (2026-11-05): all 137 core tests pass. Ten targeted
head-review/session-lifecycle tests executed successfully on the iPad Pro 11-inch
(M5), iOS 27.2 simulator, including saved-surface persistence, unchanged session
identity, legacy reference metadata preservation, crop/review invalidation, and no
GeoScan release prompts. The final unsigned device app/test bundle also compiles.
`git diff --check` passes. Physical head scans and visual/device interaction checks
remain pending; existing concurrency warnings are tracked as H3.

## H3: capture/export concurrency and completion

RAW and paired RAW/solved exports now share an explicit worker. Main-actor
preparation captures producer/device information and freezes mutable JSON sidecars;
workers receive Sendable values and source asset URLs. Deep receipt validation,
copying, finalization, and paired verification run off the UI actor with an owned
file manager. Original frame files are immutable during export. Final-review deep
receipt checks also run on a worker while the review guard remains active.

Session switching/deletion is locked before the first suspension. Accepted writes
finish and checkpoint errors stop export. Share URLs are published only after the
export succeeds and its bundle IDs are saved. A bounded latest-value progress stream
feeds one main-actor consumer; it finishes before UI state is cleared, preventing
late updates from a completed export. Cancellation finishes the current synchronous
file operation, then removes uncommitted output. There is no new cancel button;
this covers task cancellation and internal failure cleanup.

Regressions cover frozen metadata despite later working-context edits, main-actor
progress delivery with no late updates, off-main worker execution, paired-export
failure cleanup, cancellation before/during finalization, checkpoint failure, failed
receipt validation, lineage commit, source preservation, and session switching /
deletion during export. Older receipt fixtures now supply a real image and validate
current directory packages rather than feeding them to the ZIP-only importer.

Physical acceptance still pending: run a full-size M5 RAW and paired export, observe
UI responsiveness/memory/storage, background or terminate during work, recover the
capture, and transfer/reopen on Mac. Compilation and simulator fixtures do not
establish physical throughput or thermal behavior. Receiver reconstruction actor
warnings and iPad orientation deprecation remain separate follow-ups.

H3 software validation (2026-11-05): all 137 core tests pass. Xcode reports 54
selected simulator tests passed (including parameterized runs), zero failures and
zero runtime warnings on iPad Pro 11-inch (M5), iOS 27.2. The final unsigned device
app/test build succeeds with `SWIFT_STRICT_CONCURRENCY=complete`; capture/export
concurrency diagnostics are resolved without suppressing checks. Legacy test suites
now call main-actor app APIs from the main actor, with immutable parameter arrays
available to nonisolated test discovery. `git diff --check` passes. Full-size physical
M5 capture/export validation remains pending.


## R1 — Receiver opening and derivative storage (2026-11-05)

- Core regression suite: 140 tests pass, including stable in-place indexing with
  submillisecond source timestamps, unchanged source metadata, changed-acquisition
  rejection, the reserved derivatives directory, symlink escape rejection, and
  intermediate byte progress through a 2 GiB file.
- Receiver Debug build succeeds. `MANTAReceiverTests/run_regression.py <derived-data>`
  links a generated-fixture harness against that build to exercise the real save
  and reload policy: head-crop/fiducial edits, stable lineage, cumulative change log,
  unchanged acquisition/index bytes, and rejection of mismatched processed identity.
- A collected head-only folder opened in the UI with a visible indexing progress
  bar, 49 RGB-D frames, and a 49,075-point fused preview. All 251 original files were
  SHA-256 compared before/after opening; none changed. Only acquisition-index JSON
  was created under derivatives. The saved receipt reports 49 decoded image/depth/
  confidence payloads; it is not a geometric accuracy result.
- Physical review remains open: preview gaps/stray triangles, 15 blur advisories,
  and all 49 frames carrying unassessed motion status. No automatic movement recovery
  or validated full-head surface is claimed. Photogrammetry requires a separate run.


## Automatic overlay screening (2026-11-05)

Receiver now accepts automatic surface registration only with a finite, nonnegative
symmetric RMS at or below 10 mm (previously 50 mm). This is a conservative screening
policy, not a validated head-localization accuracy threshold. The viewer and saved
package status report the measured residual and screening status without a green
accuracy badge. A subsequent explicit manual alignment remains identifiable as
manual, even after unrelated edits.

Saved automatic fits are re-evaluated on open. A rejected placement is removed from
the in-memory capture while its model and original stored files remain intact.
Missing or malformed automatic-fit diagnostics block automatic placement; transforms
without identifiable automatic provenance are labeled unverified. A rejected photo
model remains available on its own and in Align. Both LiDAR and fused-depth toggles
exclude an unplaced photo model, including after asynchronous capability refreshes.

The Receiver regression harness covers 9/10/10.1 mm boundaries, the observed 46.7636 mm
legacy accepted fit, nil/nonfinite/negative residuals, missing/malformed evidence,
manual precedence, preview isolation, and depth/photo toggle exclusion. These checks
supplement the derivative save/reopen regression. Reopen the collected Medium model:
it should show “Overlay blocked: 46.8 mm RMS” and allow independent photo inspection.


## Visible manual high-resolution capture (2026-11-05)

Both iPad control rails expose **Hi-Res Photo** immediately below **Sample Frame**.
The latter remains an ordinary AR frame. Manual high-resolution stills default to
on; automatic stills are a separate opt-in setting (also enabled by the Validation
preset). Explicit Baseline RGB-D keeps stills off to prioritize synchronized depth.
The button shows unavailable reasons and only reports saved dimensions from a
completed high-resolution observation, after payload/checkpoint writing succeeds.
It uses the existing manual request path, retaining view/label tags and device,
thermal, queue, and storage checks; it does not change formats mid-session.

M5 acceptance: start a new session with defaults, tap Hi-Res Photo, and confirm the
saved width/height against the image and `high-resolution-still` provenance. Check
that automatic sampling alone does not request stills unless opted in. Verify both
iPad orientations, interrupted/failed writes, and unsupported-format feedback.
Confirm scene depth availability with the selected still-capable format: requesting
high-resolution capture does not guarantee simultaneous RGB-D on every device.

Software verification: iOS device build succeeds; both CaptureSafeguardsIntegrationTests
pass on the iPad Pro 13-inch (M5), iOS 27.2 simulator, including the new manual-on /
automatic-off defaults and explicit preset overrides. Actual still payloads and depth
coexistence require the physical M5 checks above.


## Receiver image orientation repair (2026-11-05)

The first collected session contains upright sensor-native PNGs tagged `down`.
The acquisition mapping confused the landscape directions of UIInterfaceOrientation
and UIDeviceOrientation. Future captures now map interface landscapeRight to `up`
and landscapeLeft to `down`; portrait mappings remain unchanged.

Receiver's Camera and Align image panels resolve legacy landscape tags against
projected gravity from the saved ARKit camera pose. The correction requires an
ARKit-world/top-left image with a finite pose and a strong vertical gravity component
(at least 0.5, larger than the horizontal component). Ambiguous overhead views,
non-ARKit frames, malformed poses, and portrait tags retain the declared orientation.
Registered segments use the preserved original acquisition pose. No image pixels,
depth arrays, intrinsics, or saved metadata are rewritten. Rendering, overlay markers,
and inverse landmark-click mapping share the resolved display orientation.

Verification: Receiver builds; all three CaptureSafeguardsIntegrationTests pass on
the iOS 27.2 M5 simulator, including all four interface orientations. The Receiver
harness renders an asymmetric PNG in all four orientations and verifies each pixel
center and inverse click, plus legacy/valid tags, ambiguous/malformed/non-ARKit poses,
and original-pose recovery. A read-only audit resolves all 49 collected frames to
upright display. Physical acceptance still includes capture/reopen in both landscape
and both portrait orientations, including an overhead view.


## G1 — Top-route acquisition and movement fallback (2026-11-05)

The iPad now defaults to a camera/surface split with expand/restore controls and
Setup → Reference → Orbit → Photos → Review → Finish across the top. iPad uses
full-screen landscape (left or right); iPhone keeps its existing orientations. Instructions,
evidence, and the relevant action stay visible. Stations can be revisited or skipped;
advancing never arms a reference, invents photo evidence, or ends acquisition. Finish
requires its explicit validation/save action. Surface-review acknowledgement becomes
stale after another saved frame or a changed head region. Ended captures allow route
inspection without changing their stored progress.

Movement pauses the pass and returns guidance to Reference. “Save and start new pass”
first drains/saves/ends the old pass, then creates a new pass for the same subject,
records its previous session ID, and requires a new head region/reference. It does
not merge surfaces or correct movement. If saving fails, remain on the old pass for
retry. Route metadata is retained in source session JSON, separately from canonical
coverage and geometric-quality evidence.

Physical acceptance: on the M5, rehearse every station in both landscape directions,
verify that holding the device upright does not rotate the app into portrait,
expand/restore both views, jump ahead and revisit skipped checks, freeze a reference,
collect tagged and untagged stills, inspect the saved surface, and explicitly finish.
Deliberately move a rigid head fixture, verify the paused recovery guidance, use the
linked-pass action, and reopen both passes. Confirm the old images/depth are retained,
subject/layout/settings are preserved, and the new pass has no armed old reference.
Test busy/failed writes and a retry. No simulator test establishes depth/still support,
motion sensitivity, or usable surface accuracy.

M1 in the roadmap is the next motion-recovery work, not shipped correction. Its
acceptance requires known-motion and stationary controls, held-out geometry/landmarks,
explicit rejection of uncertain/symmetric fits, foreground/background separation,
and consistent corrected photo/depth poses. Keep net slippage and deformation apart
from rigid motion, and preserve all original evidence for comparison.

Software verification: all 143 core tests pass, including skipped/revisited route
state, review invalidation, and legacy decoding. Four route integration tests pass:
advancement does not arm a reference/end a session, linked recovery retains the old
pass, failed saving prevents replacement and permits retry, and ended-route inspection
does not rewrite saved progress. All eight capture lifecycle regressions also pass.
The iPad UI test covers route navigation, skipped checks, the separate Finish action,
split expand/restore, both landscape directions, and remaining horizontal when the
device is held upright. The physical-device build succeeds; built plist inspection
confirms the iPad-only orientation override and unchanged iPhone orientations.
Full-screen simulator screenshots were visually checked in both landscape directions;
the route, guidance, both panes, and control rail fit without overlap. A reference
image is saved in `Docs/Design/capture-guidance-2026-11-05/implemented-landscape.png`.

## Continuous capture during movement (stage 1)

Automatic motion assessments no longer stop acquisition or mark an entire pass
suspect. Each saved frame retains its own admission assessment. A mismatch or
insufficient overlap holds that frame out of live depth fusion and electrode
localization. Three distinct, chronological consistent observations clear a
transient hold; three consecutive mismatches latch a hold pending alignment.
Duplicate or older frames cannot advance either counter. These counts are
provisional behavior settings, not validated movement accuracy thresholds.

Recording and raw export continue while held. Previously accepted points and
labels remain available. Held stills do not satisfy guided-photo checkpoints,
and uncorrected held frames cannot enter stationary reconstruction. The ARKit
accumulated mesh remains frozen at its last pre-hold snapshot for the rest of
that capture, even if per-frame depth fusion resumes: ARKit cannot remove the
uncertain samples already integrated internally. Live camera fiducial placement
is disabled against that frozen surface. Explicit **Subject Moved** and actual
tracking, storage, and write failures retain their existing stop behavior.

Device checks on a LiDAR-equipped iPhone/iPad:

1. Freeze a reference and collect trusted depth/labels. Orbit without subject
   movement; verify sampling continues if overlap briefly becomes insufficient.
2. Briefly obscure the head, then return to the reference view. Confirm held
   frames are saved, prior preview points remain, and only three new consistent
   observations resume per-frame model updates.
3. Move the head enough to produce sustained mismatches. Verify recording and
   sample counts continue, new frames remain excluded, and prior observations
   retain their original assessments after export/reload.
4. Capture a guided photo during the hold; verify it is saved without marking
   the view complete. Confirm stationary reconstruction rejects held frames.
5. Check explicit stopping and storage/write-failure handling still work.

The stage 1 gate itself does not estimate a pose; the stage 2 recovery below
can release it after validating a rigid alignment.

## Automatic on-device recovery (stage 2)

Recovery runs on the capturing iPad/iPhone, off the main actor. While recording
continues, it attempts the existing ambiguity-rejecting rigid multistart solver
against up to six trusted depth reference views (or the frozen reference mesh
when no views are available). One solve runs at a time, with a minimum three
seconds between attempt timestamps. A candidate must agree with three later,
distinct, spatially supported depth observations before model updates resume.
Every subsequent corrected frame must also pass the tighter registration gate.
A further movement starts another recovery against the original reference frame;
transforms are not compounded from one recovery to the next.

The search is bounded to the last known head region plus 10 cm per side while
held. This is geometry-based recovery, not an electrode-identity/net detector.
Insufficient overlap, ambiguous rounded shapes, continued movement, or a head
outside that search region can leave fusion held while recording continues.
Accuracy, false acceptance rate, and iPad latency require real-device validation.

Accepted frames store a corrected camera pose and `quality.liveMotionCorrection`
containing the original pose, rigid transform, reference segment, validation
count, and method. Depth/RGB pixels are unchanged. Raw exports retain held frames;
metric processing can omit held frames from that same recovered segment while
using trusted and corrected frames. Other segments and malformed corrections
still block processing. Image-only reconstruction requires the independent masked
workflow; it cannot reuse these corrected poses as Object Capture constraints.
The accumulated ARKit mesh remains frozen; corrected per-frame depth builds the
live and Receiver fused point clouds.

Additional device acceptance checks:

1. Translate/rotate a rigid asymmetric head phantom, then settle. Verify capture
   never stops, a candidate requires three subsequent frames, and the fused cloud
   rejoins the original without doubled surfaces. Compare independent landmarks.
2. Repeat with a second movement; check both corrections target the original
   reference, with no repeated application of the first transform.
3. Move during candidate verification, obscure depth, or use a symmetric shape.
   Verify rejected recovery leaves frames held and does not erase prior data.
4. Change the crop, reset the capture, or explicitly stop while a solve is running.
   Verify an obsolete completion cannot modify the new capture/reference.
5. Export/reopen on the Mac. Verify corrected poses, original poses, image
   orientation, and held-frame exclusion agree with the iPad result.

## Continuous net-relative tracking (phase 3)

With an electrode layout and live label detection enabled, the iPad uses two
complementary signals. Saved-frame OCR supplies label identities; bounded local
rigid depth registration updates the pose between label reads. Reference labels
require three distinct admitted observations agreeing within 8 mm, OCR confidence
at least 0.9, and high-confidence depth. At least four noncollinear matching labels
must support a rigid pose (RMS at most 5 mm; every match within 8 mm). Confirmed
reference labels never follow later samples. Held-frame labels can reacquire the
pose, but cannot establish new reference labels or become electrode measurements.

The tracker targets one background solve every 150 ms, with only one job in flight.
Depth is restricted to the neighborhood within 7 cm of confirmed net labels.
Local refinement uses at most 192 source points, 768 reference points, and ten
iterations. It requires 80% source overlap, RMS at most 8 mm, and a pose change
within 25 mm RMS point displacement and 12 degrees of its seed. Three consecutive
pose updates establish tracking. Label support expires after three seconds; delayed
OCR may refresh newer poses only when it agrees with the corresponding historical
pose. These are provisional gates, not independently calibrated accuracy claims.

Every saved frame is checked at its own timestamp and receives its own correction.
The depth search region follows the net pose; fresh, admitted views can extend the
reference coverage around the cap. The original head region remains in reference
coordinates for fusion. Missing identity support or failed depth tracking returns
to stage 2 recovery. Conflicting label geometry keeps fusion held until matching
labels agree again, rather than allowing a geometry-only recovery to override it.
Disabling tracking or changing the region cannot silently revert corrected capture
to uncorrected room coordinates. Reset/cancel guards discard obsolete async results.

Device acceptance additions:

- Orbit a stationary net: camera motion alone should not move the net reference.
- Keep capturing during slow continuous translation and rotation; verify correction
  matrices vary per saved frame and fused electrode locations stay fixed.
- Move around the cap to acquire additional labels and depth reference views.
- Cover labels for more than three seconds, then reveal them; recording must
  continue through loss and reacquisition without adding untrusted points.
- Introduce a duplicate/misread label, a rapid pose jump, and cap deformation;
  verify holds, preserved reference anchors, and recovery only with adequate support.
- Measure latency, thermal behavior, false acceptance, and electrode error on the
  actual iPad. The simulator/synthetic tests do not establish these outcomes.

This tracks a rigid net relative to its initial observed frame. It does not prove
that the net has not slipped relative to the scalp; that requires independent
anatomical evidence. Initial region/reference setup remains required.

# MANTA Roadmap: Validated Mac Processing and Platform Adoption

Date: 2026-11-03  
Reviewed source baseline: `2365e1d`  
Status: proposed implementation plan; this document does not implement the changes below.

This roadmap follows a code review of [ASSESSMENT_2026-11.md](ASSESSMENT_2026-11.md), the capture application, Receiver, `MANTACore`, and reconstruction CLI. It incorporates checks against Apple documentation and the installed Xcode 27.2 SDK. It supplements [VALIDATION.md](VALIDATION.md), [ARCHITECTURE.md](ARCHITECTURE.md), and [MLModels.md](../MLModels.md).

## 1. Direction and scope

Prioritize a reproducible Mac-side pipeline that preserves original capture evidence, improves camera calibration and geometry, and measures whether each processing change improves electrode localization. Use the iPhone/iPad primarily to acquire high-quality calibrated evidence and provide immediate operator guidance. Preserve existing on-device functionality while the Mac path matures.

Adopt useful macOS 26 capabilities first. Add macOS/iOS/iPadOS 27 features behind capability checks and explicit fallbacks. Platform adoption is a means to improve capture, reconstruction, or review; it is not itself an accuracy milestone.

The first implementation milestone comprises stages 1–3 below: establish a trustworthy baseline, share the processing pipeline, and consume Object Capture poses and calibration. More elaborate fusion and machine learning depend on this foundation.

### Scientific and architectural requirements

- RAW acquisitions remain immutable. Derived results identify their source bundle and processing configuration.
- Preserve measured, inferred, manually placed, and reviewed electrode states. Report their metrics separately.
- Reprocessing must not silently overwrite manual corrections or erase previous results.
- Declare coordinate frames, units, transform direction, image orientation, and calibration provenance at subsystem boundaries.
- Numerical geometry remains in `MANTACore`; RealityKit, Vision, and platform-specific decoding belong in adapters.
- A failed or unsupported optional feature must produce an explicit fallback or diagnostic, rather than a silently degraded measurement.
- Compare candidate methods on the same held-out captures. Do not tune and report accuracy on the same examples.

## 2. Assessment findings and corrections

### Confirmed in the reviewed code

| Finding | Relevant implementation | Implication |
|---|---|---|
| Electrode positions are averaged from depth back-projections with OCR/depth-confidence weights. | `MANTAReceiver/ReceiverElectrodeDetection.swift`, `MANTACore/.../ElectrodeObservationAggregator.swift` | The solve does not model different lateral and along-ray uncertainty. |
| Ray triangulation contributes a diagnostic rather than the final position. | `ReceiverElectrodeDetection.swift` | Multi-view image geometry is underused. |
| Close electrode estimates snap to a nearest mesh vertex. | `ReceiverElectrodeDetection.swift`, `ReceiverSurfaceVertexIndex` | Mesh tessellation can introduce lateral displacement. |
| Detection requires an image, valid camera calibration, and depth. | `ReceiverElectrodeDetector.detect` | RGB-only high-resolution observations currently cannot contribute. |
| OCR uses a thumbnail capped at 2,048 pixels and one orientation; cup proposals are sampled over approximately 24 frames. | `ReceiverElectrodeDetection.swift` | Recognition improvements need configurable sampling and image handling. |
| Reconstruction is duplicated between Receiver and CLI; Object Capture estimated poses are unused. | `ReceiverPhotogrammetryReconstruction.swift`, CLI `Reconstruction.swift` | Improvements can diverge unless the workflow is shared. |
| Depth fusion uses confidence-filtered voxel point averaging. | `MetricDepthPointCloud.swift` | Range, incidence, and boundary uncertainty are not explicitly modeled. |

### Corrections and qualifications

1. **Object Capture provides optional estimated calibration as well as poses.** `PhotogrammetrySession.Pose.intrinsics` and `.lensDistortionData` are available from macOS/iOS 26 according to the installed SDK. The roadmap must consume these when present instead of assuming that only poses are available. Missing values remain a supported case.
2. **Submillimetre localization is unproven.** Pixel-to-ray precision is one component of error. Pose uncertainty, motion, calibration, label ambiguity, and surface error also contribute.
3. **A depth-guided mesh is not independent LiDAR ground truth.** Residuals against that mesh are useful diagnostics, but shared input errors can conceal bias. Establish absolute accuracy with an independently measured phantom or reference system.
4. **Scale disagreement does not uniquely measure LiDAR bias.** VIO drift, imperfect correspondence, reconstruction, subject motion, and registration can also explain discrepancies.
5. **Posterior covariance is initially a model-based estimate.** Correlated views and uncertain poses can make naive inverse-information estimates overconfident. Validate empirical coverage before presenting uncertainty as calibrated.
6. **TSDF fusion does not guarantee a watertight or more accurate surface.** Coverage, truncation, motion, and extraction choices still matter. Advance it only after a comparison demonstrates value.
7. **Foreground/person segmentation does not guarantee a clean head mask.** Protect electrodes and fiducials from mask erosion and retain review/fallback paths.
8. **Vision revision pinning does not freeze OS-provided model behavior.** OS 27 regression reports justify benchmarking, but do not establish a MANTA regression. The Swift API is also not assumed to bypass the underlying issue.
9. **Landscape orientation and gravity conventions remain hardware-validation questions.** Do not change a transform solely because a plausible mapping appears in documentation or another sample.

### Baseline test result

The review ran the `MANTACore` package tests with Xcode 27.2: **73 of 74 tests passed**. `WorldAlignmentTests.seededICPDoesNotCollapseEstablishedScale` failed at its scale assertion: absolute error approximately `0.05327`, versus the permitted `0.02`.

Investigate this existing failure before evaluating a new alignment implementation. It is not yet classified as a solver defect, a test expectation problem, or a toolchain-sensitive numerical issue. The review did not establish application-build, real-device, or end-to-end accuracy results.

## 3. Platform policy

| Component | Proposed baseline | Optional enhancement policy |
|---|---|---|
| Receiver and new `MANTAProcessing` package | macOS 26 | Gate macOS 27 segmentation and Core AI features by availability and readiness. |
| Capture application | iOS/iPadOS 27 | Check hardware and model readiness independently of OS availability. |
| `MANTACore` | Retain existing deployment settings | Raise requirements only if its own implementation needs them. |
| Headless processing CLI | macOS 26 | Report unavailable optional backends and selected fallbacks. |

The application baselines were approved on 2026-11-03: macOS 26 and iOS/iPadOS 27. The shared core retains its lower deployment floors.

Build with an SDK containing the required APIs, but distinguish SDK availability from runtime OS, hardware, model-asset, and framework support. Record the actual capability selection in every processing report.

### Feature decisions

- **Object Capture poses:** existing capability predating OS 26; adopt early with stable sample IDs.
- **Estimated intrinsics and lens distortion:** OS 26 capability; include in the same calibration work.
- **Lens-smudge detection:** OS 26 capability; advisory capture guidance on supported devices.
- **High-resolution AR still capture:** existing capability, not an OS 27 prerequisite; verify supported formats and concurrent tracking/depth behavior on each target device.
- **Iterative segmentation:** OS 27 enhancement for editable masks; model assets require readiness/download handling.
- **Core AI:** evaluate as a 27 inference backend for trained detection/classification models. Preserve a supported 26 path.
- **Foundation Models image input:** optional review assistance only, after measurement and provenance work is mature.
- **Document recognition:** no initial adoption; electrode labels do not require document-layout understanding unless benchmarks establish a benefit.
- **Gaussian splats, rigid object tracking, and Structure Sensor integration:** separate experiments; none is a prerequisite for the core roadmap.

## 4. Stage 1 — Establish a reproducible baseline

### Implementation

1. Reproduce and investigate the existing scale-preservation test failure. Record the root cause and fix the implementation or test contract with evidence; do not simply widen the tolerance to obtain a pass.
2. Introduce a versioned processing configuration and run-report model. Record input hashes, source bundle ID, code/build version, OS/build, hardware, selected API/backend, Vision revision where exposed, parameters, and stage timings.
3. Freeze a small labelled OCR benchmark using representative cap images: portrait/landscape, rotated labels, glare, blur, edge-of-image labels, and confusable digits. Include expected disc centers where practical.
4. Prepare a real convention fixture with independently measured visible targets. Capture portrait and both landscape orientations, different viewing directions, and RGB/depth evidence.
5. Add diagnostics for projection/unprojection consistency, camera-axis conventions, gravity alignment, and image/depth correspondence. Preserve diagnostic overlays alongside numerical results.
6. Separate calibration/tuning captures from held-out validation captures, grouped by session or subject to avoid near-duplicate leakage.

### Outputs

- Versioned configuration and JSON report definitions.
- Labelled benchmark inventory and annotation instructions.
- Baseline OCR, alignment, localization, runtime, and failure reports where reference data exists.
- A documented hardware-fixture procedure and a list of unresolved conventions.

### Acceptance

- Core tests pass or any remaining failure has an explicitly documented unresolved cause; alignment changes do not claim success over an unexplained failing baseline.
- Repeated runs identify their exact inputs and settings and yield comparable metrics.
- Hardware fixtures verify the image, depth, pose, gravity, and unit conventions before dependent transforms are promoted.
- Missing independent reference data is reported as missing, rather than replaced with self-consistency metrics.

Software infrastructure can proceed while fixtures are collected. Hardware-dependent accuracy claims cannot.

## 5. Stage 2 — Share the processing pipeline

### Implementation

1. Add a macOS-only `MANTAProcessing` package depending on `MANTACore`, with platform adapters for RealityKit, Vision, and image decoding.
2. Extract the existing reconstruction preparation, execution, diagnostics, and output-finalization workflow first, preserving behavior before changing algorithms.
3. Define typed pipeline inputs/outputs and stage progress, cancellation, errors, and logs. Support bounded concurrency and cleanup of temporary files after cancellation or failure.
4. Make Receiver and CLI thin front ends over the same orchestration. Resolve whether to retain `manta-reconstruct` as a compatibility command or introduce `manta-process` alongside it.
5. Add a proposed command shape such as `manta-process <bundle-or-folder> --config config.json --report report.json`, with explicit output destination and meaningful exit status. This command is planned, not currently implemented.
6. Store derived artifacts and processing metadata using the existing validated bundle/lineage mechanisms. Reconcile differences between current persistence behavior and architectural documentation before defining new run history.
7. Associate manual edits with their source result. On reprocessing, preserve them and explicitly identify edits requiring reconciliation.

### Acceptance

- Receiver and CLI call the same implementation and produce equivalent scientific outputs for the same inputs/configuration.
- RAW hashes remain unchanged through successful, failed, and cancelled processing.
- Batch reports distinguish input-validation failures, unsupported capabilities, reconstruction failures, and successful solves.
- Existing derived bundles and review flows remain usable under the project's documented schema policy.
- Deterministic serialization is tested where controlled by MANTA; numerical equivalence uses justified tolerances where frameworks are not deterministic.

## 6. Stage 3 — Use Object Capture poses and calibration

### Implementation

1. Use `PhotogrammetrySample` sequences for both image-only and depth-guided processing. Preserve existing gravity/depth behavior deliberately rather than changing it accidentally during extraction.
2. Persist a one-to-one mapping between sample IDs, capture observation IDs, and source images. Never infer identity from folder enumeration order.
3. Request `.poses` alongside reconstruction. Consider `.pointCloud` as a diagnostic artifact rather than an automatic new solver dependency.
4. Persist estimated pose, optional intrinsics, optional distortion data, coordinate conventions, and sample status. Handle skipped or invalid samples explicitly.
5. Implement robust similarity fitting between corresponding camera centers, with outlier rejection and conditioning checks for insufficient or poorly distributed trajectories.
6. Verify transform direction, camera-axis convention, model frame, and scale using synthetic correspondences and the real fixture. Enable yaw-only fitting only after the gravity convention is established.
7. Preserve existing fiducial/PCA/ICP paths as explicit fallbacks. Report why the preferred alignment was rejected and which fallback was selected.
8. Use matching pose and image calibration for downstream rays. Validate distortion correction direction and pixel conventions; avoid applying correction twice.
9. Preserve original ARKit calibration as immutable acquisition evidence. Estimated calibration is a derived artifact, not an overwrite.

### Diagnostics

- Sample mapping completeness and rejected sample reasons.
- Camera-trajectory residuals, conditioning, inlier count, and scale.
- Model-up versus world-up angle, without treating it alone as proof of correct gravity handling.
- Held-out reprojection error and independent spatial alignment error.
- Estimated-calibration versus original-calibration comparisons, including edge-of-image behavior.

### Acceptance

- Synthetic tests recover known transforms and reject degenerate/outlier cases.
- Skipped samples cannot shift pose-to-image associations.
- Missing intrinsics or distortion data selects a documented fallback.
- Refined calibration improves held-out reprojection and independent alignment metrics, or remains opt-in if results are mixed.
- A global similarity fit is not assumed to remove nonrigid subject motion or all VIO drift.

## 7. Stage 4 — Improve electrode localization

### Implementation

1. Decouple 2D observations from depth availability. Represent image points, label candidates, camera calibration, and optional depth separately so RGB-only observations can contribute.
2. Replace nearest-vertex snapping with triangle-aware surface queries. Add acceleration structures when profiling justifies them, and retain surface normals and hit identity for diagnostics.
3. Define the target anatomical/physical point: visible disc/cup center versus scalp contact location. Do not force a cup center onto a scalp surface without an explicit geometric model.
4. Implement robust multi-view ray fusion with optional depth priors. Account for viewing baseline and reject ill-conditioned solves rather than treating repeated near-identical views as independent strong evidence.
5. Add anisotropic uncertainty for image localization and along-ray depth, with conservative pose uncertainty. Distinguish label confidence from geometric measurement uncertainty.
6. Use surface constraints only after alignment and surface quality checks. Handle occlusion, back-facing surfaces, missing triangles, and implausible ray hits.
7. Avoid double-counting correlated evidence: a mesh hit and a surface prior from the same reconstruction are not independent measurements.
8. Retain fallback estimates and explicit reasons when there is insufficient geometry. Add uncertainty metadata through a deliberate schema change.

### Acceptance

- Tests cover one view, weak baseline, well-separated views, outliers, missing depth, occlusion, wrong labels, and mesh gaps.
- Mesh tessellation changes do not cause arbitrary lateral jumps in the solution.
- Held-out localization error improves without an increase in accepted incorrect labels.
- Report uncertainty as estimated until its coverage has been measured against independent reference coordinates.
- Preserve distinct provenance for OCR-labelled observations, layout-assigned visual cups, inferred positions, and manual placements.

## 8. Stage 5 — Improve recognition and capture evidence

### Mac recognition work

- Add configurable full-resolution tiles and rotation passes, starting with 90-degree increments. Add finer rotations only if their measured benefit justifies the cost.
- Map tile/rotation detections back to native image coordinates and deduplicate them before counting support.
- Make cup-proposal sampling configurable; benchmark all-frame processing with bounded concurrency and memory.
- Compare legacy and Swift Vision text APIs on physical devices and Macs across supported OS versions. Test language correction/custom vocabulary rather than assume their interaction.
- Keep confusable labels as candidates until image and geometric evidence can adjudicate them. Layout agreement must not silently turn an ambiguous read into a confirmed observation.
- After an initial solve, search projected neighborhoods in additional images with visibility and appearance checks. Track these sightings separately to avoid self-reinforcing label assignments.

### Capture work

- Maintain a bounded frame-selection window and score sharpness, motion, pose novelty, and coverage. Preserve the chosen frame's own timestamp, pose, intrinsics, and depth association.
- Test periodic high-resolution still capture on each supported device/configuration. Store each still's actual dimensions and calibration; do not assume it shares a nearby video frame's pose or depth.
- Verify tracking continuity, depth availability, thermal behavior, capture latency, memory, and storage before enabling automatic high-resolution sampling.
- Add `DetectLensSmudgeRequest` as an advisory with capability checks and a measured false-warning rate. A warning must not indefinitely block capture.

### Acceptance

- Better correct-label recall at an explicitly measured false-label rate.
- No duplicate support inflation from tiles, rotations, or repeated searches of the same image.
- Capture improves usable image yield without unacceptable coverage loss or tracking degradation.
- Runtime, memory, battery/thermal behavior, and storage are measured; “no storage cost” is not assumed for high-resolution stills.

## 9. Stage 6 — Segmentation, model backends, and surface experiments

### Editable masks

1. Add conservative automatic mask proposals with a visible review overlay.
2. On OS 27, integrate `GenerateIterativeSegmentationRequest` for include/exclude points and other supported selection interactions.
3. Handle asset availability and the initial model download before an offline session. Provide a manual/older-API fallback when unavailable.
4. Persist masks in image coordinates with source-image identity, generation configuration, and manual-edit provenance.
5. Evaluate reconstruction with and without masks, checking especially electrode edges, ears, fiducials, and partial head views.

Acceptance: masks reduce background reconstruction without worsening relevant surface coverage or localization; users can correct or disable them.

### Cup detector and label classifier

1. Follow the detector-first direction in `MLModels.md`, with session-separated training/validation/test data.
2. Define a backend-independent interface for cup proposals and label probabilities.
3. Evaluate Core AI on OS 27; retain a supported OS 26 backend such as Core ML or the existing Vision/classical path, according to model feasibility.
4. Record model identity/hash, preprocessing, backend, and confidence calibration in run metadata.
5. Compare model quality, latency, memory, and failure modes against the improved classical/OCR baseline.

Acceptance: the model improves correct labels and/or review burden on held-out captures without hiding uncertainty or creating an unsupported mandatory dependency.

### Weighted depth fusion / TSDF

1. First add boundary rejection and range/confidence weighting experiments to the existing point fusion.
2. Calibrate depth bias/noise using independently measured targets. Mesh residuals remain supplementary diagnostics.
3. Prototype a bounded TSDF volume with explicit voxel size, truncation, weights, minimum support, and unknown-space handling.
4. Profile memory and runtime before selecting a CPU/GPU implementation. Do not treat voxel count alone as a performance guarantee.
5. Compare extracted surfaces and downstream alignment/localization against the simpler weighted point-cloud baseline.

Acceptance: retain TSDF only if it improves independently measured outcomes or a clearly documented fallback/review need. Do not fill unseen areas and present them as measured surface.

### Optional review assistant

Foundation Models image input may later help flag suspicious crops or summarize review findings. It must remain explicitly advisory, respect model availability, and never silently write scientific labels or coordinates. Human decisions continue through the existing audited review flow.

## 10. Evaluation and release gates

Each stage should ship behind a versioned configuration choice until its comparison is complete. Preserve the previous method for reproducible comparisons and rollback during development.

| Area | Required measurements |
|---|---|
| Recognition | Correct-label precision/recall, confusion pairs, missing labels, false positives, observed count. |
| Geometry | Held-out reprojection error, independent coordinate error, alignment error, conditioning and failure rate. |
| Uncertainty | Predicted uncertainty versus empirical error/coverage; separate systematic bias from spread. |
| Review | Manual corrections per scan, unresolved ambiguity, time to usable export. |
| Performance | Stage runtime, peak memory, storage, and device capture/thermal effects. |
| Reliability | Decode/reconstruction/solve failures, fallback use, cancellation, and partial-output handling. |
| Provenance | Source/configuration/model identities, RAW integrity, and preservation of manual edits. |

Use the provisional localization objective in `VALIDATION.md` as a research target, not an achieved specification. Define numerical promotion thresholds from the baseline and intended use before tuning each candidate. Report median, RMS, tail errors, and failure counts; a better mean alone is insufficient.

Recommended ablations:

1. Original versus estimated camera poses.
2. Estimated poses alone versus poses plus estimated intrinsics/distortion.
3. Depth averaging versus ray fusion versus ray fusion with surface constraints.
4. Existing OCR versus tiled/rotated OCR versus a trained detector/classifier.
5. Unmasked versus automatically masked versus reviewed-mask reconstruction.
6. Existing point fusion versus weighted point fusion versus TSDF.

## 11. Suggested implementation increments

1. **Baseline/configuration:** investigate failing test; add report/configuration models and benchmark instructions.
2. **Shared reconstruction:** extract existing workflow without algorithm changes; route Receiver and CLI through it.
3. **Sample identity and pose artifacts:** unify sample input and persist estimated calibration.
4. **Trajectory alignment:** add robust fit, diagnostics, fallbacks, and real-fixture validation.
5. **RGB-only observations:** remove mandatory depth coupling and preserve optional-depth provenance.
6. **Triangle-aware constraints and ray solve:** replace vertex snapping, then introduce uncertainty-aware fusion in separately measurable steps.
7. **Recognition upgrades:** configurable tiles/rotations/proposals and visibility-gated supporting observations.
8. **Capture upgrades:** frame selection, high-resolution still trial, and smudge guidance.
9. **Masks and OS 27 segmentation:** introduce editable masks with asset readiness handling.
10. **Model/TSDF experiments:** promote independently after comparative validation.

Each increment should include relevant unit/integration coverage, a baseline comparison where scientific behavior changes, and documentation updates. Avoid combining a package extraction with multiple numerical changes in one review.

## 12. Open decisions and required evidence

- Which iPhone/iPad/Mac models and OS versions constitute the supported test matrix?
- Which independent phantom/reference measurements are available, and what point on the electrode do they measure?
- Are real capture fixtures available with permissions and handling appropriate for a regression dataset?
- Does Object Capture gravity behave consistently with the current native-image convention?
- What intrinsics/distortion outputs are actually populated across the target devices and reconstruction modes?
- Which high-resolution capture formats preserve the required tracking/depth behavior on target hardware?
- Does OS 27 Vision change MANTA label recognition materially on physical devices?
- How should existing manual edits be reconciled when reconstruction or estimated calibration changes?

These questions should be resolved at the stage where they affect promotion. They do not block baseline reporting or extraction of the existing shared processing path.

## 13. Platform references

- [Object Capture pose results](https://developer.apple.com/documentation/realitykit/photogrammetrysession/pose) — estimated pose and optional calibration properties.
- [Object Capture poses request](https://developer.apple.com/documentation/realitykit/photogrammetrysession/request/poses) — sample-associated estimated camera poses.
- [Estimated pose intrinsics](https://developer.apple.com/documentation/realitykit/photogrammetrysession/pose/intrinsics).
- [Estimated lens-distortion data](https://developer.apple.com/documentation/realitykit/photogrammetrysession/pose/lensdistortiondata).
- [DetectLensSmudgeRequest](https://developer.apple.com/documentation/vision/detectlensmudgerequest).
- [Recommended high-resolution AR capture format](https://developer.apple.com/documentation/arkit/arconfiguration/recommendedvideoformatforhighresolutionframecapturing).
- [WWDC26: What's new in image understanding](https://developer.apple.com/videos/play/wwdc2026/237/) — iterative segmentation, model-asset readiness, and Foundation Models image input.
- [WWDC26: Integrate on-device AI models using Core AI](https://developer.apple.com/videos/play/wwdc2026/326/).
- [Apple Developer Forums: Vision](https://developer.apple.com/forums/tags/vision) — developer-reported OCR regressions; reports are motivation for local tests, not validated MANTA findings.

API availability was checked during the review, including the installed SDK declarations for OS 26 pose calibration. Recheck exact signatures and runtime requirements when implementing each adapter.

## 14. Stage 1 implementation update — 2026-11-03

- Application deployment floors raised to macOS 26 and iOS/iPadOS 27; CLI raised
  to macOS 26. Shared core floors remain unchanged.
- Initial pilot uses iPad Pro M5, Mac Studio M3 Ultra on macOS 26, and GeoScan
  on the same person/net. Exported
  coordinates target visible disc/cup centers; contact-point offsets are separate.
- Fixed the PCA seed's rotation-handedness check without relaxing the failing
  scale test. Added explicit proper-rotation and seed-residual checks.
- Added optional versioned run provenance to Receiver detection and Receiver/CLI reconstruction
  and persisted the actual OCR configuration, including explicit Vision revision.
- Added paired acquisition and OCR annotation procedures to `VALIDATION.md`.
- Stage 1 remains in progress: complete report/configuration coverage, benchmark
  execution, real conventions, and independent measurements are still required.

### GeoScan comparison increment

Implemented the shared strict TXT importer and rigid fiducial comparison engine,
plus `manta-compare` in the CLI package. Inputs are GeoScan-style TXT with explicit
units; reports preserve measurement flags, separate primary measured-only and
all-matched metrics, include fiducial residuals and unmatched labels, and record
input hashes. No scale fitting, electrode-based alignment, or automatic unit
inference is performed. MANTA bundle/SFP import and a Receiver comparison UI are
not part of this increment.

Validation: 83 core tests pass; the CLI builds and passes known-error, missing-unit,
and no-overwrite checks. Local parsing/self-comparison of the supplied S05 TXT
found three fiducials and 257 electrode/reference points, four flagged estimated.
This is a format check, not an accuracy result. Source units and paired acquisition
remain outstanding; current MANTA exports still require verified per-point
provenance before producing primary measured-only accuracy metrics.

### Receiver comparison workspace

Added a Compare tab and a standalone sidebar comparison dialog. Both support
GeoScan reference/candidate TXT selection with explicit units, or a snapshot of
the current capture as the candidate. The GUI displays summary statistics,
fiducial and electrode residuals, missing labels, and provenance warnings, and
exports JSON. GUI and CLI now use the same `GeoScanComparisonRun` for hashing,
comparison, and report encoding. SFP import and verified per-point provenance
remain separate follow-up work.

### iPad capture provenance and validation context

Added optional electrode provenance across working sessions, solved bundles,
Receiver review, CSV, and GeoScan-style TXT. Review state no longer serves as a
proxy for measured origin: only explicit image/depth observations export as
measured; inferred, layout-assigned, manual, synthetic, and unknown origins remain
estimated. Older records retain unknown provenance. Added the paired GeoScan
validation form and hardware/software metadata in capture-start events.
Best-frame selection and high-resolution capture remain future increments.

### M5 capture experiment implementation

Implemented opt-in recent-frame ranking for automatic sampling, experimental
manual/periodic high-resolution AR still capture, and an advisory lens-smudge
check. Capture uses frame-specific calibration and depth, bounded frame retention,
serialized still requests, thermal gating, and cancellation/session guards.
Requested settings and actual saved frame sizes/depth are logged. See VALIDATION.md
for the physical M5 trial; defaults remain conservative pending device evidence.
RGB-only electrode localization remains a separate downstream dependency.

### RGB-only offline electrode localization

Plan and implemented first increment:

1. Admit all calibrated images to Receiver detection, regardless of depth presence.
2. Cast each detected image point through its stored camera calibration against
   the saved, world-aligned photogrammetry triangle mesh. Prefer the nearest
   forward hit; compare with actual scene depth when available and fall back to
   scene depth if the disagreement exceeds 30 mm. Accept optical-axis depths only
   in the provisional 0.05–2 m range.
3. Store `depthSource` separately from confidence: aligned-mesh hits do not invent
   a LiDAR confidence value. Retain optical-axis depth, ray, and world position.
4. Preserve unlocalized OCR candidates and cup rays for later offline processing.
   They carry observation identity, native image point, OCR text/label candidates
   and confidences/bounds where present, and a failure reason. They are not 3D
   measurements. Evidence-only runs retain existing coordinates and can be saved.
5. Remove nearest-vertex snapping from the OCR-derived measured aggregate; keep
   vertex distance diagnostic only. Record image/mesh provenance independently of
   review state. Mesh-hit geometry still depends on reconstruction quality.
6. Raise Receiver OCR's long-edge decode cap to 4096 pixels and run classical cup
   proposals on every frame. Keep original images unchanged for future reprocessing.
7. Expose RGB-only review frames and pending-2D counts; permit detection without
   an aligned mesh so useful candidates can be saved before reconstruction.

Remaining increments: accelerated mesh queries if profiling requires them,
robust multi-view triangulation without a mesh, refined Object Capture calibration,
full-resolution tiled/multi-rotation OCR, calibrated uncertainty, and a visual
review/assignment tool for pending rays. A missing mesh hit never becomes a guessed
3D measurement. Re-run detection after saving alignment to retry pending evidence
from the original images. Real captures must validate occlusion/registration,
mesh holes, incorrect labels, memory, and runtime before accuracy claims.

### Pre-participant safeguards implemented

Added a pre-release validation/checklist screen using deep capture receipts,
per-observation checkpoint recovery, conservative interruption/reopen world guards,
visible high-resolution depth/tracking fallback guidance, and optional paired
cadence/selected-frame retention. The completion checklist records operator
confirmation of reference export and repeat acquisition. See VALIDATION.md for
limitations and physical bench tests. Next requested work: finish Object Capture
pose/calibration extraction and add an offline benchmark runner.

### Estimated calibration extraction and offline benchmark runner

Implemented a shared macOS `MANTAProcessing` library target within the local Swift
package. RealityKit adapters remain outside the portable `MANTACore` target.
Receiver and reconstruction CLI request estimated poses using explicit sample IDs
and export original ARKit calibration alongside optional estimated intrinsics and
lens-distortion tables. Rejected/missing samples and optional-request failures are
explicit; existing output artifact paths and RAW acquisition are preserved.

Added `manta-benchmark` for frozen labelled-image OCR cases and paired coordinate
comparisons, with configurable rotation passes, revision, resolution cap, input
hashes, runtime, TP/FP/FN metrics, and per-case failure reports. An example manifest
is in `Docs/BENCHMARK_MANIFEST.example.json`; CLI README documents the contract.
This is not yet a full Receiver detector/reconstruction batch scheduler.
Trajectory alignment, consuming estimated calibration in electrode rays, and
real-capture convention/accuracy validation remain separate work.

### Final pre-acquisition presets and storage guard

Implemented Baseline RGB-D and Validation experiments presets, a visible started-
settings summary, acquisition-log settings, and controls locked after saving frames
so a resumed coordinate world cannot silently adopt a different camera configuration.
Both presets select Both capture mode; baseline disables the experiments and
validation enables best-frame selection, cadence pairs, and high-resolution stills.

Added an independent two-second capacity monitor and per-observation write checks.
Below 3 GB warns; at/below the 1 GB reserve or unknown capacity pauses capture and
sampling, invalidates pending frames, and leaves existing evidence available for
finalization. Recovery requires explicit resume. See VALIDATION.md for the bench
protocol and the limits of capacity estimates. Core tests pass; unsigned iPad app
and integration-test compilation pass. Device execution remains outstanding.

### Receiver triangulation and nonblocking integrity follow-up

Removed silent depth/placeholder fallbacks from triangulation readiness, solver
inputs, and saved click evidence. Invalid forward intersections remain unresolved;
mode changes clear incompatible temporary clicks. Added geometry regressions for
nearly parallel rays, nonfinite input, coincident origins, and behind-camera points.

Restored streamed SHA-256 auditing with advisory warnings in Receiver and the
reconstruction CLI. Checksum/size discrepancies and legacy ZIP CRC mismatches do not
block otherwise readable imports. Missing checksums in working/legacy manifests
are accepted as unverified. Directory packages and in-place processed edits are
preserved; no new ZIP conversion or payload-sized allocations were introduced.
Regression coverage includes a known-hash sparse file larger than 2 GiB.

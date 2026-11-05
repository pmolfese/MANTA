# MANTA roadmap background and implementation history

Historical context retained from the roadmap on 2026-11-05. The active order and
status are in [MANTA_ROADMAP.md](MANTA_ROADMAP.md); plans below are not current
completion claims.

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

### Findings at the original assessment baseline

This table describes `2365e1d`, not the current implementation. Later increments in section 14 supersede several findings; the remaining work is ordered in section 11.

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

### Original baseline test result

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
7. Add `.github/workflows` CI for pushes and pull requests. Select a macOS runner and explicit Xcode version supporting Swift 6.2 and the Apple APIs used by `MANTACoreTests`/`MANTAProcessing`; do not assume any macOS image is sufficient. Run the core suite, including large-file integrity regressions, and retain failure logs. No participant data, physical iPad, signing identity, or successful GPU reconstruction is required for this initial job.

### Outputs

- Versioned configuration and JSON report definitions.
- Labelled benchmark inventory and annotation instructions.
- Baseline OCR, alignment, localization, runtime, and failure reports where reference data exists.
- A documented hardware-fixture procedure and a list of unresolved conventions.
- A CI workflow recording the selected toolchain and running the core regression suite on pushes and pull requests.

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

Current status: sample identity and estimated-pose/calibration export are implemented. Production localization still uses original ARKit cameras; reading the estimated records, trajectory fitting, and calibrated downstream camera selection remain planned. Exporting calibration alone does not improve localization.

### Implementation

1. Use `PhotogrammetrySample` sequences for both image-only and depth-guided processing. Preserve existing gravity/depth behavior deliberately rather than changing it accidentally during extraction.
2. Persist a one-to-one mapping between sample IDs, capture observation IDs, and source images. Never infer identity from folder enumeration order.
3. Request `.poses` alongside reconstruction. Consider `.pointCloud` as a diagnostic artifact rather than an automatic new solver dependency.
4. Persist estimated pose, optional intrinsics, optional distortion data, coordinate conventions, and sample status. Handle skipped or invalid samples explicitly.
5. Read `ReconstructionCameraRecord` artifacts and join usable estimates to original observations by stable identity. Implement robust similarity fitting between corresponding camera centers using deterministic RANSAC and/or trimmed refitting. Record inliers, rejected samples, residuals over capture time, scale, and conditioning; reject insufficient or poorly distributed trajectories. An accepted trajectory fit can align the model without requiring ICP or clicked fiducials, but those remain comparison/fallback methods.
6. Verify transform direction, camera-axis convention, model frame, and scale using synthetic correspondences and the real fixture. Enable yaw-only fitting only after the gravity convention is established.
7. Preserve existing fiducial/PCA/ICP paths as explicit fallbacks. Report why the preferred alignment was rejected and which fallback was selected.
8. Add a shared calibrated-camera provider used by Receiver and CLI. Keep original ARKit and accepted Object Capture calibration as explicit configuration choices and record the source per observation. Map estimated camera centers through the accepted similarity transform; compose rotations without accidentally retaining the similarity scale in camera orientation. Use matching image intrinsics and distortion handling for downstream rays, and update projection overlays consistently. Validate native-image dimensions, orientation, distortion correction direction, and pixel conventions; avoid applying correction twice. Missing estimates or optional calibration must select a documented fallback.
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
- Original ARKit, estimated-pose-only, and estimated-pose-plus-calibration runs can be compared on identical captures without overwriting source evidence or manual edits.
- Refined calibration improves held-out reprojection and independent alignment metrics, or remains opt-in if results are mixed.
- A global similarity fit is not assumed to remove nonrigid subject motion or all VIO drift.

## 7. Stage 4 — Improve electrode localization

Current status: localization supports aligned-triangle hits and scene-depth fallback; unlocalized image evidence is retained. A private Receiver electrode ray fit already contributes diagnostic/confidence information, while the final measured coordinate remains the aggregated depth/mesh position. The missing feature is a primary robust multi-view electrode solve, not the first existence of any ray-triangulation code.

### Implementation

1. Decouple 2D observations from depth availability. Represent image points, label candidates, camera calibration, and optional depth separately so RGB-only observations can contribute.
2. Replace nearest-vertex snapping with triangle-aware surface queries. Add acceleration structures when profiling justifies them, and retain surface normals and hit identity for diagnostics.
3. Define the target anatomical/physical point: visible disc/cup center versus scalp contact location. Do not force a cup center onto a scalp surface without an explicit geometric model.
4. Promote robust multi-view ray fusion to a primary coordinate method in shared geometry code. Include retained RGB-only/unlocalized sightings; do not require an existing depth/mesh position to admit a ray. Use OCR to associate identity and consistent visible disc/cup centers as the measured image points. Keep text-center fallbacks distinguishable from disc centers. Reject conflicting labels, bad reprojections, behind-camera intersections, and ill-conditioned viewing baselines; deduplicate sightings from one source image. Preserve depth/mesh methods for single-view or rejected solves, with explicit provenance. Keep surface and depth cross-checks separate from the mesh-independent triangulation result.
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
- Add padded crops around disc/cup proposals, with configurable upscaling and rotation. Benchmark full-frame, tiled, and proposal-crop passes independently and together. Rectification is a separate experiment requiring a trustworthy local orientation; upscaling is preprocessing, not recovery of missing image detail.
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

- Better correct-label recall at an explicitly measured false-label rate. Measure disc-center localization separately from OCR accuracy, including small, oblique, rotated, and edge-of-image labels.
- No duplicate support inflation from tiles, rotations, or repeated searches of the same image.
- Capture improves usable image yield without unacceptable coverage loss or tracking degradation.
- Runtime, memory, battery/thermal behavior, and storage are measured; “no storage cost” is not assumed for high-resolution stills.

## 9. Stage 6 — Segmentation, model backends, and surface experiments

### Editable masks

1. Add conservative automatic head/cap mask proposals on the Mac with a visible review overlay. A whole-person foreground mask is not automatically a head mask; preserve peripheral electrodes, ears, and relevant fiducials.
2. On OS 27, integrate `GenerateIterativeSegmentationRequest` for include/exclude points and other supported selection interactions.
3. Handle asset availability and the initial model download before an offline session. Provide a manual/older-API fallback when unavailable.
4. Persist/cache masks in native image coordinates with source-image identity, generation configuration, and manual-edit provenance. Feed them to `PhotogrammetrySample.objectMask` in both reconstruction front ends through a shared adapter. Check the required single-channel format and exact image dimensions/orientation. Load masks lazily with samples so a large capture is not resident in memory all at once.
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

## 11. Current implementation order — updated 2026-11-05

Acquisition milestones A1–A5 below are the gate before another subject: the cost of
net application makes missing or unusable capture evidence more urgent than offline
processing improvements. Complete and bench-validate these acquisition changes on
the available iPad Pro M5 before participant capture. CI (11.1) can proceed alongside
them. The remaining offline increments retain their relative order after this gate.
Software completion alone does not satisfy physical-device acceptance.

### 11.0 Acquisition milestones — pre-subject gate

These milestones implement the capture-ideas review of 2026-11-05. Checkboxes report
implemented work, not device validation or scientific accuracy. A1 and A2 have software increments;
A3–A5 are planned. Physical validation is deferred until the combined acquisition
changes are ready, at the user’s request; software checks continue per increment. Automatic registration in A6 is a separate proposed recovery
milestone; whether it must also precede another subject remains an open user decision.

#### A1 — Recoverable evidence and capture timings

**Why this will benefit MANTA:** A1 protects the images and depth already collected if the app stops unexpectedly, and makes capture bottlenecks measurable. A more reliable, diagnosable acquisition reduces the chance that an expensive net application produces an unusable session.

- [x] Share checkpoint merging between iPad reopening and Mac RAW-session recovery.
  Preserve existing observation metadata, deterministic ordering, and original RAW
  files. Reject unreadable/corrupt checkpoints instead of silently omitting them.
- [x] Reuse a camera-image `CIContext` per artifact store.
- [x] Record monotonic image/depth/checkpoint write durations and sample-save timing.
- [ ] Run the M5 baseline/experimental-format bench trial, including still/depth
  registration, tracking continuity, actual image dimensions, storage, and thermal load.
- [ ] Verify abrupt termination/reopening and Mac recovery on actual device artifacts.

Done when recovery preserves every completed checkpointed observation, incomplete
artifacts are not invented as frames, and a real scan identifies capture costs and
the supported hi-res/depth configuration. Use a bench object; no subject is required.

#### A2 — Bounded, responsive acquisition

**Why this will benefit MANTA:** A2 keeps image encoding and disk writes from stalling the capture UI and regular sampling. Bounded app-owned buffers protect ARKit tracking resources, while explicit backpressure and completion checks preserve usable evidence under load. Shorter, smoother scans reduce opportunities for subject movement.

- [x] Move encoding/writing to a bounded worker with owned RGB/depth/confidence buffers
  and immutable frame-specific calibration; release retained AR frames promptly.
- [x] Log queue pressure, dropped candidates, stage timings, and failed writes. Preserve
  session-generation guards and storage protection; drain work before finalization.
- [x] Batch full metadata/diagnostic writes after A1 automated recovery checks pass. Flush
  at stop, session changes, backgrounding where possible, and finalization. Checkpoint
  critical non-observation state independently; frame checkpoints do not recover it.
- [x] Schedule serialized hi-res requests independently of the automatic sampling loop.

Software implemented; physical acceptance remains pending. Full metadata/diagnostics
are batched at ten completed frames or five seconds on the next completion, with
explicit stop/finalization flushes. Critical settings/fiducials retain immediate
persistence. Three owned frame jobs are permitted, including the active write;
accepted jobs drain even on cancellation. A session switch/deletion during a drain
asks the operator to retry after saving finishes; export/end/release wait for drain.

Done when a sustained M5 capture remains responsive with bounded memory and explicit
backpressure, and cancellation/storage/termination tests preserve committed evidence.
Keep PNG; a new raw YCbCr format is deferred until measurements justify it.

#### A3 — Motion awareness and safe capture segments

**Why this will benefit MANTA:** A3 makes subject movement visible before it silently contaminates surfaces and electrode coordinates. Preserving separate stable segments and flagging uncertainty gives the operator a chance to collect a repeat or overlap while the net is still on, and gives later correction trustworthy source evidence.

- [ ] Add manual “subject moved” marking and stable-segment identities with timestamps.
- [ ] Add a conservative depth consistency advisory against a previously accepted
  stable reference. Track overlap/confidence and an insufficient-evidence state;
  avoid incorporating suspect frames into trusted fusion or reference updates.
- [ ] Retain suspect raw evidence; flag uncertain intervals and guide the operator to
  settle, collect overlap, or acquire a separate repeat pass. Do not silently combine
  segments or imply that normal ARKit tracking proves a stationary head.
- [ ] Keep tracking-world identity separate from head-segment identity; interruption
  still requires the existing new-session policy. Invalidate stale coverage overlays.

Done when stationary scans, camera-only motion, deliberate head-object motion,
occlusion, and inadequate overlap produce understandable, recorded outcomes on M5.
Measure false alerts and detection failures before selecting thresholds. No claim of
millimetre motion accuracy or automatic correction is required for this milestone.

#### A4 — Sharp evidence and live label coverage

**Why this will benefit MANTA:** A4 increases the number of readable electrode sightings per minute and reveals what the camera actually captured. Sharp stills and honest label coverage reduce redundant views and prevent a template-filled preview from disguising missing measurements.

- [ ] Add hold-still still capture with sharpness, angular-motion, thermal, and
  coverage gates plus a manual override. Enable only the configuration validated in A1.
- [ ] Add hybrid novelty/coverage sampling with minimum and maximum time gaps and
  adequate view overlap. Preserve manual sampling and revisits for unread labels.
- [ ] Let calibrated RGB-only stills contribute OCR identity evidence without requiring
  a depth/mesh hit. Keep “read”, “supported in distinct views”, and “localized” separate.
- [ ] Keep inferred/template electrodes visibly distinct from actual sightings;
  conflicting or ambiguous OCR must not falsely complete coverage.

Done when bench scans demonstrate improved usable image/label yield without unacceptable
coverage gaps, false labels, tracking degradation, memory growth, or heat. Still count
and hold duration are tuning parameters, not proof that a 256-channel net is complete.

#### A5 — Recapture before release

**Why this will benefit MANTA:** A5 turns coverage feedback into action while the participant is still available. The operator can revisit unread or ambiguous electrodes before ending tracking, reducing incomplete datasets and repeat visits requiring another net application.

- [ ] Add a coverage review while tracking remains active, followed by targeted
  recapture, then the final integrity/release check. Show unread/ambiguous labels and
  coarse guidance before attempting precise camera overlays.
- [ ] Project predicted locations only with trustworthy head alignment and visibility;
  label them as guidance, never observed measurements. Suppress stale motion overlays.
- [ ] Validate a full M5 rehearsal: deliberately omit views, recover missing evidence,
  mark movement, collect a safe repeat, finalize, transfer, and reopen on the Mac.

Done when the operator can identify and address missing evidence before ending the
live capture, and the saved package passes the integrity/recovery checks. Summarize
unresolved labels/segments explicitly; neither a template nor frame count implies
measurement completeness. All A1–A5 acceptance evidence is required before a subject.

#### A6 — Validated recovery across stable segments, then individual frames

- [ ] Register overlapping stable segments on the Mac using preserved depth evidence
  and conservative acceptance criteria; reject weak or ambiguous alignment.
- [ ] Store derived head-to-world transforms with direction, provenance, confidence,
  and validity. Preserve original ARKit poses. Apply a common head frame to surfaces,
  depth, rays, fiducials, coverage, and aggregation; unknown is not stationary.
- [ ] Integrate with 11.2 camera calibration and make 11.3 triangulation segment-aware.
  Compare stationary controls and known rigid motion against independent references.
- [ ] Only then evaluate per-frame registration and masked Object Capture poses.
  Deformation, net slippage, and blur remain distinct failure modes. TSDF is optional.

Done when accepted segment registration preserves independently measured localization
and failed recovery remains explicit. Object Capture/ARKit disagreement alone is not
a head-motion estimate; down-weighting moved frames alone is not correction.

### 11.1 CI for the existing regression suite — first

Implement the Stage 1 macOS workflow on pushes and pull requests. Record Xcode/Swift
versions and retain test/build failure output. Cover geometry, pose identity, exports,
checksum warnings, and the sparse file exceeding 2 GiB. Start with package tests;
add unsigned Receiver/CLI build jobs once the runner/toolchain configuration is stable.

Done when a clean checkout runs the suite on the configured runner and a failing test
fails the job. This infrastructure needs no participant capture or signing secrets.

### 11.2 Trajectory alignment and calibrated camera selection — next accuracy work

Complete Stage 3: load exported estimates, robustly fit Object Capture camera centers
to ARKit centers, and expose accepted estimated cameras to electrode localization and
reprojection overlays. Share the implementation between Receiver and CLI. Preserve
original ARKit calibration, prior alignments, and explicit rejection/fallback reasons.

Test known rotation/translation/scale, shuffled and missing sample IDs, outliers,
short/poorly distributed trajectories, native-image orientation, and optional calibration.
Compare original, estimated-pose-only, and estimated-pose-plus-calibration runs on the
same held-out captures. Report trajectory coverage, scale, temporal residuals,
reprojection error, and independent spatial error. Model-up/world-up angle is a useful
diagnostic, not proof of accuracy; a global fit cannot remove arbitrary head motion
or time-varying ARKit drift. Keep the new path opt-in until it earns promotion.

### 11.3 Primary multi-view electrode triangulation

Complete the Stage 4 solve using disc/cup-center rays grouped by supported electrode
identity, including sightings without a mesh hit or depth value. Reuse/consolidate
existing ray-fitting code with the shared numerical implementation rather than adding
another private solver. Integrate original and estimated camera choices from 11.2.

Require distinct source views and adequate geometry; reject label outliers and invalid
intersections. Report support, residuals, method, and provisional uncertainty. Preserve
single-view depth/mesh fallbacks and distinguish measured centers from layout guesses.
Test wrong labels, ambiguous center types, repeated tiles of one image, missing depth,
weak baselines, and outliers. Promote based on held-out localization and false-label
rates, not merely smaller ray disagreement. Never overwrite manual corrections silently.

### 11.4 Profile and accelerate geometry

Profile representative full-detail, 256-channel captures before changing query methods.
Record mesh triangle counts, source/target cloud sizes, ray counts, stage wall time,
index construction time, and peak memory. The existing surface-vertex grid does not
accelerate `MeshRaycaster.firstHit` or ICP's brute-force nearest-neighbor search.

Add a reusable triangle BVH for repeated raycasts and a suitable spatial index for ICP
where measurements justify them. Cache against mesh/cloud identity and invalidate on
replacement or coordinate-frame changes. Compare indexed hits/neighbors against the
existing exhaustive routines, including misses, edge hits, degenerate triangles, and
transformed meshes. Preserve nearest-hit/numerical behavior within explicit tolerances.
Point-to-plane ICP is a separate, later algorithm experiment; it is not required to
make the current point-to-point implementation faster.

### 11.5 Previewable head masks for Object Capture

Implement the Stage 6 mask adapter, caching, and review controls on macOS 26; add OS 27
interactive refinement as an optional enhancement. Use bounded-memory sample loading
and preserve image-to-mask identity. Allow masks to be disabled or corrected without
changing original RGB evidence.

Compare unmasked, automatically masked, and reviewed-mask runs on identical inputs.
Measure background geometry, reconstruction failures, retained electrode/head coverage,
localization, runtime, and memory. Do not promote a mask merely because the mesh looks
cleaner if it removes peripheral electrodes or damages their measurements.

### 11.6 Tiled and disc-crop OCR

Complete Stage 5 tiled passes and padded/upscaled crops around cup proposals. Map every
crop/rotation back to native image coordinates and deduplicate per observation before
counting multi-view support. Keep proposal-center quality separate from OCR identity,
and retain ambiguous candidates instead of forcing a layout-consistent label.

Extend the offline benchmark to score correct-label precision/recall, confusions,
false labels, annotated disc-center error, runtime, and peak memory. Include small,
oblique, rotated, blurred, and glare-affected labels. Compare full-frame, tiled, and
candidate-crop configurations on held-out sessions; upscaling is not an accuracy claim.

### Shared requirements and deferred experiments

Continue extracting common Receiver/CLI orchestration as needed for these increments;
the existing `MANTAProcessing` target shares adapters but is not yet the complete shared
pipeline. Preserve directory-package imports and mutable processed-package workflows.
Checksums remain advisory, and new caches/artifacts must use bounded memory without
forcing ZIP conversion or rebuilding multi-gigabyte payloads on every edit.

The existing model/geometry sidecar, learned cup classifier, weighted fusion/TSDF,
point-to-plane ICP, and optional review assistant remain later experiments. They are
not prerequisites for the six increments above. Capture presets, storage safeguards,
calibration export, and the initial benchmark runner are already implemented; they
should not be presented as new backlog items.

Each increment needs relevant unit/integration coverage and documentation. Scientific
behavior changes also need baseline comparisons and the release gates in section 10.
Avoid combining adapter extraction with multiple numerical changes in one review.

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
limitations and physical bench tests. The subsequent pose/calibration extraction
and offline benchmark increment is recorded below.

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

### Acquisition A1 initial increment — 2026-11-05

Unified working-session checkpoint recovery in `MANTACore` and adopted it in iPad
reopening and Mac RAW recovery. Recovery now includes completed observations missing
from stale `session.json`, preserves existing metadata and original files, and surfaces
corrupt/unreadable checkpoints. Reused the camera-image Core Image context and added
monotonic artifact-stage and regular-sample save timings to acquisition events.

Validation: 116 core tests pass, including stale-metadata RAW recovery, checkpoint
deduplication/order, corrupt/unreadable checkpoint handling, and legacy-directory
compatibility. The unsigned iPad app builds with Xcode 27.2. Existing export-concurrency
and orientation-deprecation warnings remain outside this increment. Physical M5
acceptance is pending; A1 is not complete. Metadata batching, background writing,
motion handling, and guided recapture remain explicitly planned in A2–A5.

### Acquisition A2 software increment — 2026-11-05

Added a three-job serial background frame writer with bounded app-owned RGB/depth/
confidence pools and immutable frame-specific calibration. Saved observations become
visible only after checkpoint commit. Capture events record copying, queue pressure,
drops, queue wait, write timings, and failures. Automatic still requests run separately
from regular sampling while retaining serialization, thermal, and generation guards.

Full session/diagnostic writes are batched at ten frames or five seconds on the next
completion; critical state changes still persist immediately. Stop drains accepted
writes; end/release/export wait before consuming evidence. Backgrounding requests
limited execution time to drain, with checkpoint recovery as the termination fallback.
Session replacement/deletion is blocked during drain. Metadata flushing remains on
the main actor to preserve ordering with synchronous fiducial/settings updates.

Validation: 118 core tests pass, including queue ordering, bounded admission,
off-main execution, failures, and cancellation-safe completion. Unsigned iPad app and
integration-test compilation pass; new pixel-buffer-copy/pool tests are not yet run
on iOS. Combined M5 physical acceptance is deferred at the user's request. A2 is
software-implemented, not device-validated; A3 has not been started.

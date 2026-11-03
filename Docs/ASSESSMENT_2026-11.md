# MANTA Assessment and Mac-First Processing Plan

Date: 2026-11-03. Scope: the iPad/iPhone capture app, MANTA Receiver, `MANTACore`, and `MANTAReconstructCLI` as they exist at commit `2365e1d`. This is a code review plus a plan. Nothing in the source was changed.

## Summary

The engineering foundation is solid. The bundle format, hashing, hardened import, RAW/PROCESSED lineage, typed units/frames, and the separation of measured vs. inferred electrodes are better than most research tools ever get. The accuracy ceiling right now is set by how the geometry is fused, not by the plumbing.

You're right about LiDAR. Right now it's used as the primary 3D measurement for every electrode. It should be a weak, range-dependent prior that photogrammetry overrides wherever the multi-view geometry is good. Three specific problems follow from that:

1. Each electrode position is a quality-weighted average of LiDAR back-projections. The weight is OCR confidence times a 1.0/0.82 depth-confidence factor. Nothing accounts for range, incidence angle, or the very different precision across the ray versus along it.
2. The multi-view ray triangulation that would give sub-millimetre lateral precision is already computed (`ReceiverElectrodeDetection.swift:269`), but it's only used as a diagnostic.
3. The final "snap" moves each electrode to the nearest *vertex* of the photogrammetry mesh within 12 mm (`:278`, `:395`). That can slide an electrode sideways along the scalp, which is exactly the direction where you have the most information and should move it least.

Moving post-processing to the Mac is the right call for testing. The Mac can afford full-resolution, multi-rotation OCR on every frame. It can run Object Capture at full/raw detail with its bundle-adjusted camera poses, fuse depth properly into a signed-distance volume, and run the whole pipeline headless over a folder of captures so changes can be scored. The sections below go through what to change, roughly in priority order.

## What the platform releases give you (macOS/iOS 26 and 27)

Your Mac reports Darwin 25.6 (macOS 26.x). macOS/iOS 27 shipped in September 2026.

**Object Capture `.poses` (and `.pointCloud`) requests.** These are available since macOS 14 but unused here. `PhotogrammetrySession` returns its own bundle-adjusted camera pose for each sample early in processing, in the model's coordinate frame. MANTA currently writes a `poses.json` that is just the ARKit poses copied in. Requesting `.poses` gives you two things:

- **A closed-form model-to-world alignment.** With known correspondences between the two sets of camera centres (Object Capture versus ARKit), you get the alignment by Umeyama/Horn fitting with no ICP and no PCA seed.
- **Refined poses for every downstream ray computation**, mapped into ARKit world. The ARKit poses carry millimetre-to-centimetre jitter and drift. This is the single highest-leverage change in this document. It needs nothing new from the OS.

**Depth-guided `PhotogrammetrySample` input.** This is already implemented (`ReceiverPhotogrammetrySampleSequence`), which is good. Two follow-ups:

- Always use the sample-sequence initializer, even for images-only runs (just omit depth). Then you control sample IDs and can join `.poses` output back to observation UUIDs without guessing the folder order.
- Fill in `objectMask`. On macOS 14+, `VNGenerateForegroundInstanceMaskRequest` or person segmentation can generate head/torso masks automatically. Masks remove the room, the operator's hands, and the chair, which are common causes of alignment failures and junk geometry.

**Vision.** WWDC25 (OS 26) added `RecognizeDocumentsRequest` and `DetectLensSmudgeRequest`. The smudge check is a cheap pre-capture check on the iPad; a smudged lens quietly ruins label legibility. WWDC26 (OS 27) added a tap-to-segment request, which would fit an interactive "click the head" mask tool in the Receiver.

**macOS/iOS 27 OCR regression.** Several developers report that the legacy `VNRecognizeTextRequest` at its default revision with `.accurate` got noticeably worse on iOS/macOS 27. The reported symptoms are missed strings, text read upside down, and junk characters after numbers. The revision number reportedly did not change, so apps cannot opt out. Before you upgrade the Mac to 27:

- Freeze a labelled OCR benchmark from your own frames.
- Record the request revision and OS build in `detectorMetadata`.
- Run the benchmark against both the legacy API and the Swift `RecognizeTextRequest` (macOS 15+).

The Receiver currently targets macOS 14 and doesn't pin a revision. I'd raise the Receiver to macOS 26.

**Core AI (OS 27).** Apple now positions Core AI as the successor to Core ML for neural networks: `.aimodel` format, PyTorch conversion via `coreai-torch`, and ahead-of-time compilation. The cup detector and 256-way label classifier planned in `MLModels.md` should target Core AI rather than Core ML.

**Foundation Models with image input (OS 27).** The model now accepts images and has a Vision-backed OCR tool. It's fine as a review-UI helper, for example "which of these crops look misread?". It shouldn't produce measurements or labels that enter the solution: it isn't deterministic and can't be calibrated the way Vision plus geometry can.

**Other 27 items worth knowing about, but not on the critical path.**

- **ARKit object tracking on iOS.** Useful later for tracking a rigid validation phantom.
- **RealityKit Gaussian-splat rendering.** It looks great, but splats are not a metric surface.

**Capture-side items worth testing on the iPad.**

- **High-resolution stills during the session.** `ARSession.captureHighResolutionFrame` gives you 4K stills while the regular frames keep supplying poses and depth. See the capture section below.
- **AVFoundation's `builtInLiDARDepthCamera`.** It can deliver still-photo depth at higher resolution than ARKit's 256×192, plus a full `AVCameraCalibrationData` that includes lens-distortion tables. It can't run alongside ARKit world tracking, so it's a separate experiment rather than a drop-in.
- **Object Capture on iPhone 17 Pro.** There are open forum reports of `PhotogrammetrySession` failing with error 4004 on iPhone 17 Pro image sets under iOS 26.x. That matters if anyone captures on a 17 Pro.

## How LiDAR and photogrammetry should share the work

The three sensors have complementary error shapes:

- **Multi-view RGB photogrammetry and triangulation.** Very precise across each viewing ray, and high resolution. On its own it has no metric scale or gravity, and it is weak where there is no texture.
- **ARKit visual-inertial odometry.** Metric and gravity-aligned (you set `worldAlignment = .gravity`), but the per-frame pose has millimetre-to-centimetre noise and slow drift.
- **The LiDAR depth map.** Metric and absolute, but coarse. ARKit densifies a sparse dot pattern to 256×192. The noise grows with range and with grazing incidence. It smooths over features the size of a cup, mixes foreground and background at silhouettes, and behaves unpredictably on hair.

The comment at `WorldAlignment.swift:128` notes landmark depth "reads several cm short" and that a landmark-derived scale came out around 0.2 against roughly 0.44 from the dense clouds. That is a systematic bias, not random noise. A reliable fusion has to measure such a bias and down-weight it, not average it in.

### "Gravity" in the literal sense

ARKit's world is Y-up. If Object Capture honours the per-sample gravity vector, its model is Y-up too. Then the model-to-world alignment only needs yaw, translation, and scale: five degrees of freedom instead of seven. Constraining rotation to yaw:

- removes the tilt errors ICP can settle into,
- removes most of the 24-way PCA flip ambiguity in `CoarseAlignment.pca`,
- makes the solve better conditioned.

This only works if the gravity convention is right, and I couldn't confirm Apple's expected frame for `PhotogrammetrySample.gravity` from the documentation. `CameraGravity` supplies world-down expressed in ARKit's camera axes. Those axes are aligned with the native (landscape) sensor image, which is how the RGB buffer is passed in, so the convention is plausible. Core Motion's device-frame gravity, which Apple's old capture sample stored, is rotated 90° about Z relative to that.

There's a cheap empirical test. After a depth-guided reconstruction and alignment, transform the model's +Y into world and measure its angle to world +Y:

- **Near 0°:** the convention is right.
- **Near 90°:** it's off by the device rotation.
- **Arbitrary angles across runs:** Object Capture is ignoring the vector.

This test belongs in the reconstruction diagnostics.

### "Gravity" in the sense you meant: weighting by distance and certainty

Treat every per-frame electrode sighting as an anisotropic Gaussian rather than a point. Here is the setup for one sighting:

- `c` is the camera centre and `d` is the unit ray through the disc centre.
- `r` is the range along the ray. Convert ARKit's z-depth to range with `r = z / (d · a)`, where `a` is the optical axis.
- `μ = c + r·d` is the sighted position.
- The covariance is `Σ = σ⊥²(I − ddᵀ) + σ∥² ddᵀ`.
  - `σ⊥ ≈ r · σpx / f` is the lateral error from locating the disc in the image.
  - `σ∥ = σLiDAR(r, confidence, incidence, edge distance)` is the error along the ray.

The fused electrode is then the information-weighted solve

```
x̂ = (Σᵢ Λᵢ + Λs)⁻¹ (Σᵢ Λᵢ μᵢ + Λs q),   Λᵢ = Σᵢ⁻¹
Λs = (1/σs²) n nᵀ
```

where `q` and `n` are the nearest point and normal on the reconstructed surface.

For typical numbers (r = 0.4 m, f ≈ 1,500 px, disc located to about 1.5 px), σ⊥ is about 0.4 mm. LiDAR's σ∥ at that range is plausibly several millimetres, so the lateral information is 100–200× stronger.

That ratio is exactly the "gravity" behaviour you were looking for:

- **Single sighting:** LiDAR sets the depth and the ray sets everything else.
- **Two or more well-separated views:** the rays triangulate, and LiDAR's contribution fades automatically.
- **Surface term:** it pulls the estimate only along the surface normal, so it can't drag an electrode sideways.

Run it with a robust loss (Huber or Cauchy via iteratively reweighted least squares). Gate outliers by Mahalanobis distance instead of the fixed 12 mm Euclidean threshold in `ElectrodeObservationAggregator`. The posterior covariance `(ΣΛ)⁻¹` then gives each electrode a real uncertainty ellipsoid in millimetres. That is far more useful and defensible than the current hand-tuned confidence products.

If you keep ARKit poses rather than Object Capture's refined poses, inflate σ⊥ by the pose jitter. That inflation is a big part of why refined poses matter.

### Measure σLiDAR instead of guessing it

Once a high-detail photogrammetry mesh is aligned, every LiDAR depth pixel in every frame gives a signed residual against the mesh along its ray. Bin those residuals by:

- range,
- confidence class,
- incidence angle (from the mesh normal),
- distance to the nearest depth discontinuity.

Then fit the bias and σ for each bin and store them as a per-device calibration file. This turns the "several cm short" observation into a correctable bias and gives you a defensible weighting for the methods section. The same weights then drive both electrode fusion and depth fusion.

## Specific code findings

### Electrode localization (`MANTAReceiver/ReceiverElectrodeDetection.swift`)

Positions are currently built like this:

1. LiDAR depth is sampled once per OCR hit, as the median of a 5×5 patch of depth pixels (about a centimetre on the head).
2. The point is back-projected with the ARKit pose.
3. Points are averaged per label with a 12 mm outlier gate.
4. The result snaps to the nearest mesh vertex.

Two changes give most of the gain. First, intersect each sighting's ray with the aligned photogrammetry mesh (`MeshRaycaster` already exists in Core; it needs a bounding-volume hierarchy for speed) and use the hit as `μ`, with a small σ∥. The mesh is a much better depth source than raw LiDAR once it exists. Second, replace the vertex snap with the normal-only surface prior above, or at minimum project onto the closest point on the closest triangle along the surface normal.

Two smaller issues:

- **Cup proposals:** the classical cup-proposal pass only runs on about 24 frames in total (`cvFrameStride`, line 180). On the Mac it should run on every frame.
- **Re-projection pass (new):** after the first solve, project each fused electrode back into every frame that should see it and look for the disc there, by template match or by the detector, even where OCR failed. Most electrodes are visible in many more frames than they're read in. This adds supporting rays cheaply and is how label-free sightings should accumulate.

### OCR

Images are downscaled to a 2,048-px thumbnail (line 609), OCR runs once in one orientation, and `minimumTextHeight = 0.008`.

Labels on a head appear at every rotation, and `.accurate` doesn't read upside-down or steeply rotated text well. On the Mac, run full-resolution overlapping tiles at 0°/90°/180°/270° (45° steps if recall is still poor) and vote across rotations. Better still, crop each detected disc, rectify the crop to face the camera using the local surface normal, and classify that crop. That is the detector-first pipeline `MLModels.md` already describes.

Two smaller points. `customWords` is set but language correction is off; as far as I know the custom vocabulary only matters when language correction is on, so it is probably doing nothing. And watch for upside-down 6/9 confusions (for example 16↔91); the layout guide should get to adjudicate those explicitly.

### Label legibility is limited by resolution

LiDAR modes deliberately skip the high-resolution video format (`ARScanViewModel.swift:135`) to keep depth synchronized, so frames are about 1920×1440. Assume a printed number about 3 mm tall:

- At 40 cm it is roughly 11–12 px tall at that resolution. That's at the edge of reliable digit recognition.
- At 4K it is roughly 22–24 px.

You don't actually need synchronized depth for the hi-res frames. You need a pose, and `captureHighResolutionFrame` gives you a pose and intrinsics. Once the Mac has a fused surface, depth for any image can be rendered by raycasting. So capture regular frames continuously for tracking and depth, and request 4K stills periodically for labels.

### Capture cadence

Auto-sampling grabs whatever frame is current every 0.75 s (`ScanSessionViewModel.swift:1117`), and blur is only recorded as a warning. Instead:

- keep a short ring buffer of recent frames,
- score each by sharpness, angular velocity, and pose novelty,
- persist the best one in each window.

That improves OCR and reconstruction at no storage cost.

### Image orientation, which looks inverted in landscape

`storedImageOrientation()` (`ARScanViewModel.swift:444`) maps the interface orientation `.landscapeLeft → "up"` and `.landscapeRight → "down"`.

ARKit's captured image is in the sensor's native orientation, which corresponds to interface `.landscapeRight`. That is device `.landscapeLeft`, home-button-right, which is the mapping Apple's ARKit+Vision sample uses. So the two landscape cases look swapped. Portrait is correct.

Projection geometry is unaffected, because `rawPoint` inverts whatever transform is used. But Vision gets a 180°-rotated hint for every landscape frame, and the Receiver would display those frames upside down. Check one landscape capture to confirm. Multi-rotation OCR would make this harmless for recognition anyway.

### Depth fusion (`ReceiverDepthFusion.swift`, `MetricDepthPointCloud.swift`)

The current fusion averages points in 4–5 mm voxels:

- every accepted sample gets equal weight,
- confidence is only a threshold,
- there is no rejection of silhouette ("flying") pixels,
- there is no incidence or range weighting.

A head is mostly silhouette from any viewpoint, so mixed edge pixels inflate the surface outward.

On the Mac, replace this with a truncated signed-distance (TSDF) integration using the same σLiDAR weights, and drop pixels near depth discontinuities and at grazing incidence. A 40 cm cube at 2 mm voxels is only 8 M voxels, so it's trivial on Apple Silicon. Extract the surface with marching cubes. You get a weighted, watertight LiDAR surface that is a much better alignment target and fallback depth source than a raw point cloud. Keep the iPad's live accumulator as a preview only.

### Alignment (`WorldAlignment.swift`, `ReceiverPhotogrammetryReconstruction.swift`)

The current pipeline is a PCA seed, point-to-point ICP with brute-force nearest neighbours (O(N·M) per iteration), and a scale bound of ±20% around the cloud-moment ratio. That's a reasonable fallback, but it should come third, not first:

1. Similarity fit on Object Capture vs. ARKit camera centres. Use RANSAC to drop bad frames, and constrain rotation to yaw when gravity is honoured.
2. Optionally refine with point-to-plane ICP against the TSDF surface, using a k-d tree.
3. Keep the existing landmark and PCA paths for when `.poses` is unavailable.

Two diagnostics come cheaply from this:

- **Scale cross-check:** compare the camera-trajectory scale (from IMU-based VIO) with the LiDAR-surface ICP scale. A persistent mismatch measures LiDAR bias directly.
- **Reprojection check:** the existing overlays of projected electrodes on frames should visibly tighten once refined poses are used.

### Lens distortion

`PinholeCamera` ignores distortion, and ARKit doesn't expose it. Object Capture fits its own distortion internally but only returns poses. For now, give sightings near the image edges larger σ⊥. Longer term, calibrate the wide lens once per device model, using AVFoundation's distortion tables or a checkerboard, and undistort disc centres before casting rays.

### Code organisation

The reconstruction workflow is duplicated between the Receiver and `MANTAReconstructCLI`, and the CLI has no depth-guided mode. Electrode detection lives entirely in a 1,600-line Receiver file with many magic thresholds. I'd split it into three pieces:

- **A macOS-only `MANTAProcessing` package**, depending on `MANTACore`, RealityKit, and Vision, that owns reconstruction, alignment, TSDF fusion, OCR/detection, and the probabilistic solve.
- **The Receiver**, as a UI over that package.
- **The CLI**, as a second front end. Use `manta-process <bundle-or-folder> --report report.json` to run the full pipeline headless.

Put every threshold in a versioned config struct written into the evidence document. That makes the "post-process on the Mac" workflow fast to iterate. You can re-run a folder of captures after each change and diff metrics such as:

- labelled-electrode yield and median support count,
- posterior σ per electrode,
- reprojection error,
- alignment residual,
- camera-scale vs. LiDAR-scale ratio,
- distance to the GeoScan fixture after fiducial alignment.

## Suggested order of work

| Priority | Change | Why |
|---|---|---|
| P0 | Record one real convention fixture (phantom or measured targets, landscape and portrait) and add the gravity-axis and orientation checks to diagnostics | Several sign and frame questions are still unverified on hardware, and everything else depends on them |
| P0 | Replace the nearest-vertex snap with a normal-only projection | Removes lateral sliding of up to 12 mm |
| P0 | Pin and record the Vision OCR revision and OS build; build a small labelled OCR benchmark before moving to macOS 27 | Protects against the reported OS 27 regression and makes runs reproducible |
| P1 | Request `.poses`, align with a similarity fit on camera centres, and use refined poses for all rays | Biggest single accuracy gain; replaces fragile ICP-first alignment |
| P1 | Anisotropic, information-weighted electrode fusion with ray-mesh hits, a surface-normal prior, and robust weighting; report covariance | Implements the LiDAR "gravity" correctly and gives real uncertainty |
| P1 | Full-resolution, tiled, multi-rotation OCR and cup proposals on every frame; re-projection pass for extra sightings | Recall, especially on rotated and upside-down labels |
| P1 | Weighted TSDF fusion with edge and grazing rejection; calibrate σLiDAR and bias from residuals | A better surface, and measured rather than guessed weights |
| P2 | Headless `manta-process` CLI with JSON metrics; extract a shared macOS processing package; raise the Receiver to macOS 26 | Fast Mac-side iteration and regression tracking |
| P2 | Capture: sharpest-frame selection, periodic 4K stills, lens-smudge check, segmentation masks for Object Capture | Better raw evidence at no extra burden on the operator |
| P3 | Core AI cup detector and label classifier; Structure Sensor depth path; Foundation Models as a review-only helper; non-rigid cap fit | Next generation, once the geometry is sound |

A note on the Structure Sensor work in `StructureProto/`: at 30–50 cm, a structured-light sensor at 640×480 or 1280×960 should give far better close-range depth than the iPad's LiDAR. The weighting framework above handles it naturally. It becomes another depth source with its own measured σ(r, θ), so the decoding effort pays off without redesigning the solver.

## Things I could not verify

Several points above are inferences and need a quick hardware or documentation check:

- Apple's expected coordinate frame for `PhotogrammetrySample.gravity`.
- Whether the 4K AR video format really drops `sceneDepth` on current iPads.
- The landscape orientation mapping.
- How Vision treats `customWords` when language correction is off.
- Whether the macOS 27 OCR regression affects your labels.

The LiDAR noise magnitudes are illustrative; the residual calibration described above is how to replace them with your device's numbers.

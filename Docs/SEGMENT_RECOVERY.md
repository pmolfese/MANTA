# Reviewed stable-segment recovery (A6)

This experimental Mac workflow combines **manually reviewed stable intervals** from
separate passes of the same person and unchanged net application. It creates a report
and, only when requested and accepted, a new `.manta` directory package. Originals are
never rewritten. It is not automatic motion tracking or validated localization.

During capture, continue using A3: stop after movement, preserve the pass, start a
new pass, and reacquire overlapping head views. Complete stationary coverage remains
the acquisition goal. A6 may salvage useful frames from earlier passes afterward.

## Prepare a selection

Use finalized directory packages containing `manifest.json` and `capture.json` at the
root. Extract ZIP `.manta` archives to separate directories first if necessary. Keep
inputs unchanged while registration runs. Working-session folders with an acquisition index are also supported.

1. Inspect source images/depth and select only a stable interval in each pass. The
   reviewer must verify the same person/net and no net slippage. A3's suspect flag
   covers a whole stopped pass; it does not identify safe intervals automatically.
2. Read each selected observation's `id` and `quality.motionAssessment.segmentID`
   from `capture.json`. Select at least three overlapping depth frames per segment.
   RGB-only photos are optional and must have selected depth evidence within one
   second. Timing proximity is supporting evidence, not proof of head stability.
3. Define a tight head bounding box in **that segment's original ARKit world meters**.
   Exclude stationary background, torso, and hands.
4. Supply at least three corresponding, spatially spread noncollinear landmarks,
   measured in each segment's original world. Use the same names in every segment.
   Do not substitute template electrode coordinates. These registration landmarks
   are separate from final scientific fiducials.
5. Put the reference segment first. Its world defines the canonical reference-head
   frame; this is not automatically an anatomical coordinate system.

Example structure below uses placeholders. Replace paths, UUIDs, bounds, and landmark
coordinates with reviewed measurements; the sample coordinates are not a calibration.
Legacy captures without segment metadata may be assigned distinct segment UUIDs;
legacy frames without quality metadata support report-only registration.

```json
{
  "acquisitionGroupID": "same-net-application-001",
  "segments": [
    {
      "bundlePath": "/absolute/path/pass-one.manta",
      "segmentID": "11111111-1111-1111-1111-111111111111",
      "observationIDs": [
        "11111111-1111-1111-1111-111111111112",
        "11111111-1111-1111-1111-111111111113",
        "11111111-1111-1111-1111-111111111114"
      ],
      "reviewedStable": true,
      "headBounds": {
        "center": {"x": 0, "y": 0, "z": -0.5},
        "widthMeters": 0.3, "heightMeters": 0.4, "depthMeters": 0.3
      },
      "landmarks": [
        {"name": "left-anchor", "coordinate": [-0.08, 0, -0.5]},
        {"name": "right-anchor", "coordinate": [0.08, 0, -0.5]},
        {"name": "top-anchor", "coordinate": [0, 0.12, -0.48]}
      ]
    },
    {
      "bundlePath": "/absolute/path/pass-two.manta",
      "segmentID": "22222222-2222-2222-2222-222222222221",
      "observationIDs": [
        "22222222-2222-2222-2222-222222222222",
        "22222222-2222-2222-2222-222222222223",
        "22222222-2222-2222-2222-222222222224"
      ],
      "reviewedStable": true,
      "headBounds": {
        "center": {"x": 0.05, "y": 0, "z": -0.5},
        "widthMeters": 0.3, "heightMeters": 0.4, "depthMeters": 0.3
      },
      "landmarks": [
        {"name": "left-anchor", "coordinate": [-0.03, 0, -0.5]},
        {"name": "right-anchor", "coordinate": [0.13, 0, -0.5]},
        {"name": "top-anchor", "coordinate": [0.05, 0.12, -0.48]}
      ]
    }
  ]
}
```

## Run and inspect

From the repository root:

```sh
swift run --package-path MANTAReconstructCLI manta-recover-segments \
  --request /absolute/path/selection.json \
  --output /absolute/path/new-registration-report
```

Inspect `registration.json` and `request.json`. A geometric rejection writes a report
and exits 2 without a derived package. Invalid inputs exit 1 with an error. An accepted
report exits 0. Output must not exist and must be outside every source package; its
parent directory must exist. To create a package, repeat with a new output directory
and `--emit-derived` (registration runs again).

Current limits: 2–8 segments, 3–32 landmarks, up to 256 selected frames per segment;
confidence-2 zlib Float32 little-endian depth up to 512×512. Computation uses 6 mm
voxels and bounded deterministic point samples. Provisional gates use 15 mm nearest
correspondences, at least 60% overlap in both directions, at most 8 mm inlier RMS in
both directions, and at most 8 mm error for each matched landmark. Each depth frame
must independently agree with the reference cloud; reference frames are checked
against the other reference frames. These limits can reject useful partial views.

Passing means **geometric checks passed**, not that electrode error is below 8 mm.
Residuals reuse the fitted depth, and smooth or symmetric geometry can hide movement.
Landmark review constrains ambiguity but does not measure registration uncertainty.
No scale fitting, nonrigid correction, automatic interval segmentation, continuous
per-frame tracking, or Object Capture pose correction is performed.

## Use a derived package

Open the new package in Receiver. Rebuild depth/surfaces and rerun detection using
corrected cameras. Object Capture can attempt a fresh reconstruction with
foreground masking in either input mode. Depth-guided mode supplies the original
camera-local depth maps, not corrected camera poses. Gravity is omitted across
moved-head passes. This does not retain the recovered metric registration; inspect
foreground masking, dimensions and alignment before metric use.
Source depth pixels and RGB remain unchanged; original camera
poses and suspect flags are retained in per-frame correction metadata. Cameras now
map into the reference frame, so existing calibrated rays and depth unprojection use
the same rigid transform. No uncertainty calibration is claimed.

Source fused meshes, electrode solutions, fiducials, old coverage, and acquisition
release summaries are not reused: their association with a stable interval is not
established. Place final fiducials on the rebuilt surface. Original capture/manifest
metadata, selected image/depth assets, selection, and registration report are included
for provenance. All original packages should still be retained.

Receiver provides the reviewed workflow in its **Motion Correction** tab:

1. Open a consolidated capture and choose the reference and matching pass. Include
   only passes with at least three confidence-supported depth frames.
2. Scrub each image interval, set its first/last frames, and confirm a stable head
   with unchanged cap. Adjust the head region to exclude background and torso.
3. Choose **Attempt automatic alignment** to search rigid alignments from depth
   geometry without landmarks. Alternatively, select landmark names and click at
   least three well-spread corresponding locations on every included LiDAR surface,
   then choose **Preview with landmarks**.
4. Inspect the colored depth overlay, overlap, residuals, and rejected frame IDs.
   Change the interval/head region if rejected. If automatic alignment is ambiguous,
   place matching landmarks and use the manual preview.
5. Accept and save to a new destination. Receiver rechecks the approved selection
   and source payload hashes, writes a separate corrected `.manta` package, and
   rebuilds `corrected-depth.ply` from corrected camera poses. It publishes the
   result folder only after these steps succeed.
6. Open the corrected capture to view or export it. Original/corrected comparison
   buttons remain available during the current Receiver session. The saved package
   can also be reopened independently.

Editing selection invalidates approval. Original passes remain unchanged. This is
reviewed rigid registration of stable intervals, not automatic motion tracking.

Estimated Object Capture camera
calibration and primary multi-view triangulation remain the later roadmap 11.2/11.3
integration. A6 remains open until measured-motion and independent-reference tests
validate recovery. See [validation](VALIDATION.md).


## Consolidated start/stop capture

Pausing and resuming keep the same session and AR world. After a movement stop,
“Continue in this session” saves the previous pass's mesh and landmark snapshot
under `acquisition/passes/<segmentID>/`, then starts a new coordinate world in
that same session. All completed frames stay in `captureObservations` and one
session folder. `capturePasses` declares the archived artifacts in exported
capture metadata; movement-stop checkpoints are scoped to a segment.

Receiver and `manta-reconstruct --input-mode images` enable Object Capture
foreground masking and unordered image matching. This path accepts multiple
passes, supplies no AR camera poses, depth or gravity, and estimates cameras from
RGB images. Mask quality and image overlap still determine whether reconstruction
succeeds. Automatic AR-world alignment is disabled when movement, multiple
segments, or motion corrections are present. Inspect the model and align it
before metric use. Depth-guided Object Capture also accepts separate passes:
foreground masking and unordered matching are enabled, camera-local depth is
retained to assist scale, and AR pose/gravity constraints are omitted. Direct
depth fusion and electrode triangulation retain their stationary/registered
geometry requirements.

To recover older recordings split into explicitly linked session folders:

```sh
swift run --package-path MANTAReconstructCLI manta-consolidate \
  --output /path/to/Consolidated.manta /path/to/first-pass /path/to/next-pass
```

The command verifies the complete `previousSessionID` chain, creates a new
validated directory package, preserves each original pass in its own namespace,
and keeps all camera transforms unchanged. It rejects unrelated sessions and
missing frame payloads. Original folders are never modified. No registration or
accuracy claim is made by consolidation.


In Receiver's Viewer, **3D surface → LiDAR pass** opens each archived full/head
mesh in its own original coordinate world. Split view filters camera frames to
that same pass. Archived geometry and bounds are read-only; selecting a pass
does not change the full capture used for reconstruction or export. The photo
model remains a separate choice until it has an appropriate alignment. Expected
fusion ineligibility no longer triggers an automatic failed solve on opening.

## Automatic geometry alignment prototype

Automatic alignment runs locally in Swift without downloaded models, Python, or
network services. It uses bounded deterministic point samples, principal-axis
permutations and world-axis rotation starts, then rigid ICP refinement. It is a
multistart geometry search, not a learned feature matcher or exhaustive global solver.
A clipped bidirectional distance cost penalizes unmatched geometry. Materially
different transforms with comparable costs are rejected as ambiguous; this heuristic
cannot establish uniqueness or accuracy for smooth heads.

Each selected interval must still be explicitly reviewed as stable with unchanged
cap. Every third supported depth frame is excluded from transform fitting. All
selected depth frames must subsequently agree with the reference, including withheld
frames. These are consistency checks, not independent ground-truth validation.
The reference pass remains in its original coordinate frame. Only an accepted preview
can be saved, and saving reruns registration and verifies source/selection hashes.

The CLI request can opt into this same path using `"automaticAlignment": true` and
empty `landmarks` arrays. Existing requests retain landmark-guided behavior. Failed
or ambiguous automatic attempts never emit a corrected capture. Continuous motion,
cap slippage, and automatic selection of stable intervals remain unsupported.

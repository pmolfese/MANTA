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
inputs unchanged while registration runs. Working-session folders need RAW recovery
and finalization before use here.

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
corrected cameras. Object Capture in Receiver and `manta-reconstruct` explicitly
reject these packages until foreground masking and pose handling are validated;
the stationary background cannot be corrected by changing head-frame camera poses.
Source depth pixels and RGB remain unchanged; original camera
poses and suspect flags are retained in per-frame correction metadata. Cameras now
map into the reference frame, so existing calibrated rays and depth unprojection use
the same rigid transform. No uncertainty calibration is claimed.

Source fused meshes, electrode solutions, fiducials, old coverage, and acquisition
release summaries are not reused: their association with a stable interval is not
established. Place final fiducials on the rebuilt surface. Original capture/manifest
metadata, selected image/depth assets, selection, and registration report are included
for provenance. All original packages should still be retained.

Receiver has no segment/landmark selection UI yet. Estimated Object Capture camera
calibration and primary multi-view triangulation remain the later roadmap 11.2/11.3
integration. A6 remains open until measured-motion and independent-reference tests
validate recovery. See [validation](VALIDATION.md).

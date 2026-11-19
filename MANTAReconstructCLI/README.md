# manta-reconstruct

A standalone macOS command-line tool that runs MANTA's photogrammetry
reconstruction (RealityKit Object Capture) on a captured bundle — so you can
grind through a heavy reconstruction in the terminal while continuing to work
in the MANTA app / receiver.

It is its own Swift package. It links [`MANTACore`](../MANTACore) via a local
path dependency (bundle import/validation, point-cloud loading, world
alignment) and reproduces the receiver's Object Capture driver. It does **not**
touch the app or `MANTA.xcodeproj`.

## Build

Requires macOS 26+ and Xcode 27 or later.

```sh
cd MANTAReconstructCLI
swift build -c release
```

The binary lands at `.build/release/manta-reconstruct`. Symlink it somewhere on
your `PATH` if you like:

```sh
ln -sf "$(pwd)/.build/release/manta-reconstruct" /usr/local/bin/manta-reconstruct
```

## Use

```sh
# From a .manta archive, Full detail (default):
manta-reconstruct /path/to/capture.manta

# Depth-guided reconstruction from a .manta directory package, Raw detail:
manta-reconstruct /path/to/bundle.manta --input-mode depth --detail raw -o ~/Desktop/recon
```

Options: `-d/--detail medium|full|raw`, `-m/--input-mode images|depth`,
`-o/--output DIR`, `--keep-workspace`, `-h/--help`. Progress and logs go to
stderr; the final `model.usdz` path is printed to stdout (handy for scripting).
Ctrl-C cancels cleanly and releases the GPU.

`--input-mode depth` feeds each frame's LiDAR depth map + gravity into Object
Capture; it falls back to images-only automatically if no frame carries usable
depth.

The input may be a `.manta` **directory package** or a `.manta` **zip
archive**. Directory packages are loaded leniently — the manifest and capture
document are read directly. SHA-256 and byte counts are checked in bounded-memory
streams and reported as warnings, never as import gates. Missing/malformed hashes
also warn. Legacy ZIP CRC mismatches are advisory when the archive remains
structurally readable. This preserves access to older or edited captures without
silently describing them as integrity-verified. Files and manifests are not rewritten
by the audit, and directory packages are never converted to ZIP.

### Outputs (written into `--output`)

| File | Contents |
| --- | --- |
| `model.usdz` | Reconstructed textured mesh |
| `poses.json` | Per-image camera poses (ARKit world, meters) |
| `diagnostics.json` | Timing, skipped samples, LiDAR-alignment metrics |

## Note on shared code

The reconstruction driver in `Sources/manta-reconstruct/Reconstruction.swift`
is a port of the receiver's `ReceiverPhotogrammetryReconstruction.swift`. The
two are intentionally decoupled (this package makes no changes to the app), so
if the receiver's reconstruction logic changes, port the change here too.

## GeoScan comparison harness

Build the separate executable from this package:

```sh
swift build --product manta-compare
```

Export MANTA coordinates as **GeoScan TXT** in the Receiver or iPad. Compare that
file with the original GeoScan five-column TXT (not an empirically transformed
SFP). The following example assumes the reference units have been verified as cm:

```sh
.build/debug/manta-compare \
  --reference /path/to/geoscan.txt --reference-unit cm \
  --candidate /path/to/manta_coordinates_head-ras_cm.txt --candidate-unit cm \
  --report /path/to/comparison.json
```

Both unit arguments are required (`m`, `cm`, or `mm`). A declared `# Units = ...`
header must agree. FidNz/FidT9/FidT10 must represent nasion/LPA/RPA; electrode
locations named T9/T10 are not interchangeable with those landmarks. The importer
rejects duplicates, malformed rows, nonfinite coordinates, invalid Estimated
flags, and conflicting units. Template paths are metadata and are never opened.

The command fits a rigid least-squares transform from candidate to reference
using only the three fiducials. It does not fit scale or use electrodes to improve
alignment. Reports contain:

- SHA-256 of both input files, OS/build, timestamp, and explicit source units.
- A column-major candidate-to-reference transform (translation in millimeters).
- Per-fiducial residuals, separately from electrode errors.
- Per-label aligned/reference positions and errors, all in millimeters.
- Count, mean, median, RMS, nearest-rank 95th percentile, and maximum error.
- Separate mutually-measured and all-matched summaries, plus missing labels.
- Warnings for estimated fiducials and unavailable measured-only metrics.

Cz is scored as an electrode; only the three cardinal fiducials are excluded
from electrode summaries. Labels match exactly. No automatic relabelling,
outlier removal, numerical pass threshold, or anatomical unit guessing occurs.
Zero common electrodes and missing/degenerate fiducials fail explicitly.

New MANTA TXT exports mark explicit image/depth observations Estimated=0.
Inferred, manually placed, synthetic, layout-assigned, and older provenance-unknown
points remain Estimated=1. Primary metrics require mutually measured points;
otherwise only exploratory all-matched agreement is available. Do not change flags
merely to obtain primary metrics. A successful exit means a report was produced,
not that accuracy passed a threshold. Existing report files are never overwritten.

This first harness reads TXT files, not `.manta` bundles or SFP. No subject data
is copied into the repository. GeoScan units in the historical S05 example remain
unconfirmed; assuming cm for a parser smoke test is not unit validation.

### Receiver GUI

The same comparison is available in MANTA Receiver:

1. Choose **Validation → Compare GeoScan…** in the sidebar, even without an
   imported capture, or use the **Compare** tab on an imported capture.
2. Choose the original GeoScan TXT and explicitly select its units.
3. Choose a candidate TXT and its units, or select **Use Current Capture
   Coordinates** to snapshot the loaded capture as centimeter world coordinates.
4. Select **Compare**. Review mutually measured/all-matched summaries, fiducial
   residuals, missing labels, and per-point errors.
5. Select **Export JSON Report…** to save the same report schema as the CLI.

Changing a selected file or its units clears the old result. Current-capture
coordinates are a snapshot: click the button again after editing electrodes or
fiducials. Capture evidence is never modified. GUI reports also refuse to
replace an existing file; choose a new report filename.

## Object Capture estimated calibration

`manta-reconstruct` and Receiver reconstruction now request `.poses` alongside
the model. Both use explicit sample IDs even for images-only input. Receiver's
depth-guided sequence retains those same IDs. The exported `poses.json` (Receiver:
`reconstruction/macos_poses.json`) remains an array of per-image records, adding:

- `sampleID` linked to `observationID` and `imageFilename`.
- Original `cameraToWorld`, `intrinsics`, and image orientation, unchanged.
- `estimated.modelFromCamera`: column-major transform in Object Capture's
  reconstruction frame, with reconstruction-native translation units.
- Optional estimated `intrinsics`, `distortionCenter`, and `radialLookupTable`,
  copied without rectification or guessed replacement values.
- `status`: pending during processing, then estimated/rejected/unavailable;
  `statusDetail` explains rejection or missing pose output.

A pose-request failure does not discard a successfully reconstructed model;
unavailable calibration is explicit in the records. Unknown output IDs and
ambiguous duplicate input IDs fail instead of guessing an image association.
Images that could not be decoded remain represented as unavailable if Object
Capture never receives/returns them. Original acquisition files are not modified.

These estimated poses are not ARKit-world poses. Existing cloud alignment remains
in use. Applying estimated calibration to localization requires a validated
trajectory/model-to-world transform and camera/distortion convention checks. Do
not combine estimated poses with original intrinsics without evaluating that
combination. Actual Object Capture output and gravity convention still need a
real capture test; extraction tests do not prove reconstruction accuracy.

## Offline benchmark runner

```sh
swift build --product manta-benchmark
.build/debug/manta-benchmark --manifest /path/to/dataset.json --report /path/to/run-001.json
```

Copy `Docs/BENCHMARK_MANIFEST.example.json` beside your dataset and replace its
placeholder paths and annotations. Paths resolve relative to the manifest (absolute
paths also work). Source units in a comparison are explicit `meters`, `centimeters`,
or `millimeters`; confirm reference units before scoring. Either `images` or
`comparisons` may be empty, but the dataset must contain at least one case. IDs
must be unique across both lists.

Image cases run offline Vision accurate OCR, with language correction disabled,
explicit revision, native-image decode size, minimum text height, and selected
orientation passes. Expected labels are unique `E1`...`E128` or `E256`; use an empty
array for a negative image. Predicted labels are deduplicated across passes.
Reports retain recognized strings, exact-label TP/FP/FN lists, precision/recall,
runtime, file hashes, the complete manifest and its hash, OS/build, runner version,
and case errors. Aggregate OCR metrics exclude failures and the failed-case count
must always accompany comparisons. Empty denominators are unavailable, not perfect
scores. Comparison cases use the same rigid GeoScan engine as the GUI/CLI.

The runner is a controlled OCR/reference-comparison harness, not the full Receiver
cup detector or a reconstruction scheduler. It does not score pixel-localization,
wrong-identity geometry, or infer reference labels from the net template. Label
annotations should be reviewed and frozen, with session-separated held-out sets.
Use identical data and change one configuration at a time; compare reports from
separate OS/device runs to evaluate model behavior. This Mac runner does not
substitute for Vision tests on the physical iPad.

Cases run sequentially with image temporaries released between cases. A failed
image/comparison does not stop the remaining cases. Exit 0 means all cases ran,
1 means the report includes failed cases, and 2 indicates invalid arguments,
manifest, or report-writing failure. Existing reports are never overwritten.
There are no network requests or telemetry in the runner. Keep reports with the
same access controls as captures: recognized strings may contain identifying text.

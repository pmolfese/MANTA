# MANTA ML Models

## Goal

Build an on-device Core ML pipeline that finds EEG sensor centers and reads their
labels from MANTA capture frames. Geometry and the known net topology should remain
separate from the learned model: ML proposes image observations, while calibrated
depth, multi-view fusion, surface snapping, and the layout graph produce the final
3D sensor map.

## Recommended Pipeline

1. **Sensor detector or segmenter**
   - Input: an oriented RGB frame or overlapping high-resolution tiles.
   - Output: sensor cup bounding boxes, center points, and detection confidence.
   - A small object detector is the simplest first target. Instance segmentation
     may eventually locate the cup center more reliably under perspective.
2. **Label recognizer**
   - Input: a rectified crop around one detected cup.
   - Output: `E1...E256`, unreadable, or not-a-label.
   - Keep this separate from cup detection. The visual evidence for a cup is much
     more common than a readable printed number, and the two tasks need different
     crops and augmentations.
3. **Geometric and topology solver**
   - Convert centers to camera rays and metric depth samples.
   - Fuse repeated sightings and snap them to the aligned cap surface.
   - Robustly fit the known HydroCel layout, reject inconsistent OCR labels, and
     infer missing neighbors as review-required suggestions.

## Training Data From MANTAReceiver

`analysis/electrode_evidence.json` already records the raw OCR box, image point,
frame ID, recognized text, confidence, depth, ray, and fused coordinate. Extend the
format only when needed; preserve old versions for reproducible training exports.

Useful supervision:

- A dragged image point is the corrected sensor center for that frame.
- A label correction links the OCR crop to the corrected class while preserving the
  original recognized text.
- A reviewed point is a positive example after projection back into supporting
  camera frames.
- Deleted or rejected candidates should become hard negatives.
- Inferred layout points are pseudo-labels and must not be mixed with human labels
  without an explicit lower training weight.

Export a conventional dataset manifest containing session ID, frame path, raw image
dimensions, center, box, corrected label, annotation source, and confidence. Split
train, validation, and test data by participant/session, never by frame, to prevent
nearly identical views from leaking across splits.

## Bootstrap Strategy

1. Collect manual corrections from diverse 128- and 256-channel sessions.
2. Use Vision OCR boxes plus reviewed corrections to bootstrap label crops.
3. Hand-verify a smaller high-quality set of sensor centers and hard negatives.
4. Train the cup detector first; its output can accelerate collection of label
   crops even before the recognizer is ready.
5. Train the label recognizer with unreadable and background classes.
6. Run both models in shadow mode and save disagreements for active-learning review.

Create ML can provide a quick detector baseline. A PyTorch detector exported through
`coremltools` is preferable if tiling, keypoints, segmentation, or custom losses are
needed. The first useful recognizer can be a compact image classifier; sequence OCR
is only necessary if fixed 256-way classification proves too brittle.

## Augmentation

- Full 360-degree rotation and moderate perspective warp.
- Exposure, white balance, glare, shadow, contrast, and color variation.
- Motion blur, defocus, image compression, and downsampling.
- Partial hair, straps, neighboring cups, and realistic crop truncation.
- Printed-label wear and low-contrast ink.

Do not mirror label crops unless the text is also rendered correctly. Synthetic
numbers can supplement rare classes, but validation must remain entirely real.

## Evaluation

- Cup detection precision/recall and center error in pixels.
- Reprojected center error in millimeters after depth fusion.
- Exact label accuracy, top-k accuracy, and unreadable rejection quality.
- Per-electrode confusion matrix, especially visually similar labels.
- Complete-net coverage and number of human corrections per session.
- Runtime, peak memory, and energy on the oldest supported iPad.

The operational metric should be review time saved without increasing undetected
label swaps, not OCR accuracy alone.

## Core ML Integration

- Package models as versioned `.mlpackage` resources with training-data and metric
  metadata.
- Run inference through Vision so orientation and normalized coordinates follow one
  tested path.
- Tile large frames rather than allocating full-resolution model tensors.
- Benchmark CPU, GPU, and Neural Engine compute-unit policies on device.
- Keep the current Vision OCR route as a fallback and as a source of ensemble
  evidence during rollout.
- Save model version and thresholds in each evidence document for reproducibility.

## Privacy And Governance

Training exports contain participant imagery. Strip unrelated metadata, use coded
session identifiers, document consent and retention rules, encrypt datasets at rest,
and keep face-containing frames within the approved research environment. A future
crop exporter should default to sensor-local crops when full head images are not
required.

## Dynamic Layout Guessing

MANTAReceiver currently proposes unobserved electrodes by fitting the known net to
OCR observations, reviewed points, and Nasion/LPA/RPA, then applying local neighbor
residuals and snapping predictions to the reconstructed surface. Moving or reviewing
a point refits all remaining guesses. The displayed confidence combines fit error,
anchor count, local confirmed neighbors, surface distance, and spatial collisions.

Important limitations:

- The displayed percentage is a heuristic confidence score, not a statistically
  calibrated probability. Calibration needs a held-out set of fully reviewed nets.
- A guess does not yet mean an unlabeled cup was detected in the image. The current
  solver can place the layout on plausible surface geometry even when a cup is
  occluded or absent from every frame.
- Nearest-surface snapping can select hair, scalp, straps, or another cup. A trained
  cup detector or segmenter should supply visual support before high-confidence
  automatic acceptance.
- A mistaken manual confirmation can influence nearby guesses and the global fit.
  Manual history is retained, but a dedicated anchor enable/disable and undo UI is
  still desirable.
- A similarity transform plus local residual interpolation approximates cap stretch;
  it is not a full non-rigid net deformation model.
- Labels remain attached to template slots. This is not yet a global assignment
  solver matching all visible unlabeled cups to all layout labels.
- Guessed points are persisted with their state and confidence. Coordinate exports
  need an explicit policy for whether to include guesses, and at what threshold.

# MANTA Capture Bundle Format

Status: version 1 implementation in progress. `MANTACore` includes typed
manifest/capture models, JSON Schemas, deterministic archive finalization,
hardened archive extraction, a minimal fixture, and strict logical-bundle
validation.

## Goals

The MANTA Capture Bundle is the durable interchange between iPhone/iPad capture,
macOS receipt, archival storage, offline solvers, and third-party tools. It must:

- Preserve the immutable raw inputs required to rerun future solvers.
- Define units, coordinate frames, camera conventions, and file relationships.
- Detect truncation, corruption, substitution, and incomplete transfers.
- Support forward-compatible readers and explicit migrations.
- Preserve the protected acquisition separately from mutable working results.
- Remain inspectable with common JSON, XML, image, and binary-data tools.

Bundles can contain PHI and identifiable imagery. Integrity metadata is part of
version 1; encryption, access control, and audit policy are responsibilities of
storage and transport and must be specified before clinical deployment.

## Serialization decision

JSON is the normative metadata serialization for version 1.

- It maps cleanly to Swift `Codable`.
- JSON Schema can validate syntax and structure independently of MANTA.
- It is widely supported by scientific and clinical tooling.
- Existing EGI XML inputs remain XML and are preserved as layout source files
  when licensing and provenance permit.

Do not maintain independent JSON and XML manifests. If XML interchange becomes
necessary, define an XSD mapping generated from the same semantic model and
test JSON/XML equivalence. The JSON manifest remains canonical for bundle
hashing and compatibility.

## Container

The RAW logical bundle is a directory. Its transfer form is a ZIP archive with the
extension `.manta` (a `.manta.zip` compatibility name is acceptable during
migration). ZIP entries use UTF-8 names and forward slashes. Version 1 writers
use ZIP method 0 (stored): HEIC, JPEG, PNG, USDZ, and raw depth assets are already
compressed at their artifact layer, and a single deterministic container method
keeps readers small and auditable. Readers reject encryption, data descriptors,
multi-disk archives, ZIP64, and other compression methods until a later format
version explicitly permits them. A macOS PROCESSED `.manta` is instead a mutable
directory package: it is not zipped, archive-wide hashed, or passed through RAW
validation after every edit.

Archive readers must reject:

- Absolute paths, `..` traversal, symlinks, and hard links.
- Duplicate normalized paths.
- Entries not declared by the manifest, except explicitly permitted extension
  paths.
- Uncompressed sizes or compression ratios above configured safety limits.
- A manifest that is not at the archive root.

Extraction is streamed through bounded buffers into a private partial
directory. The partial directory is deleted on any error and is moved to its
requested destination only after manifest, size, SHA-256, lineage, and capture
validation succeeds. Default reader limits are 10,000 entries, 16 GiB archive
and expanded totals, 8 GiB per entry, and a 200:1 expansion ratio; applications
may impose tighter limits.

## Proposed version 1 layout

```text
<yyyyMMdd_HHmmss>.manta/
├─ manifest.json
├─ capture.json
├─ log_manta.json                  required for a derived "Save As" bundle
├─ subject.json                    optional; PHI-bearing
├─ layouts/
│  ├─ layout.json                  normalized layout snapshot
│  └─ source/                      optional original EGI XML/metadata
├─ assets/
│  ├─ camera_<observation-uuid>.png primary lossless RGB
│  ├─ camera_<observation-uuid>.heic optional compressed comparison
│  │                                      (`_compressed.jpg` encoder fallback)
│  ├─ depth_<observation-uuid>.f32.zlib
│  ├─ confidence_<observation-uuid>.u8.zlib
│  └─ depth_<observation-uuid>.png optional preview
├─ reconstruction/                optional
│  ├─ model.usdz
│  ├─ lidar_mesh.ply              complete raw ARKit environment mesh
│  ├─ lidar_mesh_head.ply         optional head-bounds crop
│  └─ poses.json
├─ runs/                           optional, repeatable derived results
│  └─ <run-uuid>/
│     ├─ run.json
│     ├─ observations.json
│     └─ electrodes.json
└─ reviews/                        optional, user decisions layered over runs
   └─ <review-uuid>.json
```

MANTA exposes two package roles. **RAW** is the immutable acquisition ZIP and is
never modified. **PROCESSED** is one editable directory package for that session.
The first saved reconstruction, review, or solve promotes the Receiver's existing
extracted RAW workspace into PROCESSED, gives it a stable `bundleID`, and records
RAW as `parentBundleID`. Later macOS edits atomically replace only the assets or
JSON they changed and append to `log_manta.json`. PROCESSED is intentionally not
re-zipped, fully re-hashed, or RAW-validated after each edit.

The iPhone/iPad UI uses **Export**, not Save As. Export finalizes the current
working session as a new immutable `.manta`, including any newly applied model
results. The first exported snapshot has no parent. After an export, the app
records that bundle ID; a later export from the same evolving session is a
derived snapshot referencing the most recently exported bundle and documenting
changes in `log_manta.json`.

Exporting CSV, BESA ELP, MNE SFP, BIDS, EGI electrode-coordinate XML, or another
terminal format does not create a new MANTA bundle or alter lineage.

The iOS working session writes throttled live OCR/depth output to
`runs/live-current/run.json`. Each comprehensive **Finalize Electrode Detection**
pass writes a new immutable run directory keyed by UUID. Run metadata records
the engine/version, contributing frame IDs, raw/live counts when available,
directly localized versus template-predicted electrodes, suspect labels,
template-fit residual, and the complete electrode result. These run files are
included in export so live, finalized, and future desktop solvers can be
compared without treating provisional template positions as observations.

## Manifest

`manifest.json` is a small root document sufficient to identify, validate, and
route the bundle before loading large assets.

```json
{
  "$schema": "https://manta.local/schemas/bundle-manifest-1.0.0.json",
  "format": "org.nih.manta.capture-bundle",
  "schemaVersion": "1.0.0",
  "bundleID": "86b20bb6-f31e-4b0b-b423-cf93ae2742bc",
  "sessionID": "c75cf330-8751-46f3-bcd4-7bef70b28ee8",
  "createdAt": "2026-07-11T13:30:22.123Z",
  "finalizedAt": "2026-07-11T13:32:51.902Z",
  "producer": {
    "application": "MANTA",
    "version": "0.1.0",
    "build": "42",
    "platform": "iPadOS",
    "operatingSystemVersion": "26.5",
    "deviceModel": "iPad16,6"
  },
  "content": {
    "capture": "capture.json",
    "subject": "subject.json",
    "layout": "layouts/layout.json"
  },
  "files": [
    {
      "path": "capture.json",
      "mediaType": "application/json",
      "role": "capture-metadata",
      "size": 18342,
      "sha256": "<64 lowercase hexadecimal characters>"
    }
  ]
}
```

Rules:

- UUIDs use lowercase canonical hyphenated strings on write; readers may accept
  uppercase.
- Dates use RFC 3339 UTC with fractional seconds.
- SHA-256 is computed over each file's exact uncompressed bytes.
- `manifest.json` is not listed in `files`, avoiding a recursive self-hash.
- A transport may hash/sign the complete archive separately.
- Paths are relative, normalized, case-sensitive, and unique.
- JSON writers emit finite numbers only. NaN and infinity are invalid.
- Readers ignore unknown object properties for minor-version compatibility but
  preserve them when performing a lossless rewrite where practical.

An original RAW capture omits both `parentBundleID` and `content.changeLog`. A
PROCESSED bundle includes both; they must agree with the IDs inside
`log_manta.json`.

## RAW immutability, PROCESSED updates, and `log_manta.json`

`log_manta.json` is the cumulative audit trail for PROCESSED. It contains:

- Its own schema version.
- The stable PROCESSED bundle ID and immutable RAW parent bundle ID.
- UTC creation time and producing application/build/device.
- One or more uniquely identified change records.
- For each change: UTC time, category, human-readable summary, and stable
  targets such as `electrodes/E17`, a processing-run ID, or a review ID.

RAW manifests list and hash every protected file. PROCESSED still lists its
working files for discovery, but modified entries do not carry an integrity
promise and are not fed back through the RAW validator. A lightweight load checks
that the package, manifest, capture, and change-log IDs agree. Each update retains
prior change records and appends the new operation before replacing only the
changed files.

Bundle filenames are PHI-free UTC timestamps with semantic roles, normally
`yyyyMMdd_HHmmss_raw.manta` and `yyyyMMdd_HHmmss_processed.manta`. If a RAW file
with the same timestamp already exists, the application must ask the user to
choose another destination or replace explicitly; it must not silently mutate
or overwrite an existing snapshot.

## Capture metadata

`capture.json` describes immutable acquisition inputs. Required top-level data:

- Session UUID and capture timestamps.
- Capture mode and selected layout identifier/revision.
- Device and camera calibration metadata.
- Explicit coordinate-system definitions.
- Ordered observation records.
- Optional reconstruction artifact relationships.

Each observation records:

- Observation UUID and timestamp.
- RGB asset path and pixel dimensions.
- Camera intrinsics as a 3x3 Float64 matrix.
- Advisory quality evidence: AR frame timestamp, mapping state, light,
  luminance/clipping, sharpness, pose novelty, coverage sector, valid-depth and
  high-confidence fractions, and warning codes. Pilot thresholds do not discard
  raw evidence.
- Camera-to-world transform as a 4x4 Float64 matrix.
- Image origin and EXIF-style orientation required to display the stored sensor
  pixels upright.
- Optional compressed HEIC path associated with the same observation as the
  primary lossless PNG image. A high-quality JPEG may occupy this role when the
  platform encoder refuses HEIC.
- Optional depth/confidence asset paths and formats.
- Depth dimensions, scalar type, byte order, compression, units, and mapping to
  RGB pixel coordinates.
- Tracking state and acquisition-quality metrics.

When a reconstruction is present, `capture.json` explicitly relates its full
LiDAR mesh, optional head-bounds crop, and/or ObjectCapture model to the capture.
Both LiDAR meshes are stored directly in the declared ARKit world frame; the
full mesh remains the immutable acquisition input and the crop is a reversible
convenience artifact. `reconstruction.headBoundingBox` records the exact
world-space center and width/height/depth used to produce that crop so deferred
depth fusion can apply the same region rather than inferring it from surviving
triangles. ObjectCapture models also record a
column-major 4x4 model-to-world transform so desktop viewers can overlay
fiducials and electrode solutions without assuming the two coordinate frames
coincide.

Each observation may record both `quality.coverageSector` (the camera optical
axis direction) and `quality.headCenteredCoverageSector` (the camera position
around the selected head center). Acquisition-readiness counts use the latter;
consumers must not treat the two sector definitions as interchangeable.

Matrices are serialized as flat arrays in column-major order for compatibility
with ARKit and `simd`. Every matrix field also has a schema-defined shape and
direction; names such as `cameraToWorld` are preferred over ambiguous
`transform`.

### Fiducial placement evidence

`acquisition/fiducial-placements.json` retains how each fiducial was obtained so
alternative head-frame solvers can audit it. Each record's **world coordinate**
(`arkit-world`, meters) is the authoritative landmark; the `hitMethod`,
`rayOrigin`, and `rayDirection` describe how it was derived (LiDAR mesh raycast
vs. estimated-plane raycast vs. model-surface pick).

Caveat for consumers: for live-camera placements, the app saves a dedicated
observation at placement time and links it through `observationID`. Its
`imagePoint` is still a tap location in **AR-view point space**
(`pointCoordinateSpace: "ar-view-points"`), not stored image-pixel space.
Therefore:

- Treat the world coordinate as ground truth for the placement.
- Use the linked observation as contemporaneous camera evidence, but do **not**
  reproject `imagePoint` as though it were already a pixel coordinate.

If a future solver needs pixel-exact fiducial correspondence, add a pixel point
computed from the view's `displayTransform` for the linked frame. The current
evidence is contemporaneous but intentionally does not pretend view points are
image pixels.

The version 1 world frame is identified as `arkit-world`, right-handed, in
meters. The ARKit camera looks along its negative Z axis. Stored RGB pixel
coordinates use a top-left origin after the orientation declared by the
observation. These conventions require confirmation against a real capture
before freezing schema 1.0.0.

## Binary artifact formats

Version 1 retains the existing encodings:

- RGB: lossless PNG is always the primary image. When **Also Save HEIC** is
  enabled, the same observation also receives a maximum-quality HEIC companion,
  or a high-quality JPEG if the device encoder refuses HEIC. Dimensions and
  orientation are declared in `capture.json`; the media type of every image is
  declared in the manifest. RGB is captured at the highest camera format the
  device offers; for LiDAR modes the dedicated high-resolution-frame format is
  deliberately avoided so scene depth stays synchronized to the color frame.
- Depth: zlib-compressed little-endian IEEE-754 Float32, row-major, meters.
- Confidence: zlib-compressed UInt8, row-major, using the declared value map.
- LiDAR mesh: little-endian Float32 XYZ triples in the declared world frame.

Decoders validate decompressed byte counts exactly. Metadata declares the
expected count before allocation. Future formats receive new media types and
must not silently reuse an existing type with different semantics.

## Layout snapshot

A head-mesh-only acquisition declares `layoutID: "none"`, uses a zero-channel
layout in the working session, and omits layout reference artifacts. This is an
explicit acquisition choice rather than an unknown or missing net model.

`layouts/layout.json` is the normalized layout actually used for capture and
solving, rather than only a reference to whatever layout ships with a later app.
It includes:

- Stable layout ID, name, revision, channel count, and source provenance.
- Electrode number, label, role, coordinate prior, and neighbors.
- Coordinate-prior frame and units.
- Fiducial priors and sensor hints.
- Reference sensor metadata.

This makes old captures reproducible even if bundled application resources
change. Original EGI XML may be retained under `layouts/source/` and hashed in
the manifest.

## EGI coordinate XML and SFP reference fixture

`Fixtures/EGI/GeoScanDerived128/` contains a paired real-world EGI
`coordinates_mff` XML file and its derived SFP file. The source GeoScan point
export is deliberately excluded. `ConversionMetadata.json` records its SHA-256
for provenance without storing the source capture.

The paired artifacts establish:

- EGI XML namespace: `http://www.egi.com/coordinates_mff`.
- Sensor type `0`: numbered electrodes; type `1`: vertex reference; type `2`:
  fiducials.
- EGI names/numbers for nasion, left/right periauricular points, and VREF.
- SFP mappings `Nasion -> FidNz`, `Left periauricular point -> FidT9`,
  `Right periauricular point -> FidT10`, and `Vertex Reference -> Cz`.
- XML-to-SFP is a direct coordinate copy plus decimal rounding; all 132 paired
  coordinates differ by at most 0.000005.
- The example coordinates are in centimeters according to the GeoScan source
  provenance. The XML itself has no explicit units field, so the future exporter
  must perform an explicit head-frame millimeter-to-centimeter conversion and
  record units outside the XML where possible.
- MANTA's MNE-oriented SFP export is always converted to meters. SFP has no
  embedded unit declaration, so this is an exporter contract rather than a
  property discoverable from the file itself.
- BIDS export pairs `electrodes.tsv` with a required `coordsystem.json`; EGI XML
  is converted to centimeters; BESA ELP contains spherical theta/phi angles and
  never Cartesian XYZ values.

The reconstructed GeoScan conversion is more than a rigid frame change. Three
fiducials determine an effectively exact rigid transform. Electrode/reference
marker positions are then moved inward along local surface normals by 0.95 cm,
except E64, E68, E69, E73, E74, E81, E82, E88, E89, E94, and E95, which move
1.25 cm. Those normal directions are not present in the point-only GeoScan text;
the exact conversion therefore also required GeoScan's surface geometry or
equivalent normals. The metadata states this reproducibility limit and treats
the included XML as authoritative.

## Subject metadata and PHI

`subject.json` is optional and contains the subject label/MRN or future study
identifiers. Keeping it separate allows de-identification without rewriting
capture geometry. The manifest indicates whether subject metadata is present
but must not duplicate PHI into filenames or general audit messages.

Bundle filenames use the UTC timestamp policy above. Human-readable PHI is
shown only after authorized import and is never copied into the filename.

## Processing runs

A processing run is immutable and references one capture plus exact software
and parameter provenance. `run.json` includes:

- Run UUID, timestamps, status, and input bundle/session IDs.
- Pipeline name, semantic version, source revision, and model/checkpoint hashes.
- Parameters and feature flags, including OCR and depth thresholds.
- Host platform/device information.
- Input file hashes or finalized bundle identity.
- Stage metrics, warnings, errors, and timing.
- Paths to recognized observations and electrode results.

Every electrode result records whether it is `observed`, `inferred`, or
`manuallyPlaced`, plus confidence, coordinate frame, units, supporting
observation IDs, validation findings, and template-fit residuals. Inferred
electrodes remain distinguishable in all downstream exports and metrics.

Reviews are separate documents referencing a run and electrode stable IDs.
Reprocessing therefore cannot overwrite either prior results or user decisions.

## Versioning and compatibility

`schemaVersion` follows semantic versioning:

- Patch: clarification or constraint change that does not alter valid data.
- Minor: backward-compatible optional fields or enum cases with defined unknown
  handling.
- Major: incompatible representation or semantic change.

A reader:

- Must reject an unsupported major version with an actionable error.
- Must accept supported older minor versions and unknown fields.
- Must validate required fields and relationships before solving.
- Must never guess units, frames, matrix direction, or binary encoding.

Migrations are pure, separately tested transformations. Imported bundles remain
unchanged; saving a migrated representation creates a new immutable bundle with
lineage and a change-log entry describing the migration.

## Integrity versus authenticity

Per-file SHA-256 detects corruption and incomplete transfer but does not prove
who created the bundle. A later security profile should add a detached digital
signature over a canonical manifest representation or an archive digest. Do not
describe an unsigned hash list as tamper-proof.

## Validation and test fixtures

Before schema 1.0.0 is frozen, add:

1. JSON Schemas for manifest, capture, change log, layout, run, review, and
   subject files.
2. A minimal valid 128-channel fixture with two observations.
3. A minimal valid 256-channel fixture.
4. A sanitized real-device fixture with manually verified camera/depth
   relationships.
5. Golden encode/decode tests with deterministic semantic comparisons.
6. Compatibility tests that decode every prior supported schema fixture.
7. Corruption tests for hash, size, missing file, duplicate path, bad byte
   count, unknown major version, invalid date, NaN, and ambiguous matrix shape.
8. Malicious archive tests for traversal, symlinks, duplicate normalized paths,
   and decompression bombs.
9. Cross-implementation validation using a small non-Swift reader.
10. JSON/XML equivalence tests if an XML representation is introduced.

## Implementation sequence

1. Confirm real-device camera, image-orientation, and depth conventions.
2. Freeze the semantic types and coordinate vocabulary, not their Swift names.
3. Add JSON Schemas and hand-authored minimal fixtures.
4. Implement read-only bundle validation in `MANTACore`.
5. Implement deterministic metadata encoding and bundle finalization.
6. Switch iOS export directly to the new bundle; pre-release working-session
   formats are intentionally unsupported.
7. Build macOS local-file import and inspection against the same validator.
8. Add processing runs, reviews, iOS Export/macOS Save As finalization, and
   lineage UI.
9. Add authenticated/resumable network transfer after file import is stable.

## Decisions still required before 1.0.0

- Public schema identifier/namespace and where schemas will be published.
- Encryption-at-rest requirements for PHI-bearing bundles.
- Maximum asset sizes/counts and archive expansion limits.
- Whether Float64 metadata is required throughout or Float32 values are retained
  exactly from ARKit with an explicit numeric type.
- Whether XML output is required by a named downstream consumer.
- Long-term representation of image/depth calibration beyond simple resolution
  scaling.
- Whether downstream EGI tools impose additional requirements beyond the
  captured `coordinates_mff` dialect and fixture.

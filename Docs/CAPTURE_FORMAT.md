# MANTA Capture Bundle Format

Status: proposed version 1 design, not yet implemented.

## Goals

The MANTA Capture Bundle is the durable interchange between iPhone/iPad capture,
macOS receipt, archival storage, offline solvers, and third-party tools. It must:

- Preserve the immutable raw inputs required to rerun future solvers.
- Define units, coordinate frames, camera conventions, and file relationships.
- Detect truncation, corruption, substitution, and incomplete transfers.
- Support forward-compatible readers and explicit migrations.
- Preserve multiple processing runs instead of silently overwriting results.
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

The logical bundle is a directory. Transfer form is a ZIP archive with the
extension `.manta` (a `.manta.zip` compatibility name is acceptable during
migration). ZIP entries use UTF-8 names and forward slashes.

Archive readers must reject:

- Absolute paths, `..` traversal, symlinks, and hard links.
- Duplicate normalized paths.
- Entries not declared by the manifest, except explicitly permitted extension
  paths.
- Uncompressed sizes or compression ratios above configured safety limits.
- A manifest that is not at the archive root.

## Proposed version 1 layout

```text
<session-uuid>.manta/
├─ manifest.json
├─ capture.json
├─ subject.json                    optional; PHI-bearing
├─ layouts/
│  ├─ layout.json                  normalized layout snapshot
│  └─ source/                      optional original EGI XML/metadata
├─ assets/
│  ├─ camera_<observation-uuid>.jpg
│  ├─ depth_<observation-uuid>.f32.zlib
│  ├─ confidence_<observation-uuid>.u8.zlib
│  └─ depth_<observation-uuid>.png optional preview
├─ reconstruction/                optional
│  ├─ model.usdz
│  ├─ lidar_mesh.f32
│  └─ poses.json
├─ runs/                           optional, repeatable derived results
│  └─ <run-uuid>/
│     ├─ run.json
│     ├─ observations.json
│     └─ electrodes.json
└─ reviews/                        optional, user decisions layered over runs
   └─ <review-uuid>.json
```

Raw capture files and capture metadata are immutable after finalization.
Processing runs and reviews may be appended, but a new finalized manifest and
bundle identity must be produced whenever bundle contents change.

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
- Camera-to-world transform as a 4x4 Float64 matrix.
- Image origin and orientation applied to stored pixels.
- Optional depth/confidence asset paths and formats.
- Depth dimensions, scalar type, byte order, compression, units, and mapping to
  RGB pixel coordinates.
- Tracking state and acquisition-quality metrics.

Matrices are serialized as flat arrays in column-major order for compatibility
with ARKit and `simd`. Every matrix field also has a schema-defined shape and
direction; names such as `cameraToWorld` are preferred over ambiguous
`transform`.

The version 1 world frame is identified as `arkit-world`, right-handed, in
meters. The ARKit camera looks along its negative Z axis. Stored RGB pixel
coordinates use a top-left origin after the orientation declared by the
observation. These conventions require confirmation against a real capture
before freezing schema 1.0.0.

## Binary artifact formats

Version 1 retains the existing encodings:

- RGB: JPEG with dimensions and orientation declared in `capture.json`.
- Depth: zlib-compressed little-endian IEEE-754 Float32, row-major, meters.
- Confidence: zlib-compressed UInt8, row-major, using the declared value map.
- LiDAR mesh: little-endian Float32 XYZ triples in the declared world frame.

Decoders validate decompressed byte counts exactly. Metadata declares the
expected count before allocation. Future formats receive new media types and
must not silently reuse an existing type with different semantics.

## Layout snapshot

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

## Subject metadata and PHI

`subject.json` is optional and contains the subject label/MRN or future study
identifiers. Keeping it separate allows de-identification without rewriting
capture geometry. The manifest indicates whether subject metadata is present
but must not duplicate PHI into filenames or general audit messages.

The current subject-derived ZIP filename should be replaced by a configurable
policy. The safe default for clinical transfer is the bundle/session UUID plus
capture timestamp, with human-readable PHI shown only after authorized import.

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
unchanged; a migrated working representation or newly exported bundle records
its source bundle ID and original schema version.

## Integrity versus authenticity

Per-file SHA-256 detects corruption and incomplete transfer but does not prove
who created the bundle. A later security profile should add a detached digital
signature over a canonical manifest representation or an archive digest. Do not
describe an unsigned hash list as tamper-proof.

## Validation and test fixtures

Before schema 1.0.0 is frozen, add:

1. JSON Schemas for manifest, capture, layout, run, review, and subject files.
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
6. Add a legacy importer for the current `session.json` directory/ZIP format.
7. Switch iOS export to the new bundle while retaining legacy import tests.
8. Build macOS local-file import and inspection against the same validator.
9. Add processing runs and reviews.
10. Add authenticated/resumable network transfer after file import is stable.

## Decisions still required before 1.0.0

- Public schema identifier/namespace and where schemas will be published.
- Whether bundle identity changes when derived runs/reviews are appended, or
  whether capture and analysis are separate linked bundles.
- PHI filename policy and encryption-at-rest requirements.
- Maximum asset sizes/counts and archive expansion limits.
- Whether Float64 metadata is required throughout or Float32 values are retained
  exactly from ARKit with an explicit numeric type.
- Whether XML output is required by a named downstream consumer.
- Long-term representation of image/depth calibration beyond simple resolution
  scaling.


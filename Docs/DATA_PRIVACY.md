# MANTA Data Privacy

Status: pre-release policy and design notes. This document is not legal advice
and does not replace IRB, institutional privacy, information-security, records
management, or informed-consent requirements.

## Current decision

MANTA treats every raw human `.manta` capture as potentially identifiable data.
Removing a participant name or using a timestamp filename does **not** make a
capture de-identified.

For the initial research deployment, MANTA will preserve the full capture needed
for reproducibility and protect it with:

- Encrypted storage on iPhone/iPad, macOS, backups, and approved archival media.
- Controlled access limited to authorized study personnel and systems.
- Institution-approved encrypted transfer mechanisms.
- PHI-free `.manta` filenames and separation of direct subject identifiers from
  capture metadata wherever practical.
- Documented retention, deletion, access-review, and incident-response procedures.

Automated facial redaction and a privacy-reduced bundle profile are future work.
Until those mechanisms are implemented and validated, MANTA must not describe a
raw capture as anonymized or de-identified.

## Why the capture may identify a participant

MANTA combines multiple data sources that can preserve appearance and geometry:

- Full RGB camera frames used for OCR and photogrammetry.
- LiDAR scene depth aligned with camera pixels.
- Camera poses and intrinsics that permit multi-view reconstruction.
- Point clouds, LiDAR meshes, and photogrammetry models.
- Model textures, if retained.
- Nasion and left/right preauricular landmarks near distinctive facial anatomy.
- Head shape, ears, capture dates, device metadata, and study metadata that may
  increase re-identification risk when combined with other records.

An EGI net obscures portions of the scalp and hair, but it does not reliably
obscure the eyes, nose, mouth, cheeks, jaw, or ears. A scan passing around the
front and sides of the head may therefore produce recognizable source images or
a recognizable three-dimensional reconstruction.

Photogrammetry presents the clearest risk because it reconstructs geometry from
many overlapping photographs and may retain photographic texture. LiDAR without
RGB is less immediately recognizable, but detailed facial and ear geometry may
still act as identifying biometric information. Combining RGB and depth is more
revealing than either source alone.

Apple documents that ARKit scene depth measures objects in the corresponding
camera image and demonstrates a camera-colored depth point cloud that can
closely resemble the camera feed:

- [ARKit scene depth](https://developer.apple.com/documentation/arkit/arconfiguration/framesemantics-swift.struct/scenedepth)
- [Displaying a point cloud using scene depth](https://developer.apple.com/documentation/arkit/displaying-a-point-cloud-using-scene-depth)
- [RealityKit Object Capture](https://developer.apple.com/documentation/realitykit/realitykit-object-capture/)

## Regulatory and research context

HHS HIPAA de-identification guidance includes biometric identifiers and
full-face photographs or comparable images among the identifiers addressed by
the Safe Harbor method. A textured facial model should be treated as a
comparable image; a detailed untextured facial mesh should also be handled
conservatively as potentially identifiable.

- [HHS guidance on de-identification](https://www.hhs.gov/hipaa/for-professionals/special-topics/de-identification/index.html)

NIH guidance emphasizes protecting participant privacy and generally sharing
human-participant data in de-identified form unless identifiable sharing is
appropriately consented and governed. Actual requirements depend on the study,
institution, consent, applicable law, and intended recipient.

- [NIH privacy guidance for sharing human research participant data](https://grants.nih.gov/grants/guide/notice-files/NOT-OD-22-213.html)

Consent and protocol language should describe the collection of photographs and
three-dimensional head/facial geometry, not only “electrode coordinates.”

## Data classification

For current use, the following should remain inside the restricted-data
boundary:

- Raw and derived RGB frames, including previews and thumbnails.
- Depth and confidence maps paired with camera frames.
- Colored point clouds and textured models.
- Untextured head or face meshes unless reviewed under an approved policy.
- Working sessions, raw `.manta` bundles, reconstruction inputs, and temporary
  export/import directories.
- Logs or metadata containing subject, study, device, network, or precise time
  information that could assist linkage.

Terminal coordinate exports such as SFP, ELP, BIDS, EGI XML, and CSV contain
less directly recognizable information, but they are not automatically public.
Their study linkage, subject coding, dates, and unique geometry still require
the project’s approved data-handling policy.

## Storage and access baseline

Before capturing participants, deployment planning should document:

1. Which platform encryption and key-management mechanisms protect iOS working
   sessions, exported `.manta` files, macOS imports, backups, and archives.
2. Which users, applications, and service accounts may read, export, copy,
   process, or delete captures.
3. Where unencrypted temporary files could appear and how they are removed.
4. Which transfer paths are approved; consumer cloud sharing and removable
   media should not be assumed acceptable.
5. Whether access and export events require audit records.
6. Retention periods for raw frames, reconstructed models, derived bundles, and
   coordinate-only exports.
7. Procedures for participant withdrawal, deletion requests, device loss, and
   suspected disclosure.

The `.manta` SHA-256 inventory protects integrity, not confidentiality or
authenticity. Hashes do not encrypt data. Archive encryption, authenticated
transfer, storage encryption, and access control are separate requirements.

## Future privacy-reduced profile

A later MANTA version may support two explicit bundle profiles:

| Profile | Intended contents | Handling |
| --- | --- | --- |
| `restricted-raw` | Original RGB, depth, confidence, poses, meshes, models, and reconstruction evidence | Identifiable controlled-access research data |
| `privacy-reduced` | Redacted or cropped images, scalp-only geometry, electrode evidence crops, derived observations, and coordinates | Reduced disclosure risk; not automatically a legal de-identification determination |

A privacy-reduced bundle must be a new immutable derivative with its own
`bundleID`, `parentBundleID`, and `log_manta.json`. The source bundle must remain
unchanged and restricted. Proposed machine-readable privacy provenance includes:

- Whether full-frame RGB is present.
- Whether facial pixels, facial geometry, ears, or textures are present.
- Redaction algorithm name and version.
- Source bundle ID.
- Automated and human review status.
- Known limitations and regions deliberately retained for nasion/LPA/RPA.

## Candidate minimization and redaction techniques

These are future research directions, not current guarantees:

- Guide capture above a scalp-focused privacy boundary.
- Warn or gate capture when excessive lower-face area is visible.
- Collect short, localized fiducial views instead of continuous facial sweeps.
- Mask facial pixels before JPEG persistence and photogrammetry processing.
- Prefer irreversible solid masking over ordinary blur.
- Retain small electrode-label evidence crops instead of full RGB frames.
- Remove model textures and delete central-face, nose, eye, mouth, cheek, and jaw
  geometry from privacy-reduced derivatives.
- Replace detailed ear geometry with reviewed LPA/RPA landmark points when the
  solver does not require the ear surface.
- Preserve redaction masks and removed-volume definitions as provenance.

Any minimization technique must be evaluated against electrode OCR,
photogrammetry reconstruction, LiDAR alignment, fiducial placement, and final
electrode localization accuracy.

## Validation needed before a privacy claim

A useful empirical study would generate, from representative 128- and
256-channel captures:

1. Original RGB frames.
2. RGB-colored depth point clouds.
3. Untextured meshes.
4. Textured photogrammetry models.
5. Candidate privacy-reduced versions of each artifact.

Independent reviewers should assess recognizability, while MANTA measures OCR
recall, reconstruction quality, alignment residuals, fiducial reliability, and
electrode localization error. This produces a privacy–accuracy tradeoff based on
evidence rather than assuming that a net or an untextured mesh conceals identity.


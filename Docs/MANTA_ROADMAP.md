# MANTA implementation roadmap

Updated: 2026-11-05

## Milestones — execute in this order

The first head-only trial is collected. Complete G1 device acceptance, then prioritize
M1 motion recovery and the remaining M5 acquisition checks before an expensive net
trial. Continue software checks with each increment; do not treat compilation as
device validation. Preserve original capture evidence.

| Milestone | Required outcome | Software status | Physical acceptance |
|---|---|---|---|
| A1 | Recover completed frames and measure capture costs | Implemented | Pending |
| A2 | Keep capture responsive with bounded background writes | Implemented | Pending |
| A3 | Flag movement, preserve evidence, and separate repeat passes | Implemented, conservative policy | Pending |
| A4 | Capture sharp stills and show honest label coverage | Implemented, experimental gates | Pending |
| A5 | Recover missing evidence before participant release | Implemented, coarse guidance | Pending |
| A6 | Register stable segments, then evaluate per-frame correction | Experimental reviewed-segment CLI implemented; full milestone open | Pending |
| H1 | Head-only readiness, saved-surface review, and collection without GeoScan | Implemented | Pending |
| H2 | Separate view coverage, depth, surface, blur, and motion evidence | Implemented, advisory | Pending |
| H3 | Keep capture/export actor boundaries and completion handling safe | Implemented | Pending |
| R1 | Open captures in place with visible progress; keep Mac results in derivatives | Implemented; first head-only folder opened | Inspect surface quality before a net trial |
| G1 | Guide capture with a persistent top route and actionable movement fallback | Implemented; device acceptance pending | Rehearse the route, skipped steps, and linked-pass recovery on M5 |
| M1 | Correct head motion and guide reacquisition when uncertain | Next; extends A6, not implemented | Known-motion controls and independent accuracy before relying on correction |

Run CI setup alongside acquisition work. A6's initial offline recovery path is now
coded alongside A1–A5. Before a head-only person trial, complete A1–A3, the geometry
and photo portions of A4/A5, and H1–H3 bench checks in [VALIDATION.md](VALIDATION.md).
Complete net-specific label/recapture checks before a net trial. GeoScan belongs to
Receiver on macOS, not iPad collection. A6 is not yet validated automatic recovery: keep the A3 stop/new-pass
workflow, and retain a complete stationary pass before relying on recovered data.

Prioritize M1 below before these later offline increments. Coordinate its camera
handling with the calibration work; do not delay recovery solely for OCR features.
After acquisition readiness, implement these offline increments in order:

1. Align Object Capture trajectories and consume accepted calibrated cameras.
2. Make robust multi-view electrode triangulation the primary supported solve.
3. Profile geometry and accelerate ray/nearest-neighbor queries where justified.
4. Add previewable head masks without eroding electrodes or fiducials.
5. Add tiled and disc-crop OCR, scored on held-out sessions.

Keep original poses immutable, identify measured versus inferred coordinates, preserve
manual edits, and require independent validation before promoting accuracy changes.
Defer TSDF, a new raw image codec, and learned recognition until comparisons justify them.

### A1 — Recoverable evidence and capture timings

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

### A2 — Bounded, responsive acquisition

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

### A3 — Motion awareness and safe capture segments

**Status: software implemented with the conservative separate-pass policy; physical validation pending.**

**Why this will benefit MANTA:** A3 makes subject movement visible before it silently contaminates surfaces and electrode coordinates. Preserving separate stable segments and flagging uncertainty gives the operator a chance to collect a repeat or overlap while the net is still on, and gives later correction trustworthy source evidence.

- [x] Add manual “subject moved” marking and stable-segment identities with timestamps.
- [x] Add a conservative depth consistency advisory against a previously accepted
  stable reference. Track overlap/confidence and an insufficient-evidence state;
  avoid incorporating suspect frames into trusted fusion or reference updates.
- [x] Retain suspect raw evidence; flag uncertain intervals and guide the operator to
  settle, collect overlap, or acquire a separate repeat pass. Do not silently combine
  segments or imply that normal ARKit tracking proves a stationary head.
- [x] Keep tracking-world identity separate from head-segment identity; interruption
  still requires the existing new-session policy. Invalidate stale coverage overlays.

Current behavior: the operator freezes a head-cropped mesh reference. Each sampled
frame checks sparse high-confidence depth against that fixed reference. Insufficient
overlap/depth is reported as unknown, not stationary. Suspected or manually marked
movement stops the pass, persists a recovery marker, hides stale live guidance, and
requires a separate session/pass with a new segment identity. RAW evidence remains
available; automatic detection, depth fusion, and reconstruction reject flagged
captures pending review/registration. There is no same-session post-motion merge.
The check is sample-triggered, not continuous video tracking. Thresholds (25 mm
median residual, 60 mm association radius, 50% overlap) are provisional bench settings,
not a claim of motion sensitivity. Rotation on a smooth head can remain undetected.

Done when stationary scans, camera-only motion, deliberate head-object motion,
occlusion, and inadequate overlap produce understandable, recorded outcomes on M5.
Measure false alerts and detection failures before selecting thresholds. No claim of
millimetre motion accuracy or automatic correction is required for this milestone.

### A4 — Sharp evidence and live label coverage

**Why this will benefit MANTA:** A4 increases the number of readable electrode sightings per minute and reveals what the camera actually captured. Sharp stills and honest label coverage reduce redundant views and prevent a template-filled preview from disguising missing measurements.

- [x] Add hold-still still capture with sharpness, angular-motion, thermal, and
  coverage gates plus a manual override. Enable only the configuration validated in A1.
- [x] Add hybrid novelty/coverage sampling with minimum and maximum time gaps and
  adequate view overlap. Preserve manual sampling and revisits for unread labels.
- [x] Let calibrated RGB-only stills contribute OCR identity evidence without requiring
  a depth/mesh hit. Keep “read”, “supported in distinct views”, and “localized” separate.
- [x] Keep inferred/template electrodes visibly distinct from actual sightings;
  conflicting or ambiguous OCR must not falsely complete coverage.

Software behavior: automatic high-resolution stills require a sharp view held steady
for at least 0.3 seconds, normal tracking, thermal readiness, and a camera direction
without a successfully saved sharp still. Manual stills remain available for revisits.
Adaptive sampling is opt-in; it uses novelty, a minimum gap, and a three-second
sharp-frame fallback. These are provisional thresholds pending the combined trial.
Live OCR reads stills even without depth, samples fewer regular frames, and displays
read/unverified, distinct-view support, ambiguous, localized, and unread counts.
Template predictions are hidden while tracking. Advisory per-image OCR evidence is
saved and included when available in exports; this is not the final Mac solve.

Done when bench scans demonstrate improved usable image/label yield without unacceptable
coverage gaps, false labels, tracking degradation, memory growth, or heat. Still count
and hold duration are tuning parameters, not proof that a 256-channel net is complete.

### A5 — Recapture before release

**Why this will benefit MANTA:** A5 turns coverage feedback into action while the participant is still available. The operator can revisit unread or ambiguous electrodes before ending tracking, reducing incomplete datasets and repeat visits requiring another net application.

- [x] Add a front/left/right/back/top photo checklist within one continuous tracking
  session. Keep sampling active between/through stops; five photos are not a
  completeness requirement. Each still keeps its own pose/calibration.
- [x] Add a coverage review while tracking remains active, followed by targeted
  recapture, then the final integrity/release check. Show unread/ambiguous labels and
  coarse guidance before attempting precise camera overlays.
- [x] Suppress predicted location overlays until head alignment and visibility are
  validated. A5 uses operator-selected view/label targets and coarse guidance; precise
  overlays are deferred to the validated alignment work, not guessed from templates.
- [ ] Validate a full M5 rehearsal: deliberately omit views, recover missing evidence,
  mark movement, collect a safe repeat, finalize, transfer, and reopen on the Mac.

Software behavior: Review coverage leaves tracking/sampling active. Optional view
buttons select a named photo target; only a committed sharp tagged still checks its
box. Automatic/general stills remain untagged. The panel separates unread, ambiguous,
and single-view labels and supports a manual recapture target. Final integrity review
is explicit, drains writes/OCR, pauses tracking, and records unresolved gaps in the
acquisition context. New frames invalidate old review/export status, including during
checkpoint recovery. No count or set of checked boxes certifies measurement completeness.
Offline view-tag editing is a later Receiver convenience; metadata already supports it.

Done when the operator can identify and address missing evidence before ending the
live capture, and the saved package passes the integrity/recovery checks. Summarize
unresolved labels/segments explicitly; neither a template nor frame count implies
measurement completeness. Geometry/acquisition acceptance is required before a head-only trial; net-specific acceptance is required before a net trial.

### A6 — Validated recovery across stable segments, then individual frames

**Why this will benefit MANTA:** recover useful evidence from stable intervals before
and after head movement, reducing the chance that an expensive net application must
be repeated. Rigid registration can bring depth and photo rays into the same frame;
it cannot repair blur, deformation, or net slippage.

- [x] Implement Mac registration of explicitly reviewed, overlapping stable segments
  using cropped high-confidence depth, matched landmarks, rigid refinement, symmetric
  overlap/residual gates, and individual depth-frame checks. Rejections stay explicit.
- [x] Add report-only default and opt-in NEW derived package output; preserve original
  packages, original poses, suspect flags, source hashes, forward/inverse transforms,
  and uncalibrated status. Correct cameras so depth and image rays share one reference
  frame. Exclude stale surfaces, coordinates, and coverage; regenerate them downstream.
- [ ] Validate the provisional gates against measured movement, poor overlap, symmetric
  geometry, and stationary controls. Confirm independent localization accuracy.
- [ ] Add Receiver selection/landmark UI. Until then use the reviewed JSON request and
  [Mac recovery command](SEGMENT_RECOVERY.md). No automatic interval selection exists.
- [ ] Complete common-frame fiducial/coverage handling with validated interval
  provenance. Currently place final fiducials on the rebuilt surface; never reuse
  source fused meshes or aggregate coordinate solutions across a movement event.
- [ ] Integrate with 11.2 camera calibration and make 11.3 triangulation segment-aware.
  Compare stationary controls and known rigid motion against independent references.
- [ ] Only then evaluate per-frame registration and masked Object Capture poses.
  Deformation, net slippage, and blur remain distinct failure modes. TSDF is optional.

Done when accepted segment registration preserves independently measured localization
and failed recovery remains explicit. Object Capture/ARKit disagreement alone is not
a head-motion estimate; down-weighting moved frames alone is not correction.

### H1 — Head-only readiness and saved-surface review

**Why this will benefit MANTA:** make the first person trial about collecting and
inspecting usable head geometry, without electrode or reference-study distractions.

- [x] Reuse No Net / Head Mesh Only with guided head-region setup, stable-reference
  freezing, overlapping views, optional head-photo tags, and optional fiducials.
- [x] Add Save and inspect head surface: pause, drain writes, checkpoint the mesh,
  then open the model for orbit/zoom without ending or replacing the session.
- [x] Remove GeoScan collection prompts and the iPad GeoScan export choice. Keep
  comparison and GeoScan-specific output in Receiver; preserve legacy metadata.
- [x] Invalidate old cropped-mesh/review/export references and the motion reference
  after head-region edits; retain the original mesh and frames.
- [ ] Verify region/reference setup, inspection, valid resume, and new-pass handling
  on M5. Confirm no reference-study fields interrupt either head-only or net capture.

### H2 — Honest geometry feedback

**Why this will benefit MANTA:** expose missing or uncertain evidence before the
person leaves, without mistaking camera viewpoints or a displayed mesh for a
complete, accurate head surface.

- [x] Replace the surface-like percentage/progress ring with View coverage. Count
  distinct camera-position sectors around the chosen head region; without a region,
  coverage is unknown. Exclude suspect, blur-flagged, unscored, unsaved, invalid poses.
- [x] Separately show recorded depth/confidence, saved head crop versus environment
  mesh, blur/unknown sharpness, and consistent/unknown/suspect motion counts.
- [x] Save geometry evidence in the final review snapshot. File references/counts
  describe recorded evidence; receipt decoding checks and manual inspection remain
  separate. RGB-only stills do not become a missing-depth percentage failure.
- [ ] Test intentionally missed regions, RGB-only stills, blur, absent depth,
  insufficient motion evidence, and suspect frames on M5. A full view count must not
  imply complete geometry. Surface-hole heatmaps remain deferred.

### H3 — Capture/export concurrency and completion

**Why this will benefit MANTA:** keep deep validation and large exports responsive,
and prevent a failed save or interrupted export from appearing ready to share.

- [x] Prepare export values and UIKit producer metadata on the main actor; snapshot
  mutable JSON sidecars before work begins. Use an explicitly nonisolated, Sendable
  worker with its own file manager for receipt validation, copying, and hashing.
- [x] Run both RAW and paired RAW/solved export through the worker. Bound progress
  delivery to the latest update on the main actor and drain it before resetting UI.
- [x] Lock session switching/deletion before suspension, drain accepted frame writes,
  reject failed checkpoints, and publish share URLs only after lineage is persisted.
- [x] Remove uncommitted output after cancellation/failure, including partial pairs.
  Cancellation waits for the current synchronous file operation to finish; original
  capture files are preserved. No new cancellation button is introduced.
- [x] Move final-review deep receipt checks off the UI actor as well.
- [ ] Measure responsiveness and memory during a full-size M5 export. Exercise low
  storage, background/termination, recovery, and transfer/reopen on the Mac.

Separate follow-ups remain for Receiver reconstruction concurrency diagnostics and
migration of the iPad orientation API; these are outside H3's acquisition/export
actor-boundary fix.

### G1 — Guided top-route acquisition

**Why this will benefit MANTA:** keep the next capture action visible while the
operator watches the camera and surface, reducing forgotten views and settings
without making Experiment compete with the acquisition display.

- [x] Add Setup → Reference → Orbit → Photos → Review → Finish across the iPad top.
  Default to camera/surface split with individual expand/restore controls. Keep the
  iPad app full-screen and landscape-only (either horizontal direction); retain
  iPhone orientation support.
- [x] Keep step-specific instructions and evidence visible below the views; keep
  Sample Frame and Hi-Res Photo distinct. Allow manual advance/revisit, recording
  skipped steps instead of declaring coverage complete. No automatic advancement yet.
- [x] Persist route progress in native session metadata. Reopening an ended capture
  permits route inspection without rewriting the saved progress.
- [x] Make movement actionable: pause, preserve and end the old pass, then start a
  linked pass for the same subject with a new region/reference. A failed save keeps
  the old pass available for retry. This is a fallback, not motion correction.
- [ ] Rehearse in both landscape directions with actual depth, stills, a deliberate
  movement event, incomplete steps, surface inspection, and final file validation.

### M1 — Head motion correction and guided reacquisition (next)

**Why this will benefit MANTA:** retain usable evidence across ordinary rigid head
movement and avoid repeating an entire orbit or net application. The operator should
receive a recovery action, not just a movement warning. Extend A6 in these increments:

1. **Offline recovery and measurement first.** Add Receiver review/selection of stable
   intervals and corresponding landmarks, using A6's preserved poses and derived
   outputs. Evaluate the existing head-only data where it has adequate evidence;
   collect controlled stationary, camera-only, and known head-motion bench sequences.
   An unassessed legacy frame is not automatically a stable control.
2. **Head-relative per-frame poses.** Estimate rigid head pose separately from camera
   motion using foreground depth and image correspondences, with overlap, ambiguity,
   residual, and temporal checks. Start with offline replay. Preserve original camera
   poses, pixels, and confidence; record accepted corrections and failure reasons.
   Apply accepted transforms consistently to depth and calibrated photo rays. Mask
   the stationary room/torso out of head reconstruction and rebuild derived surfaces;
   do not transform an already smeared ARKit mesh or trust ICP residual alone.
3. **Live recovery guidance after replay validation.** Expose three distinct states:
   corrected/continue; uncertain/pause accepted fusion and return to the last good
   overlapping view; lost/save and start a linked pass. Preserve uncertain evidence
   separately for review. Require a verified reacquisition before advancing coverage.
   Associate high-resolution exposures with motion evidence at their own timestamps;
   do not assume the nearest depth frame proves a still's pose.
4. **Independent acceptance before net use.** Compare corrected geometry and held-out
   landmarks against stationary controls and measured motion, including rear/crown
   symmetry, occlusion, blur, and poor overlap. Set acceptance/uncertainty thresholds
   from these results. Treat net slippage, facial deformation, and blur separately;
   rigid correction must not silently absorb them or certify electrode accuracy.

Until these checks pass, the shipped behavior remains A3/G1's stop-and-linked-pass
fallback. A6 registration remains experimental. M1 does not promise recovery of the
already collected distorted mesh; it works from retained frame evidence when usable.

## What we have now

- iPad has a persistent six-step capture route, default split view, expand controls,
  step-specific actions, visible skipped checks, and a save-and-start-linked-pass
  fallback for movement. Route progress is separate from measured data quality.
- Receiver opens native iPad folders directly, with stage/file/byte progress and elapsed
  time. Original inputs stay unchanged; its small acquisition index and saved processing
  outputs live under `derivatives/`. Legacy ZIPs still extract to a chosen location.
- A first head-only capture has opened with 49 RGB-D frames. This establishes successful
  loading, not surface accuracy or validated movement recovery. Review gaps and stray
  geometry before the next participant; physical acceptance remains open.

- iPad capture stores calibrated RGB, depth/confidence, frame checkpoints, mesh,
  fiducial evidence, acquisition events, and named sessions with explicit ending.
- Capture presets, storage protection, interruption guards, recent-frame selection,
  experimental high-resolution stills, and release integrity checks exist.
- A1/A2 share iPad/Mac checkpoint recovery, reuse the image context, write frames on a
  bounded worker, batch metadata, record timings/backpressure, and drain before export.
- A3 records head-segment identity and depth-consistency assessments. Manual or suspected
  movement stops the pass and preserves a durable recovery flag. A separate pass is
  required; automatic correction is not implemented. A6 can derive an experimental
  package from manually reviewed stable intervals offline. Checks require an operator-frozen
  head reference and run when frames are sampled.
- Receiver supports calibrated RGB-only localization with mesh/depth fallbacks and
  retains unresolved 2D evidence. Shared core geometry, RAW recovery, integrity checks,
  GeoScan comparison, estimated calibration export, and a benchmark runner exist.
- Estimated camera calibration is exported but not yet the default localization input.
  A4 adds RGB-only live label coverage and sharp-view capture gates. A5 adds the
  optional five-view checklist, active-tracking review, recapture targets, and a final
  unresolved-evidence snapshot. Precise overlays and offline tag editing remain deferred.
- A6's Mac command produces a registration report and optionally a new package with
  corrected cameras and per-frame provenance. Receiver can process that package
  using existing depth/ray paths; Object Capture remains blocked pending masks/pose
  validation. Raw suspect captures remain blocked from automatic
  processing; partial/mixed/invalid correction metadata is rejected.
- Software regression/build checks are recorded in VALIDATION.md. No physical M5
  responsiveness, motion sensitivity, or localization accuracy claim follows from them.

## Any bugs we’ve found

| Finding | Status / required action |
|---|---|
| Mac RAW recovery omitted completed checkpoints absent from stale session.json | Fixed in A1 with a shared loader and regression tests. |
| Capture encoding blocked the main actor; still requests blocked automatic sampling | Addressed in A2; measure actual cadence and responsiveness on M5. |
| Full session/diagnostic rewrites repeated on each auto sample | Batched in A2; profile remaining main-actor metadata/event overhead. |
| Live OCR rejected RGB-only stills | Fixed in A4: RGB-only sightings contribute coverage; geometry remains separate. |
| Template-filled preview obscured actual sightings | A4 hides inferred positions while tracking and counts only OCR evidence; validate recognition on M5. |
| Healthy room tracking does not detect a moving head | A3 adds advisory checks; G1 makes the linked-pass fallback actionable. M1 continuous head tracking/correction is next and remains absent. |
| Release review paused capture before the operator could address missing evidence | A5 separates active-tracking coverage review from the explicit final check. |
| Earlier review/export status could remain visible after additional capture | A5 invalidates it on new frames and checkpoint recovery. |
| View-sector count appeared as a head-surface percentage | H2 replaces it with explicitly advisory view coverage and separate evidence counts. |
| Changing head bounds could leave stale reference/crop/review metadata | H1 clears those references and requires a new motion reference; raw evidence stays intact. |
| Suspect passes could only be retained, not registered for reuse | A6 adds experimental reviewed-segment recovery; independent accuracy and selection UI remain open. |
| iPad RAW export called main-actor store code from a detached task; paired export ran heavy work on the UI actor | Fixed in H3 with prepared worker jobs, bounded progress, checkpoint gating, and cleanup. Measure full-size performance on M5. |
| Receiver opening showed a generic copy/validation spinner and native folders required conversion | R1 opens folders in place, reports stage/file/byte progress, and confines processing writes to derivatives. |
| Receiver displayed upright landscape PNGs upside down | Fixed reversed iPad landscape tags. Receiver corrects contradictory legacy landscape tags using original camera-pose gravity; Viewer/Align render and landmark-click mappings use the same orientation. Original files stay unchanged. |
| Sample Frame was easy to mistake for a dedicated high-resolution still | Added a visible Hi-Res Photo button directly below Sample Frame in both iPad layouts; manual stills enabled by default, with saved dimensions and unavailable-state feedback. Verify format/depth compatibility on M5. |
| Automatic overlay accepted a 46.8 mm surface mismatch and displayed a green approval | Fixed: 10 mm automatic screening limit, recheck saved fits, separate unaligned photo/depth views, and no accuracy-approval badge. Registration quality still needs improvement. |
| Receiver reconstruction concurrency warnings and iPad orientation deprecation | Separate follow-up; H3 does not claim these are fixed. |

Depth/still registration, false motion alerts, motion missed by a smooth/symmetric
surface, and device performance remain validation questions, not established fixes.

## Validation and open decisions

- Run the combined M5 bench rehearsal after acquisition coding: stationary controls,
  camera-only movement, known head-object movement, occlusion, poor overlap, blur,
  storage pressure, background/termination, export/recovery, and missing-label recapture.
- Freeze a supported high-resolution/depth configuration from device evidence.
- Select motion thresholds from measured false alerts and missed movement. Current
  thresholds are experimental; an insufficient-evidence state is not a pass.
- Obtain independent reference coordinates and held-out sessions for accuracy claims.
- Test A6 on the same bench fixtures before relying on recovered coordinates. A6
  software does not replace the acquisition gate or authorize continuous-motion scans.

## Supporting detail and history

See [roadmap background](MANTA_ROADMAP_BACKGROUND.md) for the original assessments,
platform references, detailed offline designs, and implementation history. That file
is historical context; this roadmap controls the current implementation order.

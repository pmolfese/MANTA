# Surface Alignment — design sketch

Status: **proposal, not built.** Captured end of 2026-07-15 session so we can resume cold.
Related built work: multi-view triangulation + fit models + plausibility (shipped this session, see bottom).

---

## The problem this solves

The manual alignment workspace registers the photogrammetry model into the ARKit/LiDAR
world frame using landmark correspondences. Two clicking operations feed it, and **only one
is poisoned**:

- **Source landmarks** — clicked on the 3D model; already raycast onto the model *surface*
  (`onPhotogrammetryPointPicked` → `MeshRaycaster`). Clean.
- **Target landmarks** — clicked on RGB images, then resolved to world **through per-frame
  LiDAR depth**. This is the entire source of the Cz failure: depth at the grazing,
  cap-covered vertex pixel is junk, so the world-Cz lands ~50 mm off. The fit then tries to
  reconcile a clean model-Cz against a garbage world-Cz.

Evidence (bundle `20260714_140904_processed`, `logs/alignment_debug_log.json`): archived
cardinals fit at **~2.9 mm**; Cz is the lone **50–60 mm** outlier and is *already excluded*
by `AbsoluteOrientation.fitRobust`. The alignment is basically good; the target-via-depth
step manufactures a problem.

## Core idea

Treat the LiDAR/fused surface and the (depth-guided → **metric**) photogrammetry surface as
two independent metric surfaces. **Register surface-to-surface**, and demote landmarks from
*fit constraints* to *seed + validation*. Stop resolving landmark clicks through per-frame
depth entirely.

Because a depth-guided reconstruction is metric (real meters), the model surface is now
directly *measurable* — distances on it are true, and clicks already resolve onto it.

## Why it dissolves Cz specifically

Under this scheme Cz is clicked **on the model surface** (clean raycast) and never gets an
independent depth-resolved world target. Its world position becomes simply
`transform × Cz_on_model`. The 50 mm error never existed in Cz's true location — it was
purely a depth-reading artifact. Remove depth from the loop and Cz is fine for free.

## Proposed "Surface Alignment" mode

1. **Placement** — all anatomy clicked on the photogrammetry model surface (raycast). No
   image-click-through-depth for anything.
2. **Seed** — 3 archived cardinals (world, clean, from `bundle.capture.fiducials`) ↔ the 3
   cardinals clicked on the model → a rigid/similarity seed (Horn). Enough to fix gross
   orientation + the front/back mirror. Cz-on-model can be a clean 4th seed point.
3. **Fit** — surface ICP: photogrammetry cloud ↔ fused-depth/LiDAR cloud, **scale-locked**
   (`.rigid`) when the model is metric. "Do our best" over the whole overlapping head
   surface.
4. **Validate** — project model cardinals through the result, compare to the archived
   cardinals → an independent, **depth-free** "landmark check RMS" that is *not* a fit input.

## Why it's better, not just cleaner

- **Robust to wonky LiDAR.** A landmark fit is hostage to depth at a few pixels; surface ICP
  averages thousands of points, so a local LiDAR blob barely moves the answer. Trading
  pointwise depth for whole-surface registration is the right direction given the observed
  local LiDAR noise ("drew outside the lines").
- **Decouples** placement / depth-bias / fit, which are currently tangled.

## The one honest caveat

Surface ICP on a roughly spherical head still needs a **seed** to avoid the front/back
basin — can't go fully landmark-free. Archived cardinals give that seed cleanly; if
depth-guided, gravity fixes two rotation axes too (see the `.depthGuided` sketch below).
Fully pays off only when the model is metric — an images-only model still leans on the
cloud to recover scale (collapse risk), one more reason depth-guided reconstruction matters.

---

## What already exists (reuse, don't rebuild)

- **Model surface cloud**: `ModelPointCloudLoader.load(url:maxPoints:)` on
  `reconstruction.objectCaptureModelPath`.
- **Model surface raycast** (for placement): `MeshRaycaster.firstHit` + `ReceiverPLYMesh`
  (already wired for snap; see `ReceiverMeshSnap`). Placement raycasts against the *model*
  mesh, not the LiDAR mesh.
- **Fused/LiDAR target cloud**: `ReceiverManualAlignmentWorkflow.fusedDepthTarget(...)`
  (dense, metric, ARKit-world) with `alignmentTarget(...)` (sparse LiDAR head crop) fallback.
- **Surface ICP**: `WorldAlignmentSolver.solve(strategy: .icp, input:)` —
  `CoarseAlignment.pca` seed, `AbsoluteOrientation.fit(scale:)` per iteration, scale modes
  incl. `.rigid`/`.bounded`.
- **Scale-collapse-proof metric**: `SurfaceAlignmentMetrics.symmetricRMS(...)` (MANTACore).
- **Archived cardinals**: `bundle.capture.fiducials` (arkit-world meters); `FiducialKind.cardinal`,
  `.vertex` = Cz.
- **Plausibility / validation math**: `LandmarkPlausibilityAnalyzer.evaluate(...)`,
  `AbsoluteOrientation.fit(source:target:model:)`.

## What's new to build

- A `WorldAlignmentStrategy.surface` (or a mode in the workspace) that:
  - takes **model-frame** landmarks only (no image-depth target resolution),
  - builds the rigid/similarity seed from archived-cardinals(world) ↔ model-cardinals,
  - runs scale-locked surface ICP (model cloud → fused/LiDAR cloud),
  - reports the depth-free cardinal-check RMS as the acceptance number.
- Workspace: a placement path that raycasts clicks onto the **model** for the target role
  too (so target landmarks live in model frame), or simply drop the target-click step and
  use archived cardinals for the seed.
- Acceptance: gate on cardinal-check RMS + `symmetricRMS`, not on any depth-resolved target.

## Open decisions for next session

- Seed source when archived cardinals are absent: fall back to gravity+PCA (`.depthGuided`),
  or require them?
- Do we keep image-click target resolution at all, or fully retire it in favor of
  model-surface placement + triangulation (below) for the rare cross-frame need?
- Where does Cz's mirror-disambiguation come from once it's model-only — the archived
  cardinal seed already fixes front/back, so Cz may become optional again.

---

## Related, already shipped: multi-view triangulation (depth-free target resolution)

Built this session (`MANTACore/Sources/MANTACore/MultiViewTriangulation.swift`, tested).
This is the **depth-free way to get a world point from image clicks** — the complement to
Surface Alignment for any case where you still need an image-derived world target instead of
a model-surface point.

- `MultiViewTriangulation.triangulate(rays:) -> Result?` — least-squares closest point to a
  bundle of camera rays. Minimizes Σ dist(x, rayᵢ)²; solves `(Σ(I − dᵢdᵢᵀ)) x = Σ(...) oᵢ`.
  Returns `point`, `rmsMeters` (ray disagreement), `rayCount`. Rejects <2 rays / near-parallel.
- Wired as `TargetResolutionMode.triangulate` in `ReceiverAlignmentWorkspace`
  (Depth / Snap to LiDAR / **Triangulate**). Clicking is **on the photos**: same landmark in
  2+ frames → rays → intersection. Camera ray per click = `PinholeCamera` center +
  `unproject(pixel, 1)` direction (see `rays(for:)`).
- Table shows **Ray RMS · view-count**; persisted into diagnostics
  (`perLandmarkTriangulationRMSMeters`).

**How it relates to Surface Alignment:** both remove per-frame depth from the loop.
Triangulation removes it from *image-based* target resolution (rays instead of depth);
Surface Alignment removes it from the *fit* (surface ICP + model-surface placement instead
of depth-resolved landmark targets). For Cz, Surface Alignment is cleaner (Cz rides the
transform, no click-to-world needed at all); triangulation is the fallback if a genuine
image-derived world point is required.

## Also shipped this session (context)

- Fit models `rigid / similarity / affine` (`LandmarkFitModel`, `AffineLandmarkFit`);
  affine false-accept fixed (12 DOF fits 4 pts exactly → require ≥5 to accept).
- Per-landmark plausibility table (leave-one-out geometry error + ⚠ outlier), snap-to-LiDAR
  (`ReceiverMeshSnap`), symmetric-RMS acceptance (default on for ICP), archived fiducials
  default on.
- Persisted into saved diagnostics + debug log: per-landmark geometry error, snap Δ,
  triangulation RMS, edge-ratio spread, fit model, click-resolution mode.

## Deferred (keep in mind, not now)

- Nonlinear / TPS warp — with Cz being a single bad point the answer was *fewer, weighted*
  points, not more DOF. Revisit only for the electrode stage with many correspondences.
- Retained-set acceptance + Cz-as-orientation-only weighting — a cheaper interim fix that
  may unblock the current bundle without the full Surface Alignment build (accept on the
  2.9 mm cardinal fit; use Cz only to pick the mirror sign).

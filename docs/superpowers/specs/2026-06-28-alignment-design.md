# Magic Alignment, Rebuilt — Design Spec

**Date:** 2026-06-28
**Mini-project:** #4 of the expexp revival program (pulled forward ahead of color & UI)
**Status:** Approved for planning

## Program context

Mini-project #1 (orientation, done right) + landscape support are complete (PR #2). During
testing, the "Magic" alignment proved untrustworthy, so alignment hardening was pulled forward
ahead of color/blend and UI. Remaining order after this: color & blend looks, intuitive UI,
ship to App Store.

## Creative goal

Magic alignment serves two *opposite* "freeze anchors," both expressed as "align on X, let
everything else ghost":

- **Cityscape (back camera):** freeze the **static background structure** (buildings) by
  cancelling handheld jitter, so the structure stays crisp while traffic/people smear into a
  fluid moving cloud. **This is the primary use case.**
- **Selfie swirl (front camera):** freeze the **user's face** while the world swirls around it
  (a "lensbaby"/frozen-subject look) as they spin or walk — the face stays pinned regardless of
  how it changes angle/size.

## Problem (current state)

- **Preview and save use two different alignment code paths**, so what the user lines up against
  the live ghost is not what gets saved.
- The **save-time path is buggy/unstable**: homography (`VNHomographicImageRegistrationRequest`)
  produces wild half-frame slides on handheld/reflective scenes, and the face pre-align computes
  its transform on a downscaled image but applies it to the original (different) image, sliding
  front-camera layers sideways.
- **Dead code:** `OCVAligner.{h,mm}` is an unused OpenCV placeholder.

## Goals

- **WYSIWYG:** the live ghost preview is a faithful (screen-cropped) preview of exactly what
  saves. Achieved by computing each frame's alignment **once** and reusing it for both.
- **Trustworthy:** never slide a layer wildly. A bad/implausible alignment falls back to "no
  shift" (leave the frame as shot).
- **Two anchors, chosen by camera:** back camera → scene (translational); front camera → face
  (similarity).
- **Magic toggle preserved:** ON applies the chosen anchor's alignment; OFF stacks frames exactly
  as shot (identity transforms). Both modes are WYSIWYG.
- **Remove the dead and unstable code** (OpenCV placeholder, homography path, the buggy
  duplicate preview/face paths).

## Non-goals

- **Digital subject-isolation / segmentation cut-outs** (e.g. `VNGeneratePersonSegmentation`,
  subject lifting). Intentionally avoided: the desired aesthetic is a **film double-exposure with
  good jitter control**, not a clean digital cut-out. Real frame stacking + lighten blend *is* the
  film look; we only want the stacking to be steady.
- Affine/homography correction of camera *tilt* in scene mode. Translational only; tilt remains
  as natural ghosting. (Affine scene-mode is the one plausible later add-on.)
- A manual scene/face mode picker. Anchor is chosen by camera; a manual override can be added in
  the UI mini-project if wanted.
- Optical-flow / local-warp refinement (works against the ghost aesthetic; not wanted).
- A *live* viewfinder lock meter (continuous registration of the video feed). Deferred to the UI
  mini-project; this mini-project only exposes the per-capture signal it needs.

## Design

### Architecture: one alignment, one compositor, two canvas sizes

Two small, focused pieces replace the three tangled ones:

1. **`AlignmentService`** — given a moving frame, the reference (first) frame, and an `Anchor`,
   returns a **resolution-independent** `CGAffineTransform` mapping moving → reference, or `nil`
   when the result is untrustworthy.
   - `enum Anchor { case scene, face }`
   - **Scene:** `VNTranslationalImageRegistrationRequest` on a downscaled pair → a pure
     translation. The dominant rigid content (buildings) drives the registration; moving
     traffic/people are the minority and average out.
   - **Face:** detect the largest face in both frames (`VNDetectFaceLandmarksRequest`), compute a
     **similarity** transform (translate + rotate + uniform scale) from the eye anchors that maps
     the moving face onto the reference face. Computed and applied consistently at the same
     resolution (the original bug was a resolution/image mismatch).
   - Transforms are computed at a canonical downscale and stored with a normalization so they can
     be re-applied at any target resolution by scaling only the translation by the
     long-side ratio (the linear rotation/scale part is scale-invariant under uniform scaling).

2. **`ExposureCompositor`** — `composite(frames:transforms:canvasSize:exposureAlpha:) -> UIImage`.
   Lighten-blends the frames, each drawn through its transform scaled to `canvasSize`. Called by:
   - the **live preview** with the on-screen preview size, and
   - **save** with the full photo resolution.
   Same frames + same transforms ⇒ preview is a faithful crop of the saved result. (`UIImage.draw`
   is used for correct, upright drawing — consistent with the orientation work.)

### Anchor selection
Chosen automatically from the active camera: **back → `.scene`, front → `.face`.** The active
camera position is already known to `CaptureService`.

### Magic toggle
- **ON:** transforms come from `AlignmentService` with the camera's anchor.
- **OFF:** all transforms are identity (frames stacked exactly as shot).
Toggling recomputes the stored transforms and refreshes the live ghost immediately, so the
toggle's effect is always visible before saving.

### Safety guards
- **Scene:** if Vision registration fails, or the translation exceeds ~30% of the frame in either
  axis (a mis-lock, not real jitter), use identity for that frame.
- **Face:** if no face is detected in either the moving or reference frame, use identity for that
  frame (leave it as shot) rather than guessing. If the computed similarity scale is wildly out of
  range (e.g. <0.3× or >3×), also fall back to identity.

### Robustness: locking onto static structure, not moving objects

The main scene-mode failure to defend against is locking onto moving traffic instead of the static
buildings. Defenses (no segmentation needed):
- **Dominant-majority physics:** Vision's translational registration is driven by the large,
  edge-rich, consistent content (buildings). Moving cars are smaller, motion-blurred, and
  inconsistent frame-to-frame — weak signal that does not dominate.
- **Jitter-scale expectation + guard:** handheld jitter between quick successive shots is small,
  so a correct lock is a *small* shift. A mis-lock onto a moving object would demand a large shift,
  which the ~30% guard rejects (frame left as shot). The guard threshold is tunable on-device.

### Alignment feedback (confidence + minimal indicator)

`AlignmentService` returns, alongside the transform, whether the frame **locked** or **fell back**
to identity (registration failed or guard tripped) — a signal it must compute anyway. `CameraModel`
publishes the last capture's lock status. A **minimal post-capture indicator** surfaces it: when a
just-captured frame could not be locked, give brief feedback (e.g. the Magic wand flashes / a short
"couldn't lock — hold steadier" cue). This is cheap and doubles as live confirmation the guard
works. The richer *live* viewfinder lock meter is deferred to the UI mini-project (see Non-goals).

### Data flow
- `CameraModel` keeps a `transforms: [CGAffineTransform]` array parallel to the captured frames;
  index 0 (the reference) is always identity.
- On capture: compute the new frame's transform (anchor from current camera; identity if Magic
  OFF) relative to frame 0 and append it.
- On Magic toggle or camera relevant change: recompute all transforms and refresh the preview.
- Live preview overlay: `ExposureCompositor` at preview size → set as the ghost overlay image;
  `PreviewView` just displays it at the current opacity (its own duplicate compositor is removed).
- Save: `ExposureCompositor` at full resolution → saved image.

## Components touched

- Create `App/Alignment/AlignmentService.swift` — anchor-based transform computation + guards.
- Create `App/Alignment/ExposureCompositor.swift` — the single lighten-blend compositor.
- `App/CameraModel.swift` — store/compute `transforms`; route preview + save through the
  compositor; publish the last capture's lock status; remove `translationalAlignPreview`,
  `scaleImage`, and the inline blend.
- `App/ContentView.swift` — minimal post-capture "couldn't lock" indicator driven by the
  published lock status.
- `App/CameraPreview.swift` (`PreviewView`) — drop `composeLightenComposite`/`aspectFillRect`;
  display the composite handed to it; keep the opacity fast-path.
- `App/Alignment/AlignmentEngine.swift` + `App/Alignment/VisionAlignment.swift` — collapse into
  `AlignmentService`; remove the homography path and the old face-prealign. Delete whichever files
  become empty.
- Delete `App/Alignment/OCVAligner.h` and `App/Alignment/OCVAligner.mm` (dead OpenCV placeholder),
  and remove them from the Xcode project.

## Phased implementation

- **Phase A — Scene/translational, unified (primary):** build `AlignmentService` (scene only) +
  `ExposureCompositor`; route preview and save through them; remove dead/unstable code. On-device
  test: cityscape jitter removal, WYSIWYG, Magic off = exact stack, the previously-broken
  reflective/tilt cases now degrade gracefully (no wild slide). **Ship/test before Phase B.**
- **Phase B — Face/similarity (selfie swirl):** add the `.face` anchor + front-camera selection.
  On-device test: front-camera spin/walk keeps the face pinned while the background swirls.

## Testing (on device — camera does not work in the Simulator)

Each phase verified on a physical iPhone; Simulator build must compile first.

Phase A:
1. **Magic OFF, both cameras:** hand-composed stack saves exactly as framed (preview = save).
2. **Magic ON, static cityscape/handheld:** background crisp, jitter removed; preview = save.
3. **Magic ON, reflective/large-move scene:** no wild slide — guard leaves frames as shot, and the
   "couldn't lock" indicator fires.
4. Portrait and landscape stacks both behave.

Phase B:
5. **Front camera, Magic ON, spin/walk:** face stays pinned and clear; background swirls; preview
   = save.
6. **Front camera, no clear face:** falls back to as-shot (no wild transform).

## Risks & mitigations

- **Scene registration locks onto moving content** (mostly-traffic frame): mitigated by the 30%
  guard and by translational robustness; worst case it leaves a frame unshifted.
- **Face similarity instability** as the subject turns far from camera: scale/again guards fall
  back to identity; Phase B is independently testable and can be tuned without touching Phase A.
- **Preview/save divergence creeping back:** prevented structurally — there is exactly one
  compositor and one transform per frame, shared by both paths.

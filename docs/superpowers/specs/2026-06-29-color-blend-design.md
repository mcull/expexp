# Color & Blend — "Filmic Average" — Design Spec

**Date:** 2026-06-29
**Mini-project:** #2 of the expexp revival program
**Status:** Approved for planning

## Program context

Mini-projects #1 (orientation + landscape) and #4 (Magic alignment: scene + face) are merged to
`main`. This is #2 (color & blend). Remaining after this: #3 intuitive UI, #5 ship to App Store.

## Problem

The compositor blends exposures with a sequential Core Graphics `lighten` (per-channel `max`)
plus a per-exposure alpha. Two issues:
- **False-color tints.** `max` per channel makes warm+cool overlaps cross into magenta/cyan
  (observed on the floor/sky regions of test shots).
- **Unequal, order-dependent ghosts.** Sequential stacking buries earlier frames, so in an
  N-exposure stack the first ghost ends up fainter than the last — the user wants every exposure
  to count equally.

## Goal

A **"filmic average"** blend that is the daylight default and the only hardcoded look:
- **Equal-weight, order-independent.** Each of N exposures contributes exactly 1/N, so the static
  subject (building, face) stays well-exposed and crisp while each moving-object ghost is equal in
  strength regardless of capture order. (More exposures ⇒ each individual ghost is naturally
  fainter — desired, like a longer "shutter"/stronger ND filter.)
- **No false-color tints.** Averaging in linear light does not cross channels the way `max` does.
- **Filmic look.** A gentle film tone curve ("Filmic — gentle", chosen from on-device-style
  renders of the user's own photos) laid on the linear average.
- **WYSIWYG preserved.** The same compositor drives the live preview and the save, so the look the
  user sees is the look that saves.

## Non-goals

- **Night additive "light-trails" look.** A future, separate look (accumulating brightness on dark
  scenes). Explicitly out of scope here; the architecture leaves room for it.
- **The visible look-picker UI.** The three looks exist in the engine as data, but the on-screen
  control to switch them is part of mini-project #3 (UI). Filmic ships hardcoded as the default.
- Any change to alignment, orientation, capture, or save plumbing beyond the blend itself.

## Design

### Filmic-average blend (replaces sequential lighten)

`ExposureCompositor` is rewritten to:
1. Place each frame in the canvas using its existing `FrameAlignment` (translate/rotate/scale +
   aspect-fill), exactly as today.
2. **Average in linear light:** convert to a linear working space, sum each frame scaled by
   `1/N`, i.e. the per-pixel mean of all N exposures in linear light.
3. **Tone curve:** apply the selected `BlendLook`'s film curve (and, for `.moody`, slight
   warmth/saturation), then convert back to sRGB for output.

Implementation uses **Core Image** (GPU-accelerated; runs for both the preview size and the full
save resolution). The pipeline per frame: `CIImage` → affine transform for its alignment +
aspect-fill placement → scale color by `1/N` → composite with `CIAdditionCompositing` onto the
accumulator, with the `CIContext` using a **linear working color space** so addition is
linear-light. After accumulation, apply the look's tone curve (a Core Image tone-curve / color
controls pass, or an equivalent small filter) and render to sRGB.

Rationale for Core Image over the current Core Graphics path: CG has no averaging or linear-light
blend; CI gives linear-light math, GPU performance for the live preview, and a clean tone-curve
stage. The compositor keeps the same public entry point so `CameraModel` (preview + save) is
largely unchanged.

### Looks as data

```
enum BlendLook { case neutral, filmic, moody }   // default: .filmic
```
Each case defines its tone curve (and warmth/saturation for `.moody`). Values are tuned to match
the approved renders: `.neutral` = linear average only; `.filmic` = average + a gentle S-curve;
`.moody` = stronger curve + slight warm tint and saturation. `CameraModel` holds the current look
(hardcoded `.filmic` for now) and passes it to the compositor. Adding the picker in #3 is then a
small UI addition with no engine changes.

### Cleanup

- Remove the per-exposure `ghostExposureAlpha` (0.8) and its plumbing — equal `1/N` weighting
  replaces it. The compositor signature drops `exposureAlpha` and gains the `BlendLook`.
- Keep the live-ghost **opacity slider** (`ghostOpacity`, preview ghost vs. live camera) — that is
  a preview affordance, unrelated to the blend math.

## Components touched

- `App/Alignment/ExposureCompositor.swift` — rewrite to the Core Image linear-average + tone-curve
  pipeline; signature takes `BlendLook` instead of `exposureAlpha`.
- Create `App/Alignment/BlendLook.swift` — the `BlendLook` enum + its tone-curve parameters.
- `App/CameraModel.swift` — hold the current `BlendLook` (default `.filmic`); remove
  `ghostExposureAlpha`; update the two compositor call sites (preview overlay, save).

## Testing (on device — camera does not run in the Simulator)

Simulator build must compile first. On a physical iPhone:
1. **Equal, order-independent ghosts:** shoot a static scene with one moving object passing through
   (the building+car case), 3–4 exposures, Magic on. → static subject crisp and well-exposed; each
   moving ghost equal in strength; no "first fainter than last."
2. **No tints:** a warm+cool scene (sunlit wood + sky) → overlaps are clean, no magenta/cyan.
3. **Filmic look:** matches the approved "Filmic — gentle" render — natural with gentle film depth.
4. **Exposure scaling:** 2 exposures vs 4 → ghosts get fainter but stay equal; static subject
   stays well-exposed in both.
5. **WYSIWYG:** the live ghost preview matches the saved result.
6. **No regressions:** orientation (portrait/landscape, both cameras), alignment (scene + face),
   and the "couldn't lock" indicator still behave.

## Risks & mitigations

- **Core Image color-space correctness** (getting true linear-light averaging): verify visually on
  device against the approved render; the tone-curve values are tunable on device.
- **Preview performance** with the CI pipeline: CI is GPU-accelerated; the preview composites only
  on capture/toggle (not every video frame), so cost is acceptable. If a frame is slow, the
  preview can composite at a reduced size (it already renders at screen size).
- **Look drift from the approved renders:** the `.filmic` curve is seeded from the same math used
  in the brainstorm renders, then confirmed on device.

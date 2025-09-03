# Alignment Progress Log

This running log tracks the alignment module work: what’s done and what’s next.

## 2025-09-03
- Added design document "AlignmentDesign.md" outlining the full pipeline (Vision pre-align, OpenCV homography/affine, optional optical flow), integration points, heuristics, and phased plan.
- Scaffolded code:
  - Swift API stub: `App/Alignment/AlignmentEngine.swift` with models, options, and no-op methods.
  - ObjC++ placeholders: `App/Alignment/OCVAligner.h` and `.mm` (no OpenCV calls yet).
- Next steps:
  1) Add OpenCV to the project (SPM/CocoaPods/manual), create bridging, and wire `OCVAligner` into the target.
  2) Implement ORB + BFMatcher + RANSAC homography and affine fallback at downscaled resolution.
  3) Expose metrics; integrate preview alignment (fast path) behind a feature flag.
  4) Implement Vision pre-align and optional local refinement as follow-ups.

### Update: Vision Alignment Wiring
- Implemented Vision-based alignment in `App/Alignment/VisionAlignment.swift`:
  - Uses `VNTranslationalImageRegistrationRequest` first; falls back to `VNHomographicImageRegistrationRequest`.
  - Applies affine via Core Graphics; applies homography via `CIPerspectiveTransform` by warping corner points.
  - Downscales to ~1–2MP for speed; scales transforms back to full resolution.
- Integrated into `AlignmentEngine` (options.useAppleVision default true):
  - `align(...)` now returns Vision-aligned output when available.
  - `previewAlignForOverlay(...)` uses Vision as a best-effort (fallback to aspect-fill).
- Next: Optionally integrate with live ghost overlay and save path behind a feature flag; add metrics logging.

### Update: Save-Time Alignment Integration
- Added a feature flag `CameraModel.isAlignmentEnabled` (default true).
- In `savePhoto()`, when there are multiple images, each subsequent image is aligned to the first (reference) via `AlignmentEngine` using Vision (translation → homography) before blending.
- Added simple console logs with model type and runtime per aligned image.

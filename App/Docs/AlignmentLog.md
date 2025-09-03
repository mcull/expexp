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


# Image Alignment & Stabilization Design (Vision + OpenCV)

## Goals
- Snap handheld captures so key structures align across exposures, creating a magical, stabilized double-exposure.
- Preserve natural parallax for moving objects (cars, people), while aligning dominant scene geometry (buildings, faces).
- Keep the live experience responsive (preview alignment feels instant, save-time alignment is robust).

## User Experience
- Live ghost preview: when a second shot is captured, the prior capture “snaps” into place so static structure aligns.
- Save-time blend: use the best alignment at full resolution before compositing.
- Defaults on; no extra UI. Optional advanced toggle for “Extra snap (beta)” to enable local refinement.

## Pipeline Overview
1) Optional semantic pre-align (Vision)
   - Detect largest face in both images. If both exist:
     - Compute similarity transform (scale + rotation + translation) using eye centers and inter-eye vector.
     - Pre-warp the moving image with this transform.
   - If no faces, skip.

2) Global geometric alignment (OpenCV)
   - Detect ORB features (1–2k keypoints) in reference and moving (downscaled to ~1–2MP for speed).
   - Match with BFMatcher (Hamming). Ratio test (Lowe 0.75–0.8), and cross-check optional.
   - Estimate homography via RANSAC: reprojThreshold ≈ 3 px (scaled), confidence ≈ 0.995, maxIters ≈ 2000.
   - If homography fails (few inliers / singular), fallback to estimateAffinePartial2D (rotation+scale+translation).
   - Track inlier count and inlier ratio for quality diagnostics.

3) Warp to reference
   - If H found: warpPerspective(moving, H) -> aligned.
   - Else if affine A: warpAffine(moving, A) -> aligned.
   - Re-apply transform at full resolution using scale factor from downscaled run.

4) Optional local refinement (optical flow)
   - Dense Farnebäck optical flow on a further downscaled pair; build small displacement field.
   - Cap displacement magnitude to 2–3 px; upsample and apply to aligned image (remap) for subtle edge refinement.
   - Time-bound to keep UI snappy (e.g., 20–40 ms budget); skip if over budget.

5) Blend
   - Return aligned `UIImage`; compose with Core Image blend (lighten, screen, etc.) as we already do.

## Transform Selection Heuristics
- Try homography first (handles perspective/planar scenes). If inliers < threshold (e.g., < 30 or inlier ratio < 0.2), fallback to affine.
- If both images contain faces, run Vision pre-align, then features; still use homography if strong enough.
- Local refinement only when user enables “Extra snap” and only if global alignment succeeds.

## Downscale & Performance
- Build a downscaled working copy at ~1–2MP (example: longest side ≈ 1400–1600 px). Record `scaleFactor` vs. full-res.
- Run detection/matching/alignment on downscaled; apply resulting transform to full-res image for the final export.
- Use persistent OpenCV objects where possible; reuse buffers to reduce allocations.
- Place CPU-heavy steps on a background queue; do not block main thread.

## Integration Points
- Live Preview (ghost):
  - Trigger alignment computation when the second (or subsequent) image is captured.
  - Compute transform in background using downscaled frames and immediately re-warp the ghost overlay at preview size.
  - Smooth the transform over a few preview frames (EMA) if we allow interactive opacity scrubbing.

- Save-Time:
  - Repeat alignment with the same seed but at full-res (or reuse previously computed H/A and scale it up precisely).
  - Optionally enable local refinement flow before blending.

## Public API (Swift)
- `AlignmentEngine.align(moving: UIImage, reference: UIImage, options: AlignmentOptions) -> AlignmentResult`
  - Options: `preferHomography: Bool`, `enableVisionPrealign: Bool`, `enableLocalRefine: Bool`, `downscaleTargetMP: Double`.
  - Result:
    - `alignedImage: UIImage` (same size as reference)
    - `transformModel: TransformModel` (homography or affine + quality metrics)
    - `metrics: AlignmentMetrics` (inliers, inlier ratio, runtime)

- `AlignmentEngine.previewAlignForOverlay(moving: UIImage, referencePreviewSize: CGSize) -> UIImage` (fast path)
  - Returns pre-warped moving image at preview size for ghost overlay.

## Obj‑C++ Wrapper (OpenCV)
- Objective-C++ class: `OCVAligner`
  - `.alignHomography(cv::Mat moving, cv::Mat reference, params) -> cv::Mat H / bool success`
  - `.alignAffinePartial(cv::Mat moving, cv::Mat reference, params) -> cv::Mat A / bool success`
  - `.warpWithHomography(cv::Mat img, cv::Mat H, cv::Size size) -> cv::Mat`
  - `.warpWithAffine(cv::Mat img, cv::Mat A, cv::Size size) -> cv::Mat`
  - `.refineWithOpticalFlow(cv::Mat aligned, cv::Mat reference, capPx) -> cv::Mat`

- Bridging header exposes a thin Swift wrapper `AlignmentEngine`.

## Vision Pre‑Align (Similarity)
- Detect faces with Vision: `VNDetectFaceLandmarksRequest`.
- Find largest face in each image; compute eye centers and angle of inter-eye vector.
- Compute similarity transform:
  - Translate to face center, rotate to match eye-line angles, scale to match inter-eye distances.
- Pre-warp moving image (Core Image or vImage) quickly; proceed to OpenCV features on the pre-warped pair.

## Local Refinement (Optional)
- Farnebäck params: pyramidScale ~0.5, levels 3–4, winsize 9–15, iterations 2–3, polyN 5, polySigma 1.2.
- Generate displacement map; clamp magnitude to <= 2–3 px; remap.
- Skip if runtime exceeds budget; fallback to global only.

## Quality Metrics & Fallbacks
- Homography considered valid if:
  - Inliers ≥ 30 (after RANSAC) and inlier ratio ≥ 0.2–0.3.
  - Determinant not near 0; no extreme skew.
- If invalid → try affine; if still invalid → return unaligned moving (no worse than today).

## Threading & Budgets
- Live preview: target < 60–100 ms for alignment on downscaled images.
- Save-time: tolerate 200–400 ms at full-res; do on background queue.
- Use cancellation tokens so interactive actions can drop stale computations.

## Storage & Memory
- Reuse Mats, CIContexts; avoid retaining full-size intermediates longer than needed.
- For preview, render directly at the preview size to minimize memory.

## Error Handling
- If OpenCV unavailable (build flag), disable alignment gracefully and use current behavior.
- Log metrics for debugging (inliers, chosen model, runtime).

## Phased Implementation Plan
1) Scaffolding
   - Add OpenCV dependency and bridging (Objective-C++ wrapper, module map, headers).
   - Add `AlignmentEngine` Swift facade with no-op implementations.

2) Global Alignment
   - Implement ORB + BFMatcher + RANSAC homography with downscale.
   - Add affine fallback; expose metrics.
   - Integrate in preview overlay path and save-time path (behind a feature flag).

3) Vision Pre‑Align (Similarity)
   - Face detection + landmark extraction; compute similarity pre-warp.
   - Feed pre-warped images into Step 2; measure improvement.

4) Optional Local Refinement
   - Farnebäck flow with magnitude clamp and timeout; integrate as a refinement pass.

5) Smoothing & Heuristics
   - EMA smoothing for preview transforms; auto-select model (H vs affine) based on inliers.

6) Polish & Settings
   - Feature flags in a hidden settings panel; diagnostics overlay (inlier count, model type).

## Risks & Mitigations
- Performance on older devices → aggressive downscale, early exits, timeout for flow stage.
- Build complexity (OpenCV) → isolate in a module; compile-guard for simulator/device.
- Robustness across scenes → rely on homography first, sensible thresholds, and fallbacks.

---
Last updated: Initial draft

# Magic Alignment, Rebuilt — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Magic alignment trustworthy by computing each frame's alignment once and reusing it for both the live preview and the save (WYSIWYG), with a safety guard that refuses implausible shifts; support two freeze anchors (scene/translational for the back camera, face/similarity for the front).

**Architecture:** One `AlignmentService` returns a resolution-independent `FrameAlignment` (normalized translation + optional rotation/scale + a `locked` flag) for a moving frame relative to the first frame. One `ExposureCompositor` lighten-blends frames through their alignments into any canvas size — called by the live preview (screen size) and by save (full resolution), so the preview is a faithful crop of the saved result. The old split preview/save paths, the unstable homography, the buggy face pre-align, and the dead OpenCV placeholder are removed.

**Tech Stack:** Swift, SwiftUI, AVFoundation, Apple Vision (`VNTranslationalImageRegistrationRequest`, `VNDetectFaceLandmarksRequest`), UIKit drawing.

**Spec:** `docs/superpowers/specs/2026-06-28-alignment-design.md`

**Why no automated tests:** Same as mini-project #1 — this is a camera app with no XCTest target, and end-to-end behavior depends on real capture. Verification is a Simulator **compile** (`xcodebuild … build`) per task plus **on-device acceptance** per phase. The alignment math deliberately mirrors the previously-working preview logic (offset `(tx, -ty)` in top-left coords) to avoid re-fighting coordinate spaces; the on-screen "couldn't lock" indicator gives live confirmation the guard works. Do not write placeholder/fake unit tests.

**Shared build command** (compile check after each task):
```bash
xcodebuild -project Expexp.xcodeproj -scheme Expexp \
  -destination 'id=C738E874-4763-4772-845B-F8E3088CBCCE' build 2>&1 \
  | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```
Expected at the end of each task: `** BUILD SUCCEEDED **` and no `error:` lines. (Destination is the iPhone 16 Pro Simulator by ID — the by-name destination is ambiguous across OS versions.)

**Branch:** Work on the existing `mini-4-alignment` branch.

---

## File structure

- Create `App/Alignment/AlignmentService.swift` — `FrameAlignment`, `AlignmentAnchor`, scene + face alignment, downscale helper, guards.
- Create `App/Alignment/ExposureCompositor.swift` — the single lighten-blend compositor (handles translation + rotation/scale about a normalized anchor).
- Modify `App/CameraModel.swift` — keep a `transforms: [FrameAlignment]`; compute on capture; recompute on Magic toggle; composite for preview and save; publish a transient "couldn't lock" flag. Remove `translationalAlignPreview`, `scaleImage`, `blendImages`, and `AlignmentEngine` usage.
- Modify `App/CameraPreview.swift` (`PreviewView`) — replace the internal compositor with a dumb `setOverlayImage(_:opacity:)`; keep the opacity fast-path.
- Modify `App/ContentView.swift` — minimal post-capture "couldn't lock" indicator.
- Delete `App/Alignment/AlignmentEngine.swift`, `App/Alignment/VisionAlignment.swift`, `App/Alignment/OCVAligner.h`, `App/Alignment/OCVAligner.mm` and remove their references from `Expexp.xcodeproj/project.pbxproj`.

---

# PHASE A — Scene/translational, unified (primary; ship & test before Phase B)

## Task A1: Create `AlignmentService` (types + scene alignment + guard)

**Files:**
- Create: `App/Alignment/AlignmentService.swift`

- [ ] **Step 1: Write the file**

```swift
import UIKit
import Vision

/// Which feature the alignment should "freeze."
enum AlignmentAnchor {
    case scene   // freeze the static structure (back camera / cityscape)
    case face    // freeze the user's face (front camera / selfie swirl) — Phase B
}

/// A resolution-independent alignment of one frame relative to the first (reference) frame.
/// Translation is stored as a fraction of the frame's width/height so it maps correctly to any
/// canvas size. Rotation (radians) and uniform `scale` default to identity (scene/translational);
/// `anchor` is the normalized (0...1, top-left) point that rotation/scale pivot about.
struct FrameAlignment {
    var dx: CGFloat
    var dy: CGFloat
    var rotation: CGFloat
    var scale: CGFloat
    var anchor: CGPoint
    var locked: Bool   // true if alignment succeeded; false if it fell back to no-op

    /// The reference frame (frame 0): no movement, considered locked.
    static let identity = FrameAlignment(dx: 0, dy: 0, rotation: 0, scale: 1,
                                         anchor: CGPoint(x: 0.5, y: 0.5), locked: true)
    /// A frame whose alignment could not be trusted: draw it unshifted, flag it unlocked.
    static let unlocked = FrameAlignment(dx: 0, dy: 0, rotation: 0, scale: 1,
                                         anchor: CGPoint(x: 0.5, y: 0.5), locked: false)
}

enum AlignmentService {
    /// Max plausible handheld shift as a fraction of the frame. Larger ⇒ assume mis-lock.
    static let maxShiftFraction: CGFloat = 0.30
    /// Long-side pixel size used for registration (downscaled for speed; fractions are scale-free).
    static let registrationMaxDimension: CGFloat = 1200

    static func alignment(moving: UIImage, reference: UIImage, anchor: AlignmentAnchor) -> FrameAlignment {
        switch anchor {
        case .scene: return sceneAlignment(moving: moving, reference: reference)
        case .face:  return .unlocked   // implemented in Phase B (Task B1)
        }
    }

    // MARK: - Scene (translational)

    private static func sceneAlignment(moving: UIImage, reference: UIImage) -> FrameAlignment {
        guard let refCG = downscaled(reference, maxDimension: registrationMaxDimension),
              let movCG = downscaled(moving, maxDimension: registrationMaxDimension) else {
            return .unlocked
        }
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: movCG)
        let handler = VNImageRequestHandler(cgImage: refCG)
        do { try handler.perform([request]) } catch { return .unlocked }
        guard let obs = request.results?.first as? VNImageTranslationAlignmentObservation else {
            return .unlocked
        }
        // Vision gives a pixel translation; the proven preview convention is (tx, -ty) in
        // top-left coords. Normalize by the registration image's pixel dimensions.
        let w = CGFloat(refCG.width), h = CGFloat(refCG.height)
        guard w > 0, h > 0 else { return .unlocked }
        let dx = obs.alignmentTransform.tx / w
        let dy = -obs.alignmentTransform.ty / h
        if abs(dx) > maxShiftFraction || abs(dy) > maxShiftFraction { return .unlocked }
        return FrameAlignment(dx: dx, dy: dy, rotation: 0, scale: 1,
                              anchor: CGPoint(x: 0.5, y: 0.5), locked: true)
    }

    // MARK: - Helpers

    /// Downscales to `maxDimension` on the long side via UIKit drawing (top-left, no flip), so
    /// reference and moving are reduced identically and the translation convention is preserved.
    static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> CGImage? {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > 0 else { return nil }
        guard longest > maxDimension else { return image.cgImage }
        let s = maxDimension / longest
        let newSize = CGSize(width: size.width * s, height: size.height * s)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let reduced = UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return reduced.cgImage
    }
}
```

- [ ] **Step 2: Compile check** — run the shared build command. Expected: `** BUILD SUCCEEDED **`. (The file is not referenced yet, but it must be added to the target; if the build does not pick it up, see Task A1 Step 3.)

- [ ] **Step 3: Confirm the new file is in the build target**

New `.swift` files under `App/` are compiled only if referenced by the Xcode target. Verify:
```bash
grep -c "AlignmentService.swift" Expexp.xcodeproj/project.pbxproj
```
Expected: a non-zero count. If it prints `0`, the file is not in the target — open `Expexp.xcodeproj` in Xcode, and it will offer to add the new file, or drag `AlignmentService.swift` into the `Alignment` group with "Expexp" target checked. Re-run the build. (This is a user/GUI step; prompt for it if needed.)

- [ ] **Step 4: Commit**

```bash
git add App/Alignment/AlignmentService.swift Expexp.xcodeproj/project.pbxproj
git commit -m "feat: AlignmentService with scene/translational alignment + guard"
```

---

## Task A2: Create `ExposureCompositor`

**Files:**
- Create: `App/Alignment/ExposureCompositor.swift`

- [ ] **Step 1: Write the file**

```swift
import UIKit

/// The single lighten-blend compositor used by BOTH the live preview and the save path, so the
/// preview is a faithful (screen-cropped) preview of the saved result.
enum ExposureCompositor {
    /// Lighten-blends `frames` into `canvasSize`. Each frame is drawn aspect-fill, then transformed
    /// by its `FrameAlignment` (rotation/scale about the normalized anchor, then a normalized shift).
    /// `alignments[i]` corresponds to `frames[i]`; index 0 is the reference (identity).
    static func composite(frames: [UIImage],
                          alignments: [FrameAlignment],
                          canvasSize: CGSize,
                          scale: CGFloat,
                          exposureAlpha: CGFloat) -> UIImage? {
        guard !frames.isEmpty, canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            cg.clear(CGRect(origin: .zero, size: canvasSize))
            for (i, frame) in frames.enumerated() {
                let a = i < alignments.count ? alignments[i] : .identity
                let base = aspectFillRect(imageSize: frame.size, canvasSize: canvasSize)
                let pivot = CGPoint(x: base.minX + a.anchor.x * base.width,
                                    y: base.minY + a.anchor.y * base.height)
                cg.saveGState()
                // Rotate/scale about the pivot, then apply the normalized shift.
                cg.translateBy(x: pivot.x + a.dx * base.width, y: pivot.y + a.dy * base.height)
                cg.rotate(by: a.rotation)
                cg.scaleBy(x: a.scale, y: a.scale)
                cg.translateBy(x: -pivot.x, y: -pivot.y)
                frame.draw(in: base, blendMode: .lighten, alpha: exposureAlpha)
                cg.restoreGState()
            }
        }
    }

    private static func aspectFillRect(imageSize: CGSize, canvasSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: canvasSize)
        }
        let s = max(canvasSize.width / imageSize.width, canvasSize.height / imageSize.height)
        let w = imageSize.width * s, h = imageSize.height * s
        return CGRect(x: (canvasSize.width - w) / 2, y: (canvasSize.height - h) / 2, width: w, height: h)
    }
}
```

- [ ] **Step 2: Compile check** — run the shared build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Confirm the new file is in the build target**

```bash
grep -c "ExposureCompositor.swift" Expexp.xcodeproj/project.pbxproj
```
Expected: non-zero. If `0`, add it to the target in Xcode (same as Task A1 Step 3) and rebuild.

- [ ] **Step 4: Commit**

```bash
git add App/Alignment/ExposureCompositor.swift Expexp.xcodeproj/project.pbxproj
git commit -m "feat: ExposureCompositor — single lighten-blend path for preview and save"
```

---

## Task A3: Wire alignment into CameraModel (compute once, composite both paths)

**Files:**
- Modify: `App/CameraModel.swift`

- [ ] **Step 1: Add alignment state and the transient lock-warning flag**

In `CameraModel`, just after the `lockedCaptureAngle` property block, add:
```swift
    /// Alignment of each captured frame relative to frame 0 (parallel to capturedRawImages).
    private var transforms: [FrameAlignment] = []
    /// Anchor for alignment. Phase A always uses .scene; Phase B selects by camera.
    private var currentAnchor: AlignmentAnchor { .scene }
    /// Briefly true when a just-captured frame could not be aligned (Magic on).
    @Published var showAlignmentWarning: Bool = false
```

- [ ] **Step 2: Compute the new frame's alignment on capture**

In `capturePhoto()`, replace this block:
```swift
                // Store raw image for final processing
                capturedRawImages.append(image)
                capturedPhotos.append(photo)

                // Frames are already upright (rotation handled at capture time).
                ghostPreviewImages.append(image)
                // Update overlay (optionally with Vision alignment) for live preview
                updateGhostPreviewOverlay()
```
with:
```swift
                // Store raw image for final processing
                capturedRawImages.append(image)
                capturedPhotos.append(photo)
                ghostPreviewImages.append(image)

                // Compute this frame's alignment relative to the first (reference) frame.
                if capturedRawImages.count == 1 {
                    transforms = [.identity]
                } else if isAlignmentEnabled, let reference = capturedRawImages.first {
                    let a = AlignmentService.alignment(moving: image, reference: reference, anchor: currentAnchor)
                    transforms.append(a)
                    if !a.locked { flashAlignmentWarning() }
                } else {
                    transforms.append(.identity)
                }

                updateGhostPreviewOverlay()
```

- [ ] **Step 3: Add the warning helper and a transforms recompute (for the Magic toggle)**

In `CameraModel`, add these methods (place them next to `updateGhostPreviewOverlay`):
```swift
    private func flashAlignmentWarning() {
        withAnimation(.easeOut(duration: 0.15)) { showAlignmentWarning = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeIn(duration: 0.25)) { self.showAlignmentWarning = false }
        }
    }

    /// Recomputes all alignments (identity when Magic is off). Used when the toggle changes.
    private func recomputeTransforms() {
        guard let reference = capturedRawImages.first else { transforms = []; return }
        var result: [FrameAlignment] = [.identity]
        for img in capturedRawImages.dropFirst() {
            if isAlignmentEnabled {
                result.append(AlignmentService.alignment(moving: img, reference: reference, anchor: currentAnchor))
            } else {
                result.append(.identity)
            }
        }
        transforms = result
    }
```

- [ ] **Step 4: Recompute + refresh when the Magic toggle changes**

Replace the `isAlignmentEnabled` declaration:
```swift
    @Published var isAlignmentEnabled: Bool = true
```
with:
```swift
    @Published var isAlignmentEnabled: Bool = true {
        didSet {
            recomputeTransforms()
            updateGhostPreviewOverlay()
        }
    }
```

- [ ] **Step 5: Rewrite `updateGhostPreviewOverlay` to use the compositor**

Replace the entire `updateGhostPreviewOverlay()` method and its helpers `scaleImage(_:toAspectFill:)` and `translationalAlignPreview(moving:reference:)` (the whole run from `private func updateGhostPreviewOverlay()` through the end of `translationalAlignPreview`) with:
```swift
    private func updateGhostPreviewOverlay() {
        guard let canvas = previewView?.previewLayer.bounds.size, canvas.width > 0, canvas.height > 0 else {
            previewView?.setOverlayImage(nil, opacity: 0)
            return
        }
        let composite = ExposureCompositor.composite(frames: ghostPreviewImages,
                                                     alignments: transforms,
                                                     canvasSize: canvas,
                                                     scale: UIScreen.main.scale,
                                                     exposureAlpha: CGFloat(ghostExposureAlpha))
        previewView?.setOverlayImage(composite, opacity: CGFloat(1.0 - ghostOpacity))
    }
```

- [ ] **Step 6: Point the exposure-alpha slider at the new overlay path**

Replace the `ghostExposureAlpha` `didSet`:
```swift
    @Published var ghostExposureAlpha: Double = 0.8 {
        didSet {
            // Update preview's exposure alpha and recompose with existing images
            previewView?.setExposureAlpha(CGFloat(ghostExposureAlpha), currentImages: ghostPreviewImages)
        }
    }
```
with:
```swift
    @Published var ghostExposureAlpha: Double = 0.8 {
        didSet {
            updateGhostPreviewOverlay()
        }
    }
```

- [ ] **Step 7: Replace the save path to composite via the shared compositor**

In `savePhoto()`, replace the whole block from `// Frames are captured upright; no rotation needed.` through the line `print("🖼️ DEBUG: Blend complete")` and its enclosing `}` (i.e. the `let finalImage: UIImage` if/else that builds the single or blended image) with:
```swift
                let finalImage: UIImage
                if capturedRawImages.count == 1 {
                    finalImage = capturedRawImages[0]
                    print("🖼️ DEBUG: Single upright image saved as-is")
                } else if let canvas = capturedRawImages.first?.size,
                          let composite = ExposureCompositor.composite(frames: capturedRawImages,
                                                                       alignments: transforms,
                                                                       canvasSize: canvas,
                                                                       scale: 1,
                                                                       exposureAlpha: CGFloat(ghostExposureAlpha)) {
                    finalImage = composite
                    print("🖼️ DEBUG: Composited \(capturedRawImages.count) frames (aligned: \(isAlignmentEnabled))")
                } else {
                    finalImage = capturedRawImages[0]
                    print("🖼️ DEBUG: Composite failed; saved first frame")
                }
```

- [ ] **Step 8: Reset transforms when the stack clears**

In `savePhoto()` where the buffer is cleared, add a `transforms.removeAll()`:
```swift
                capturedRawImages.removeAll()
                capturedPhotos.removeAll()
                ghostPreviewImages.removeAll()
                transforms.removeAll()
                lockedCaptureAngle = nil  // next stack picks a fresh orientation
                previewView?.updateGhostImages([], opacity: 0)
```
And in `clearBuffer()` add the same `transforms.removeAll()`:
```swift
    func clearBuffer() {
        capturedRawImages.removeAll()
        capturedPhotos.removeAll()
        ghostPreviewImages.removeAll()
        transforms.removeAll()
        lockedCaptureAngle = nil  // next stack picks a fresh orientation
        previewView?.updateGhostImages([], opacity: 0)
    }
```
(The `previewView?.updateGhostImages([], opacity: 0)` calls are replaced in Task A4; leave them for now so this task compiles.)

- [ ] **Step 9: Remove the old blend helper**

Delete the entire `blendImages(_:)` method from `CameraModel` (no longer used — the compositor replaces it).

- [ ] **Step 10: Compile check + reference sweep**

Run:
```bash
grep -n "blendImages\|translationalAlignPreview\|scaleImage\|AlignmentEngine\|AlignmentOptions" App/CameraModel.swift
```
Expected: empty (all removed). Then run the shared build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 11: Commit**

```bash
git add App/CameraModel.swift
git commit -m "feat: unify preview+save through AlignmentService/ExposureCompositor; lock warning"
```

---

## Task A4: Simplify `PreviewView` to a dumb overlay display

**Files:**
- Modify: `App/CameraPreview.swift`

- [ ] **Step 1: Replace the overlay API**

In `PreviewView`, replace the three methods `updateGhostImages(_:opacity:)`, `setGhostOpacity(_:)`, and `setExposureAlpha(_:currentImages:)` (the run from `// Update overlay images…` through the end of `setExposureAlpha`) with:
```swift
    /// Display a pre-composited overlay image (built by CameraModel via ExposureCompositor).
    func setOverlayImage(_ image: UIImage?, opacity: CGFloat) {
        ghostCompositeLayer.contents = image?.cgImage
        ghostCompositeLayer.opacity = Float(max(0, min(1, opacity)))
        ghostCompositeLayer.contentsGravity = .resizeAspectFill
        ghostCompositeLayer.frame = ghostContainerLayer.bounds
    }

    /// Fast path: change only the opacity without recompositing.
    func setGhostOpacity(_ opacity: CGFloat) {
        ghostCompositeLayer.opacity = Float(max(0, min(1, opacity)))
    }
```

- [ ] **Step 2: Remove the now-unused compositor internals**

In `PreviewView`, delete:
- the method `composeLightenComposite(from:)` and the method `aspectFillRect(forImageSize:inCanvas:)` (entire methods),
- the stored properties `var ghostExposureAlpha: CGFloat = 0.8`, `private var currentGhostImageCount: Int = 0`, and `private var cachedCompositeImage: CGImage?`.

- [ ] **Step 3: Update the two CameraModel call sites that used the old API**

In `App/CameraModel.swift`, replace both occurrences of:
```swift
                previewView?.updateGhostImages([], opacity: 0)
```
with:
```swift
                previewView?.setOverlayImage(nil, opacity: 0)
```
(There are two: one in `savePhoto()`, one in `clearBuffer()`.)

Also in `App/CameraPreview.swift`, in `CameraPreviewWithModel.makeUIView`, delete the now-invalid line:
```swift
        preview.ghostExposureAlpha = CGFloat(cameraModel.ghostExposureAlpha)
```

- [ ] **Step 4: Compile check**

Run:
```bash
grep -n "updateGhostImages\|composeLightenComposite\|ghostExposureAlpha\|cachedCompositeImage" App/CameraPreview.swift App/CameraModel.swift
```
Expected: empty. Then run the shared build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add App/CameraPreview.swift App/CameraModel.swift
git commit -m "refactor: PreviewView just displays the composited overlay (single compositor)"
```

---

## Task A5: Post-capture "couldn't lock" indicator

**Files:**
- Modify: `App/ContentView.swift`

- [ ] **Step 1: Add the indicator overlay**

In `ContentView`, immediately after the `CameraPreviewWithModel(...) { … }.ignoresSafeArea()` block, add:
```swift
                if cameraModel.showAlignmentWarning {
                    VStack {
                        Spacer().frame(height: 60)
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text("Couldn't lock — hold steadier")
                                .font(.footnote.weight(.semibold))
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.yellow.opacity(0.95)))
                        Spacer()
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
```

- [ ] **Step 2: Compile check** — run the shared build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/ContentView.swift
git commit -m "feat: transient 'couldn't lock' alignment indicator"
```

---

## Task A6: Delete dead alignment code

**Files:**
- Delete: `App/Alignment/AlignmentEngine.swift`, `App/Alignment/VisionAlignment.swift`, `App/Alignment/OCVAligner.h`, `App/Alignment/OCVAligner.mm`
- Modify: `Expexp.xcodeproj/project.pbxproj`

- [ ] **Step 1: Confirm nothing references them**

```bash
grep -rn "AlignmentEngine\|VisionAligner\|VisionAlignmentResult\|OCVAligner\|AlignmentOptions\|AlignmentResult\|AlignmentMetrics\|TransformModel" App --include=*.swift
```
Expected: empty (Tasks A1–A4 removed all uses). If anything prints, fix that reference before deleting.

- [ ] **Step 2: Remove the files from the Xcode project**

These files are referenced in `Expexp.xcodeproj/project.pbxproj`. The reliable way to remove them and their build references is in Xcode: select `AlignmentEngine.swift`, `VisionAlignment.swift`, `OCVAligner.h`, `OCVAligner.mm` in the Project navigator → Delete → "Move to Trash". (This is a user/GUI step — prompt for it.) Alternatively, if comfortable, delete the files on disk and remove every line mentioning their names from `project.pbxproj`:
```bash
rm App/Alignment/AlignmentEngine.swift App/Alignment/VisionAlignment.swift App/Alignment/OCVAligner.h App/Alignment/OCVAligner.mm
```
then open the project in Xcode once so it reconciles, or hand-edit `project.pbxproj` to remove the `PBXBuildFile`/`PBXFileReference`/group/sources lines that mention those four filenames.

- [ ] **Step 3: Compile check**

```bash
grep -c "OCVAligner\|VisionAlignment.swift\|AlignmentEngine.swift" Expexp.xcodeproj/project.pbxproj
```
Expected: `0`. Then run the shared build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore: delete dead OpenCV placeholder + old homography/face-prealign code"
```

---

## Task A7: On-device acceptance — Phase A (manual)

Run on a physical iPhone (camera does not work in the Simulator). Build & run from Xcode (⌘R).

- [ ] **Step 1: Magic OFF is exact (both cameras)** — toggle Magic off, shoot a 2–3 frame hand-composed stack, Save. Expected: saved image stacks exactly the frames as framed; preview matched the save.
- [ ] **Step 2: Magic ON, static handheld scene** — toggle Magic on, brace lightly and shoot 2–3 frames of a static scene (a window/building works). Expected: the static structure is crisp (jitter removed); the live ghost matched the saved result.
- [ ] **Step 3: Guard fires on a hard scene** — Magic on, deliberately move a lot / shoot a reflective or fast-moving scene. Expected: no layer slides wildly across the frame; the yellow "Couldn't lock — hold steadier" indicator appears for frames that fell back.
- [ ] **Step 4: Orientation still good** — confirm portrait and landscape stacks still save upright/correct (no regression from mini-project #1).
- [ ] **Step 5: Toggle is WYSIWYG** — with a stack captured, flip Magic on/off and watch the live ghost change; the saved result matches whatever the ghost shows.

**If a check fails:**
- Ghost looks offset vs. save: both now use `ExposureCompositor`; verify `transforms` indices line up with `ghostPreviewImages` (both append per capture).
- Everything shifts the wrong direction: flip the sign in `sceneAlignment` (`dy = +ty/h` or `dx = -tx/w`) — the proven preview convention is `(tx, -ty)`, but confirm on device.
- Guard never/always fires: tune `AlignmentService.maxShiftFraction`.

---

# PHASE B — Face/similarity (selfie swirl). Build & test after Phase A passes.

## Task B1: Implement face alignment (similarity from eye landmarks)

**Files:**
- Modify: `App/Alignment/AlignmentService.swift`

- [ ] **Step 1: Replace the face case stub with a real implementation**

In `AlignmentService.alignment(moving:reference:anchor:)`, replace:
```swift
        case .face:  return .unlocked   // implemented in Phase B (Task B1)
```
with:
```swift
        case .face:  return faceAlignment(moving: moving, reference: reference)
```

- [ ] **Step 2: Add the face alignment + helpers**

In `AlignmentService`, add (after `sceneAlignment`):
```swift
    // MARK: - Face (similarity: translate + rotate + uniform scale, pinned to the face)

    /// Acceptable face-scale ratio; outside this we assume a bad detection and fall back.
    static let faceScaleRange: ClosedRange<CGFloat> = 0.3...3.0

    private static func faceAlignment(moving: UIImage, reference: UIImage) -> FrameAlignment {
        guard let movCG = moving.cgImage, let refCG = reference.cgImage,
              let mEyes = eyeCenters(in: movCG), let rEyes = eyeCenters(in: refCG) else {
            return .unlocked
        }
        // Pixel-space geometry (true angle/scale); image dims for normalization.
        let mw = CGFloat(movCG.width), mh = CGFloat(movCG.height)
        let rw = CGFloat(refCG.width), rh = CGFloat(refCG.height)
        let mL = CGPoint(x: mEyes.left.x * mw, y: mEyes.left.y * mh)
        let mR = CGPoint(x: mEyes.right.x * mw, y: mEyes.right.y * mh)
        let rL = CGPoint(x: rEyes.left.x * rw, y: rEyes.left.y * rh)
        let rR = CGPoint(x: rEyes.right.x * rw, y: rEyes.right.y * rh)

        let mMidPx = CGPoint(x: (mL.x + mR.x) / 2, y: (mL.y + mR.y) / 2)
        let rMidPx = CGPoint(x: (rL.x + rR.x) / 2, y: (rL.y + rR.y) / 2)
        let mVec = CGVector(dx: mR.x - mL.x, dy: mR.y - mL.y)
        let rVec = CGVector(dx: rR.x - rL.x, dy: rR.y - rL.y)
        let mLen = max(hypot(mVec.dx, mVec.dy), 1e-6)
        let rLen = max(hypot(rVec.dx, rVec.dy), 1e-6)
        let scale = rLen / mLen
        guard faceScaleRange.contains(scale) else { return .unlocked }
        let rotation = atan2(rVec.dy, rVec.dx) - atan2(mVec.dy, mVec.dx)

        // Anchor = moving eye midpoint (normalized to moving image). Shift maps moving mid → ref mid,
        // normalized to the moving image dims (the frame the compositor draws).
        let anchor = CGPoint(x: mMidPx.x / mw, y: mMidPx.y / mh)
        let dx = (rMidPx.x / rw) - (mMidPx.x / mw)
        let dy = (rMidPx.y / rh) - (mMidPx.y / mh)
        return FrameAlignment(dx: dx, dy: dy, rotation: rotation, scale: scale, anchor: anchor, locked: true)
    }

    private struct EyeCenters { let left: CGPoint; let right: CGPoint }  // normalized, top-left origin

    /// Largest face's eye centers, normalized (0...1) in top-left coordinates.
    private static func eyeCenters(in cgImage: CGImage) -> EyeCenters? {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage)
        do { try handler.perform([request]) } catch { return nil }
        guard let faces = request.results, !faces.isEmpty else { return nil }
        guard let face = faces.max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }) else { return nil }
        guard let lm = face.landmarks,
              let left = lm.leftEye?.normalizedPoints, !left.isEmpty,
              let right = lm.rightEye?.normalizedPoints, !right.isEmpty else { return nil }
        let bbox = face.boundingBox
        func center(_ pts: [CGPoint]) -> CGPoint {
            let sum = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            let n = CGFloat(pts.count)
            // Landmark points are normalized within the bbox, bottom-left origin.
            let xBL = bbox.origin.x + (sum.x / n) * bbox.size.width
            let yBL = bbox.origin.y + (sum.y / n) * bbox.size.height
            return CGPoint(x: xBL, y: 1 - yBL)  // → top-left origin
        }
        return EyeCenters(left: center(left), right: center(right))
    }
```

- [ ] **Step 3: Compile check** — run the shared build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add App/Alignment/AlignmentService.swift
git commit -m "feat: face-anchored similarity alignment (selfie swirl)"
```

---

## Task B2: Select the anchor by camera

**Files:**
- Modify: `App/CameraModel.swift`

- [ ] **Step 1: Track the active camera position**

In `CameraModel`, add a stored property near `transforms`:
```swift
    private var captureCameraPosition: AVCaptureDevice.Position = .back
```

- [ ] **Step 2: Keep it current**

In `initialize()`, right after `await setUpRotationCoordinator()`, add:
```swift
                captureCameraPosition = await captureService.currentCameraPosition
```
In `switchCamera()`, right after `await setUpRotationCoordinator()`, add:
```swift
                captureCameraPosition = await captureService.currentCameraPosition
                recomputeTransforms()
                updateGhostPreviewOverlay()
```

- [ ] **Step 3: Choose the anchor from the camera**

Replace:
```swift
    private var currentAnchor: AlignmentAnchor { .scene }
```
with:
```swift
    private var currentAnchor: AlignmentAnchor {
        captureCameraPosition == .front ? .face : .scene
    }
```

- [ ] **Step 4: Compile check** — run the shared build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add App/CameraModel.swift
git commit -m "feat: anchor by camera — front=face, back=scene"
```

---

## Task B3: On-device acceptance — Phase B (manual)

Run on a physical iPhone.

- [ ] **Step 1: Front camera, Magic ON, spin/walk** — point the front camera at yourself, keep your face roughly centered, and take 2–3 frames while rotating your body / walking. Expected: your face stays pinned and clear across exposures; the background swirls. Preview matched the save.
- [ ] **Step 2: Front camera, no clear face** — cover your face / aim away so no face is detected, shoot a stack. Expected: it falls back to as-shot (no wild transform); the "couldn't lock" indicator may appear.
- [ ] **Step 3: Back camera unchanged** — confirm back-camera cityscape behavior is still the Phase A scene alignment.
- [ ] **Step 4: Switch cameras mid-session** — start a stack on one camera, switch, and confirm the ghost recomputes and behaves for the new anchor.

**If a check fails:**
- Face drifts / over-rotates: widen or tighten `AlignmentService.faceScaleRange`; verify eye-center Y flip (`1 - yBL`).
- Background doesn't swirl (whole frame frozen): expected only if you barely moved — move more between shots.

---

## Self-review

**Spec coverage:**
- WYSIWYG via one alignment + one compositor → Tasks A2, A3 (preview and save both call `ExposureCompositor` with the same `transforms`). ✅
- Scene anchor = translational with guard → Task A1. ✅
- Face anchor = similarity, applied correctly → Tasks B1, B2. ✅
- Anchor chosen by camera (back=scene, front=face) → Task B2. ✅
- Magic toggle ON/OFF, both WYSIWYG; recompute + refresh on toggle → Task A3 Steps 3–4. ✅
- Safety guard (≤30% shift; face scale 0.3–3.0; fallback to identity/unlocked) → Tasks A1, B1. ✅
- Resolution-independent transforms reused at preview + full size → `FrameAlignment` normalized fields + `ExposureCompositor` (A1/A2). ✅
- Alignment confidence + minimal post-capture indicator → Task A3 (`showAlignmentWarning`, `flashAlignmentWarning`) + Task A5. ✅
- Robustness against mis-lock → guard (A1) + on-device check (A7 Step 3). ✅
- Delete dead OpenCV + homography/face-prealign + duplicate preview path → Tasks A3, A4, A6. ✅
- Live viewfinder lock meter NOT built (deferred to UI mini-project) → consistent with spec Non-goals. ✅

**Placeholder scan:** No TBD/TODO. Every code step shows complete code. The `.face` stub in Task A1 is intentional and explicitly replaced in Task B1 (phased), not a placeholder.

**Type/name consistency:** `FrameAlignment` (fields `dx, dy, rotation, scale, anchor, locked`; statics `.identity`, `.unlocked`), `AlignmentAnchor` (`.scene`, `.face`), `AlignmentService.alignment(moving:reference:anchor:)`, `AlignmentService.downscaled(_:maxDimension:)`, `ExposureCompositor.composite(frames:alignments:canvasSize:scale:exposureAlpha:)`, `PreviewView.setOverlayImage(_:opacity:)`/`setGhostOpacity(_:)`, `CameraModel.transforms`/`currentAnchor`/`recomputeTransforms()`/`flashAlignmentWarning()`/`showAlignmentWarning`/`captureCameraPosition` are used consistently across tasks.

**Note on Xcode project membership:** New `.swift` files must be added to the Expexp target (Tasks A1/A2 Step 3) and deleted files removed from it (Task A6) — these may require a one-time Xcode GUI action by the user; the plan flags each.

# Orientation, Done Right — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every saved photo (single and multi-exposure, front and back camera) come out upright by handling rotation at capture time, and delete all the manual post-capture rotation hacks.

**Architecture:** Add an `AVCaptureDevice.RotationCoordinator` (iOS 17) that feeds the correct rotation angle to both the preview layer connection and the photo-output connection, so captured pixel buffers are already upright. Front-camera output is mirrored to match the mirrored preview (WYSIWYG). With capture upright, all the scattered 90° rotation code is removed and the blend is rewritten to draw with `UIGraphicsImageRenderer` (which handles image orientation correctly), matching the existing live-preview compositor.

**Tech Stack:** Swift, SwiftUI, AVFoundation (`AVCaptureDevice.RotationCoordinator`, `AVCaptureConnection.videoRotationAngle`), Core Graphics / UIKit image drawing.

**Spec:** `docs/superpowers/specs/2026-06-27-orientation-design.md`

**Why no automated tests:** This work depends on camera hardware and live AVFoundation connection geometry, which cannot be exercised in unit tests or the iOS Simulator. Each task is verified by a successful Simulator **compile** (`xcodebuild … build`) and a commit; behavioral correctness is verified by the **on-device manual checklist** in Task 6. Do not write placeholder/fake unit tests for this plan.

**Implementation note (deviation from spec wording):** The spec said `CaptureService` would "own/refresh the RotationCoordinator." During planning it became clear the coordinator needs the `AVCaptureVideoPreviewLayer` (a `@MainActor` UIKit object owned by `PreviewView`), while `CaptureService` is an `actor` that owns the device and photo output. So the coordinator is owned by `CameraModel` (`@MainActor`), which already holds both the `previewView` and the `captureService`. This keeps orientation policy in one place and respects actor/UIKit isolation. Behavior matches the approved spec exactly.

**Shared build command** (used as the compile check in every task):
```bash
xcodebuild -project Expexp.xcodeproj -scheme Expexp \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 \
  | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```
Expected at the end of each task: `** BUILD SUCCEEDED **` and no `error:` lines.

**Branch:** Work happens on the existing `mini-1-orientation` branch.

---

## File structure

- `Expexp.xcodeproj/project.pbxproj` — raise `IPHONEOS_DEPLOYMENT_TARGET` to 17.0.
- `App/CaptureService.swift` — expose the active `AVCaptureDevice`; add a method to apply the
  capture-connection rotation angle and front/back mirroring.
- `App/CameraModel.swift` — own the `RotationCoordinator`; apply preview + capture angles; remove
  all manual rotation methods/properties; simplify `capturePhoto`/`savePhoto`; rewrite
  `blendImages` to use `UIGraphicsImageRenderer`.
- `App/CameraPreview.swift` (`PreviewView`) — simplify the ghost-overlay composite transform now
  that frames are upright.

---

## Task 1: Raise the deployment target to iOS 17

**Files:**
- Modify: `Expexp.xcodeproj/project.pbxproj`

- [ ] **Step 1: Replace the deployment target**

In `Expexp.xcodeproj/project.pbxproj`, replace **all** occurrences of:
```
IPHONEOS_DEPLOYMENT_TARGET = 16.6;
```
with:
```
IPHONEOS_DEPLOYMENT_TARGET = 17.0;
```
(Use a replace-all; there is typically one entry per build configuration.)

- [ ] **Step 2: Verify no 16.6 references remain**

Run:
```bash
grep -n "IPHONEOS_DEPLOYMENT_TARGET" Expexp.xcodeproj/project.pbxproj
```
Expected: every line shows `= 17.0;`.

- [ ] **Step 3: Compile check**

Run the shared build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add Expexp.xcodeproj/project.pbxproj
git commit -m "build: raise deployment target to iOS 17 for RotationCoordinator"
```

---

## Task 2: Expose device + capture-geometry control from CaptureService

This task is purely additive (new methods, not yet called), so it compiles with no behavior change.

**Files:**
- Modify: `App/CaptureService.swift`

- [ ] **Step 1: Add an accessor for the active capture device**

In `CaptureService` (after the existing `currentCameraPosition` computed property, around line 83), add:
```swift
    var activeDevice: AVCaptureDevice? {
        activeVideoInput?.device
    }
```

- [ ] **Step 2: Add a method to apply rotation angle + mirroring to the photo-output connection**

In `CaptureService`, add this method (place it after `focusAt(point:)`):
```swift
    /// Applies the capture rotation angle and front/back mirroring to the photo-output
    /// connection so captured pixel buffers come out upright (and mirrored for the front
    /// camera, to match the mirrored preview).
    func applyCaptureGeometry(rotationAngle: CGFloat) {
        guard let connection = photoCapture.output.connection(with: .video) else { return }

        if connection.isVideoRotationAngleSupported(rotationAngle) {
            connection.videoRotationAngle = rotationAngle
        }

        let isFront = activeVideoInput?.device.position == .front
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = isFront
        }
    }
```

- [ ] **Step 3: Compile check**

Run the shared build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add App/CaptureService.swift
git commit -m "feat: expose active device and capture-geometry control in CaptureService"
```

---

## Task 3: Own the RotationCoordinator in CameraModel and apply angles

Adds rotation wiring. The manual rotations are still present after this task, so the app is **not yet correct** (frames may be double-transformed) — that is fixed in Task 4. Do not device-test between Task 3 and Task 4. The compile check is the only gate here.

**Files:**
- Modify: `App/CameraModel.swift`

- [ ] **Step 1: Add coordinator storage**

In `CameraModel`, add these stored properties near the top of the class (just after `var previewView: PreviewView?` around line 12):
```swift
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewAngleObservation: NSKeyValueObservation?
    private var captureAngleObservation: NSKeyValueObservation?
```

- [ ] **Step 2: Add the coordinator setup method**

In `CameraModel`, add this method (place it just below `initialize()`):
```swift
    /// Creates a RotationCoordinator for the active camera + preview layer and keeps the
    /// preview and photo-output rotation angles up to date. Safe to call again after a
    /// camera switch; it rebuilds the coordinator and observations.
    func setUpRotationCoordinator() async {
        guard let previewLayer = previewView?.previewLayer,
              let device = await captureService.activeDevice else { return }

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator

        applyPreviewAngle(coordinator.videoRotationAngleForHorizonLevelPreview)
        await applyCaptureAngle(coordinator.videoRotationAngleForHorizonLevelCapture)

        previewAngleObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,
                                                      options: [.new]) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            Task { @MainActor in self?.applyPreviewAngle(angle) }
        }
        captureAngleObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture,
                                                      options: [.new]) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            Task { @MainActor in await self?.applyCaptureAngle(angle) }
        }
    }

    private func applyPreviewAngle(_ angle: CGFloat) {
        guard let connection = previewView?.previewLayer.connection else { return }
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    private func applyCaptureAngle(_ angle: CGFloat) async {
        await captureService.applyCaptureGeometry(rotationAngle: angle)
    }
```

- [ ] **Step 3: Call setup after the session starts**

In `CameraModel.initialize()`, inside the `if isAuthorized { do { … } }` block, after `isSessionRunning = true` (around line 60), add:
```swift
                await setUpRotationCoordinator()
```

- [ ] **Step 4: Rebuild the coordinator after a camera switch**

In `CameraModel.switchCamera()`, inside the `do` block after `previewView?.refreshMirroring()` (around line 109), add:
```swift
                await setUpRotationCoordinator()
```

- [ ] **Step 5: Compile check**

Run the shared build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add App/CameraModel.swift
git commit -m "feat: drive preview/capture rotation via RotationCoordinator"
```

---

## Task 4: Remove manual rotation and rewrite the blend

This is the correctness swap. After this task the app captures and saves upright with no manual rotation. Steps must all land together (single commit) because intermediate states are inconsistent.

**Files:**
- Modify: `App/CameraModel.swift`

- [ ] **Step 1: Stop rotating the ghost preview frame on capture**

In `capturePhoto()`, replace these lines (around lines 88–90):
```swift
                // Rotate ghost to match camera preview orientation  
                let rotatedGhost = rotateImageClockwise(image)
                ghostPreviewImages.append(rotatedGhost)
```
with:
```swift
                // Frames are already upright (rotation handled at capture time).
                ghostPreviewImages.append(image)
```
Also remove the now-stale debug line referencing `rotatedGhost` (around line 93):
```swift
                print("📷 DEBUG: Ghost image size: \(rotatedGhost.size), scale: \(rotatedGhost.scale) (rotated to match preview)")
```

- [ ] **Step 2: Remove first-capture orientation/camera bookkeeping**

In `capturePhoto()`, delete this block (around lines 74–79):
```swift
                // Only capture orientation and camera position for the first image
                if capturedRawImages.isEmpty {
                    captureOrientation = UIDevice.current.orientation
                    captureCamera = await captureService.currentCameraPosition
                    print("📷 DEBUG: First capture - orientation: \(captureOrientation), camera: \(captureCamera)")
                }
```

- [ ] **Step 3: Simplify the save path (no per-image rotation, no single-image rotation)**

In `savePhoto()`, replace the whole processing+single-image block — from the comment `// Process raw images (apply rotation) at save time for speed` down through the end of the single-image `else` branch (the block that currently builds `processedImages` and the `if processedImages.count == 1 { … }` branch, around lines 136–159) — with:
```swift
                // Frames are captured upright; no rotation needed.
                let processedImages = capturedRawImages

                let finalImage: UIImage
                if processedImages.count == 1 {
                    finalImage = processedImages[0]
                    print("🖼️ DEBUG: Single upright image saved as-is")
                } else {
```
(Leave the existing multi-image alignment+blend body that follows — the `var imagesForBlend = processedImages` through `finalImage = blendImages(imagesForBlend)` — unchanged, and keep its closing brace.)

- [ ] **Step 4: Rewrite `blendImages` to draw upright with UIGraphicsImageRenderer**

Replace the entire `blendImages(_:)` method (around lines 313–370) with:
```swift
    private func blendImages(_ images: [UIImage]) -> UIImage {
        guard let first = images.first else { return UIImage() }
        guard images.count > 1 else { return first }

        let canvasSize = first.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = first.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        let drawRect = CGRect(origin: .zero, size: canvasSize)

        return renderer.image { ctx in
            ctx.cgContext.clear(drawRect)
            // Lighten blend with per-exposure alpha, matching the live preview compositor.
            // UIImage.draw handles image orientation correctly (no manual rotation needed).
            for image in images {
                image.draw(in: drawRect, blendMode: .lighten, alpha: CGFloat(ghostExposureAlpha))
            }
        }
    }
```

- [ ] **Step 5: Delete the now-unused rotation helpers and properties**

Delete these declarations entirely from `CameraModel`:
- `rotateCGImageClockwise(_:)` (around lines 372–405)
- `shouldRotateImage(_:for:cameraPosition:)` (around lines 407–426)
- `rotateImage(_:for:cameraPosition:)` (around lines 428–486)
- `rotateImageClockwise(_:)` (around lines 488–520)
- the stored properties `captureOrientation` and `captureCamera` (around lines 46–47):
```swift
    private var captureOrientation: UIDeviceOrientation = .portrait
    private var captureCamera: AVCaptureDevice.Position = .back
```

- [ ] **Step 6: Compile check (this also confirms nothing else referenced the deleted code)**

Run the shared build command. Expected: `** BUILD SUCCEEDED **`. If the build reports an `error:` about an undefined symbol, it means a call site to one of the deleted methods was missed — find it with `grep -n "rotateImage\|rotateCGImageClockwise\|shouldRotateImage\|captureOrientation\|captureCamera" App/CameraModel.swift` and remove/fix that reference.

- [ ] **Step 7: Commit**

```bash
git add App/CameraModel.swift
git commit -m "refactor: remove manual rotation hacks; capture/blend now upright by construction"
```

---

## Task 5: Simplify the ghost-overlay composite transform

The overlay always vertical-flipped to compensate for the old flipped pixel space. With upright (and front-mirrored) frames, that compensation is no longer needed. Set the transform to identity; the on-device checklist (Task 6, step 5) confirms alignment and we tune here only if needed.

**Files:**
- Modify: `App/CameraPreview.swift`

- [ ] **Step 1: Make the composite transform identity**

In `PreviewView.applyCompositeTransform()` (around lines 216–221), replace the body:
```swift
    private func applyCompositeTransform() {
        let isMirrored = previewLayer.connection?.isVideoMirrored ?? false
        let sx: CGFloat = isMirrored ? -1 : 1
        let sy: CGFloat = -1
        ghostCompositeLayer.setAffineTransform(CGAffineTransform(scaleX: sx, y: sy))
    }
```
with:
```swift
    private func applyCompositeTransform() {
        // Frames are captured upright and front-camera frames are mirrored to match the
        // preview, so the ghost composite needs no extra flip. Kept as the single tuning
        // point for overlay orientation.
        ghostCompositeLayer.setAffineTransform(.identity)
    }
```

- [ ] **Step 2: Compile check**

Run the shared build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add App/CameraPreview.swift
git commit -m "refactor: ghost overlay needs no flip now that frames are upright"
```

---

## Task 6: On-device acceptance (manual)

This is the real verification gate. Run on a physical iPhone (camera does not work in the Simulator). If any check fails, see "If a check fails" below.

- [ ] **Step 1: Install on device**

Connect the iPhone, select it as the run destination in Xcode, and Run (⌘R). (User performs this; the implementer should prompt for it and wait for results.)

- [ ] **Step 2: Portrait, back camera — multi-exposure**

Capture a 2–3 exposure stack of a scene with clear up/down (e.g., a window with sky on top), tap Save. Open Photos.
Expected: composite is upright (sky on top), not rotated or flipped.

- [ ] **Step 3: Portrait, front camera — multi-exposure**

Switch to the front camera. Capture a stack that includes something asymmetric/readable (e.g., yourself holding text). Save.
Expected: upright, and the composition matches what you framed in the mirrored preview (not surprisingly reversed).

- [ ] **Step 4: Single exposure, back and front**

Capture one shot on each camera and Save.
Expected: both upright.

- [ ] **Step 5: Live ghost overlay alignment**

While shooting a stack, watch the translucent ghost of previous frames over the live feed.
Expected: the ghost lines up with the live camera (same orientation/mirroring), no flipped or upside-down overlay.

- [ ] **Step 6: Camera switch mid-session**

Start a stack on the back camera, switch to front, take another, and Save.
Expected: preview and captures stay correctly oriented across the switch.

**If a check fails:**
- Saved photo rotated 90°/180°: the capture angle isn't applying — verify `applyCaptureGeometry` runs (add a temporary `print` of the angle) and that `setUpRotationCoordinator()` is called after session start.
- Front selfie reversed vs. what you framed: flip the mirroring intent — in `applyCaptureGeometry`, set `connection.isVideoMirrored = false` for front (saves un-mirrored like the stock Camera app). Rebuild and recheck step 3.
- Ghost overlay flipped/upside-down only: adjust `applyCompositeTransform()` in `PreviewView` — reintroduce the minimal flip needed (`scaleX:1, y:-1` for vertical, or `scaleX:-1, y:1` for horizontal) until the overlay matches the live preview.

- [ ] **Step 7: Final confirmation**

Once all checks pass, the mini-project is complete. Leave the branch `mini-1-orientation` ready for review/merge (handled separately).

---

## Self-review

**Spec coverage:**
- Raise deployment target to 17 → Task 1. ✅
- RotationCoordinator drives preview + capture angles → Tasks 2–3. ✅
- Front-camera mirroring matches preview (WYSIWYG) → Task 2 (`applyCaptureGeometry` mirrors front). ✅
- Remove manual rotation methods + bookkeeping → Task 4 steps 1,2,5. ✅
- Remove single-image 90° rotation and per-image rotation pass → Task 4 step 3. ✅
- Remove trailing rotate in blend → Task 4 step 4 (rewrite). ✅
- Simplify overlay transform → Task 5. ✅
- On-device testing checklist (all 6 spec checks) → Task 6 steps 2–6. ✅
- Simulator build must still succeed → compile check in every task. ✅

**Placeholder scan:** No TBD/TODO/"handle edge cases". Each code step shows full code. The only
"tune on device" item (overlay transform / mirroring) is an explicit, bounded fallback in Task 6,
not a placeholder — the default implementation is fully specified.

**Type/name consistency:** `setUpRotationCoordinator()`, `applyPreviewAngle(_:)`,
`applyCaptureAngle(_:)`, `applyCaptureGeometry(rotationAngle:)`, and `activeDevice` are used
consistently across Tasks 2 and 3. `blendImages(_:)` keeps its signature; callers in `savePhoto()`
are unchanged. `ghostExposureAlpha` (existing property) reused in the blend rewrite.

**Note on scope:** Rewriting `blendImages` to use `UIGraphicsImageRenderer` is included because the
manual rotation being removed lived inside that method; removing it correctly requires fixing the
draw context. The blend *mode* (lighten) and look are unchanged — improving the look is
mini-project #2.

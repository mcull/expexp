# Orientation, Done Right — Design Spec

**Date:** 2026-06-27
**Mini-project:** #1 of the expexp revival program
**Status:** Approved for planning

## Program context

This is the first of five sequential mini-projects in the effort to upgrade the `expexp`
double-exposure camera app. Each mini-project gets its own spec → plan → implement → on-device
test cycle so the app stays working throughout. Agreed order:

1. **Orientation, done right** ← this spec
2. Color & blend looks
3. Intuitive UI
4. Alignment hardening (remove dead OpenCV, unify preview/save paths)
5. Ship it (TestFlight → App Store)

The app is a personal project; a secondary goal is to learn App Store shipping via phase 5.

## Problem

Photos are captured in the camera's native (rotated) pixel orientation, then "un-rotated"
after the fact with hardcoded 90° rotations plus a device-orientation lookup table. This works
in the common case (portrait, back camera) but produces sideways/flipped saves in other cases
(observed: a composite saved rotated 90° to landscape). The orientation logic is spread across
multiple methods and is the single most fragile part of the codebase.

Current orientation-handling code (all to be removed or replaced):
- `CameraModel.rotateImageClockwise(_:)` — applied to each ghost preview frame.
- `CameraModel.rotateCGImageClockwise(_:)` — applied in `blendImages` and the single-photo save path.
- `CameraModel.shouldRotateImage(_:for:cameraPosition:)` and `rotateImage(_:for:cameraPosition:)`
  — device-orientation lookup table applied at save time.
- `CameraModel.captureOrientation` / `captureCamera` — captured on the first frame to drive the above.
- `PreviewView.applyCompositeTransform()` — always vertical-flips the ghost composite (and
  horizontal-flips when mirrored) to compensate for the flipped pixel space.

## Goals

- Saved photos (single and multi-exposure) are always upright, for back and front cameras,
  regardless of how the phone was held during a portrait-locked session.
- Front-camera captures match what the user framed in the (mirrored) preview — WYSIWYG.
- All exposures within one stack share a single, consistent orientation so they blend cleanly.
- Delete the manual rotation code entirely; orientation becomes correct-by-construction.

## Non-goals

- Landscape capture / landscape UI. The app remains portrait-locked (`Info.plist` already
  restricts to `UIInterfaceOrientationPortrait`). Upright-always is the contract.
- Any change to capture, blend, save, alignment, or UI *behavior* beyond orientation.

## Approach

### 1. Raise the deployment target
Set `IPHONEOS_DEPLOYMENT_TARGET = 17.0` (from 16.6). This unlocks
`AVCaptureDevice.RotationCoordinator`. All known test devices run iOS 18+, so there is no
practical device-coverage loss.

### 2. Drive rotation at capture time with RotationCoordinator
- Create an `AVCaptureDevice.RotationCoordinator` for the active camera + preview layer
  (recreated when the camera switches in `CaptureService.switchCamera`).
- Observe `videoRotationAngleForHorizonLevelPreview` → apply to the preview layer connection,
  so the live preview is correctly oriented.
- Observe `videoRotationAngleForHorizonLevelCapture` → apply to the photo output connection,
  so captured pixel buffers come out upright. No post-capture rotation needed.
- Because the UI is portrait-locked, in practice this resolves to the upright angle; using the
  coordinator (rather than a hardcoded angle) keeps it correct and future-proof, and handles
  the camera/preview wiring cleanly.

### 3. Front-camera mirroring (WYSIWYG)
- Keep the preview connection mirrored for the front camera (natural selfie feel; this is
  effectively current behavior).
- Mirror the front-camera captured output to match the preview, so framing the shot in the
  mirrored preview produces the same composition in the saved photo. Back camera: no mirroring.
- This keeps every exposure in a set consistent and makes "what you frame is what you get" true.

### 4. Remove manual rotation and simplify the overlay
- Delete the methods and stored properties listed under "Problem."
- In `CameraModel.capturePhoto()`, append the captured image to the ghost preview buffer
  without `rotateImageClockwise`.
- In `CameraModel.savePhoto()`, remove the single-photo 90° rotation and the per-image
  device-orientation rotation pass; blend/save the upright frames directly.
- In `blendImages`, remove the trailing `rotateCGImageClockwise` step.
- In `PreviewView`, simplify `applyCompositeTransform()`: the always-on vertical flip existed to
  compensate for flipped pixels and is no longer needed once frames are upright. Retain only the
  horizontal flip required to match a mirrored front-camera preview, if any is needed after the
  capture path change. The exact residual transform is determined empirically during
  implementation (see Testing); the end state is "ghost overlay lines up with live preview."

## Components touched

- `Expexp.xcodeproj/project.pbxproj` — deployment target 16.6 → 17.0.
- `CaptureService.swift` — own/refresh the `RotationCoordinator`; apply rotation angles to the
  preview and photo-output connections; set front-camera mirroring on capture.
- `PhotoCapture.swift` — ensure capture settings/connection produce upright (and, for front,
  mirrored) output; no post-rotation.
- `CameraModel.swift` — delete all manual rotation methods and the orientation/camera
  bookkeeping; simplify `capturePhoto`, `savePhoto`, `blendImages`.
- `CameraPreview.swift` (`PreviewView`) — simplify the ghost composite transform.

## Architecture notes

Orientation becomes a property of the capture pipeline (one place: the `RotationCoordinator`
wiring in `CaptureService`), rather than a cross-cutting concern patched at preview, blend, and
save time. After this change, the rest of the app deals only in upright `UIImage`s, which also
simplifies the later color/blend and alignment mini-projects.

## Testing (on device — the camera does not work in the simulator)

Manual acceptance checks, each performed on a physical iPhone:

1. **Portrait, back camera:** capture a 2–3 exposure stack, Save → opens upright in Photos.
2. **Portrait, front camera:** capture a stack → upright, and the composition matches what was
   framed in the mirrored preview (text/asymmetric scene reads correctly, not reversed in a
   surprising way).
3. **Single exposure, back and front:** Save one shot → upright.
4. **Regression on the previously-broken grab:** reproduce the kind of capture that produced the
   sideways save → now upright.
5. **Live ghost overlay:** while shooting a stack, the ghost of prior frames stays aligned with
   the live camera feed (no flip/rotation mismatch).
6. **Camera switch mid-session:** flip cameras and confirm preview + subsequent captures remain
   correctly oriented.

A build for the simulator (`xcodebuild … build`) must still succeed (compile-level check) before
device testing.

## Risks & mitigations

- **Low risk overall.** Only affects orientation of new photos; no stored data is altered.
- **Residual flip/rotation in preview or ghost overlay:** adjust the single composite transform
  in `PreviewView` until the overlay matches the live preview (Testing step 5).
- **Front-camera mirroring expectations:** if "match the preview" feels wrong in testing, the
  alternative (save un-mirrored, like the stock Camera app default) is a one-line change; we pick
  based on what looks right on device.

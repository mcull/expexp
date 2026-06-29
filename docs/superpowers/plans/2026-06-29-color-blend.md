# Color & Blend — "Filmic Average" — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the sequential `lighten` blend with a "filmic average" — an equal-weight, order-independent, coverage-weighted average computed in linear light, finished with a gentle film tone curve — fixing the false-color tints and the unequal-ghost problem.

**Architecture:** `ExposureCompositor` keeps the proven UIKit frame **geometry** (render each aligned frame into a canvas-sized image) and moves the **color math** to Core Image: composite the positioned frames with progressive-alpha source-over (the i-th frame at opacity 1/i) in a linear-light working color space, which yields a per-pixel coverage-weighted mean; then apply a `BlendLook` tone curve in sRGB. Looks are data (`.neutral`/`.filmic`/`.moody`), default `.filmic`.

**Tech Stack:** Swift, UIKit (UIGraphicsImageRenderer for geometry), Core Image (linear-light compositing + tone curves).

**Spec:** `docs/superpowers/specs/2026-06-29-color-blend-design.md`

**Why progressive-alpha = average:** drawing frame 1 at opacity 1, frame 2 at 1/2, frame 3 at 1/3, … frame i at 1/i with normal source-over produces the running mean: after frame i the result is (F1+…+Fi)/i. Where a frame is transparent (an alignment gap), it simply doesn't contribute, so each pixel is averaged only over the frames that actually cover it (coverage-weighted — no dark edges). Doing it in a linear-light color space makes it a *linear* average, matching the approved render.

**Why no automated tests:** camera app, no XCTest target (same as prior mini-projects). Verify each task with a Simulator **compile** and the **on-device acceptance** checklist. Do not write fake unit tests.

**Shared build command:**
```bash
xcodebuild -project Expexp.xcodeproj -scheme Expexp \
  -destination 'id=C738E874-4763-4772-845B-F8E3088CBCCE' build 2>&1 \
  | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```
Expected at the end of each task: `** BUILD SUCCEEDED **`.

**Branch:** Work on the existing `mini-2-color` branch.

---

## File structure

- Create `App/Alignment/BlendLook.swift` — `BlendLook` enum + its tone-curve / color treatment.
- Modify `App/Alignment/ExposureCompositor.swift` — rewrite to linear-average + tone; signature takes `BlendLook` instead of `exposureAlpha`.
- Modify `App/CameraModel.swift` — remove `ghostExposureAlpha`; add `blendLook` (default `.filmic`); update the preview and save call sites.

---

## Task 1: Create `BlendLook`

**Files:**
- Create: `App/Alignment/BlendLook.swift`
- Modify: `Expexp.xcodeproj/project.pbxproj` (register the new file in the target)

- [ ] **Step 1: Write the file**

```swift
import CoreImage

/// A selectable finishing "look" applied on top of the linear-average blend.
/// `.filmic` is the shipping default; `.neutral` and `.moody` exist for a future in-app picker.
enum BlendLook {
    case neutral
    case filmic
    case moody

    /// Applies this look's tone curve / color treatment to an sRGB CIImage and returns sRGB.
    func apply(to image: CIImage) -> CIImage {
        switch self {
        case .neutral:
            return image
        case .filmic:
            return Self.sCurve(image, lift: 0.22, shoulder: 0.78)
        case .moody:
            let curved = Self.sCurve(image, lift: 0.18, shoulder: 0.82)
            let warm = curved.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 5400, y: 0),   // nudge warmer
            ])
            return warm.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.12,
            ])
        }
    }

    /// Gentle film S-curve: lifts the quarter-tone and rolls the three-quarter-tone.
    private static func sCurve(_ img: CIImage, lift: CGFloat, shoulder: CGFloat) -> CIImage {
        img.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0.0,  y: 0.0),
            "inputPoint1": CIVector(x: 0.25, y: lift),
            "inputPoint2": CIVector(x: 0.5,  y: 0.5),
            "inputPoint3": CIVector(x: 0.75, y: shoulder),
            "inputPoint4": CIVector(x: 1.0,  y: 1.0),
        ])
    }
}
```

- [ ] **Step 2: Register the file in the Xcode target**

The project lists files explicitly. Add `BlendLook.swift` mirroring the existing alignment entries. In `Expexp.xcodeproj/project.pbxproj`:

In the `PBXBuildFile` section (near the other `… in Sources` lines), add:
```
		BBBB0001AABBCCDDEEFF0001 /* BlendLook.swift in Sources */ = {isa = PBXBuildFile; fileRef = BBBB0002AABBCCDDEEFF0002 /* BlendLook.swift */; };
```
In the `PBXFileReference` section, add:
```
		BBBB0002AABBCCDDEEFF0002 /* BlendLook.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = BlendLook.swift; sourceTree = "<group>"; };
```
In the `Alignment` group's `children = ( … )` list (where `AlignmentService.swift` / `ExposureCompositor.swift` are listed), add:
```
				BBBB0002AABBCCDDEEFF0002 /* BlendLook.swift */,
```
In the `PBXSourcesBuildPhase` `files = ( … )` list (where the other `… in Sources` are), add:
```
				BBBB0001AABBCCDDEEFF0001 /* BlendLook.swift in Sources */,
```

- [ ] **Step 3: Verify registration + compile**

```bash
grep -c "BlendLook.swift" Expexp.xcodeproj/project.pbxproj
```
Expected: `4`. Then run the shared build command. Expected: `** BUILD SUCCEEDED **`. (If it prints `0`/doesn't build, the file isn't in the target — add it via Xcode's Project navigator instead; prompt the user for that GUI step.)

- [ ] **Step 4: Commit**

```bash
git add App/Alignment/BlendLook.swift Expexp.xcodeproj/project.pbxproj
git commit -m "feat: BlendLook enum (neutral/filmic/moody) with film tone curves"
```

---

## Task 2: Rewrite `ExposureCompositor` to filmic average + update callers

This is one coherent change: the compositor signature changes (`exposureAlpha` → `look`), so its two callers in `CameraModel` must change in the same task to compile.

**Files:**
- Modify: `App/Alignment/ExposureCompositor.swift`
- Modify: `App/CameraModel.swift`

- [ ] **Step 1: Replace the body of `ExposureCompositor.swift`**

Replace the entire file with:
```swift
import UIKit
import CoreImage

/// The single compositor used by BOTH the live preview and the save path (WYSIWYG).
/// Produces an equal-weight, order-independent, coverage-weighted average of the aligned frames
/// in LINEAR light, finished with a `BlendLook` tone curve.
enum ExposureCompositor {
    /// Linear-light working space for the averaging stage.
    private static let linearContext: CIContext = {
        if let linear = CGColorSpace(name: CGColorSpace.linearSRGB) {
            return CIContext(options: [.workingColorSpace: linear])
        }
        return CIContext()
    }()
    /// sRGB working space for the tone-curve stage (so curves act on sRGB values).
    private static let toneContext: CIContext = {
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
            return CIContext(options: [.workingColorSpace: srgb])
        }
        return CIContext()
    }()
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)

    static func composite(frames: [UIImage],
                          alignments: [FrameAlignment],
                          canvasSize: CGSize,
                          scale: CGFloat,
                          look: BlendLook) -> UIImage? {
        guard !frames.isEmpty, canvasSize.width > 0, canvasSize.height > 0 else { return nil }

        // 1. Render each aligned frame into its own canvas-sized image (proven UIKit geometry).
        var positioned: [CIImage] = []
        for (i, frame) in frames.enumerated() {
            let a = i < alignments.count ? alignments[i] : .identity
            guard let img = renderPositioned(frame: frame, alignment: a, canvasSize: canvasSize, scale: scale),
                  let ci = CIImage(image: img) else { continue }
            positioned.append(ci)
        }
        guard !positioned.isEmpty else { return nil }

        // 2. Coverage-weighted equal-weight average in LINEAR light: composite the i-th frame
        //    (1-indexed) at opacity 1/i with source-over → running mean; transparent gaps don't
        //    contribute, so each pixel averages only the frames that cover it.
        var acc: CIImage?
        for (idx, ci) in positioned.enumerated() {
            let opacity = CGFloat(1.0) / CGFloat(idx + 1)
            let faded = ci.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: opacity, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: opacity, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: opacity, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
            ])
            if let a = acc {
                acc = faded.applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: a])
            } else {
                acc = faded
            }
        }
        guard let averaged = acc else { return nil }

        // 3. Render the linear average to sRGB pixels.
        let pxRect = CGRect(x: 0, y: 0, width: canvasSize.width * scale, height: canvasSize.height * scale)
        let renderSpace = sRGB ?? CGColorSpaceCreateDeviceRGB()
        guard let avgCG = linearContext.createCGImage(averaged, from: pxRect, format: .RGBA8, colorSpace: renderSpace) else {
            return nil
        }

        // 4. Apply the look's tone curve (acts on sRGB values), render to the final image.
        let toned = look.apply(to: CIImage(cgImage: avgCG))
        guard let finalCG = toneContext.createCGImage(toned, from: toned.extent, format: .RGBA8, colorSpace: renderSpace) else {
            return UIImage(cgImage: avgCG, scale: scale, orientation: .up)
        }
        return UIImage(cgImage: finalCG, scale: scale, orientation: .up)
    }

    /// Draws one frame into a transparent canvas-sized image, applying its alignment transform
    /// (rotate/scale about the normalized anchor, then a normalized shift) over an aspect-fill base.
    private static func renderPositioned(frame: UIImage,
                                         alignment a: FrameAlignment,
                                         canvasSize: CGSize,
                                         scale: CGFloat) -> UIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: canvasSize, format: format).image { ctx in
            let cg = ctx.cgContext
            cg.clear(CGRect(origin: .zero, size: canvasSize))
            let base = aspectFillRect(imageSize: frame.size, canvasSize: canvasSize)
            let pivot = CGPoint(x: base.minX + a.anchor.x * base.width,
                                y: base.minY + a.anchor.y * base.height)
            cg.saveGState()
            cg.translateBy(x: pivot.x + a.dx * base.width, y: pivot.y + a.dy * base.height)
            cg.rotate(by: a.rotation)
            cg.scaleBy(x: a.scale, y: a.scale)
            cg.translateBy(x: -pivot.x, y: -pivot.y)
            frame.draw(in: base)   // opaque draw (no blend); alpha = 1 where covered, 0 in gaps
            cg.restoreGState()
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

- [ ] **Step 2: Replace `ghostExposureAlpha` with `blendLook` in `CameraModel`**

In `App/CameraModel.swift`, replace the `ghostExposureAlpha` property:
```swift
    /// Per-exposure alpha used for both preview and save-time lighten blends.
    /// Keeping this configurable ensures the live preview closely matches the final export.
    @Published var ghostExposureAlpha: Double = 0.8 {
        didSet {
            updateGhostPreviewOverlay()
        }
    }
```
with:
```swift
    /// Finishing look for the filmic-average blend. Hardcoded default; a picker can bind this later.
    @Published var blendLook: BlendLook = .filmic {
        didSet {
            updateGhostPreviewOverlay()
        }
    }
```

- [ ] **Step 3: Update the preview call site**

In `updateGhostPreviewOverlay()`, change the composite call:
```swift
        let composite = ExposureCompositor.composite(frames: ghostPreviewImages,
                                                     alignments: transforms,
                                                     canvasSize: canvas,
                                                     scale: UIScreen.main.scale,
                                                     exposureAlpha: CGFloat(ghostExposureAlpha))
```
to:
```swift
        let composite = ExposureCompositor.composite(frames: ghostPreviewImages,
                                                     alignments: transforms,
                                                     canvasSize: canvas,
                                                     scale: UIScreen.main.scale,
                                                     look: blendLook)
```
(The composite is then rotated by `rotatedForPreview` exactly as today — leave that untouched.)

- [ ] **Step 4: Update the save call site**

In `savePhoto()`, change:
```swift
                } else if let canvas = capturedRawImages.first?.size,
                          let composite = ExposureCompositor.composite(frames: capturedRawImages,
                                                                       alignments: transforms,
                                                                       canvasSize: canvas,
                                                                       scale: 1,
                                                                       exposureAlpha: CGFloat(ghostExposureAlpha)) {
```
to:
```swift
                } else if let canvas = capturedRawImages.first?.size,
                          let composite = ExposureCompositor.composite(frames: capturedRawImages,
                                                                       alignments: transforms,
                                                                       canvasSize: canvas,
                                                                       scale: 1,
                                                                       look: blendLook) {
```

- [ ] **Step 5: Compile check + reference sweep**

```bash
grep -rn "ghostExposureAlpha\|exposureAlpha" App
```
Expected: empty (all removed). Then run the shared build command. Expected: `** BUILD SUCCEEDED **`. (If `ghostExposureAlpha` appears in `ContentView.swift` or elsewhere, remove that reference — there is no UI slider bound to it; the visible slider is `ghostOpacity`.)

- [ ] **Step 6: Commit**

```bash
git add App/Alignment/ExposureCompositor.swift App/CameraModel.swift
git commit -m "feat: filmic-average blend (linear coverage-weighted mean + tone curve)"
```

---

## Task 3: On-device acceptance (manual)

Build & run on a physical iPhone (⌘R). The camera does not work in the Simulator.

- [ ] **Step 1: Equal, order-independent ghosts (the headline)** — Magic on, frame a static scene with one thing moving through it (the building+car case; a person walking works). Shoot 3–4 exposures, Save. Expected: static subject crisp and well-exposed; each moving ghost is **equal in strength**, and the first is **not** more faded than the last.
- [ ] **Step 2: No false-color tints** — shoot a warm+cool scene (sunlit wood/floor + sky). Expected: overlaps are clean — **no magenta/cyan**.
- [ ] **Step 3: Filmic look** — the result has gentle film depth (matches the approved "Filmic — gentle" render); not flat, not over-cooked.
- [ ] **Step 4: Exposure scaling** — compare a 2-exposure vs a 4-exposure stack of the same moving subject. Expected: individual ghosts get fainter with more exposures but stay **equal**, and the static subject stays well-exposed in both.
- [ ] **Step 5: No dark edges from alignment** — Magic on with a little handheld jitter so frames shift slightly. Expected: no darkened strip at the edges where frames don't fully overlap (coverage weighting handles it).
- [ ] **Step 6: WYSIWYG** — the live ghost preview matches the saved result (color and mood).
- [ ] **Step 7: No regressions** — orientation (portrait/landscape, both cameras), alignment (scene + face swirl), and the "couldn't lock" indicator all still behave.

**If a check fails:**
- Colors look too dark/muddy in overlaps (gamma vs linear): the averaging may not be running in linear light — verify `linearContext` uses `CGColorSpace.linearSRGB`. As a fallback, the average can be done in sRGB by using a default `CIContext()` and compensating the `BlendLook` curve; revisit only if linear looks wrong on device.
- Look too strong/weak: tune the S-curve control points (`lift`/`shoulder`) in `BlendLook.swift`.
- Tints still present: confirm the blend is the average path (not a leftover `lighten`).

---

## Self-review

**Spec coverage:**
- Linear-light average, equal-weight, order-independent → Task 2 Step 1 (progressive-alpha source-over in `linearContext`). ✅
- Coverage-weighted (no dark edges) → Task 2 Step 1 (transparent gaps don't contribute) + Task 3 Step 5. ✅
- No false-color tints → averaging replaces `lighten` (Task 2). ✅
- Filmic tone curve, `.filmic` default → Task 1 (`BlendLook`) + Task 2 Step 2 (`blendLook = .filmic`). ✅
- Looks as data (`.neutral`/`.filmic`/`.moody`) for a future picker → Task 1. ✅
- Remove `ghostExposureAlpha`; keep `ghostOpacity` slider → Task 2 Steps 2/5 (only `ghostExposureAlpha` removed; `ghostOpacity` untouched). ✅
- WYSIWYG (one compositor for preview + save) → Task 2 Steps 3/4 both call `ExposureCompositor.composite(... look:)`. ✅
- Night light-trails + picker UI out of scope → not implemented (correct). ✅

**Placeholder scan:** No TBD/TODO. Every code step is complete. The fallback note in Task 3 is a contingency, not a placeholder — the primary implementation is fully specified.

**Type/name consistency:** `BlendLook` (`.neutral`/`.filmic`/`.moody`, `apply(to:)`), `ExposureCompositor.composite(frames:alignments:canvasSize:scale:look:)`, `CameraModel.blendLook`. The compositor's new `look:` parameter is used at both call sites; `exposureAlpha` is fully removed. `FrameAlignment` fields (`dx,dy,rotation,scale,anchor`) used in `renderPositioned` match their definitions.

**Note on the CI ids in Task 1:** the `BBBB…` identifiers are placeholders for unique pbxproj object ids; they only need to be unique within `project.pbxproj` (they are, given the existing `AAAA…` ids) — use them verbatim.

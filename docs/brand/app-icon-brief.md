# Expexp — App Icon Design Brief

**For:** an image/design generator (e.g. Claude design) to produce the polished app icon.
**App:** *Expexp* — an iOS film **double-exposure** camera. You take several exposures of a scene;
a moving subject ghosts across a static one, with a warm, filmic look (not clean/digital).

## The concept
A **bird in flight across a glowing sun/moon, captured as a multiple exposure** — several
overlapping wing positions of the same bird arcing across the disc, like real chronophotography /
a film double exposure. The overlapping areas read **denser/darker** where exposures stack. It
should feel like a single beautiful photograph, not clip art.

## Mood & palette
- **Cinematic and filmic**, warm and a little moody. Think golden-hour film grain, halation glow.
- Background: a deep **teal/blue at top easing into warm amber/maroon** toward the bottom; subtle
  vignette.
- The **sun/moon**: a soft, warm, slightly blooming disc (gentle halation, not a hard circle).
- The **birds**: warm-dark silhouettes; where they cross the disc and each other, slightly denser.
  A touch of warm rim-light/glow on edges is welcome.

## Composition
- **3–5 ghosted bird positions** in a gentle arc across the disc — enough to read "motion stacked,"
  not so many it turns to mush.
- **Centered and balanced**; bold, simple silhouettes that survive shrinking.
- Bird style: a graceful **swift/swallow/gull** in flight, wings in different flap phases.

## Hard requirements (App Store / iOS)
- **1024 × 1024 px**, square, **full-bleed** (art reaches all edges).
- **No transparency / no alpha**; **no pre-rounded corners** (iOS rounds it automatically).
- **No text, no words, no logos.**
- Keep important content within the central ~80% (corners get rounded/cropped).
- Must remain legible and attractive at **~40 px** (home-screen/spotlight) — verify small.

## Avoid
- Flat vector clip-art or cartoon mascots.
- A clean/techy/digital look (this app is deliberately *filmic*).
- Busy fine detail that muddies when small; heavy drop shadows; gradients that band.

## Deliverable
A single 1024×1024 PNG. (A couple of variations welcome: e.g. sun vs. moon, warmer vs. cooler.)
Drop the chosen file in and we'll wire it into the Xcode asset catalog.

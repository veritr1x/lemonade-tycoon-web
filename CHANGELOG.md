# Changelog

User-visible changes are grouped by port. iOS build numbers match the app's
`CFBundleVersion`; web updates are published from `main` to GitHub Pages.

## Unreleased

No changes yet.

## 2026-09-05 — iOS build 10

- Made **Fill screen** the default: portrait columns use the full available width,
  and widescreen uses the full game area without side padding.
- Added a layout menu with **Fill screen**, **Keep proportions**, and **Original
  layout**, available in both orientations. The choice persists between launches.
- Kept touch mapping aligned with the expanded images. Fill stretches the original
  artwork; the other modes retain its proportions and use black padding.

## 2026-09-05 — iOS build 8

### iOS

- Added a landscape/widescreen layout with sound and pause controls in a side rail,
  giving the original side-by-side game view the full available height.
- Removed the large in-game title. Portrait uses one compact 48-point toolbar row,
  including at accessibility text sizes.
- Kept portrait stacking and game progress when switching between layouts.

### Project

- Added this changelog and contributor guidance for keeping it up to date.

## 2026-09-05 — iOS build 7

- Added portrait with the complete right game column on top and the left column
  below, with touch input in both panes.
- Added a layout switch for the full game view; landscape retains the original layout.
- Kept native text entry above the docked keyboard, with outside-tap dismissal.
- Added pause/resume and sound controls with VoiceOver labels and large touch targets.
- Added Dynamic Type to native interface text, including a separate toolbar row at
  accessibility sizes. Original bitmap game text remains fixed-size.
- Bounded pending frame delivery and released held touches during layout changes
  and backgrounding. Pause and audio interruptions freeze the game clock.
- Added coordinate checks and a separate simulator app for interaction checks.

## 2026-09-05 — iOS build 6

- Added the original lemon artwork as the iPhone and iPad app icon.

## 2026-09-05 — Initial public ports

### Web

- Published the browser game on GitHub Pages with original menus, sound, native
  text entry, fullscreen controls, and local saves.
- Added a local development server that can reuse the published runtime.

### iOS

- Published the native UIKit and AVAudioEngine host for iPhone and iPad.
- Added documented simulator builds and locally signed device builds.
- Kept app bundles, IPA archives, provisioning profiles, and signing material out
  of the repository and CI artifacts.

### Shared engine and project

- Organized the repository into `engine/`, `ports/`, `assets/`, and `tools/` so
  future platforms can use the same engine and build workflow.
- Added build checks for both ports, runtime tests, architecture notes, and
  contributor documentation.
- Clarified the license boundary between port implementation and original game material.

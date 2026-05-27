# Native Player UX Baseline Audit

Date: 2026-05-26 21:49 EDT  
Issue: `dreamio-ee1`

## Scope

This audit covers the current VLC-backed native playback experience before Liquid Glass and broader UX changes. The primary implementation is `Dreamio/NativePlayerViewController.swift`, backed by `Dreamio/NativePlaybackBackend.swift` and `Dreamio/VLCNativePlaybackBackend.swift`.

## Current Experience Summary

Dreamio presents native playback as a full-screen black video surface with a compact bottom control tray, a top-right close button, a loading spinner, and a simple centered failure label. Controls are built directly in UIKit and are intentionally lightweight.

Current user-facing controls:

- Top-right close button.
- Bottom compact blur-backed tray capped at 430 points wide.
- Elapsed time, scrubber, and remaining time row.
- Audio menu button.
- 15-second jump back.
- Play/pause.
- 15-second jump forward.
- Captions menu button with subtitle delay controls.
- Tap anywhere on the playback surface to reveal or hide controls.
- Auto-hide while playing after 3 seconds.

## Existing Strengths

- **Minimal interruption:** The player is full-screen and hides chrome while playback is active.
- **Compact controls:** Recent work reduced the overlay footprint so video content stays dominant.
- **Core playback affordances exist:** Play/pause, seeking, jump controls, elapsed/remaining time, audio tracks, captions, and subtitle delay are present.
- **Backend-aware disabling:** Seek and jump controls disable when VLC reports a non-seekable stream.
- **Track menus are cached:** Audio and captions menus avoid unnecessary rebuilds through signature values.
- **Subtitle handoff exists:** The native player can receive subtitle candidates from the Stremio Web bridge and attach them through the backend.
- **Safe-area aware:** Close and controls are anchored to safe-area guides.

## Current UX Gaps

### Visual Treatment

- The control surface uses `UIBlurEffect(style: .systemUltraThinMaterialDark)` plus manual tint/border styling, not iOS 26 Liquid Glass.
- Buttons are individual translucent wells rather than an intentional grouped glass system.
- There is no bottom readability scrim; bright video frames could reduce time label and icon contrast.
- Loading and failure states are plain compared with the rest of the player chrome.

### Touch Targets and Hierarchy

- Secondary controls are 36×36 points, below Apple’s recommended 44×44 point minimum target.
- The play/pause button is only 42×42 points, so the primary action is not dominant enough.
- Audio and captions have the same visual weight as transport controls even when unavailable or secondary.
- Disabled captions do not currently mirror the explicit alpha treatment used by audio.

### Scrubbing

- The scrubber has a compact thumb and row, but no preview/target time bubble.
- During scrubbing, the elapsed label updates, but the user does not get a larger focused scrubbing affordance.
- There is no haptic feedback on scrub begin/end or jump actions.

### Gestures

- Single tap toggles controls, but no richer playback gestures exist.
- There is no double-tap left/right jump behavior.
- There is no center tap play/pause behavior separate from chrome visibility.
- Gesture conflict handling will need care because `tap.cancelsTouchesInView = false` currently allows control touches to pass through.

### Auto-Hide

- Controls hide after 3 seconds while playing, which can feel short for subtitle/audio menu interactions or careful scrubbing.
- The auto-hide timer only checks `backend.isPlaying`; future changes should explicitly protect menu presentation, scrubbing, loading, paused, and failure states.

### Loading and Failure

- Startup loading is only a white `UIActivityIndicatorView` over black.
- Failure is a plain text label with no retry, close action, or debug affordance.
- The 20-second startup timeout is useful, but the user receives little guidance after it fires.

### Accessibility

- Buttons have accessibility labels, but no accessibility hints.
- The scrubber has no dynamic accessibility value describing elapsed and remaining time.
- Jump actions are not exposed as custom accessibility actions on the player surface.
- Motion preferences are not checked before animations.
- Dynamic Type behavior for the compact controls has not been explicitly protected.

### Device Adaptation

- The bottom tray is capped at 430 points, which is good for phones but underuses iPad/large landscape space.
- Button sizing and row spacing are fixed; orientation-specific density has not been tuned.
- The supported orientations allow all but upside down, so landscape crowding should be part of validation.

## Implementation Constraints

- `NativePlaybackBackend` currently exposes no thumbnail/preview frames, so scrub previews should begin as a time bubble rather than video thumbnails.
- The backend exposes seekability, duration, position, audio tracks, subtitle tracks, and subtitle delay, which is enough for richer controls without backend changes.
- The app must preserve compatibility with builds where MobileVLCKit is unavailable through the existing fallback backend behavior.
- Liquid Glass APIs should be gated with iOS availability checks and keep the current blur/material implementation as fallback.
- Multiple glass controls should be grouped with container effects where possible to avoid expensive standalone glass rendering.

## Recommended Next Implementation Slice

Start with a low-risk visual and ergonomics pass:

1. Add iOS 26 Liquid Glass availability-gated styling for the main controls tray and interactive buttons, preserving the current blur fallback.
2. Increase button targets to at least 44×44 points and make play/pause 54–58 points.
3. Add a subtle bottom gradient scrim behind controls for contrast.
4. Extend auto-hide timing from 3 seconds to about 4.5 seconds and prevent hiding while scrubbing.
5. Add missing accessibility hints and scrubber accessibility value.

Defer until the second implementation slice:

- Scrubber target time bubble.
- Double-tap jump gestures.
- Center tap play/pause behavior.
- Glass-backed loading and failure cards with retry.
- iPad-specific wider layout.

## Validation Targets for Future Changes

- Build the workspace with Xcode command-line tools.
- Test seekable and non-seekable streams.
- Test streams with one audio track, multiple audio tracks, no captions, embedded captions, and external captions.
- Verify controls remain usable in portrait and landscape.
- Verify VoiceOver labels, hints, and scrubber values.
- Verify older iOS fallback styling still works when Liquid Glass is unavailable.

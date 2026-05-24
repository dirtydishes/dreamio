# Dreamio

Dreamio is a minimal iOS `WKWebView` wrapper around hosted Stremio Web.

The MVP intentionally keeps native code thin. It loads `https://web.stremio.com/`
inside a UIKit host app, handles new-window navigation in the existing web view,
allows inline media playback, and leaves playback viability to real-device
testing.

## Running the MVP

1. Open `Dreamio.xcodeproj` in Xcode.
2. Select the `Dreamio` scheme.
3. Pick a real iPhone or iPad device.
4. Set a development team for code signing if Xcode asks.
5. Build and run.

The repository machine currently has Command Line Tools selected instead of full
Xcode, so command-line `xcodebuild` validation is not available here.

## MVP Validation Checklist

- Cold launch loads hosted Stremio Web.
- Login completes and persists after app relaunch.
- Catalog and library navigation work.
- Addon install or configuration flows work, including redirects or popups.
- HLS direct stream playback works.
- MP4 direct stream playback works.
- Unsupported formats fail understandably.
- Fullscreen, rotation, pause/resume, and background/foreground behavior are
  acceptable for v1.

Track playback results by device, iOS version, stream protocol, container,
codec, subtitle type, HTTP status, and WebKit media error when available.

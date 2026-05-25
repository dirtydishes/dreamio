# Dreamio

Dreamio is a minimal iOS `WKWebView` wrapper around hosted Stremio Web.

The MVP intentionally keeps native code thin. It loads `https://web.stremio.com/`
inside a UIKit host app, handles new-window navigation in the existing web view,
allows inline media playback, and leaves playback viability to real-device
testing.

## Running Dreamio

1. Install CocoaPods if needed.
2. Run `pod install`.
3. Open `Dreamio.xcworkspace` in Xcode.
4. Select the `Dreamio` scheme.
5. Pick a real iPhone or iPad device.
6. Set a development team for code signing if Xcode asks.
7. Build and run.

Dreamio uses MobileVLCKit for native playback of direct-file streams that iOS
WebKit commonly cannot play, especially MKV, AVI, and WebM debrid URLs. Keep
using `Dreamio.xcworkspace` after installing pods so Xcode links the native
playback backend.

## Validation Notes

The repository machine currently has Command Line Tools selected instead of full
Xcode, and CocoaPods is not installed, so command-line `pod install` and
`xcodebuild` validation are not available here.

## Playback Validation Checklist

1. Cold launch loads hosted Stremio Web.
2. Login completes and persists after app relaunch.
3. Catalog and library navigation work.
4. Addon install or configuration flows work, including redirects or popups.
5. HLS direct stream playback works.
6. MP4 direct stream playback works.
7. Debridio, Torrentio, and Real-Debrid MKV/AVI/WebM direct-file streams open
  the native player before WebKit reaches its visible media failure state.
8. Closing the native player returns to the existing Stremio Web session.
9. DEBUG logs show sanitized stream classification and native player errors
  without full debrid URLs, query strings, tokens, or long secret-like path
  segments.

Track playback results by device, iOS version, stream protocol, container,
codec, subtitle type, HTTP status, and WebKit media error when available.

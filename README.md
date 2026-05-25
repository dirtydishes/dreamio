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

If the app says "Native playback needs CocoaPods" or a player screen says
"Native playback is not available in this build," the binary was built without
MobileVLCKit linked. To resolve it, install CocoaPods, run `pod install` from
this repository, open `Dreamio.xcworkspace` instead of `Dreamio.xcodeproj`, and
build the workspace. Direct MKV, AVI, and WebM playback depends on that
workspace build because the raw project intentionally keeps a fallback compile
path for environments where CocoaPods has not been installed yet.

On macOS, install CocoaPods with RubyGems:

```bash
sudo gem install cocoapods
pod --version
pod install
open Dreamio.xcworkspace
```

If the gem install fails because of a local Ruby or permissions issue, another
common macOS option is Homebrew:

```bash
brew install cocoapods
pod --version
pod install
open Dreamio.xcworkspace
```

The official CocoaPods getting started guide documents the RubyGems install
path: https://guides.cocoapods.org/using/getting-started.html

## Validation Notes

CocoaPods 1.16.2 was installed with Homebrew on this repository machine, and
`pod install` generated `Dreamio.xcworkspace` plus `Podfile.lock` with
MobileVLCKit 3.7.3. The workspace builds from the command line when full Xcode
is selected for that command:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -workspace Dreamio.xcworkspace \
  -scheme Dreamio \
  -configuration Debug \
  -sdk iphonesimulator \
  build
```

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

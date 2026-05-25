# Dreamio iOS Plan

## Goal

Build **Dreamio**, a thin iOS wrapper around `stremio-web` for TestFlight, personal sideload, and private-device use. The v1 target is direct web playback only: debrid-backed HTTP/HLS sources that iOS WebKit can play without an on-device torrent engine or local streaming server.

## Product Positioning

Dreamio is not a public App Store product by default. Treat TestFlight and personal sideload as the intended distribution path until a separate App Store review strategy exists.

Avoid bundling, hardcoding, or presenting anything that implies unauthorized content access. Dreamio should behave like a web shell for user-configured Stremio flows, not a content service.

## Non-Goals

- On-device torrent engine
- Local streaming server parity with desktop
- Public App Store release in v1
- Full desktop feature parity in v1
- Large native rewrite in Swift/UIKit
- Native player bridge unless real-device testing proves it is needed

## Recommended Base

1. Use `stremio-web` as the app UI and flow source.
2. Do not start from `stremio-shell` because the desktop Qt shell does not map cleanly to iOS.
3. Keep native iOS code minimal; let the web app do most work.
4. Start with hosted `stremio-web` in `WKWebView` before investing in local bundling.
5. Pin the upstream `stremio-web` version or commit once bundling begins.

## Architecture (v1)

1. Native iOS host app using `WKWebView`.
2. Hosted `stremio-web` viability check first.
3. Bundled `stremio-web` static assets only after hosted viability passes.
4. Local `index.html` loaded inside `WKWebView`, assuming routing, storage, CORS, CSP, and auth still work from the bundled context.
5. Tiny JS <-> native bridge only for proven gaps such as fullscreen, PiP, external links, share sheet behavior, or subtitles.
6. Optional `AVPlayer` bridge only if real-device playback or subtitle behavior makes web playback unacceptable.

## Why This Is Feasible

- Direct web playback removes the hardest iOS blockers.
- No torrent/local-streaming process is needed.
- iOS WebKit can handle a practical subset of media formats, especially HLS and many MP4 streams.
- `WKWebView` can host the Stremio web flow with minimal native code if auth, storage, and media constraints are handled carefully.

## Feasibility Gates

Do not move to the next phase until the current gate passes on a real iPhone.

1. **Hosted web gate:** hosted `stremio-web` works inside `WKWebView` for login, browsing, addon flow, and library screens.
2. **Playback gate:** representative debrid-backed HLS and MP4 streams play on real iPhone/iPad hardware.
3. **Bundled app gate:** bundled static assets work without routing, storage, CORS, CSP, service worker, or auth regressions.
4. **Web-player sufficiency gate:** fullscreen, subtitles, PiP expectations, pause/resume, and background/foreground behavior are acceptable without a native player bridge.

## Hard Blockers / Stop Conditions

Pause or redesign the approach if any of these remain unresolved after focused investigation:

1. Login cannot persist reliably in `WKWebView`.
2. Direct playback fails for both HLS and MP4 on real iOS devices.
3. `stremio-web` depends on browser APIs unavailable in `WKWebView` with no practical workaround.
4. Debrid or addon flows depend on blocked origins, popups, redirects, or auth behavior that cannot be safely handled.
5. Bundled local assets introduce CORS, CSP, or storage behavior that cannot be fixed without turning Dreamio into a large fork.

## Implementation Steps

### 1) Fast viability check

1. Create a throwaway iOS app with a single `WKWebView`.
2. Point it to hosted `stremio-web` first.
3. Enable Safari Web Inspector for real-device debugging.
4. Verify login, browsing, addon install/config, catalog navigation, and library sync.
5. Test one representative playback flow before doing any local bundling.

### 2) Playback validation (critical)

1. Test known direct debrid streams on real iPhone and iPad hardware.
2. Validate at minimum:
   - HLS (`.m3u8`), expected best path
   - MP4, expected generally workable
   - MKV/custom codecs, expected mixed or unsupported
   - HEVC/H.265, especially device-generation differences
   - HDR, surround audio, and embedded subtitles as likely edge cases
3. Track failures by protocol, container, codec, subtitle type, MIME/content type, HTTP status, and WebKit media error.
4. Do not track failures only by provider name; provider labels are less useful than format behavior.

### 3) Local bundle integration

1. Pin the upstream `stremio-web` version or commit.
2. Build `stremio-web` static assets.
3. Copy build output into Xcode project resources through a reproducible script or documented build step.
4. Load bundled `index.html` from the app sandbox.
5. Verify routing, static asset paths, service worker behavior, API origins, CSP, CORS, auth redirects, cookies, local storage, and IndexedDB.
6. Document any local patches separately so upstream updates remain possible.

### 4) WebKit compatibility patches

1. Handle service worker limitations by disabling, bypassing, or adapting the affected behavior if needed.
2. Fix popup and new-tab flows in `WKWebView`.
3. Confirm auth/session persistence across app relaunch.
4. Confirm local storage and IndexedDB behavior under normal iOS cache pressure.
5. Confirm touch UX, viewport sizing, safe areas, and rotation.
6. Confirm ATS/HTTPS behavior for all required remote requests.

### 5) Optional native bridge additions

Add only when real-device tests show a specific gap:

- Fullscreen controls
- Picture in Picture
- External URL handling
- Share sheet/open-in-app behavior
- Subtitle import glue
- Minimal native player surface using `AVPlayer`

## Native Bridge Decision Rule

Stay web-only if HTML `<video>` playback, fullscreen, subtitles, and PiP behavior are good enough for v1.

Add a minimal JS <-> native bridge only for specific, test-proven gaps. Do not add broad native abstractions preemptively.

Consider an `AVPlayer` bridge only if one of these is true:

1. HLS/MP4 playback is materially more reliable in `AVPlayer` than in WebKit.
2. Subtitle behavior is unacceptable in WebKit but practical with native playback.
3. PiP, backgrounding, or fullscreen behavior cannot meet the v1 bar through the web path.

## Auth, Origin, and Storage Risks

Plan for these differences between hosted web, bundled local files, and `WKWebView`:

- OAuth/login redirects may need explicit navigation handling.
- Popup/new-tab flows need a `WKUIDelegate` path.
- Cookies may not behave exactly like Safari.
- Session persistence must be tested across app relaunch.
- Local storage and IndexedDB may be affected by iOS storage pressure.
- CORS and CSP behavior may differ between HTTPS origins and bundled local files.
- Raw `file://` loading may be insufficient; a local app-origin strategy may be needed if APIs assume a web origin.

## iOS Constraints To Plan For

- ATS/HTTPS requirements
- Autoplay and user-gesture media rules
- Background/foreground transitions during playback
- PiP entitlement and behavior
- Rotation and safe-area handling
- Storage limits and cache eviction patterns
- WebKit codec/container support differences by device generation
- AirPlay behavior if users expect it

## Debugging / Diagnostics

During PoC, keep a small manual compatibility log for every playback attempt:

1. Device and iOS version
2. Hosted or bundled build
3. Stream protocol and URL type, without storing sensitive tokens
4. MIME/content type and HTTP status
5. Container and codec guess
6. Subtitle type
7. WebKit media error, console error, or native navigation error
8. Outcome: plays, partially plays, fails clearly, or fails confusingly

Use Safari Web Inspector for console, network, storage, and media debugging wherever possible.

## v1 Scope

In scope:

1. Login/account sync
2. Catalog/discovery/library navigation
3. Addon install/config flow, assuming the web path supports it in `WKWebView`
4. Debrid-backed direct stream playback for iOS-compatible formats
5. Basic subtitle, fullscreen, rotation, and pause/resume behavior
6. TestFlight or personal sideload packaging

Out of scope:

1. Torrent-backed streaming
2. Universal codec parity with desktop
3. Desktop-equivalent advanced playback features
4. Public App Store optimization or review strategy
5. Native browsing/library rewrite

## Success Criteria

1. Dreamio starts quickly and consistently on real devices.
2. Login/session survives app relaunch.
3. Addon and library flows work without major rendering or redirect bugs.
4. Core browse flows work without major rendering bugs.
5. Representative HLS and MP4 direct streams play reliably.
6. Playback handles fullscreen, rotation, pause/resume, and background/foreground transitions acceptably.
7. Unsupported formats fail clearly rather than confusingly.
8. The build and bundle process is reproducible from a pinned `stremio-web` source version.

## Test Matrix (minimum)

Devices:

- One recent iPhone
- One older iPhone
- One iPad

Core flows:

1. Cold launch -> login -> browse -> select stream -> play
2. App relaunch preserves session
3. Addon install/config flow works
4. Library/catalog navigation works

Playback:

1. HLS baseline stream
2. MP4 baseline stream
3. MKV or codec-problem stream, documented as expected failure if unsupported
4. Subtitle on/off and language switch
5. Fullscreen enter/exit and rotation
6. Pause/resume -> background -> return -> continue
7. Network switch, Wi-Fi <-> cellular/hotspot

Bundle-specific checks:

1. Hosted `stremio-web` behavior compared against bundled build
2. Routing and asset loading
3. Storage persistence
4. CORS/CSP/auth redirect behavior
5. Service worker behavior

## Delivery Strategy

1. Build the `WKWebView` PoC against hosted `stremio-web`.
2. Continue only if hosted `stremio-web` inside `WKWebView` can complete login, browse, addon flow, and at least HLS/MP4 playback on a real iPhone.
3. If playback is good enough, bundle pinned `stremio-web` assets and harden routing, storage, auth, and media behavior.
4. Package for TestFlight or personal sideload.
5. Add native bridge features only when real-device tests prove they are necessary.

## Distribution and Review Risk

Dreamio should be treated as a private/TestFlight/sideload project unless and until a separate public App Store strategy exists.

A public App Store path may require changes to addon discovery, content positioning, account flows, and review messaging. Do not assume the private/TestFlight version can ship unchanged through public review.

## Bottom Line

For direct web-only debrid playback, Dreamio as a `stremio-web` + `WKWebView` wrapper is a realistic path if the real-device feasibility gates pass. Keep v1 narrow, prove hosted-web playback first, bundle only after the web flow works, and add native code only for specific problems that WebKit cannot solve well enough.

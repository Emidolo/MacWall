# MacWall

A native macOS menu-bar app that plays [Wallpaper Engine](https://store.steampowered.com/app/431960/) Workshop wallpapers as your desktop background.

> You must own Wallpaper Engine on Steam. MacWall downloads Workshop items with **your** Steam account through Valve's own `steamcmd`; it does not bypass DRM or redistribute any content.

## Features

- **Video** wallpapers (AVFoundation): seamless loop, aspect-fill, muted by default, volume slider.
- **Web** wallpapers (WKWebView) with Wallpaper Engine's JS API: `wallpaperPropertyListener.applyUserProperties` (fed from `project.json` → `general.properties`), `applyGeneralProperties`, `setPaused`, and `wallpaperRegisterAudioListener` (128 bins — 64 left, 64 right — of live system audio).
- **Scene** wallpapers (Metal): see [Scene support](#scene-support).
- Library with previews, search and type filter; import folders or `.zip`s copied from a Windows PC.
- Workshop downloads by URL or ID via `steamcmd`, including the Steam Guard prompt.
- A different wallpaper per display, or one mirrored on all; survives display connect/disconnect and resolution changes.
- Pauses when a fullscreen (or maximized, ≥95% coverage) window hides the desktop, on sleep, on screen lock, and in Low Power Mode.
- Quality and FPS-limit settings, launch at login, optional Dock icon. Remembers your wallpapers.

## Build

Requires macOS 14+ and Swift 5.9+ — either Xcode or just the Command Line Tools (`xcode-select --install`).

```bash
make app                      # build/MacWall.app (release, current architecture)
make app ARCHS="arm64 x86_64" # universal binary
make run                      # build and open
make test                     # unit tests
```

In Xcode: **File → Open…** and pick `Package.swift`, then run the `MacWall` scheme. (Launch at login and Screen Recording permission work best from the bundled `build/MacWall.app`; copy it to `/Applications`.)

The bundle is ad-hoc signed. If you rebuild, macOS may ask for Screen Recording permission again because the signature changed.

## steamcmd setup

```bash
brew install steamcmd
steamcmd +quit                # first run updates itself; let it finish
```

MacWall looks for `steamcmd` in `/opt/homebrew/bin` and `/usr/local/bin`, or at the path you set in Settings. The brew build is Intel-only, so Apple Silicon Macs need Rosetta (`softwareupdate --install-rosetta`).

In the library window choose **Download…**, enter your Steam username and a Workshop URL (`https://steamcommunity.com/sharedfiles/filedetails/?id=…`) or ID. The first time, MacWall asks for your password and Steam Guard code (or tells you to approve the sign-in in the Steam Mobile app) and passes them straight to steamcmd's terminal. Only the username is stored (in the Keychain); after that steamcmd reuses its own cached session.

Downloads land in `~/Library/Application Support/MacWall/wallpapers/<workshopId>/`.

## Importing from a Windows PC

Copy folders from `…\steamapps\workshop\content\431960\` (each contains a `project.json`), zip them if you like, and use **Import…**. A folder or zip can contain one wallpaper or many.

## Permissions

- **Screen Recording** — only requested when a web wallpaper registers an audio listener (system audio is captured with ScreenCaptureKit). If denied, the wallpaper receives zeros.

## Scene support

Scene wallpapers (`scene.pkg`) are rendered by a custom Metal renderer; unsupported features are skipped and the library shows a **Partial** badge. See the Phase 2 section below for what is implemented.

## Known limitations

- **Application** wallpapers (Windows `.exe`) can't run; the preview image is shown instead.
- Video wallpapers in formats AVFoundation can't decode (e.g. WebM/VP9 without system support) won't play.
- Web wallpapers relying on Wallpaper Engine–only APIs beyond those listed above (media integration, `wallpaperRequestRandomFileForProperty`, …) may partially work.
- User property editing isn't exposed yet; `project.json` defaults are used.
- Fullscreen detection polls the window list every 2 s, so pausing can lag by up to 2 s.

## Development

`MACWALL_SELFTEST=<dir>` with a debug build (`make app CONFIG=debug`) writes a snapshot and a status line for each wallpaper window plus the library and settings windows — handy for checking rendering without Screen Recording permission.

Layout: `Sources/MacWallKit` holds the pure, unit-tested logic (project.json, Workshop IDs, steamcmd output parsing, the web JS shim, scene formats); `Sources/MacWall` is the app.

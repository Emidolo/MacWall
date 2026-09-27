# MacWall

A native macOS menu-bar app that plays [Wallpaper Engine](https://store.steampowered.com/app/431960/) Workshop wallpapers as your desktop background.

> You must own Wallpaper Engine on Steam. MacWall downloads Workshop items with **your** Steam account through Valve's own `steamcmd`; it does not bypass DRM or redistribute any content.

## Features

- **Video** wallpapers (AVFoundation): seamless loop, aspect-fill, muted by default, volume slider.
- **Web** wallpapers (WKWebView) with Wallpaper Engine's JS API: `wallpaperPropertyListener.applyUserProperties` (fed from `project.json` → `general.properties`), `applyGeneralProperties`, `setPaused`, and `wallpaperRegisterAudioListener` (128 bins — 64 left, 64 right — of live system audio).
- **Scene** wallpapers (Metal): see [Scene support](#scene-support).
- Library with previews, search and type filter; import folders or `.zip`s copied from a Windows PC.
- Wallpaper properties (colours, sliders, toggles, dropdowns, text) editable per wallpaper: right-click → **Properties…**. Web wallpapers update live; scenes reload. Edits are stored separately, so `project.json` stays untouched and **Reset to Defaults** always works.
- Workshop downloads by URL or ID via `steamcmd`, including the Steam Guard prompt.
- A different wallpaper per display, or one mirrored on all; survives display connect/disconnect and resolution changes.
- Pauses when a fullscreen (or maximized, ≥95% coverage) window hides the desktop, on sleep, on screen lock, and in Low Power Mode.
- Quality and FPS-limit settings, launch at login, optional Dock icon. Remembers your wallpapers.

## Build

Requires macOS 14+ and Swift 5.9+ — either Xcode or just the Command Line Tools (`xcode-select --install`).

```bash
make app                      # build/MacWall.app (release, current architecture)
make app ARCHS="arm64 x86_64" # universal binary (built per arch, merged with lipo)
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

MacWall looks for `steamcmd` in `/opt/homebrew/bin` and `/usr/local/bin`, or at the path you set in Settings. It shares `~/Library/Application Support/Steam` with the Steam desktop client if you have that installed.

In the library window choose **Download…**, enter your Steam username and a Workshop URL (`https://steamcommunity.com/sharedfiles/filedetails/?id=…`) or ID. The first time, MacWall asks for your password and Steam Guard code (or tells you to approve the sign-in in the Steam Mobile app) and passes them straight to steamcmd's terminal. Only the username is stored (in the Keychain, as an item attribute with no secret, so it never triggers a Keychain prompt); after that steamcmd reuses its own cached session.

Downloads land in `~/Library/Application Support/MacWall/wallpapers/<workshopId>/`.

## Importing from a Windows PC

Copy folders from `…\steamapps\workshop\content\431960\` (each contains a `project.json`), zip them if you like, and use **Import…**. A folder or zip can contain one wallpaper or many.

## Permissions

- **Screen Recording** — only requested when a web wallpaper registers an audio listener (system audio is captured with ScreenCaptureKit). If denied, the wallpaper receives zeros.

## Scene support

Scene wallpapers (`scene.pkg`) are rendered by MacWall's own Metal renderer. Anything it can't render is skipped, the rest is drawn, and the library shows a **Partial** badge (hover it for the list).

| Supported | Notes |
|---|---|
| `scene.pkg` (PKGV) archives, `.tex` textures | RGBA8888, DXT1/3/5, RG88, R8, LZ4, embedded PNG/JPEG |
| Image layers | z-order, origin/size/scale/rotation, parenting, alignment, colour, alpha, `normal`/`translucent`/`additive` blending, texture padding crop |
| User properties | `{"user": …}` bindings resolve against `project.json` defaults |
| Camera parallax | Follows the mouse, per-layer `parallaxDepth`, smoothing via `cameraparallaxdelay` |
| Keyframe animation | origin/scale/angles/alpha/colour; loop, mirror, single; step and Bézier keys |
| Effects | `shake`, `waterripple`, `scroll`, `tint` — native Metal re-implementations |
| Particles | `boxrandom`/`sphererandom` emitters; lifetime/size/alpha/colour/velocity/rotation initializers; movement, fade, size/alpha/colour change, oscillate operators; instance overrides |

Many scenes also reuse textures that ship inside Wallpaper Engine itself (e.g. particle sprites, the water-ripple normal map). If you have a Windows install, copy its `wallpaper_engine/assets` folder to your Mac and set it under **Settings → Wallpaper Engine assets folder**. Without it, particles fall back to a soft dot and water ripples use procedural waves.

## Known limitations

- **Application** wallpapers (Windows `.exe`) can't run; the preview image is shown instead.
- Video wallpapers in formats AVFoundation can't decode (e.g. WebM/VP9 without system support) won't play.
- Web wallpapers relying on Wallpaper Engine–only APIs beyond those listed above (media integration, `wallpaperRequestRandomFileForProperty`, …) may partially work.
- File/folder properties (e.g. a custom background image) aren't editable.
- Fullscreen detection polls the window list every 2 s, so pausing can lag by up to 2 s.
- The FPS limit applies to web and scene wallpapers; videos play at their native frame rate.
- Web audio played through the Web Audio API ignores the volume slider (only `<video>`/`<audio>` elements follow it).

Scenes:
- Wallpaper Engine's shader sources aren't part of the Workshop download, so effects are hand-written Metal equivalents reconstructed from their parameters, not translations of the originals. Only the four effects above exist; others (god rays, blur, bloom, foliage sway, …) are skipped. Their look approximates WE's, and parallax amplitude isn't calibrated against real Wallpaper Engine.
- Not rendered: perspective (3D) cameras, puppet/skeletal animation, text, sound, lights, 3D models, SceneScript, sprite-sheet/GIF and video textures, particle children, control points, turbulence/vortex operators, rope/trail renderers, audio-reactive effects, bloom/HDR.
- RG88 textures are read as luminance + alpha; the byte order is disputed between reference implementations.

## Development

`python3 Tools/make-test-scene.py <dir>` writes a synthetic scene exercising most of the renderer; drop it into the library folder.

`MACWALL_SELFTEST=<dir>` with a debug build (`make app CONFIG=debug`) writes a snapshot and a status line for each wallpaper window plus the library and settings windows — handy for checking rendering without Screen Recording permission.

Layout: `Sources/MacWallKit` holds the pure, unit-tested logic (project.json, Workshop IDs, steamcmd output parsing, the web JS shim, scene formats); `Sources/MacWall` is the app.

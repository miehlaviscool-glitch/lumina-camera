# Lumina

A pro camera app for iPhone (iOS 16+), built with SwiftUI, AVFoundation and Core Image.

## Modes
| Mode | What it does |
|---|---|
| Photo | HEIF/JPEG, Live Photo, flash, burst (hold shutter), 48MP "Max Res" |
| Portrait | Depth + portrait matte capture (adjust blur in Photos) |
| Night | Aligns (Vision) and averages frames for clean handheld low light |
| **Stars** | Astro preset: infinity focus, longest exposure, ISO 1600, 4000K WB, then stacks frames to cut noise and auto-lifts the sky |
| Trails | Lighten-stacks frames into star trails, building live on screen |
| Long Exp | Averages frames for silky water/clouds, or lighten-blend for light trails |
| Pro | Manual ISO, shutter, focus, white balance, EV bias, ProRAW, focus peaking, histogram |
| Macro | Ultra wide lens with near focus restriction |
| Video / Slo-Mo | 720p/1080p/4K at 24/30/60 fps (HEVC), 240 fps slow motion, torch |
| Time-lapse | Interval frames (1-30 s) written to an H.264 video, with filters applied |
| Scan | QR / barcode scanner with copy and open |

Also: 22 live filters with intensity, a photo editor (filters, light, color, detail, crop), grid overlays, level, red night-vision UI, timer, aspect ratios, location tagging, volume-button shutter.

## Building the IPA
Every push to `main` runs `.github/workflows/build.yml` on a macOS runner (XcodeGen, then xcodebuild) and uploads
`Lumina-unsigned.ipa` as a workflow artifact. Push a tag like `v1.0.0` to also attach it to a GitHub Release.

The IPA is **unsigned**. Install it with Sideloadly, AltStore or TrollStore (free Apple ID works; the signature expires after 7 days),
or re-sign it with your own certificate.

## Local project
```
brew install xcodegen
swift tools/make_icon.swift Sources/Assets.xcassets/AppIcon.appiconset/icon.png
xcodegen generate
open Lumina.xcodeproj
```

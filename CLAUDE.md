# camtune — Claude development notes

Working notes so future sessions (and humans) don't re-discover painful
macOS-specific gotchas the hard way.

## What this is

A macOS native Swift / SwiftUI app that:
1. Captures the user's webcam (`AVCaptureSession`).
2. Applies real-time color correction + AI helpers via Core Image / Vision.
3. Exposes the corrected feed as a **virtual camera** (`camtune Virtual Camera`)
   that shows up in Zoom / Teams / Meet / Photo Booth via a **CMIO Camera
   Extension** (System Extension, macOS 13+).

Main goal: tune the webcam once in camtune, every other app on the system
sees the corrected video.

## Architecture at a glance

```
┌──────────────────────────────── camtune.app (host) ─────────────────────────────┐
│  AVCaptureSession (real camera, e.g. Dell Webcam)                               │
│        ↓ CVPixelBuffer                                                          │
│  FilterPipeline (CIFilter chain: AWB, color, low-light, portrait, noise)        │
│        ↓ CIImage                                                                │
│  • MTKView preview (mirrored selfie view)                                       │
│  • CMIOSinkClient.enqueue → CMSimpleQueueEnqueue                                │
└────────────────────────────────────────────────────────────────────────────────┘
                                       ↓ CMSampleBuffer over CMIO sink stream
┌─────── camtune.app/Contents/Library/SystemExtensions/...CameraExtension ───────┐
│  ExtensionSinkStream.consumeSampleBuffer(from:) { callback }                    │
│        ↓                                                                        │
│  ExtensionStreamSource.send(sampleBuffer)                                       │
└────────────────────────────────────────────────────────────────────────────────┘
                                       ↓
                       Zoom / Meet / Teams / Photo Booth
                       (selects "camtune Virtual Camera")
```

The extension also emits a **test pattern** when no host frames are flowing
(host quit, etc.).

## Build / run

```bash
# Default: ad-hoc signed; will NOT be able to install the System Extension
./build.sh

# Real build for testing the virtual camera (requires Developer ID Application
# cert in Keychain + provisioning profiles in repo root):
SIGN_IDENTITY="Developer ID Application: <Your Name> (TEAMID)" ./build.sh
./notarize.sh                     # Apple notarization, ~1-5 min
rm -rf /Applications/camtune.app  # System Extension only works from /Applications
cp -R camtune.app /Applications/
open /Applications/camtune.app
```

`build.sh` auto-bumps `CFBundleVersion` on every run so the OS treats each
rebuild as a new version and replaces the running extension.

### Required user-supplied files (gitignored)

- `embedded.provisionprofile` — Developer ID profile for `com.ghken.camtune`
  with the **App Groups** capability (`group.com.ghken.camtune`).
- `extension.provisionprofile` — Developer ID profile for
  `com.ghken.camtune.CameraExtension` with App Groups.

Both profiles must list the App Group identifier so `CMIOExtensionMachServiceName`
(`964L98DYMA.group.com.ghken.camtune.CameraExtension`) is allowed.

### Entitlements

- Host (`Resources/camtune.entitlements`):
  - `com.apple.security.device.camera`
  - `com.apple.developer.system-extension.install`
  - `com.apple.security.application-groups` = `[964L98DYMA.group.com.ghken.camtune]`
- Extension (`Resources/extension/extension.entitlements`):
  - `com.apple.security.app-sandbox`
  - `com.apple.security.application-groups` (same)

## Hard-won lessons (do not re-litigate)

### 1. Camera Extensions run as `_cmiodalassistants`, NOT the user

macOS runs CMIO Camera Extensions as the `_cmiodalassistants` system daemon
user. This means **none of these work** for host ↔ extension IPC:

| Approach | What happens |
|---|---|
| App Group container (`FileManager.containerURL(...)`) | Host gets `/Users/$USER/Library/Group Containers/...`; extension gets `/private/var/db/cmiodalassistants/Library/Group Containers/...`. **Different paths.** |
| POSIX shm (`shm_open`) | Returns `EPERM` from the extension's sandbox no matter what name. |
| `/Users/Shared/...` filesystem write | Host can write, extension's sandbox blocks with `EPERM`. |
| Vanilla NSXPC on a custom Mach service | Extension can't register additional Mach services beyond `CMIOExtensionMachServiceName`. |

Apple's docs hint at App Groups but in practice they only work for non-Camera
System Extensions. **Use CMIO sink streams.**

### 2. CMIO sink stream activation: callback form, timer-driven, +
   `notifyScheduledOutputChanged`

The `async` form of `stream.consumeSampleBuffer(from: client)` returns
`Invalid not streaming` forever — the framework never transitions the stream
to "streaming" state via that path. You MUST use the **callback form** plus
a `DispatchSourceTimer` polling at ~3x frame rate, and call
`stream.notifyScheduledOutputChanged(output)` after each consume.

Reference implementation: `Sources/CameraExtension/ExtensionDeviceSource.swift`
— modeled directly on OBS Studio's `mac-virtualcam` plugin.

### 3. Host-side stream selection: index 1

After `device.addStream(source); device.addStream(sink)` in the extension,
the host enumerates streams via `CMIODevicePropertyStreams` with **scope =
`kCMIOObjectPropertyScopeGlobal`** (NOT `Input`) and takes `streams[1]`.
Filtering by `kCMIOStreamPropertyDirection` is unreliable — order of
`addStream` calls is the contract.

### 4. CMIO device list is cached per-host-process

After a System Extension reinstall, the running host process **cannot see
the new device via CMIO enumeration** even though Photo Booth (a separate
process) can. The fix is to **relaunch the host app** after install
completes — implemented in `ExtensionManager.relaunchApp()` using
`NSWorkspace.shared.openApplication(at:configuration:)` with
`createsNewApplicationInstance = true`, followed by `NSApp.terminate(nil)`.

Closing the window via the red dot does NOT count — the process keeps
running. Only `⌘Q` (or our auto-relaunch) works.

### 5. System Extensions only install from `/Applications/`

`OSSystemExtensionRequest` returns `unsupportedParentBundleLocation` if the
host app is anywhere else (e.g., `/Users/ghken/dev/camtune/`). The
`./build.sh install` command copies to `/Applications/` automatically.

### 6. Default camera must not be the virtual camera (feedback loop)

`CameraManager.pickInitialDeviceID()` filters out
`FramePipeIPCConstants.virtualCameraName` to avoid the user accidentally
selecting their own augmented output as the input.

### 7. Color temperature direction is counter-intuitive

`CITemperatureAndTint`'s `inputTargetNeutral.x` is the target white point in
Kelvin. Higher value = bluer image (more correction toward warm-source = cooler-output).
This is **scientifically correct** but UI-wise opposite from "warm = high
temperature" expectation. The slider label spells it out:
"色温度 (左:暖色← 6500K →右:寒色)". Built-in presets use the correct
direction (暖色 = 5000K, 寒色 = 8000K).

### 8. Chrome (and Electron apps) cache the camera list at launch

After installing/replacing the Camera Extension, **Chrome must be quit with
`⌘Q` and re-launched** before it sees the new device in
`MediaDevices.enumerateDevices()`. Just closing the window isn't enough.

## File map

```
Sources/
├── Shared/                        Constants used by both targets
│   └── FramePipeProtocol.swift    extensionBundleID, virtualCameraName
├── camtune/                       Host app
│   ├── camtuneApp.swift           @main, WindowGroup
│   ├── Camera/                    AVCaptureSession + MTKView preview
│   ├── Processing/                FilterSettings, FilterPipeline, presets
│   ├── UI/                        SwiftUI views, preset tile grid
│   └── VirtualCamera/             ExtensionManager (install/uninstall),
│                                  CMIOSinkClient, VirtualCameraOutput
└── CameraExtension/               System Extension target
    ├── main.swift                 startService + CFRunLoopRun
    ├── ExtensionProviderSource.swift
    ├── ExtensionDeviceSource.swift   coordinates source + sink streams
    ├── ExtensionStreamSource.swift   thin: delegates to DeviceSource
    └── ExtensionSinkStream.swift     thin: delegates to DeviceSource
Resources/
├── Info.plist                     Host bundle info, NSCameraUsageDescription
├── camtune.entitlements
└── extension/
    ├── Info.plist                 CMIOExtensionMachServiceName, etc.
    └── extension.entitlements
build.sh                            swiftc + bundle structure + ad-hoc/dev-id signing
notarize.sh                         xcrun notarytool submit + stapler staple
```

## Testing checklist

1. `SIGN_IDENTITY=... ./build.sh && ./notarize.sh`
2. Copy to `/Applications/`, launch.
3. Click "更新 / 再インストール" → approve in System Settings → app
   auto-relaunches.
4. **Photo Booth** is the quickest test (it picks up new cameras instantly).
   Select `camtune Virtual Camera` → should show the augmented webcam, not
   the test pattern.
5. Move sliders / click preset tiles → Photo Booth follows live.
6. **Chrome**: quit with `⌘Q`, relaunch, open Meet. `camtune Virtual Camera`
   should be in the camera dropdown.

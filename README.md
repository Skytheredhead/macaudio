# MacAudio (Apple Silicon only)

macOS-first desktop app + HAL AudioServerPlugIn driver that captures live mic input, runs a low-latency vocal chain, and exposes a virtual input device named **Virtual Mic** for Discord and other apps.

## Status

This repo now contains a full project scaffold with:

- SwiftUI desktop app (`/App`)
- real-time audio engine (`/AudioEngine`)
- native DSP chain stub (`/DSP`)
- lock-free shared-memory ring buffer + atomic parameter store (`/Shared`)
- HAL plug-in placeholder driver exposing a virtual input stream (`/Driver`)

The app path is functional for live capture + processing + monitor playback. The driver path is implemented as a minimal AudioServerPlugIn and is structured to become production-ready with more property/clocking hardening.

## Folder Structure

- `/App` SwiftUI app UI and view models
- `/AudioEngine` AVAudioEngine/CoreAudio routing and runtime controller
- `/DSP` C DSP chain (HPF, 3-band EQ, compressor, limiter, optional gate/de-esser stubs)
- `/Driver` AudioServerPlugIn (HAL) virtual input device
- `/Shared` lock-free ring buffer and atomic parameter utilities
- `/scripts` install/uninstall helpers for `.driver`

## Latency Budget (48 kHz default)

At 48 kHz:

- 64 frames: ~1.33 ms per buffer
- 128 frames: ~2.67 ms per buffer
- 256 frames: ~5.33 ms per buffer

End-to-end voice path target is reached by keeping:

- input buffer small (64-128 frames)
- DSP block processing in-buffer (sub-ms CPU)
- ring handoff lock-free (near-zero extra)
- virtual-device read size matched to host IO block

Typical practical round-trip estimate:

`input buffer + DSP + virtual device block + app/client capture block`

For 128-frame blocks this is commonly ~8-15 ms before app-specific jitter; Discord can add extra buffering depending on its own device mode.

## Buffer Strategy (stability vs latency)

Default policy:

- **Balanced**: 128 frames @ 48 kHz
- **Low Latency**: 64 frames (higher CPU risk)
- **Safe/Quality**: 256 frames (best glitch resistance)

`Latency/Quality` slider maps both:

- buffer size (`64/128/256`)
- denoise aggressiveness (lower at low-latency end)

If xruns spike, denoise auto-fallback disables denoise to preserve realtime stability.

## Parameter Smoothing (zipper-noise avoidance)

DSP uses block-time atomic targets + per-sample one-pole smoothing:

- smoothing window: ~8 ms
- parameters read lock-free from atomics
- no locks, no allocations on audio thread

## Monitoring and Feedback Safety

Monitor path is optional and separate gain-controlled.

Recommendation:

- use headphones when monitor is enabled
- keep speaker monitoring off to avoid acoustic feedback loops

## macOS Permissions and Entitlements

App:

- `NSMicrophoneUsageDescription` is set in app `Info.plist`
- app entitlements include audio input entitlement

Driver:

- install location: `/Library/Audio/Plug-Ins/HAL/VirtualMic.driver`
- production distribution requires Developer ID signing + notarization for both app and driver bundle
- uninstall is provided via script

## Build

1. Generate project:

```bash
xcodegen generate
```

2. Build app and driver:

```bash
xcodebuild -project MacAudio.xcodeproj -scheme MacAudio -configuration Debug -destination 'platform=macOS' build
```

All targets are arm64-only via project settings:

- `ARCHS=arm64`
- `VALID_ARCHS=arm64`
- `EXCLUDED_ARCHS[sdk=macosx*]=x86_64`

## Install / Uninstall Driver

Install from a built product:

```bash
./scripts/install_driver.sh ~/Library/Developer/Xcode/DerivedData/<...>/Build/Products/Debug/VirtualMic.driver
```

Uninstall:

```bash
./scripts/uninstall_driver.sh
```

Both scripts restart `coreaudiod`.

## Discord Setup

1. Build + install `VirtualMic.driver`.
2. Launch MacAudio and click **Start**.
3. In Discord: `Settings -> Voice & Video -> Input Device` choose **Virtual Mic**.
4. Disable Discord input auto-processing if you want only MacAudio FX chain.

## Milestone Plan and Skeletons

### 1) Minimal pass-through mic -> monitor

Key files:

- `AudioEngine/AudioEngineController.swift`
- `App/ContentView.swift`

Key APIs:

- `AVAudioEngine`, `AVAudioInputNode.installTap`, `AVAudioSourceNode`

Skeleton:

```swift
engine.inputNode.installTap(onBus: 0, bufferSize: 128, format: format) { buffer, _ in
    // capture -> mono scratch
}
```

### 2) Add DSP chain

Key files:

- `DSP/include/DSPChain.h`
- `DSP/Sources/DSPChain.c`

Key APIs:

- native C DSP, atomics, biquad EQ, compressor/limiter

Skeleton:

```c
DSPChain* chain = dsp_chain_create(sampleRate, 1);
dsp_chain_set_parameters(chain, params);
dsp_chain_process_mono(chain, buffer, frames);
```

### 3) Add meters + UI controls

Key files:

- `App/ContentView.swift`
- `App/ViewModels/MainViewModel.swift`

Key APIs:

- SwiftUI `Slider`, `Toggle`, `ProgressView`
- `DispatchSourceTimer` for meter polling

Skeleton:

```swift
dsp_chain_copy_meters(chain, &meters)
inputPeak = meters.inputPeak
```

### 4) Add virtual device driver

Key files:

- `Driver/VirtualMicDriver.c`
- `Driver/Info.plist`

Key APIs:

- `AudioServerPlugInDriverInterface`
- HAL property model (`GetPropertyData`, `StartIO`, `DoIOOperation`)

Skeleton:

```c
void* VirtualMicDriver_Create(CFAllocatorRef, CFUUIDRef);
static OSStatus VirtualMic_DoIOOperation(...);
```

### 5) Connect engine -> driver via lock-free ring

Key files:

- `Shared/include/VirtualMicRingBuffer.h`
- `Shared/Sources/VirtualMicRingBuffer.c`
- `AudioEngine/AudioEngineController.swift`
- `Driver/VirtualMicDriver.c`

Key APIs:

- `shm_open`, `mmap`, C11 atomics, SPSC ring

Skeleton:

```c
vm_ring_create_writer("/com.skylarenns.macaudio.virtualmic", 8192, 1, &writer);
vm_ring_write(writer, samples, frames);
vm_ring_read(reader, out, frames);
```

### 6) Presets + robustness

Key files:

- `AudioEngine/VoiceProcessingSettings.swift`
- `AudioEngine/AudioEngineController.swift`

Key APIs:

- preset mapping, xrun counters, fallback logic

Skeleton:

```swift
if xruns > threshold {
    settings.denoiseEnabled = false
}
```

## Current Gaps to Production

- Driver property/clock model needs deeper validation against all host clients.
- Install flow should be replaced with signed/notarized installer package.
- Denoiser is lightweight placeholder; RNNoise/CoreML integration still pending.
- Extensive long-run xrun/CPU profiling and Discord matrix testing still needed.

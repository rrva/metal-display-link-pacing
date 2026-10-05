# metal-display-link-pacing

A minimal macOS app that checks whether a `CAMetalLayer` can put a **fresh
frame on screen at every refresh**, using either `CAMetalDisplayLink` or the
classic `CADisplayLink` + `nextDrawable()` path. It draws a sweeping bar so
every frame differs from the last. It records each update's callback time and
`targetPresentationTimestamp`, and when each drawable actually reached the
screen (`MTLDrawable.addPresentedHandler`). Then it prints the on-screen frame
rate, missed refreshes, and the display link's lead.

It was written to check whether a 40-45 fps ceiling seen in a terminal app's
continuous animations on a 60 Hz external display came from the system. **It
doesn't.** This app sustains the full refresh rate in every configuration
below, including the app's own presentation shape. The cause is app-side.

## Run

```sh
swift build -c release
.build/release/PacingRepro --screen 0                     # CAMetalDisplayLink, windowed
.build/release/PacingRepro --screen 0 --fullscreen
.build/release/PacingRepro --screen 0 --mode nextdrawable
.build/release/PacingRepro --screen 0 --producer --thread --srgb --large
```

Each run opens a window for about 7 seconds, prints a summary, and quits. The
last line is `RESULT {json}` for scripting. See the header of
`Sources/PacingRepro/main.swift` for every option.

`--producer` reproduces a common architecture: a main-thread display link
renders into a ring of offscreen textures on one queue. The
`CAMetalDisplayLink` callback blits the latest finished texture into its
drawable on a second queue, and skips the present when nothing new was
published. `--produce-hz N` renders from an N Hz timer instead, to model
rendering per input event.

## Results

MacBook Pro (Apple M2 Max), macOS 27 beta, Xcode beta SDK 27.0. LG UltraFine
4K at 3840x2160, "looks like 1920x1080", 60 Hz. The built-in panel was offline,
so the LG was the only display. `preferredFrameLatency` was 2 and
`maximumDrawableCount` 3 unless noted.

| Configuration | Fresh frames/s on screen | Missed refreshes | Lead (target - callback) | Callback -> on screen |
| --- | --- | --- | --- | --- |
| `CAMetalDisplayLink`, windowed 1200x800 | 59.8-60.0 | 0.0-0.3 % | 49.8 ms (3 refreshes) | 66.5 ms |
| + `--producer` (offscreen render, blit on a 2nd queue) | 60.0 | 0.0 % | 49.8 ms | 66.5 ms |
| + `--thread` (display link on its own thread) | 59.0 | 1.6 % | 49.8 ms | 66.5 ms |
| + `--srgb` (`bgra8Unorm_srgb`, `framebufferOnly = false`) | 59.2 | 1.3 % | 49.8 ms | 66.5 ms |
| + `--large` (3840x2044 drawable) | 59.2 | 1.3 % | 49.8 ms | 66.5 ms |
| producer rendering at 120 / 240 / 61 Hz | 60.0 / 60.0 / 59.8 | 0-0.3 % | 49.9 ms | n/a |
| `--fullscreen` | 59.6 | 0.6 % | 49.8 ms | 49.8 ms |
| `--fullscreen --producer --thread --srgb` | 59.6 | 0.6 % | 49.8 ms | 49.8 ms |

Observations:

- In a window, `CAMetalDisplayLink` targets frames 3 refreshes (49.8 ms) ahead
  of its callback. Apple documents that "the final latency may be bigger if the
  system needs more time, such as for windowed modes on macOS", and accepts only
  1.0 and 2.0 for `preferredFrameLatency`.
- A 3-refresh lead with 3 drawables still sustains 60 fps, so the drawable pool
  is not the limit for a well-behaved presenter.
- Windowed frames reach the screen one refresh after their target time
  (66.5 ms). Fullscreen frames land exactly on the target (49.8 ms), consistent
  with direct scan-out instead of window-server compositing.

### Built-in 120 Hz panel

Same machine, with the external display disconnected: the "Built-in Retina
Display" at 120 Hz.

| Configuration | Fresh frames/s on screen | Missed refreshes | Lead (target - callback) | Callback -> on screen |
| --- | --- | --- | --- | --- |
| `CAMetalDisplayLink`, windowed 1200x800 | 113.3 | 5.6 % | 41.5 ms (5 refreshes) | 41.5 ms |
| `--producer --thread --srgb --large` (3600x2204 drawable) | 114.4 | 4.7 % | 41.5 ms | 41.5 ms |
| `--fullscreen --producer --thread --srgb` | 118.8 | 1.0 % | 41.5 ms | 41.5 ms |

On the 120 Hz panel the windowed lead is 5 refreshes (41.5 ms), and frames
still sustain 94-99 % of the refresh rate.

### Things that do not slow the display link down

All on the built-in 120 Hz panel with `--producer --thread`. "Callbacks" counts
every `CAMetalDisplayLink` callback, including those that had nothing new and
let the drawable go unpresented.

| Added behavior | Callbacks/s | Fresh frames/s on screen |
| --- | --- | --- |
| none | 126 | 119.2-119.4 |
| `--produce-hz 90` (25 % of callbacks skip presenting) | 120 | 89.3 |
| `--produce-hz 60` (50 % skip) | 120 | 60.0 |
| `--poke-paused` (read `isPaused` on every publish and frame) | 126 | 118.7 |
| `--poke-paused --produce-hz 90` | 120 | 89.7 |
| `--poke-range` (assign the tick link's frame-rate range every tick) | 126 | 119.4 |
| `--ca-commit` (move a sibling CALayer every tick) | 126 | 119.2 |
| `METAL_CAPTURE_ENABLED=1` (Metal capture layer active) | n/a | 114.0-119.2 |

With a slower producer, the fresh frame rate equals the producer's rate, but
callbacks stay at the full 120 Hz.

## Display removal

`--scenario unplug` uses the private `CGVirtualDisplay` API (declarations
from Chromium's `virtual_display_mac_util.mm`, in
`Sources/VirtualDisplayShim`) to create a 1920x1080 60 Hz virtual display,
move the window onto it, then remove the display under the window, as when a
cable is pulled. `--hold-virtual-display S` creates one for S seconds without
a window, to pull it from under another app.

On the built-in 120 Hz panel, this app's `CAMetalDisplayLink` returns to
126 callbacks/s after the removal: without rebuilding the link, rebuilding it
on `NSWindow.didChangeScreenNotification` (`--rebuild-on-change`), and also
rebuilding on every `didChangeScreenParameters` (`--rebuild-on-params`).

The window floats above other windows. A window fully hidden behind others
gets its display link throttled to about 4 callbacks/s, which otherwise
corrupts measurements taken while you use other apps. A partly covered window
(`--cover 0.99`) is not throttled.

## License

MIT

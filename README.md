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

The 120 Hz built-in panel was not measured.

## License

MIT

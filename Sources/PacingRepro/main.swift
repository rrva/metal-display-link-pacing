// Minimal repro: can a windowed CAMetalLayer present a fresh frame on every
// refresh? One window, one moving bar, a new frame on every display-link
// update. Records each update's callback and target time and, through
// MTLDrawable.addPresentedHandler, when each drawable actually reached the
// screen. Prints a summary and a machine-readable RESULT line, then quits.
//
//   swift run -c release PacingRepro --mode displaylink --screen 0
//   swift run -c release PacingRepro --mode nextdrawable --screen 1 --fullscreen
//
// Options:
//   --mode displaylink|nextdrawable   CAMetalDisplayLink (default) or a view
//                                     CADisplayLink tick calling nextDrawable()
//   --screen N                        index into NSScreen.screens (default 0)
//   --latency 1|2                     CAMetalDisplayLink.preferredFrameLatency (default 2)
//   --drawables 2|3                   CAMetalLayer.maximumDrawableCount (default 3)
//   --fullscreen                      measure in a native fullscreen space
//   --seconds S                       measurement length (default 5)
//   --warmup S                        settle time before measuring (default 1.5,
//                                     plus 2 more with --fullscreen)
//
// Laban-style presentation (displaylink mode), to find what costs frames:
//   --producer                        a main-thread display link renders each frame
//                                     into an offscreen texture on one queue; the
//                                     present callback blits the latest finished one
//                                     into the drawable on a second queue, and skips
//                                     presenting when nothing new was published
//   --thread                          run the CAMetalDisplayLink on its own thread
//   --srgb                            bgra8Unorm_srgb with framebufferOnly = false
//   --large                           window fills the screen's visible frame
//   --produce-hz N                    with --producer: render from an N Hz timer
//                                     instead of the main display link (Laban
//                                     renders per input event, often above vsync)
//   --poke-paused                     with --producer: read the display link's
//                                     isPaused from the GPU completion handler on
//                                     every publish and from the main thread on
//                                     every produced frame
//   --poke-range                      with --producer: assign the main tick link's
//                                     preferredFrameRateRange (8-120, preferring
//                                     120) and isPaused = false on every tick
//   --ca-commit                       with --producer: move a small sibling
//                                     CALayer on every tick, so the window's layer
//                                     tree commits a Core Animation transaction
//                                     per frame (as AppKit overlays do)
//
// Display removal (displaylink mode, no --producer):
//   --scenario unplug                 measure on --screen, then create a virtual
//                                     60 Hz display, move the window onto it and
//                                     measure, then remove the display while the
//                                     window is on it (macOS moves the window
//                                     back, as on a cable unplug) and measure again
//   --rebuild-on-change               recreate the CAMetalDisplayLink whenever the
//                                     window changes screen
//   --rebuild-on-params               also recreate it on every
//                                     NSApplication.didChangeScreenParameters
//   --hold-virtual-display S          no window: create a virtual 1920x1080 60 Hz
//                                     display, print its display ID, keep it for S
//                                     seconds, then remove it (to unplug it from
//                                     under another app's window)
//   --cover F                         cover fraction F (0-1) of the window's width
//                                     with a second opaque window floating above it

import AppKit
import Metal
import QuartzCore
import VirtualDisplayShim

// MARK: - Options

struct Options {
  enum Mode: String { case displaylink, nextdrawable }
  var mode = Mode.displaylink
  var screen = 0
  var latency: Float = 2
  var drawables = 3
  var fullscreen = false
  var seconds = 5.0
  var warmup = 1.5
  var producer = false
  var thread = false
  var srgb = false
  var large = false
  var produceHz = 0.0
  var pokePaused = false
  var pokeRange = false
  var caCommit = false
  var scenario = ""
  var rebuildOnChange = false
  var cover = 0.0
  var rebuildOnParams = false
  var holdVirtualDisplay = 0.0

  init(_ args: [String]) {
    var i = 1
    func value() -> String {
      i += 1
      guard i < args.count else { fatalError("missing value for \(args[i - 1])") }
      return args[i]
    }
    while i < args.count {
      switch args[i] {
      case "--mode": mode = Mode(rawValue: value()) ?? { fatalError("bad --mode") }()
      case "--screen": screen = Int(value())!
      case "--latency": latency = Float(value())!
      case "--drawables": drawables = Int(value())!
      case "--fullscreen": fullscreen = true
      case "--seconds": seconds = Double(value())!
      case "--warmup": warmup = Double(value())!
      case "--producer": producer = true
      case "--thread": thread = true
      case "--srgb": srgb = true
      case "--large": large = true
      case "--produce-hz": produceHz = Double(value())!
      case "--poke-paused": pokePaused = true
      case "--poke-range": pokeRange = true
      case "--ca-commit": caCommit = true
      case "--scenario": scenario = value()
      case "--rebuild-on-change": rebuildOnChange = true
      case "--cover": cover = Double(value())!
      case "--rebuild-on-params": rebuildOnParams = true
      case "--hold-virtual-display": holdVirtualDisplay = Double(value())!
      default: fatalError("unknown option \(args[i])")
      }
      i += 1
    }
  }
}

// MARK: - Recording

struct Present {
  var callback: Double
  var target: Double  // 0 in nextdrawable mode
  var onGlass: Double  // MTLDrawable.presentedTime; 0 means dropped
}

final class Recorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recording = false
  private var presents: [Present] = []
  private var callbacks = 0
  private var skipped = 0

  /// Every display-link callback while recording, including ones that skip.
  func countCallback(presented: Bool) {
    lock.lock()
    if recording {
      callbacks += 1
      if !presented { skipped += 1 }
    }
    lock.unlock()
  }

  var callbackCounts: (all: Int, skipped: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (callbacks, skipped)
  }

  func start() {
    lock.lock()
    presents.removeAll()
    callbacks = 0
    skipped = 0
    recording = true
    lock.unlock()
  }

  func stop() -> [Present] {
    lock.lock()
    defer { lock.unlock() }
    recording = false
    return presents
  }

  func track(_ drawable: MTLDrawable, callback: Double, target: Double) {
    lock.lock()
    let active = recording
    lock.unlock()
    guard active else { return }
    drawable.addPresentedHandler { [weak self] d in
      guard let self else { return }
      self.lock.lock()
      if self.recording {
        self.presents.append(Present(callback: callback, target: target, onGlass: d.presentedTime))
      }
      self.lock.unlock()
    }
  }
}

// MARK: - Rendering

let shaderSource = """
  #include <metal_stdlib>
  using namespace metal;
  vertex float4 bar_vertex(uint vid [[vertex_id]], constant float &x [[buffer(0)]]) {
    float2 corners[6] = { {-1, -1}, {1, -1}, {-1, 1}, {1, -1}, {1, 1}, {-1, 1} };
    float2 c = corners[vid];
    return float4(x + c.x * 0.03, c.y, 0, 1);
  }
  fragment float4 bar_fragment() { return float4(1, 1, 1, 1); }
  """

final class Renderer {
  let device: MTLDevice
  let queue: MTLCommandQueue
  let pipeline: MTLRenderPipelineState

  init(layer: CAMetalLayer) {
    device = MTLCreateSystemDefaultDevice()!
    queue = device.makeCommandQueue()!
    let library = try! device.makeLibrary(source: shaderSource, options: nil)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "bar_vertex")
    descriptor.fragmentFunction = library.makeFunction(name: "bar_fragment")
    descriptor.colorAttachments[0].pixelFormat = layer.pixelFormat
    pipeline = try! device.makeRenderPipelineState(descriptor: descriptor)
    layer.device = device
  }

  /// Draws a bar sweeping left and right, so every frame differs from the last.
  func draw(into drawable: CAMetalDrawable, time: Double) -> MTLCommandBuffer {
    draw(into: drawable.texture, time: time)
  }

  func draw(into texture: MTLTexture, time: Double) -> MTLCommandBuffer {
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)
    let buffer = queue.makeCommandBuffer()!
    let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)!
    var x = Float(sin(time * .pi))
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBytes(&x, length: MemoryLayout<Float>.size, index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    encoder.endEncoding()
    return buffer
  }
}

// MARK: - Drivers

/// CAMetalDisplayLink: the system hands over a drawable plus the time the frame
/// will be shown, `preferredFrameLatency` frames ahead (in theory).
final class DisplayLinkDriver: NSObject, CAMetalDisplayLinkDelegate {
  var link: CAMetalDisplayLink!
  let layer: CAMetalLayer
  let renderer: Renderer
  let recorder: Recorder
  let latency: Float
  private(set) var rebuilds = 0

  init(layer: CAMetalLayer, renderer: Renderer, recorder: Recorder, options: Options, fps: Int) {
    self.layer = layer
    self.renderer = renderer
    self.recorder = recorder
    latency = options.latency
    super.init()
    attach()
  }

  private func attach() {
    link = CAMetalDisplayLink(metalLayer: layer)
    link.delegate = self
    link.preferredFrameLatency = latency
    // 120 is the highest rate any attached panel offers here; the link runs at
    // the window's display rate when that is lower.
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
    link.add(to: .main, forMode: .common)
  }

  /// Replace the link with a fresh one bound to the layer's current display.
  func rebuild() {
    link.invalidate()
    attach()
    rebuilds += 1
  }

  func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
    let now = CACurrentMediaTime()
    let buffer = renderer.draw(into: update.drawable, time: update.targetPresentationTimestamp)
    recorder.track(update.drawable, callback: now, target: update.targetPresentationTimestamp)
    buffer.present(update.drawable)
    buffer.commit()
    recorder.countCallback(presented: true)
  }
}

/// Laban's shape: a main-thread display link renders into a ring of offscreen
/// targets on `queue`; the GPU completion handler publishes the target; the
/// CAMetalDisplayLink callback blits the latest published target into its
/// drawable on a second queue, and skips the present when nothing new arrived.
final class ProducerDriver: NSObject, CAMetalDisplayLinkDelegate {
  let renderer: Renderer
  let recorder: Recorder
  let presentQueue: MTLCommandQueue
  var link: CAMetalDisplayLink!
  var tick: CADisplayLink?
  var timer: DispatchSourceTimer?
  var ring: [MTLTexture] = []
  var ringIndex = 0
  let lock = NSLock()
  var published: MTLTexture?
  var publishedVersion = 0
  var presentedVersion = 0
  let inFlight = DispatchSemaphore(value: 1)
  let pokePaused: Bool
  let pokeRange: Bool
  var overlay: CALayer?

  init(view: NSView, layer: CAMetalLayer, renderer: Renderer, recorder: Recorder, options: Options, fps: Int) {
    self.renderer = renderer
    self.recorder = recorder
    presentQueue = renderer.device.makeCommandQueue()!
    pokePaused = options.pokePaused
    pokeRange = options.pokeRange
    super.init()
    if options.caCommit {
      let overlay = CALayer()
      overlay.backgroundColor = CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1)
      overlay.frame = CGRect(x: 20, y: 20, width: 40, height: 40)
      layer.addSublayer(overlay)
      self.overlay = overlay
    }
    let size = layer.drawableSize
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: layer.pixelFormat, width: Int(size.width), height: Int(size.height), mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .private
    ring = (0..<3).map { _ in renderer.device.makeTexture(descriptor: descriptor)! }
    link = CAMetalDisplayLink(metalLayer: layer)
    link.delegate = self
    link.preferredFrameLatency = options.latency
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: Float(fps), preferred: Float(fps))
    if options.thread {
      let t = Thread { [link] in
        link!.add(to: .current, forMode: .common)
        RunLoop.current.run()
      }
      t.qualityOfService = .userInteractive
      t.start()
    } else {
      link.add(to: .main, forMode: .common)
    }
    if options.produceHz > 0 {
      let timer = DispatchSource.makeTimerSource(queue: .main)
      timer.schedule(deadline: .now(), repeating: 1 / options.produceHz, leeway: .nanoseconds(0))
      timer.setEventHandler { [weak self] in self?.render(time: CACurrentMediaTime()) }
      timer.resume()
      self.timer = timer
    } else {
      tick = view.displayLink(target: self, selector: #selector(produce))
      tick?.add(to: .main, forMode: .common)
    }
  }

  @objc func produce(_ tick: CADisplayLink) {
    if let overlay {
      overlay.position = CGPoint(x: 40 + 30 * sin(tick.targetTimestamp * 4), y: 40)
    }
    if pokeRange {
      tick.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 120, preferred: 120)
      tick.isPaused = false
    }
    render(time: tick.targetTimestamp)
  }

  func render(time: Double) {
    if pokePaused, link.isPaused { link.isPaused = false }
    inFlight.wait()
    let target = ring[ringIndex]
    ringIndex = (ringIndex + 1) % ring.count
    let buffer = renderer.draw(into: target, time: time)
    buffer.addCompletedHandler { [weak self, inFlight] _ in
      if let self {
        self.lock.lock()
        self.published = target
        self.publishedVersion += 1
        self.lock.unlock()
        if self.pokePaused, self.link.isPaused { self.link.isPaused = false }
      }
      inFlight.signal()
    }
    buffer.commit()
  }

  func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
    let now = CACurrentMediaTime()
    lock.lock()
    let source = published
    let version = publishedVersion
    lock.unlock()
    guard let source, version != presentedVersion else {
      recorder.countCallback(presented: false)
      return
    }
    presentedVersion = version
    let buffer = presentQueue.makeCommandBuffer()!
    let blit = buffer.makeBlitCommandEncoder()!
    blit.copy(from: source, to: update.drawable.texture)
    blit.endEncoding()
    recorder.track(update.drawable, callback: now, target: update.targetPresentationTimestamp)
    buffer.present(update.drawable)
    buffer.commit()
    recorder.countCallback(presented: true)
  }
}

/// The classic path: a view display link ticks, the app asks the layer for
/// the next free drawable (blocking until one is free) and presents it.
final class NextDrawableDriver: NSObject {
  let layer: CAMetalLayer
  let renderer: Renderer
  let recorder: Recorder
  var link: CADisplayLink?

  init(view: NSView, layer: CAMetalLayer, renderer: Renderer, recorder: Recorder) {
    self.layer = layer
    self.renderer = renderer
    self.recorder = recorder
    super.init()
    link = view.displayLink(target: self, selector: #selector(tick))
    link?.add(to: .main, forMode: .common)
  }

  @objc func tick(_ link: CADisplayLink) {
    let now = CACurrentMediaTime()
    guard let drawable = layer.nextDrawable() else { return }
    let buffer = renderer.draw(into: drawable, time: link.targetTimestamp)
    recorder.track(drawable, callback: now, target: 0)
    buffer.present(drawable)
    buffer.commit()
  }
}

// MARK: - Report

func percentile(_ values: [Double], _ p: Double) -> Double {
  guard !values.isEmpty else { return 0 }
  let s = values.sorted()
  return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
}

func report(
  _ presents: [Present], callbacks: (all: Int, skipped: Int), options: Options, screen: NSScreen,
  fullscreenActive: Bool, layer: CAMetalLayer
) {
  let fps = screen.maximumFramesPerSecond
  let refresh = 1.0 / Double(fps)
  let shown = presents.filter { $0.onGlass > 0 }.map(\.onGlass).sorted()
  let dropped = presents.count - shown.count
  let gaps = zip(shown, shown.dropFirst()).map { ($1 - $0) / refresh }
  var histogram: [Int: Int] = [:]
  for g in gaps { histogram[Int(g.rounded()), default: 0] += 1 }
  let refreshesSpanned = gaps.reduce(0) { $0 + max(1, Int($1.rounded())) }
  let missed = refreshesSpanned - gaps.count
  let span = (shown.last ?? 0) - (shown.first ?? 0)
  let shownPerSecond = span > 0 ? Double(shown.count - 1) / span : 0
  let toGlass = presents.filter { $0.onGlass > 0 }.map { ($0.onGlass - $0.callback) * 1000 }
  let lead = presents.filter { $0.target > 0 }.map { ($0.target - $0.callback) * 1000 }

  let fmt = { (v: Double) in String(format: "%.1f", v) }
  print("""
    display      \(screen.localizedName), \(fps) Hz, scale \(screen.backingScaleFactor)
    window       \(fullscreenActive ? "fullscreen" : "windowed")\(options.cover > 0 ? ", \(Int(options.cover * 100))% covered" : ""), drawable \(Int(layer.drawableSize.width))x\(Int(layer.drawableSize.height))
    path         \(options.mode.rawValue)\(options.producer ? "+producer" : "")\(options.thread ? "+thread" : "")\(options.srgb ? "+srgb" : "")\(options.pokePaused ? "+poke-paused" : "")\(options.pokeRange ? "+poke-range" : "")\(options.caCommit ? "+ca-commit" : "")\(options.produceHz > 0 ? " produce \(Int(options.produceHz)) Hz" : ""), latency \(options.latency), maximumDrawableCount \(layer.maximumDrawableCount)
    frames       \(presents.count) presented, \(shown.count) on glass, \(dropped) dropped
    rate         \(fmt(shownPerSecond)) fresh frames/s on glass (display \(fps) Hz)
    missed       \(missed) of \(refreshesSpanned) refreshes (\(fmt(100 * Double(missed) / Double(max(1, refreshesSpanned))))%)
    gaps         \(histogram.sorted { $0.key < $1.key }.map { "\($0.key) refresh: \($0.value)" }.joined(separator: ", "))
    callbacks    \(String(format: "%.1f", Double(callbacks.all) / options.seconds))/s, \(callbacks.skipped) skipped (nothing new to present)
    to glass     callback -> on glass p50 \(fmt(percentile(toGlass, 0.5))) ms, p95 \(fmt(percentile(toGlass, 0.95))) ms
    """)
  if !lead.isEmpty {
    print(
      "lead         target - callback p50 \(fmt(percentile(lead, 0.5))) ms (\(fmt(percentile(lead, 0.5) / (refresh * 1000))) refreshes)"
    )
  }
  let result: [String: Any] = [
    "display": screen.localizedName, "hz": fps, "fullscreen": fullscreenActive,
    "mode": options.mode.rawValue, "producer": options.producer, "thread": options.thread,
    "srgb": options.srgb, "large": options.large, "produceHz": options.produceHz, "latency": options.latency, "drawables": layer.maximumDrawableCount,
    "shownPerSecond": shownPerSecond, "missedPercent": 100 * Double(missed) / Double(max(1, refreshesSpanned)),
    "dropped": dropped, "toGlassP50Ms": percentile(toGlass, 0.5),
    "leadP50Ms": percentile(lead, 0.5), "callbacksPerSecond": Double(callbacks.all) / options.seconds,
    "skippedCallbacks": callbacks.skipped, "pokePaused": options.pokePaused,
  ]
  let json = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
  print("RESULT " + String(data: json, encoding: .utf8)!)
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
  let options = Options(CommandLine.arguments)
  let recorder = Recorder()
  var window: NSWindow!
  var layer: CAMetalLayer!
  var renderer: Renderer!
  var driver: AnyObject?

  func applicationDidFinishLaunching(_ notification: Notification) {
    if options.holdVirtualDisplay > 0 {
      let display = makeVirtualDisplay()
      virtualDisplay = display
      print("virtual display \(display.displayID) created; removing in \(options.holdVirtualDisplay) s")
      fflush(stdout)
      DispatchQueue.main.asyncAfter(deadline: .now() + options.holdVirtualDisplay) { [self] in
        virtualDisplay = nil
        print("virtual display removed")
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
      }
      return
    }
    let screens = NSScreen.screens
    guard options.screen < screens.count else {
      print("screen \(options.screen) not found; screens: \(screens.map(\.localizedName))")
      exit(2)
    }
    let screen = screens[options.screen]
    let frame: NSRect
    if options.large {
      frame = screen.visibleFrame
    } else {
      frame = NSRect(
        x: screen.frame.midX - 600, y: screen.frame.midY - 400, width: 1200, height: 800)
    }
    let size = frame.size
    window = NSWindow(
      contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered,
      defer: false, screen: screen)
    window.title = "PacingRepro"
    window.collectionBehavior = [.fullScreenPrimary]

    layer = CAMetalLayer()
    layer.pixelFormat = options.srgb ? .bgra8Unorm_srgb : .bgra8Unorm
    layer.isOpaque = true
    layer.framebufferOnly = !(options.srgb || options.producer)
    layer.maximumDrawableCount = options.drawables
    let view = NSView(frame: NSRect(origin: .zero, size: size))
    view.layer = layer
    view.wantsLayer = true
    window.contentView = view
    renderer = Renderer(layer: layer)
    updateDrawableSize()
    NotificationCenter.default.addObserver(
      forName: NSWindow.didResizeNotification, object: window, queue: .main
    ) { [weak self] _ in self?.updateDrawableSize() }

    // Float above other windows: a window left behind others (macOS will not
    // activate a background launch while the user is typing elsewhere) gets
    // its display link throttled to a few callbacks a second.
    window.level = .floating
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    NSApp.activate(ignoringOtherApps: true)
    if options.fullscreen { window.toggleFullScreen(nil) }

    switch options.mode {
    case .displaylink where options.producer:
      driver = ProducerDriver(
        view: view, layer: layer, renderer: renderer, recorder: recorder, options: options,
        fps: screen.maximumFramesPerSecond)
    case .displaylink:
      driver = DisplayLinkDriver(
        layer: layer, renderer: renderer, recorder: recorder, options: options,
        fps: screen.maximumFramesPerSecond)
    case .nextdrawable:
      driver = NextDrawableDriver(view: view, layer: layer, renderer: renderer, recorder: recorder)
    }

    if options.cover > 0 {
      let f = window.frame
      let cover = NSWindow(
        contentRect: NSRect(x: f.minX, y: f.minY - 1, width: f.width * options.cover, height: f.height + 2),
        styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
      cover.backgroundColor = NSColor(calibratedWhite: 0.85, alpha: 1)
      cover.isOpaque = true
      cover.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
      cover.orderFrontRegardless()
      coverWindow = cover
    }

    if options.scenario == "unplug" {
      runUnplugScenario(home: screen)
      return
    }

    let warmup = options.warmup + (options.fullscreen ? 2 : 0)
    DispatchQueue.main.asyncAfter(deadline: .now() + warmup) { [self] in
      recorder.start()
      DispatchQueue.main.asyncAfter(deadline: .now() + options.seconds) { [self] in
        let callbacks = recorder.callbackCounts
        let presents = recorder.stop()
        // Let the last presented handlers land.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
          report(
            presents, callbacks: callbacks, options: options, screen: window.screen ?? screen,
            fullscreenActive: window.styleMask.contains(.fullScreen), layer: layer)
          exit(0)
        }
      }
    }
  }

  // MARK: Display removal scenario

  var virtualDisplay: CGVirtualDisplay?
  var coverWindow: NSWindow?

  /// Measure callbacks and fresh on-glass frames for `seconds`.
  func measurePhase(_ name: String, seconds: Double, then next: @escaping () -> Void) {
    recorder.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
      let callbacks = recorder.callbackCounts
      let presents = recorder.stop()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
        let rate = Double(presents.filter { $0.onGlass > 0 }.count) / seconds
        let screen = window.screen
        let rebuilds = (driver as? DisplayLinkDriver)?.rebuilds ?? 0
        let visible = window.occlusionState.contains(.visible)
        print(String(
          format: "%-22@ screen %-26@ %3d Hz | callbacks %6.1f/s | fresh on glass %6.1f/s | link rebuilds %d | visible %@",
          name as NSString, (screen?.localizedName ?? "none") as NSString,
          screen?.maximumFramesPerSecond ?? 0, Double(callbacks.all) / seconds, rate, rebuilds,
          (visible ? "yes" : "NO") as NSString))
        next()
      }
    }
  }

  func waitUntil(_ timeout: Double, _ condition: @escaping () -> Bool, then next: @escaping (Bool) -> Void) {
    let deadline = Date().addingTimeInterval(timeout)
    func poll() {
      if condition() { return next(true) }
      if Date() > deadline { return next(false) }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
    }
    poll()
  }

  /// A virtual 1920x1080 60 Hz display; it disappears when released.
  func makeVirtualDisplay() -> CGVirtualDisplay {
    let descriptor = CGVirtualDisplayDescriptor()
    descriptor.queue = DispatchQueue.global(qos: .userInteractive)
    descriptor.name = "PacingRepro virtual"
    descriptor.maxPixelsWide = 1920
    descriptor.maxPixelsHigh = 1080
    descriptor.sizeInMillimeters = CGSize(width: 527, height: 296)
    descriptor.whitePoint = CGPoint(x: 0.3125, y: 0.3291)
    descriptor.redPrimary = CGPoint(x: 0.6797, y: 0.3203)
    descriptor.greenPrimary = CGPoint(x: 0.2559, y: 0.6983)
    descriptor.bluePrimary = CGPoint(x: 0.1494, y: 0.0557)
    descriptor.vendorID = 0x1234
    descriptor.productID = 0x5678
    descriptor.serialNum = 1
    let display = CGVirtualDisplay(descriptor: descriptor)
    let settings = CGVirtualDisplaySettings()
    settings.hiDPI = 0
    settings.modes = [CGVirtualDisplayMode(width: 1920, height: 1080, refreshRate: 60)]
    guard display.apply(settings) else {
      print("virtual display: applySettings failed")
      exit(3)
    }
    return display
  }

  func runUnplugScenario(home: NSScreen) {
    print("displays at start: \(NSScreen.screens.map { "\($0.localizedName) \($0.maximumFramesPerSecond) Hz" })")
    if options.rebuildOnChange {
      NotificationCenter.default.addObserver(
        forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
      ) { [weak self] _ in (self?.driver as? DisplayLinkDriver)?.rebuild() }
    }
    if options.rebuildOnParams {
      NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
      ) { [weak self] _ in (self?.driver as? DisplayLinkDriver)?.rebuild() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + options.warmup) { [self] in
      measurePhase("1 before", seconds: 2) { [self] in
        let display = makeVirtualDisplay()
        virtualDisplay = display
        let id = display.displayID
        func virtualScreen() -> NSScreen? {
          NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
          }
        }
        waitUntil(5, { virtualScreen() != nil }) { [self] found in
          guard found, let target = virtualScreen() else {
            print("virtual display \(id) never appeared as an NSScreen")
            exit(3)
          }
          let f = target.visibleFrame
          window.setFrame(
            NSRect(x: f.minX + 40, y: f.minY + 40, width: 1200, height: 700), display: true)
          waitUntil(5, { [self] in window.screen == target }) { [self] moved in
            if !moved { print("window did not move to the virtual display") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
              measurePhase("2 on virtual display", seconds: 2) { [self] in
                // Remove the display under the window, like pulling the cable.
                virtualDisplay = nil
                waitUntil(5, { [self] in window.screen != nil && window.screen != target }) { [self] _ in
                  DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                    measurePhase("3 after removal", seconds: 2) { [self] in
                      DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self] in
                        measurePhase("4 removal + 7 s", seconds: 2) { exit(0) }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  func updateDrawableSize() {
    let scale = window.backingScaleFactor
    layer.contentsScale = scale
    let bounds = window.contentView!.bounds
    layer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

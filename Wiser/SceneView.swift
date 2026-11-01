//
//  SceneView.swift
//  Wiser
//
//  Created by Marlin on 19/10/2026.
//

import SwiftUI
import Metal
import MetalKit
import QuartzCore

/// The home screen's scene, behind everything else on it: the sky and the ground the stones stand on,
/// meeting with no line between them, and the stones, all seen with the stones' camera.
struct SceneView: UIViewRepresentable {
    var scene: Rock3DScene
    var tint: Color
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> SceneRenderer {
        SceneRenderer(scene: scene)
    }

    func updateUIView(_ view: SceneRenderer, context: Context) {
        view.show(SceneLook(tint: tint, isDark: colorScheme == .dark))
    }
}

/// The colors the scene is painted in, from the sky's tint, in linear light.
struct SceneLook: Equatable {
    var skyTop: SIMD3<Float>
    var skyHorizon: SIMD3<Float>
    var isDark: Bool

    init(tint: Color, isDark: Bool) {
        let traits = UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
        func components(_ color: UIColor) -> SIMD3<Float> {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
            return SIMD3(Float(r), Float(g), Float(b))
        }
        func decode(_ c: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(c.indices.map { i in c[i] <= 0.04045 ? c[i] / 12.92 : pow((c[i] + 0.055) / 1.055, 2.4) })
        }
        let paper = components(.secondarySystemBackground)
        let sky = components(UIColor(tint))
        let wash = AmbientBackground.wash(for: isDark ? .dark : .light)
        // The same washes of the tint over the paper as the other screens, high up and low down.
        func washed(_ amount: Double) -> SIMD3<Float> {
            paper + (sky - paper) * Float(amount)
        }
        // By night the sky is darkest overhead, as a night sky is; the tint washed in more strongly high up,
        // as on the other screens, would only pale it there, like haze hanging over the scene.
        skyTop = decode(washed(isDark ? wash.middle * 0.5 : wash.top))
        skyHorizon = decode(washed(wash.middle))
        self.isDark = isDark
    }

    /// The sky at the horizon, as the screen shows it.
    var horizonColor: UIColor {
        func encoded(_ c: Float) -> CGFloat {
            CGFloat(c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055)
        }
        return UIColor(red: encoded(skyHorizon.x), green: encoded(skyHorizon.y), blue: encoded(skyHorizon.z), alpha: 1)
    }

    /// These colors moved on toward `look`'s by `elapsed` seconds, so the sky changes gently, following
    /// them over a second or two.
    func eased(toward look: SceneLook, by elapsed: CFTimeInterval) -> SceneLook {
        let share = 1 - exp(-Float(min(elapsed, 0.1)) / 1.5)
        func toward(_ from: SIMD3<Float>, _ to: SIMD3<Float>) -> SIMD3<Float> {
            let next = from + (to - from) * share
            return simd_reduce_max(simd_abs(to - next)) < 0.002 ? to : next
        }
        var colors = self
        colors.skyTop = toward(skyTop, look.skyTop)
        colors.skyHorizon = toward(skyHorizon, look.skyHorizon)
        return colors
    }
}

/// The home screen's scene with no stones in it, behind the screens beside it, so they're all one scene.
struct OpenSceneView: UIViewRepresentable {
    var scene: Rock3DScene
    var tint: Color
    var daylight: Daylight
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> OpenSceneRenderer {
        OpenSceneRenderer(scene: scene)
    }

    func updateUIView(_ view: OpenSceneRenderer, context: Context) {
        let isDark = colorScheme == .dark
        view.show(SceneLook(tint: tint, isDark: isDark),
                  lighting: Rock3DScene.lighting(sky: Rock3DScene.linear(tint, isDark: isDark), daylight: daylight))
    }
}

/// Draws the home screen's scene with no stones in it: the sky, and the ground as open to it as it is
/// away from them, with the horizon where it is on the home screen. All in one pass (see
/// `openSceneFragment`), only when its colors or its light change.
final class OpenSceneRenderer: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private let scene: Rock3DScene
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let grain: MTLTexture
    /// The scene's colors now, and as drawn, which follow them as the home screen's do.
    private var look: SceneLook?
    private var shownLook: SceneLook?
    private var lighting: Rock3DScene.Lighting?
    private var displayLink: CADisplayLink?
    private var previousTimestamp: CFTimeInterval?

    private var metalLayer: CAMetalLayer {
        layer as! CAMetalLayer
    }

    init(scene: Rock3DScene) {
        self.scene = scene
        let device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        let library = device.makeDefaultLibrary()!
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "displayVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "openSceneFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try! device.makeRenderPipelineState(descriptor: descriptor)
        let blank = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false)
        blank.usage = .shaderRead
        grain = UIImage(named: "NoiseTexture")?.cgImage.flatMap {
            try? MTKTextureLoader(device: device).newTexture(cgImage: $0, options: [.SRGB: false])
        } ?? device.makeTexture(descriptor: blank)!
        super.init(frame: .zero)

        isOpaque = true
        isUserInteractionEnabled = false
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        // Each picture shows with the rest of the screen as it is laid out: the first one with the page, which
        // otherwise came up for a frame with nothing behind it, white.
        metalLayer.presentsWithTransaction = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ look: SceneLook, lighting: Rock3DScene.Lighting) {
        guard look != self.look || lighting != self.lighting else { return }
        self.look = look
        self.lighting = lighting
        if shownLook == nil || shownLook?.isDark != look.isDark {
            shownLook = look
        }
        // Under the picture, the sky at the horizon, in case it's ever a moment late.
        backgroundColor = look.horizonColor
        run()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            displayLink?.invalidate()
            displayLink = nil
        } else {
            setNeedsLayout()
            run()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        // Drawn now, as the page is laid out, so it comes up with its picture rather than a frame later.
        if window != nil {
            draw()
        }
        run()
    }

    /// Draws frames until the colors as drawn have caught up with the colors now.
    private func run() {
        guard window != nil, displayLink == nil else { return }
        previousTimestamp = nil
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let elapsed = previousTimestamp.map { link.timestamp - $0 } ?? 0
        previousTimestamp = link.timestamp
        if let look, let colors = shownLook, colors != look {
            shownLook = colors.eased(toward: look, by: elapsed)
        }
        draw()
        if shownLook == look {
            link.invalidate()
            displayLink = nil
        }
    }

    private func draw() {
        // Where the stones stand on the home screen, which puts the horizon where it is there.
        let band = scene.band.isEmpty ? .zero : convert(scene.band, from: nil)
        guard let look = shownLook, let lighting, band.height > 0, metalLayer.drawableSize.width > 0,
              let drawable = metalLayer.nextDrawable(), let commands = queue.makeCommandBuffer() else { return }
        var uniforms = SceneRenderer.traceUniforms(look: look, lighting: lighting, camera: scene.camera, band: band,
                                                   pixelsPerPoint: metalLayer.contentsScale, screen: drawable.texture)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TraceUniforms>.stride, index: 0)
            encoder.setFragmentTexture(grain, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        commands.commit()
        commands.waitUntilScheduled()
        drawable.present()
    }
}

/// Draws the home screen's scene as light travels through it (see PathTracer.swift), only when
/// something in it changes.
final class SceneRenderer: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private let scene: Rock3DScene
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let copy: MTLRenderPipelineState
    private let tracer: PathTracer
    private var isLoadingShapes = false
    /// The picture as last drawn.
    private var background: MTLTexture?
    private let blank: MTLTexture
    private let grain: MTLTexture?
    /// Counts frames as they finish being drawn.
    private let drawn: MTLSharedEvent
    private var frameNumber: UInt64 = 0
    private var displayLink: CADisplayLink?
    private var previousTimestamp: CFTimeInterval?
    /// The scene's colors now, and as drawn, which follow them over a second or two, so the sky changes
    /// gently.
    private var look: SceneLook?
    private var shownLook: SceneLook?
    /// Whether the next picture has to start over rather than carry on from the last.
    private var startOver = true
    /// Whether something the picture is made from may have changed since it was last drawn, as when the
    /// sky or the light moves on: it's drawn again, and carries on drawing if it has.
    private var redraw = true
    private var moving = false

    private var metalLayer: CAMetalLayer {
        layer as! CAMetalLayer
    }

    init(scene: Rock3DScene) {
        self.scene = scene
        let device = MTLCreateSystemDefaultDevice()!
        self.device = device
        queue = device.makeCommandQueue()!
        drawn = device.makeSharedEvent()!
        let library = device.makeDefaultLibrary()!
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "sceneVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "copyFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        copy = try! device.makeRenderPipelineState(descriptor: descriptor)
        tracer = PathTracer(device: device, library: library)
        let blankDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false)
        blankDescriptor.usage = .shaderRead
        blank = device.makeTexture(descriptor: blankDescriptor)!
        grain = UIImage(named: "NoiseTexture")?.cgImage.flatMap {
            try? MTKTextureLoader(device: device).newTexture(cgImage: $0, options: [.SRGB: false])
        }
        super.init(frame: .zero)

        isOpaque = true
        isUserInteractionEnabled = false
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        scene.onWake = { [weak self] in
            self?.run()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ look: SceneLook) {
        guard look != self.look else { return }
        self.look = look
        if shownLook == nil || shownLook?.isDark != look.isDark {
            shownLook = look
            startOver = true
        }
        run()
    }

    /// Moves the scene's colors as drawn on toward its colors now by `elapsed` seconds.
    private func easeLook(_ elapsed: CFTimeInterval) {
        guard let look, let colors = shownLook, colors != look else { return }
        shownLook = colors.eased(toward: look, by: elapsed)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            displayLink?.invalidate()
            displayLink = nil
        } else {
            setNeedsLayout()
            run()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        run()
    }

    // MARK: Drawing

    /// Whether the sky as drawn is still on its way to the sky now.
    private var isEasing: Bool {
        shownLook != look
    }

    /// The stones' poses the light carried over is worked out for, in the order they rise through.
    private static let poseOrder: [RockState] = [.idle, .paused, .checked]

    /// How dark the stones are in dark mode, as a share of how much light the pale stones throw back.
    private static let darkStone: Float = 0.22

    /// How much light the stones throw back, before their grain, and their grain on average.
    private static let stoneAlbedo: Float = 0.9
    private static let grainAlbedo: Float = {
        let pixels = Rock3DScene.surfacePixels.colors
        func linear(_ v: UInt8) -> Double {
            let c = Double(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        var total: Double = 0, count = 0
        for i in stride(from: 0, to: pixels.count - 3, by: 4 * 7) {
            total += 0.2126 * linear(pixels[i]) + 0.7152 * linear(pixels[i + 1]) + 0.0722 * linear(pixels[i + 2])
            count += 1
        }
        return Float(total / Double(max(count, 1)))
    }()

    /// Draws frames for as long as something moves or the picture is still settling, sixty a second.
    private func run() {
        redraw = true
        guard window != nil else { return }
        if displayLink == nil {
            previousTimestamp = nil
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let elapsed = previousTimestamp.map { link.timestamp - $0 } ?? 0
        previousTimestamp = link.timestamp
        moving = scene.step(elapsed)
        easeLook(elapsed)
        loadShapes()
        // Never wait for the screen: while two frames are still being drawn, let this one go.
        if frameNumber - drawn.signaledValue < 2 {
            draw()
        }
        if moving || tracer.isSettling || isLoadingShapes || redraw || isEasing {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        } else {
            link.invalidate()
            displayLink = nil
        }
    }

    /// Lays the stones' shapes out for tracing, off the main thread, once they're built.
    private func loadShapes() {
        guard !tracer.isLoaded, !isLoadingShapes, scene.isReady else { return }
        let pebbles = scene.pebbles, scale = Rock3DScene.metersPerPoint
        guard !pebbles.isEmpty else { return }
        isLoadingShapes = true
        Task { [weak self] in
            let shapes = await Task.detached(priority: .userInitiated) {
                TraceGeometry(pebbles: pebbles, metersPerPoint: scale)
            }.value
            guard let self else { return }
            tracer.load(shapes)
            isLoadingShapes = false
            run()
            // The light carried over, worked out once for the stones as they rest in each state.
            let poses = Self.poseOrder.map { self.tracer.stones(self.scene.restingTransforms($0)) }
            tracer.bake(poses: poses, stoneAlbedo: Self.stoneAlbedo * Self.grainAlbedo) { [weak self] in
                self?.startOver = true
                self?.run()
            }
        }
    }

    /// Where the stones are drawn, in this view's points.
    private var band: CGRect {
        scene.band.isEmpty ? .zero : convert(scene.band, from: nil)
    }

    /// A texture to draw into and read from later, `width` by `height` pixels.
    private func canvas(_ existing: MTLTexture?, width: Int, height: Int, format: MTLPixelFormat) -> MTLTexture? {
        if let existing, existing.width == width, existing.height == height {
            return existing
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    private func draw() {
        guard let look = shownLook, metalLayer.drawableSize.width > 0, band.height > 0, let drawable = metalLayer.nextDrawable(),
              let commands = queue.makeCommandBuffer() else { return }
        let screen = drawable.texture
        guard let background = canvas(background, width: screen.width, height: screen.height, format: .bgra8Unorm) else { return }
        self.background = background
        frameNumber += 1

        // The picture, drawn again whenever anything in it may have changed.
        if tracer.isSettling || moving || startOver || redraw || isEasing || tracer.isLoaded == false {
            let changed: UInt32 = startOver ? 0 : moving ? 8 : 20
            startOver = false
            redraw = false
            // The stones and their shadows, either side of the middle of where they stand: as wide as on
            // iPhone, where that's the middle two thirds of the screen, and wherever the stones go.
            let scale = metalLayer.contentsScale
            let rows = Int((band.minY * scale).rounded(.down)) - 8 ..< min(screen.height, Int((band.maxY * scale).rounded(.up)) + 8)
            let reach = band.height * 0.44
            let columns = max(0, Int(((band.midX - reach) * scale).rounded(.down))) ..< min(screen.width, Int(((band.midX + reach) * scale).rounded(.up)))
            let region = (x: columns, y: rows)
            let transforms = scene.stoneTransforms()
            tracer.turn = scene.turn
            let shade = scene.groundShade()
            tracer.poseBlend = (Self.poseOrder.firstIndex(of: shade.from) ?? 0, Self.poseOrder.firstIndex(of: shade.to) ?? 0, shade.progress)
            tracer.stoneBounce = look.isDark ? Self.darkStone : 1
            let uniforms = Self.traceUniforms(look: look, lighting: scene.lighting, camera: scene.camera, band: band,
                                              pixelsPerPoint: metalLayer.contentsScale, screen: screen)
            tracer.encode(uniforms, stones: tracer.stones(transforms),
                          changed: changed, region: region, samples: moving ? 2 : 1, bounces: moving ? 3 : 6, commands: commands,
                          background: background, grain: grain, blank: blank)
        }

        // The screen: the picture.
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = screen
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
            encoder.setRenderPipelineState(copy)
            encoder.setFragmentTexture(background, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        commands.present(drawable)
        commands.encodeSignalEvent(drawn, value: frameNumber)
        commands.commit()
    }

    // MARK: Light

    /// The light the scene is traced in. The sky, in the tint the look gives it. The key light where
    /// the sun or the moon is, a soft disc of light, wider with the sun low, bright enough to light the
    /// pale stones like the drawn ones above the sky's own light. The ground, the color the sky
    /// is at the horizon once all that light falls on it. Mist, lying low over the plain from just
    /// behind the stones. `band` is where the stones stand, in the view's points.
    static func traceUniforms(look: SceneLook, lighting: Rock3DScene.Lighting, camera: simd_float4x4, band: CGRect,
                              pixelsPerPoint: CGFloat, screen: MTLTexture) -> TraceUniforms {
        let key = Self.sun(path: lighting.path, isDay: lighting.isDay)
        func luminance(_ c: SIMD3<Float>) -> Float {
            simd_dot(c, SIMD3(0.2126, 0.7152, 0.0722))
        }
        // The sun or the moon behind haze: a soft disc of light, and around it a broad glow of brighter sky,
        // far bigger, as the sky always is around the sun. Both lie behind the camera, out of view, so the
        // sky in view keeps its tint; they light the stones from the upper left in front, the glow so
        // broadly that the stones turn into shade gently and their shadows on the ground stay faint.
        let radius = (10 + 25 * (1 - lighting.crispness)) * Float.pi / 180
        let solidAngle = 2 * Float.pi * (1 - cos(radius))
        let stoneAlbedo = Self.stoneAlbedo
        // A little warm, so the blue of the sky doesn't make them look grey-blue. In dark mode the stones
        // are dark too, lit just as brightly as the pale ones.
        let warmth: Float = 0.05
        let stoneColor = stoneAlbedo * (look.isDark ? Self.darkStone : 1) * SIMD3<Float>(1 + 0.4 * warmth, 1 - 0.3 * warmth, 1 - 0.6 * warmth)
        let zenith: Float = 1, glowWidth: Float = 1
        // The glow is brightest low in the sky below the sun, where the haze it shines through is deepest.
        let drop: Float = 0.4
        let level = simd_normalize(SIMD3(key.x, 0, key.z))
        let glowHeight = asin(min(1, max(-1, key.y))) * drop
        let glowCenter = level * cos(glowHeight) + SIMD3(0, sin(glowHeight), 0)
        let plain = Self.skyIrradiance(horizon: look.skyHorizon, top: look.skyTop, zenith: zenith, from: 0.6, to: 1.45, key: glowCenter, glow: .zero, glowWidth: glowWidth)
        // As much light from the sun's side as the stones need to show as light as the drawn ones, over
        // what the rest of the sky gives them; most of it in the glow.
        let lit: Float = 0.85
        let front = max(Float.pi * lit / (stoneAlbedo * 0.84) - 0.6 * luminance(plain), 0.3 * luminance(plain))
        let glowShare: Float = 0.85
        let glow = lighting.tint * front * glowShare / Self.glowFactor(width: glowWidth)
        let sky = Self.skyIrradiance(horizon: look.skyHorizon, top: look.skyTop, zenith: zenith, from: 0.6, to: 1.45, key: glowCenter, glow: glow, glowWidth: glowWidth)
        let keyLight = front * (1 - glowShare)
        let keyRadiance = lighting.tint * keyLight / solidAngle
        let keyIrradiance = keyRadiance * Self.keyIrradiance(key: key, radius: radius)
        let open = sky + keyIrradiance
        // The ground is the color that, open to all this light, shows as the sky at the horizon does, so
        // the two meet with no line and the ground shows only where the stones touch it.
        let groundAlbedo = simd_clamp(Float.pi * look.skyHorizon / simd_max(open, SIMD3(repeating: 1e-4)), .zero, SIMD3(repeating: 0.9))
        // A mist lying low over the plain from just behind the stones. It scatters the light from all
        // around and the key light's, mostly forward; how much of that it scatters rather than soaks up is
        // what makes it, far off, the color of the sky at the horizon.
        let fog = SIMD4<Float>(1.6, 6, 0.6, 0.8)
        let forward = -SIMD3(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z)
        let g: Float = 0.25, c = simd_dot(forward, key)
        let phase = (1 - g * g) / (4 * Float.pi * pow(1 + g * g - 2 * g * c, 1.5))
        let around = 0.55 * sky / Float.pi + 0.45 * groundAlbedo * open / Float.pi
        let scattered = around + phase * keyRadiance * solidAngle
        let fogAlbedo = simd_clamp(look.skyHorizon / simd_max(scattered, SIMD3(repeating: 1e-4)), .zero, SIMD3(repeating: 0.98))
        let focal = Float(band.height) / 2 / tan(Rock3DScene.fieldOfView / 2 * .pi / 180)
        return TraceUniforms(
            eye: camera.columns.3, right: camera.columns.0, up: camera.columns.1, forward: -camera.columns.2,
            skyHorizon: SIMD4(look.skyHorizon, 0), skyTop: SIMD4(look.skyTop, 0),
            key: SIMD4(key, cos(radius)), keyRadiance: SIMD4(keyRadiance, 0),
            glow: SIMD4(glow, glowWidth), glowCenter: SIMD4(glowCenter, 0), skyIrradiance: SIMD4(sky, 0),
            keyIrradiance: SIMD4(keyIrradiance, 0),
            groundAlbedo: SIMD4(groundAlbedo, 0), stoneAlbedo: SIMD4(stoneColor, 0),
            fog: fog, fogLight: SIMD4(around, 0), fogAlbedo: SIMD4(fogAlbedo, 0), stack: .zero,
            center: SIMD2(Float(band.midX), Float(band.midY)),
            viewSize: SIMD2(Float(screen.width), Float(screen.height)), jitter: .zero,
            focal: focal, pixelsPerPoint: Float(pixelsPerPoint), limit: 0, frame: 0, zenith: zenith,
            zenithFrom: 0.6, zenithTo: 1.45, reliefDepth: 0.45,
            roughness: 0.6, specular: 0.45, exposure: 1, grainOpacity: look.isDark ? 0.3 : 1,
            isDark: look.isDark ? 1 : 0)
    }

    /// Where the sun is, `path` of the way along its day (see `AmbientSky.sunPath`), seen from the stones,
    /// with the view looking away from it: rising on the left, climbing across behind the camera to its
    /// height at midday, and setting on the right, just above the horizon at either end, so shadows fall
    /// long to the right in the morning, short and behind the stones at midday, and long to the left in
    /// the evening. By night, the moon, lower, from the right back round to the left.
    private static func sun(path: Float, isDay: Bool) -> SIMD3<Float> {
        let along = isDay ? (path + 1) / 2 : (1 - path) / 2
        let around = along * Float.pi
        let height = (isDay ? 4 + 46 * sin(around) : 12 + 30 * sin(around)) * Float.pi / 180
        let across = isDay ? -cos(around) : cos(around)
        return normalize(SIMD3(across * cos(height), sin(height), sin(around) * cos(height)))
    }

    /// What a surface facing a glow of unit radiance at its middle receives from it, the glow fading
    /// away from its middle as exp(-(angle / width)^2).
    private static func glowFactor(width: Float) -> Float {
        let rings = 64
        var total: Float = 0
        for i in 0..<rings {
            let angle = (Float(i) + 0.5) / Float(rings) * .pi / 2
            total += exp(-(angle / width) * (angle / width)) * cos(angle) * sin(angle) * (.pi / 2 / Float(rings)) * 2 * .pi
        }
        return total
    }

    /// What a level patch of open ground receives from a key light of unit radiance toward `key`, `radius`
    /// across: each direction of the light weighed by how squarely it falls, none from below the horizon.
    private static func keyIrradiance(key: SIMD3<Float>, radius: Float) -> Float {
        let up = abs(key.y) < 0.99 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
        let t = normalize(simd_cross(up, key)), b = simd_cross(key, t)
        let rings = 48, around = 96
        var total: Float = 0
        for i in 0..<rings {
            let angle = (Float(i) + 0.5) / Float(rings) * radius
            let ring = sin(angle) * (radius / Float(rings)) * (2 * .pi / Float(around))
            for j in 0..<around {
                let phi = (Float(j) + 0.5) / Float(around) * 2 * .pi
                let direction = key * cos(angle) + (t * cos(phi) + b * sin(phi)) * sin(angle)
                total += max(direction.y, 0) * ring
            }
        }
        return total
    }

    /// What a level patch of open ground receives from the sky: its radiance over the dome above, each
    /// direction weighed by how squarely its light falls.
    private static func skyIrradiance(horizon: SIMD3<Float>, top: SIMD3<Float>, zenith: Float, from: Float, to: Float,
                                      key: SIMD3<Float>, glow: SIMD3<Float>, glowWidth: Float) -> SIMD3<Float> {
        let rings = 24, around = 48
        var total = SIMD3<Float>(repeating: 0)
        for i in 0..<rings {
            let elevation = (Float(i) + 0.5) / Float(rings) * .pi / 2
            let t = min(1, max(0, elevation / 0.55))
            let z = min(1, max(0, (elevation - from) / (to - from)))
            let base = (horizon + (top - horizon) * (t * t * (3 - 2 * t))) * (1 + (zenith - 1) * (z * z * (3 - 2 * z)))
            let ring = cos(elevation) * (.pi / 2 / Float(rings)) * (2 * .pi / Float(around))
            for j in 0..<around {
                let azimuth = (Float(j) + 0.5) / Float(around) * 2 * .pi
                let direction = SIMD3(cos(elevation) * sin(azimuth), sin(elevation), -cos(elevation) * cos(azimuth))
                let angle = acos(min(1, max(-1, simd_dot(direction, key))))
                let radiance = base + glow * exp(-angle * angle / (glowWidth * glowWidth))
                total += radiance * sin(elevation) * ring
            }
        }
        return total
    }
}

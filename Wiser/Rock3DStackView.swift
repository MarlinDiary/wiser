//
//  Rock3DStackView.swift
//  Wiser
//
//  Created by Marlin on 18/10/2026.
//

import SwiftUI
import simd

/// Where the stones stand on the home screen: drag sideways to turn them; tap a stone to nudge it.
/// `SceneView`, behind everything, draws them here, lined up with the drawn stones from the front.
struct Rock3DStackView: View {
    var scene: Rock3DScene
    var state: RockState
    var tint: Color
    var daylight: Daylight

    @Environment(\.colorScheme) private var colorScheme
    @State private var nudges = 0

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { value in scene.drag(by: Float(value.translation.width)) }
                    .onEnded { value in scene.endDrag(speed: Float(value.velocity.width)) }
            )
            .onTapGesture { location in
                if scene.nudge(at: location) {
                    nudges += 1
                }
            }
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: nudges)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                scene.band = frame
            }
            // Leave room around the stack so the stones never clip while they move or turn.
            .padding(.vertical, -Rock3DScene.margin)
            .task { await scene.prepare() }
            .onChange(of: state, initial: true) { _, state in
                scene.apply(state: state)
            }
            .onChange(of: tint, initial: true) { _, tint in
                scene.applyLook(tint: tint, isDark: colorScheme == .dark, daylight: daylight)
            }
            .onChange(of: daylight) { _, daylight in
                scene.applyLook(tint: tint, isDark: colorScheme == .dark, daylight: daylight)
            }
            .onChange(of: colorScheme) { _, colorScheme in
                scene.applyLook(tint: tint, isDark: colorScheme == .dark, daylight: daylight)
            }
    }
}

/// The stones, the light and the camera for `Rock3DStackView`, kept across view updates.
@MainActor
final class Rock3DScene {
    /// The 2D stack is drawn at this scale on the home screen; the 3D view matches it.
    static let viewScale: CGFloat = 0.66
    /// Extra room above and below the stack, in points.
    static let margin: CGFloat = 40
    static let fieldOfView: Float = 22
    // One point of the original artwork is one millimeter in the scene.
    static let metersPerPoint: Float = 0.001
    private static let stackHeight: Float = 364

    /// Where the camera is and which way it looks, as the transform from its own frame to the world's: it
    /// looks along its -z, with its x to the right and its y up.
    let camera: simd_float4x4
    /// Called whenever something starts to move or change, so the view draws frames until it has all
    /// come to rest.
    var onWake: (() -> Void)?
    private(set) var isReady = false
    /// Where the stones are drawn, in the window's points; its size is used to work out where a tap lands.
    var band: CGRect = .zero {
        didSet {
            guard band != oldValue else { return }
            onWake?()
        }
    }
    var viewSize: CGSize {
        band.size
    }
    /// How far the stack is turned about the vertical, in radians.
    private(set) var turn: Float = 0
    /// The light as the sun or the moon makes it now: its tint, how crisp it is (softer with the sun
    /// low), and how far along its path the sun (by day) or the moon (by night) is; see
    /// `AmbientSky.sunPath`.
    struct Lighting: Equatable {
        var tint: SIMD3<Float>
        var crispness: Float
        var path: Float
        var isDay: Bool
    }
    private(set) var lighting = Lighting(tint: SIMD3(repeating: 1), crispness: 1, path: -0.39, isDay: true)

    /// The stones' shapes, once they're built.
    var pebbles: [Pebble] {
        layout?.pebbles ?? []
    }

    /// Where each stone is now, as the transform from its own frame (meters) to the world's.
    func stoneTransforms() -> [simd_float4x4] {
        let turning = simd_float4x4(simd_quatf(angle: turn, axis: [0, 1, 0]))
        return placed.map { turning * Self.transform($0) }
    }

    /// Where each stone comes to rest in `state`, with the stack turned to the front.
    func restingTransforms(_ state: RockState) -> [simd_float4x4] {
        layout?.poses[state]?.map(Self.transform) ?? []
    }

    /// The transform from a stone's own frame (meters) to the stack's, for it at `pose` (points).
    private static func transform(_ pose: StoneStack.Pose) -> simd_float4x4 {
        var matrix = simd_float4x4(pose.rotation)
        matrix.columns.3 = SIMD4(pose.translation * metersPerPoint, 1)
        return matrix
    }

    /// Where each stone is now, in the stack's frame.
    private var placed: [StoneStack.Pose] = []
    private var layout: StoneLayout?
    private var state: RockState = .idle
    private var glides: [Glide] = []
    private var rocks: [Rock] = []
    private var turnSpeed: Float = 0
    private var dragStart: Float?
    private var look: (tint: Color, isDark: Bool, daylight: Daylight)?
    private var appliedLook: [Float] = []
    private var isPreparing = false

    init() {
        let s = Self.metersPerPoint
        // The view is the stack's height at `viewScale`, plus `margin` above and below, seen straight on
        // from in front, level with the middle of the stack.
        let viewHeight = Self.stackHeight * Float(Self.viewScale) + 2 * Float(Self.margin)
        let worldHeight = viewHeight / Float(Self.viewScale) * s
        let distance = worldHeight / 2 / tan(Self.fieldOfView / 2 * .pi / 180)
        camera = simd_float4x4(columns: ([1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, Self.stackHeight / 2 * s, distance, 1]))
    }

    /// Builds the stones and works out how they sit; the heavy part runs off the main thread.
    func prepare() async {
        guard !isReady, !isPreparing else { return }
        isPreparing = true
        guard let layout = await Task.detached(priority: .userInitiated, operation: { StoneLayout() }).value else {
            print("Couldn't build the stones")
            return
        }
        self.layout = layout
        glides = layout.poses[state]!.map { Glide(position: $0.translation, rotation: $0.rotation) }
        rocks = Array(repeating: Rock(), count: glides.count)
        isReady = true
        place()
        if let look {
            applyLook(tint: look.tint, isDark: look.isDark, daylight: look.daylight)
        }
        onWake?()
        #if DEBUG
        let isBalanced = await Task.detached(priority: .background) { layout.isBalanced }.value
        assert(isBalanced, "The resting stack must be balanced on every contact")
        #endif
    }

    // MARK: Motion

    /// Moves the stones toward where `state` puts them. They glide there on springs, so a new state can
    /// take over at any moment and they carry on from wherever they are, at whatever speed.
    func apply(state: RockState) {
        self.state = state
        guard isReady else { return }
        onWake?()
    }

    /// Turns the stack with a finger that has moved `distance` points sideways since it touched down.
    func drag(by distance: Float) {
        if dragStart == nil {
            dragStart = turn
        }
        turn = dragStart! + distance / 110
        turnSpeed = 0
        onWake?()
    }

    /// Lets go of the stack with the finger moving at `speed` points a second: it keeps turning, slows,
    /// and swings back to face the front.
    func endDrag(speed: Float) {
        dragStart = nil
        turnSpeed = max(-12, min(12, speed / 110))
        onWake?()
    }

    /// Nudges the stone under `location` (in the view's points) as if a finger pressed it there: it rocks
    /// on what it stands on, carrying the stones above, and settles. False if no stone is there.
    func nudge(at location: CGPoint) -> Bool {
        guard isReady, let layout, viewSize.width > 0, viewSize.height > 0 else { return false }
        // The line of sight through the tap, in the turntable's frame, in points.
        let view = camera
        let screen = SIMD2(Float(location.x / viewSize.width) * 2 - 1, 1 - Float(location.y / viewSize.height) * 2)
        let spread = tan(Self.fieldOfView / 2 * .pi / 180)
        let aspect = Float(viewSize.width / viewSize.height)
        let forward = -SIMD3(view.columns.2.x, view.columns.2.y, view.columns.2.z)
        let right = SIMD3(view.columns.0.x, view.columns.0.y, view.columns.0.z)
        let up = SIMD3(view.columns.1.x, view.columns.1.y, view.columns.1.z)
        let unturn = simd_quatf(angle: -turn, axis: [0, 1, 0])
        let direction = unturn.act(normalize(forward + screen.x * spread * aspect * right + screen.y * spread * up))
        let origin = unturn.act(SIMD3(view.columns.3.x, view.columns.3.y, view.columns.3.z) / Self.metersPerPoint)

        let poses = currentPoses()
        var nearest: (stone: Int, distance: Float)?
        for (k, pose) in poses.enumerated() {
            let inverse = pose.rotation.inverse
            guard let distance = layout.pebbles[k].hit(from: inverse.act(origin - pose.translation), toward: inverse.act(direction)),
                  distance < (nearest?.distance ?? .infinity) else { continue }
            nearest = (k, distance)
        }
        guard let (k, distance) = nearest else { return false }

        // Pressed down and a little in, where the finger landed: the push turns the stone about where it
        // stands, harder the further from there it lands.
        let point = origin + direction * distance
        let pivot = k == 0 ? bedMiddle(layout) : seatedness(k) > 0.5 ? layout.footings[k].center : poses[k].apply(layout.pebbles[k].centerOfMass)
        let torque = cross(point - pivot, normalize(SIMD3<Float>(0, -1, 0) + direction * 0.5))
        // The bottom stone, held all round by the ground it's bedded in, only stirs in its bed.
        var kick = SIMD2(torque.x, torque.z) / layout.reaches[k] * (k == 0 ? 0.8 : 1.8)
        if length(kick) > 2.4 {
            kick = normalize(kick) * 2.4
        }
        rocks[k].speed += kick
        onWake?()
        return true
    }

    /// Moves everything on by `elapsed` seconds. False once it has all come to rest.
    func step(_ elapsed: TimeInterval) -> Bool {
        guard isReady, let layout else { return false }
        let dt = Float(min(elapsed, 1.0 / 20))
        var moving = dragStart != nil
        if dragStart == nil {
            Spring(frequency: 0.45, damping: 0.85).step(&turn, &turnSpeed, toward: 0, dt: dt)
            if abs(turn) < 0.0005, abs(turnSpeed) < 0.002 {
                turn = 0
                turnSpeed = 0
            } else {
                moving = true
            }
        }
        let targets = layout.poses[state]!
        // When a stone rocks, the ones sitting on it lag behind and sway on their own a little.
        let springs = [Spring(frequency: 4.5, damping: 0.4), Spring(frequency: 2.1, damping: 0.12), Spring(frequency: 2.4, damping: 0.12)]
        let swings = rocks.indices.map { rocks[$0].swing(spring: springs[$0]) }
        for k in rocks.indices {
            var carried: Float = 1
            for j in stride(from: k - 1, through: 0, by: -1) {
                carried *= seatedness(j + 1)
                rocks[k].speed -= swings[j] * 0.3 * carried * dt
            }
        }
        for k in glides.indices {
            // Heavier stones move a touch sooner, the light top one trails.
            glides[k].step(toward: targets[k], spring: Spring(frequency: [1.3, 1.2, 1.05][k], damping: 0.9), dt: dt)
            rocks[k].step(spring: springs[k], dt: dt)
            moving = moving || !glides[k].isSettled(at: targets[k]) || !rocks[k].isSettled
        }
        place()
        return moving
    }

    /// Which states' shade lies on the ground now, and how far the stones have come from the first to
    /// the second.
    func groundShade() -> (from: RockState, to: RockState, progress: Float) {
        let rise = rise()
        return rise < 1 ? (.idle, .paused, rise) : (.paused, .checked, rise - 1)
    }

    /// How far the upper stones have risen, measured along the heights they take: 0 resting, 1 paused,
    /// 2 focusing. The light they hide from the ground and from each other follows this, so it changes
    /// only as they move, whatever they're heading for.
    private func rise() -> Float {
        guard let layout else { return 0 }
        var total: Float = 0
        for k in 1..<glides.count {
            let heights = [RockState.idle, .paused, .checked].map { layout.poses[$0]![k].translation.y }
            let y = glides[k].position.y
            total += y < heights[1] ? max(0, (y - heights[0]) / (heights[1] - heights[0]))
                : 1 + min(1, (y - heights[1]) / (heights[2] - heights[1]))
        }
        return total / Float(glides.count - 1)
    }

    private func place() {
        placed = currentPoses()
    }

    /// The middle of the bottom stone's bed where it meets the ground, which it turns about.
    private func bedMiddle(_ layout: StoneLayout) -> SIMD3<Float> {
        SIMD3(layout.footings[0].center.x, 0, layout.footings[0].center.z)
    }

    /// How firmly stone `k` sits on what's below it: fully at its resting place, not at all once it has
    /// lifted a few points away.
    private func seatedness(_ k: Int) -> Float {
        guard let layout else { return 0 }
        return max(0, 1 - length(glides[k].position - layout.poses[.idle]![k].translation) / 4)
    }

    /// Where each stone is now, in the turntable's frame: gliding toward its place, rocked by any nudge,
    /// and carried along by the rocking of the stones it sits on.
    private func currentPoses() -> [StoneStack.Pose] {
        guard let layout else { return [] }
        let poses = glides.map { StoneStack.Pose(rotation: $0.rotation, translation: $0.position) }
        let seated = poses.indices.map(seatedness)
        // A seated stone tips over the edge of what it stands on; a lifted one turns about its middle.
        let pivots = poses.indices.map { k -> SIMD3<Float> in
            let middle = poses[k].apply(layout.pebbles[k].centerOfMass)
            guard length(rocks[k].tilt) > 0 else { return middle }
            // The bottom stone turns in its bed, about its middle where it meets the ground.
            if k == 0 {
                return bedMiddle(layout)
            }
            guard seated[k] > 0 else { return middle }
            let edge = layout.footings[k].edge(toward: rocks[k].downhill)
            return simd_mix(middle, edge, SIMD3(repeating: seated[k]))
        }
        return poses.indices.map { k in
            var pose = poses[k]
            var carried: Float = 1
            // Its own rock first, then the rock of each stone below that it sits on.
            for j in stride(from: k, through: 0, by: -1) {
                if j < k {
                    carried *= seated[j + 1]
                }
                guard carried > 0 else { break }
                pose = rocks[j].turned(pose, about: pivots[j], by: carried)
            }
            return pose
        }
    }

    // MARK: Light

    /// Lights the stones the same way by day and by night, so they stand out light against the dark
    /// sky like the drawn stones. The light takes a little of the sky's hue, which is what tints them.
    func applyLook(tint: Color, isDark: Bool, daylight: Daylight) {
        look = (tint, isDark, daylight)
        guard isReady else { return }
        let sky = Self.linear(tint, isDark: isDark)
        // Fine enough that the light changes in steps too small to see.
        let key = [sky.x, sky.y, sky.z].map { ($0 * 1000).rounded() } + [isDark ? 1 : 0, (daylight.path * 1000).rounded()]
        guard key != appliedLook else { return }
        appliedLook = key
        lighting = Self.lighting(sky: sky, daylight: daylight)

        // The scene is drawn again in the new light.
        onWake?()
    }

    /// The light under a sky of `sky` (in linear light) at `daylight`: a little of the sky's hue.
    static func lighting(sky: SIMD3<Float>, daylight: Daylight) -> Lighting {
        let hue = simd_min(sky / max(dot(sky, [0.2126, 0.7152, 0.0722]), 0.001), SIMD3(repeating: 3))
        let light = simd_mix(SIMD3<Float>(repeating: 1), hue, SIMD3(repeating: 0.03))
        // Crisper with the sun high, softer low; as crisp as it was first set up to be mid-morning, when
        // it's that high.
        let height = sin((daylight.path + 1) / 2 * .pi)
        let morning = sin(acos(Float(0.55 / 0.95)))
        return Lighting(tint: light, crispness: 0.85 + 0.15 * height / morning, path: daylight.path, isDay: daylight.isDay)
    }

    /// The sky's tint in linear light, as it is in light or dark mode.
    static func linear(_ tint: Color, isDark: Bool) -> SIMD3<Float> {
        let traits = UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
        return decode(components(UIColor(tint).resolvedColor(with: traits)))
    }

    // MARK: Building blocks

    /// The stone's surface, the way a river pebble looks up close: fine grain like the drawn stones, soft
    /// mottling, and a scatter of small darker and lighter mineral flecks, the darker ones worn into tiny
    /// pits. Its pixels, four bytes each: its color (sRGB), and its relief: how the surface tilts across
    /// and up (red and green, level at one half) and how much rougher or smoother it is in places (blue,
    /// as it is at one half). One texel is one point of stone. Tiles seamlessly.
    nonisolated static let surfacePixels: (colors: [UInt8], relief: [UInt8], size: Int) = {
        let size = 512
        let mottling: Float = 0.035
        var random = SeededRandom(seed: 7)
        var shade = (0..<(size * size)).map { _ in Float.random(in: -7...7, using: &random) / 236 }
        let blotches = tileableNoise(size: size, periods: [4, 8, 16], seed: 11)
        let tones = tileableNoise(size: size, periods: [3, 6], seed: 23)
        var warmth = [Float](repeating: 0, count: size * size)
        for i in shade.indices {
            shade[i] += blotches[i] * mottling
            warmth[i] = tones[i] * mottling / 2
        }
        // The surface's height, in points: a faint undulation and fine grit, and how much rougher it is.
        var height = tileableNoise(size: size, periods: [16, 32], seed: 31).map { $0 * 0.25 }
        var grit = SeededRandom(seed: 41)
        let sand = (0..<(size * size)).map { _ in Float.random(in: -1...1, using: &grit) }
        var rough = blotches.map { $0 * 0.05 }
        for y in 0..<size {
            for x in 0..<size {
                var sum: Float = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        sum += sand[(y + dy + size) % size * size + (x + dx + size) % size]
                    }
                }
                height[y * size + x] += sum / 9 * 0.35
                rough[y * size + x] += sand[y * size + x] * 0.03
            }
        }
        for _ in 0..<1400 {
            let center = SIMD2(Float.random(in: 0..<Float(size), using: &random), Float.random(in: 0..<Float(size), using: &random))
            let radius = Float.random(in: 0.5...1.5, using: &random)
            // Mostly darker flecks, some lighter.
            let isDark = Float.random(in: 0..<1, using: &random) < 0.7
            let amount = isDark ? -mottling * 3 : mottling * 1.5
            for dy in -2...2 {
                for dx in -2...2 {
                    let x = Int(center.x) + dx, y = Int(center.y) + dy
                    let distance = length(SIMD2(Float(x), Float(y)) + 0.5 - center)
                    let i = (y + size) % size * size + (x + size) % size
                    let falloff = max(0, 1 - distance / (radius + 0.5))
                    shade[i] += amount * falloff
                    if isDark {
                        height[i] -= 0.45 * falloff * falloff * (3 - 2 * falloff)
                        rough[i] += 0.15 * falloff
                    }
                }
            }
        }
        var colors = [UInt8](repeating: 255, count: size * size * 4)
        var relief = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let i = y * size + x
                let value = 236 * (1 + shade[i])
                colors[i * 4] = UInt8(min(255, max(0, value * (1 + warmth[i]))))
                colors[i * 4 + 1] = UInt8(min(255, max(0, value)))
                colors[i * 4 + 2] = UInt8(min(255, max(0, value * (1 - warmth[i]))))
                // Rows run down the image while the texture's up runs the other way.
                let across = (height[y * size + (x + 1) % size] - height[y * size + (x + size - 1) % size]) / 2
                let down = (height[(y + 1) % size * size + x] - height[(y + size - 1) % size * size + x]) / 2
                relief[i * 4] = UInt8(min(255, max(0, (0.5 + across) * 255)))
                relief[i * 4 + 1] = UInt8(min(255, max(0, (0.5 - down) * 255)))
                relief[i * 4 + 2] = UInt8(min(255, max(0, (0.5 + rough[i]) * 255)))
            }
        }
        return (colors, relief, size)
    }()

    /// Smooth random variation between -1 and 1 that wraps around at the edges: value noise on lattices
    /// of `periods` cells across, each half as strong as the one before.
    nonisolated private static func tileableNoise(size: Int, periods: [Int], seed: UInt64) -> [Float] {
        var random = SeededRandom(seed: seed)
        var result = [Float](repeating: 0, count: size * size)
        var total: Float = 0
        for (octave, period) in periods.enumerated() {
            let lattice = (0..<(period * period)).map { _ in Float.random(in: -1...1, using: &random) }
            let weight = pow(0.5, Float(octave))
            total += weight
            let cell = Float(size) / Float(period)
            for y in 0..<size {
                for x in 0..<size {
                    let p = SIMD2(Float(x), Float(y)) / cell
                    let x0 = Int(p.x) % period, y0 = Int(p.y) % period
                    let x1 = (x0 + 1) % period, y1 = (y0 + 1) % period
                    var t = p - SIMD2(Float(Int(p.x)), Float(Int(p.y)))
                    t = t * t * (3 - 2 * t)
                    let top = lattice[y0 * period + x0] * (1 - t.x) + lattice[y0 * period + x1] * t.x
                    let bottom = lattice[y1 * period + x0] * (1 - t.x) + lattice[y1 * period + x1] * t.x
                    result[y * size + x] += weight * (top * (1 - t.y) + bottom * t.y)
                }
            }
        }
        return result.map { $0 / total }
    }

    private static func components(_ color: UIColor) -> SIMD3<Float> {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD3(Float(r), Float(g), Float(b))
    }

    private static func decode(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(c.indices.map { i in c[i] <= 0.04045 ? c[i] / 12.92 : pow((c[i] + 0.055) / 1.055, 2.4) })
    }
}

/// A damped spring: how fast it swings, in cycles a second, and how quickly that dies away (1 settles
/// without overshooting).
private struct Spring {
    var frequency: Float
    var damping: Float

    /// Pulls `value` toward `target` for `dt` seconds, in small steps so it stays steady.
    func step<Value: SIMD>(_ value: inout Value, _ speed: inout Value, toward target: Value, dt: Float) where Value.Scalar == Float {
        let omega = 2 * Float.pi * frequency
        let steps = max(1, Int((dt / 0.004).rounded(.up)))
        let h = dt / Float(steps)
        for _ in 0..<steps {
            speed += (omega * omega * (target - value) - 2 * damping * omega * speed) * h
            value += speed * h
        }
    }

    func step(_ value: inout Float, _ speed: inout Float, toward target: Float, dt: Float) {
        var v = SIMD2(value, 0), s = SIMD2(speed, 0)
        step(&v, &s, toward: SIMD2(target, 0), dt: dt)
        value = v.x
        speed = s.x
    }
}

/// A stone moving toward where its state puts it, with its speed, so a new target can take over at any
/// moment without a jump.
private struct Glide {
    var position: SIMD3<Float>
    var velocity = SIMD3<Float>.zero
    var rotation: simd_quatf
    /// Radians a second.
    var spin = SIMD3<Float>.zero

    mutating func step(toward target: StoneStack.Pose, spring: Spring, dt: Float) {
        spring.step(&position, &velocity, toward: target.translation, dt: dt)
        // Turn by the same spring, measured as the rotation still left to go.
        var left = target.rotation * rotation.inverse
        if left.real < 0 {
            left = simd_quatf(vector: -left.vector)
        }
        let error = left.angle > 1e-6 ? left.axis * left.angle : .zero
        var turned = SIMD3<Float>.zero
        spring.step(&turned, &spin, toward: error, dt: dt)
        if length(turned) > 1e-7 {
            rotation = simd_normalize(simd_quatf(angle: length(turned), axis: normalize(turned)) * rotation)
        }
    }

    func isSettled(at target: StoneStack.Pose) -> Bool {
        let left = target.rotation * rotation.inverse
        return length(target.translation - position) < 0.05 && length(velocity) < 0.05
            && abs(left.real) > 0.99999 && length(spin) < 0.001
    }
}

/// A stone rocking after a nudge: tipped about a level axis, swinging back and settling.
private struct Rock {
    /// Radians about x and about z.
    var tilt = SIMD2<Float>.zero
    var speed = SIMD2<Float>.zero

    /// Which way, across the ground, the stone's lowering side faces.
    var downhill: SIMD2<Float> {
        length(tilt) > 0 ? normalize(SIMD2(-tilt.y, tilt.x)) : .zero
    }

    var isSettled: Bool {
        length(tilt) < 0.0002 && length(speed) < 0.002
    }

    /// How fast the rock is speeding up its swing, radians a second squared.
    func swing(spring: Spring) -> SIMD2<Float> {
        let omega = 2 * Float.pi * spring.frequency
        return -omega * omega * tilt - 2 * spring.damping * omega * speed
    }

    mutating func step(spring: Spring, dt: Float) {
        spring.step(&tilt, &speed, toward: .zero, dt: dt)
        if isSettled {
            tilt = .zero
            speed = .zero
        }
    }

    /// `pose` tipped by `share` of this rock about `pivot`.
    func turned(_ pose: StoneStack.Pose, about pivot: SIMD3<Float>, by share: Float) -> StoneStack.Pose {
        let angle = length(tilt) * share
        guard angle > 1e-7 else { return pose }
        let rotation = simd_quatf(angle: angle, axis: normalize(SIMD3(tilt.x, 0, tilt.y)))
        return StoneStack.Pose(rotation: rotation * pose.rotation, translation: rotation.act(pose.translation - pivot) + pivot)
    }
}

/// The stones' shapes and where they sit in each state. Built off the main thread.
nonisolated struct StoneLayout: Sendable {
    static let names = ["RockBottom", "RockMiddle", "RockTop"]
    /// How deep the bottom stone is bedded into the ground, in points.
    static let bed: Float = 8

    let pebbles: [Pebble]
    let poses: [RockState: [StoneStack.Pose]]
    /// Where each stone stands when the stack is at rest.
    let footings: [StoneStack.Footing]
    /// How far each stone reaches out from its middle, in points.
    let reaches: [Float]

    init?() {
        // Flat pebbles, a little deeper than they are tall, a bit thinner behind than in front, with
        // gently uneven faces and edges. Half thicknesses in front of the outline, in points. The bottom
        // stone's outline bulges out at its corners, so it's filled out smoothly, with its tightest turns
        // worn a little; the others are full right out to their ends.
        let thicknesses: [Float] = [81, 125, 60]
        var pebbles: [Pebble] = []
        for (k, name) in Self.names.enumerated() {
            let front = thicknesses[k]
            let shape = Pebble.Shape(front: front, back: front * 0.85, bumpiness: 0.05, wander: 0.12, wear: k == 0 ? 3 : 0,
                                     inflation: k == 0 ? .membrane : .rays, seed: UInt64(k + 1))
            guard let pebble = Pebble(imageName: name, shape: shape) else { return nil }
            pebbles.append(pebble)
        }

        // The bottom stone is bedded `bed` points into the ground, so it meets the ground all round with
        // no gap under it. Down there it lies on a flat face, so the weight of the stack, a little in
        // front of its middle, stays over what it stands on.
        let base: Float = 4
        pebbles[0] = pebbles[0].flattened(by: base)

        // Where the drawn stack puts each stone: the middle of its frame, the upper ones a little in
        // front, tilted clockwise on screen by the drawn angles.
        func pose(frameBottom: Float, frameHeight: Float, depth: Float, tilt: Float) -> StoneStack.Pose {
            StoneStack.Pose(rotation: simd_quatf(angle: -tilt * .pi / 180, axis: [0, 0, 1]),
                            translation: [0, frameBottom + frameHeight / 2 - base - Self.bed, depth])
        }
        let bottom = pose(frameBottom: 0, frameHeight: 91, depth: 0, tilt: 0)
        let poses: [RockState: [StoneStack.Pose]] = [
            .idle: [bottom, pose(frameBottom: 40, frameHeight: 136, depth: 6, tilt: 0), pose(frameBottom: 150, frameHeight: 84, depth: 10, tilt: 20)],
            .paused: [bottom, pose(frameBottom: 79, frameHeight: 136, depth: 6, tilt: -9), pose(frameBottom: 214, frameHeight: 84, depth: 10, tilt: 14)],
            .checked: [bottom, pose(frameBottom: 111, frameHeight: 136, depth: 6, tilt: 0), pose(frameBottom: 280, frameHeight: 84, depth: 10, tilt: 0)],
        ]

        // The drawn stack overlaps the stones. So that they rest on each other instead of passing into
        // each other, each upper stone has a seat worn into its underside that fits the stone below.
        let resting = poses[.idle]!
        for k in 1..<pebbles.count {
            pebbles[k] = pebbles[k].seated(at: resting[k], on: Self.stone(pebbles[k - 1]), at: resting[k - 1], blend: 24)
        }
        self.pebbles = pebbles
        self.poses = poses
        footings = StoneStack.footings(of: pebbles.map(Self.stone), at: resting)
        reaches = pebbles.map { pebble in pebble.surface.positions.map { length(SIMD2($0.x, $0.y)) }.max() ?? 1 }
    }

    /// Whether the resting stack stands: every stone's weight, with what's above it, over the patch it
    /// stands on.
    var isBalanced: Bool {
        StoneStack.imbalance(of: pebbles.map(Self.stone), at: poses[.idle]!).allSatisfy { $0 < 0.5 }
    }

    private static func stone(_ pebble: Pebble) -> StoneStack.Stone {
        StoneStack.Stone(positions: pebble.surface.positions, indices: pebble.surface.indices,
                         mass: pebble.volume, centerOfMass: pebble.centerOfMass)
    }
}

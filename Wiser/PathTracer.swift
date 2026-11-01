//
//  PathTracer.swift
//  Wiser
//
//  Created by Marlin on 19/10/2026.
//

@preconcurrency import Metal
#if !targetEnvironment(simulator)
import MetalFX
#endif
import MetalKit
import simd
import QuartzCore

/// The stones' shapes laid out for tracing rays against them on the GPU (see PathTracer.metal): their
/// bounding volumes and triangles, and what's needed to shade the surface where a ray meets one.
nonisolated struct TraceGeometry: Sendable {
    /// Matches `TraceNode` in PathTracer.metal.
    struct Node: Sendable {
        var lowerX, lowerY, lowerZ: Float
        var offset: UInt32
        var upperX, upperY, upperZ: Float
        var count: UInt32
    }

    struct Stone: Sendable {
        var nodes: UInt32
        var triangles: UInt32
        var lower: SIMD3<Float>
        var upper: SIMD3<Float>
        /// Where its vertices and its triangles (in `indices`, over three) begin, and how many there are.
        var vertexBase: UInt32
        var vertexCount: UInt32
        var first: UInt32
        var count: UInt32
    }

    var nodes: [Node] = []
    /// Three for each triangle, in the order the leaves list them: a corner and the triangle's place in
    /// `indices` (over three, as bits), and the two edges from that corner.
    var triangles: [SIMD4<Float>] = []
    var indices: [UInt32] = []
    var normals: [SIMD4<Float>] = []
    var tangents: [SIMD4<Float>] = []
    var bitangents: [SIMD4<Float>] = []
    var coordinates: [SIMD2<Float>] = []
    /// Where each corner is on its stone, in meters.
    var positions: [SIMD4<Float>] = []
    var stones: [Stone] = []

    init(pebbles: [Pebble], metersPerPoint scale: Float) {
        for pebble in pebbles {
            let surface = pebble.surface
            let positions = surface.positions.map { $0 * scale }
            let volumes = BoundingVolumes(positions: positions, indices: surface.indices)
            let vertexBase = UInt32(normals.count), triangleBase = UInt32(indices.count / 3)
            let nodeBase = UInt32(nodes.count), leafBase = UInt32(triangles.count / 3)
            let directions = Pebble.textureDirections(of: surface)
            for k in positions.indices {
                self.positions.append(SIMD4(positions[k], 1))
                normals.append(SIMD4(surface.normals[k], 0))
                tangents.append(SIMD4(directions.across[k], 0))
                bitangents.append(SIMD4(directions.up[k], 0))
                coordinates.append(surface.textureCoordinates[k])
            }
            indices += surface.indices.map { $0 + vertexBase }
            for node in volumes.nodes {
                nodes.append(Node(lowerX: node.lower.x, lowerY: node.lower.y, lowerZ: node.lower.z, offset: node.offset,
                                  upperX: node.upper.x, upperY: node.upper.y, upperZ: node.upper.z, count: node.count))
            }
            for t in volumes.triangles {
                let k = Int(t) * 3
                let a = positions[Int(surface.indices[k])], b = positions[Int(surface.indices[k + 1])]
                let c = positions[Int(surface.indices[k + 2])]
                triangles.append(SIMD4(a, Float(bitPattern: triangleBase + t)))
                triangles.append(SIMD4(b - a, 0))
                triangles.append(SIMD4(c - a, 0))
            }
            stones.append(Stone(nodes: nodeBase, triangles: leafBase, lower: volumes.nodes[0].lower, upper: volumes.nodes[0].upper,
                                vertexBase: vertexBase, vertexCount: UInt32(positions.count), first: triangleBase,
                                count: UInt32(surface.indices.count / 3)))
        }
    }
}

/// Matches `TraceStone` in PathTracer.metal.
struct TraceStone {
    var toObject: simd_float4x4
    var toWorld: simd_float4x4
    var bounds: SIMD4<Float>
    var nodes: UInt32
    var triangles: UInt32
    var index: UInt32
    var first: UInt32
}

/// Matches `TraceUniforms` in PathTracer.metal.
struct TraceUniforms {
    var eye: SIMD4<Float>
    var right: SIMD4<Float>
    var up: SIMD4<Float>
    var forward: SIMD4<Float>
    var skyHorizon: SIMD4<Float>
    var skyTop: SIMD4<Float>
    var key: SIMD4<Float>
    var keyRadiance: SIMD4<Float>
    var glow: SIMD4<Float>
    var glowCenter: SIMD4<Float>
    var skyIrradiance: SIMD4<Float>
    var keyIrradiance: SIMD4<Float>
    var groundAlbedo: SIMD4<Float>
    var stoneAlbedo: SIMD4<Float>
    var fog: SIMD4<Float>
    var fogLight: SIMD4<Float>
    var fogAlbedo: SIMD4<Float>
    var stack: SIMD4<Float>
    var center: SIMD2<Float>
    var viewSize: SIMD2<Float>
    var jitter: SIMD2<Float>
    var focal: Float
    var pixelsPerPoint: Float
    var limit: UInt32
    var frame: UInt32
    var regionTop: UInt32 = 0
    var regionHeight: UInt32 = 0
    var samples: UInt32 = 1
    var bounces: UInt32 = 3
    var zenith: Float = 1
    var zenithFrom: Float = 0
    var zenithTo: Float = 0
    var reliefDepth: Float = 0
    var roughness: Float
    var specular: Float
    var exposure: Float
    var grainOpacity: Float
    var isDark: Float
    var regionLeft: UInt32 = 0
    var regionWidth: UInt32 = 0
}

/// Traces the scene around the stones a sample a pixel each frame and keeps each pixel's running average,
/// carried along with the stones as they move; see PathTracer.metal. Where few samples are in yet, as
/// where a stone turns a new side into view, it shows them denoised meanwhile. Once nothing has changed
/// for long enough, the picture is as exact as it gets and tracing stops. Where the GPU can, MetalFX keeps
/// up with the stones while they move instead, and hands over to the full picture once they're still.
@MainActor
final class PathTracer {
    /// How many samples a still picture is averaged over before it's left as it is.
    static let samplesWhenStill = 384
    /// How many frames MetalFX goes on once the stones are still, before the full picture takes over.
    static let framesBeforeRefining = 24

    private let device: MTLDevice
    private let trace: MTLComputePipelineState
    private let variance: MTLComputePipelineState
    private let atrous: MTLComputePipelineState
    private let display: MTLRenderPipelineState
    /// Where the GPU can denoise with MetalFX: one sample a pixel at half the screen's resolution, and
    /// MetalFX makes the clean, full picture from it, carrying it along from frame to frame.
    /// The light falling on the ground, near and far, worked out on a map lying on it; this frame's and
    /// the last.
    private let groundMapPipeline: MTLComputePipelineState
    private var groundMaps: [MTLTexture] = []
    private var groundMapTurn = 0
    static let groundMapSize = 512
    private let traceFX: MTLComputePipelineState
    private let backdropFX: MTLComputePipelineState
    private let mistPipeline: MTLComputePipelineState
    /// The mist along each pixel's line of sight, and the light it was worked out in.
    private var mist: MTLTexture?
    private var mistLight: [Float] = []
    private let displayFX: MTLRenderPipelineState
    /// The scene away from the stones.
    private var backdrop: MTLTexture?
    /// The light falling on open ground, for the backdrop before the stones are there.
    private var openGround: MTLTexture?
    private let usesFX: Bool
    #if !targetEnvironment(simulator)
    private var fx: FX?
    #endif
    private let color: MTLTexture
    private let relief: MTLTexture
    private var geometry: (nodes: MTLBuffer, triangles: MTLBuffer, indices: MTLBuffer, normals: MTLBuffer,
                           tangents: MTLBuffer, bitangents: MTLBuffer, coordinates: MTLBuffer, positions: MTLBuffer,
                           stones: [TraceGeometry.Stone])?
    /// The stones as the GPU's own ray tracing sees them: each stone's triangles, once, and the three where
    /// they stand, each frame, from one of a few sets of instances so a frame still being traced keeps its own.
    private var shapes: [MTLAccelerationStructure] = []
    private var scene: (structure: MTLAccelerationStructure, scratch: MTLBuffer)?
    private var instances: [MTLBuffer] = []
    private var instanceTurn = 0
    /// Each pixel's average so far and what it shows (how far off, which stone, the ground or the sky,
    /// and how spread its samples are), this frame's and the last; which way it faces and how pale it is;
    /// and the denoised light, back and forth between passes.
    private var history: [(color: MTLBuffer, details: MTLBuffer)] = []
    private var guides: MTLBuffer?
    private var denoised: [MTLBuffer] = []
    private var current = 0
    private var regionSize = (width: 0, height: 0)
    private var frame: UInt32 = 0
    /// What was traced last frame, and how many frames running nothing has changed.
    private var previousStones: [TraceStone] = []
    private var previousPlaces: [Float] = []
    private var previousLight: [Float] = []
    private(set) var stillFrames = 0
    /// Whether the full picture has taken over from MetalFX, how many frames ago, and what was shown just
    /// before, which it fades in over.
    private var refining = false
    private var refined = 0
    private var shownBefore: MTLTexture?

    // The light carried over: worked out once for the resting stones, then drawn each frame by a sum at
    // each point; see "Light worked out ahead" in PathTracer.metal.
    nonisolated static let harmonicOrder = 6
    nonisolated static let harmonicCount = harmonicOrder * harmonicOrder
    nonisolated static let transferSize = harmonicCount + 2 * 9
    /// How many points a side the ground's map of light carried over has, and how many directions each
    /// point looks in as it's worked out.
    static let bakedGroundSize = 256
    static let bakeSamples: UInt32 = 512
    private let bakeStones: MTLComputePipelineState
    private let bakeGround: MTLComputePipelineState
    private let stoneLight: MTLComputePipelineState
    private let groundHarmonics: MTLComputePipelineState
    private let groundKey: MTLComputePipelineState
    private let groundBaked: MTLComputePipelineState
    private let fillBuried: MTLComputePipelineState
    private let stoneRaster: MTLRenderPipelineState
    private let bakedDisplay: MTLRenderPipelineState
    private let stoneDepth: MTLDepthStencilState
    private let harmonicScale: MTLBuffer
    /// What each stone vertex, and each point of the ground's map around the stack, keeps: for each of
    /// the stones' poses, resting, paused and focusing.
    private var transfers: [(stones: MTLBuffer, ground: MTLBuffer)] = []
    /// The work of finding it out, done a piece a frame so the scene keeps drawing meanwhile.
    private var bakeSteps: [(MTLCommandBuffer) -> Void] = []
    private var isBaking = false
    /// Which two poses the stones are between now, and how far from the first to the second.
    var poseBlend: (from: Int, to: Int, progress: Float) = (0, 0, 0)
    /// The light falling on each stone vertex this frame; the ground's light in the stack's frame, the
    /// key light's in the world, and both together in the world.
    private var vertexLight: MTLBuffer?
    private var bakedMaps: (kept: MTLTexture, key: MTLTexture, map: MTLTexture)?
    /// The stones drawn: their light, and the samples of each pixel they're drawn with first.
    private var stoneTargets: (color: MTLTexture, samples: MTLTexture, zBuffer: MTLTexture)?
    /// The light around the stones as harmonics in the world, and the light it was worked out from: the
    /// sky and its glow above the horizon and the key light, for the light the stones and the ground
    /// keep (which has the ground's own share in it); and all around, the ground below the horizon as
    /// pale as the sky there, for the fine relief and the sheen.
    private var environment: (light: [Float], rest: [SIMD3<Float>], key: [SIMD3<Float>], around: [SIMD3<Float>])?
    private var drewBaked = false
    /// How far the stack is turned about the vertical now, in radians.
    var turn: Float = 0
    /// How much of the light the stones were worked out to throw onto each other they throw now: as dark
    /// or as pale as they are against how they were then.
    var stoneBounce: Float = 1
    var isBaked: Bool {
        transfers.count == 3
    }

    #if !targetEnvironment(simulator)
    private struct FX {
        var scaler: MTLFXTemporalDenoisedScaler
        var radiance, depth, motion, albedo, specular, normal, roughness, output, exposure: MTLTexture
    }
    #endif

    init(device: MTLDevice, library: MTLLibrary) {
        self.device = device
        func kernel(_ name: String) -> MTLComputePipelineState {
            try! device.makeComputePipelineState(function: library.makeFunction(name: name)!)
        }
        trace = kernel("traceKernel")
        variance = kernel("varianceKernel")
        atrous = kernel("atrousKernel")
        traceFX = kernel("traceFXKernel")
        groundMapPipeline = kernel("groundMapKernel")
        backdropFX = kernel("backdropKernel")
        mistPipeline = kernel("mistKernel")
        bakeStones = kernel("bakeStonesKernel")
        bakeGround = kernel("bakeGroundKernel")
        stoneLight = kernel("stoneLightKernel")
        groundHarmonics = kernel("groundHarmonicsKernel")
        groundKey = kernel("groundKeyKernel")
        groundBaked = kernel("groundBakedKernel")
        fillBuried = kernel("fillBuriedKernel")
        let raster = MTLRenderPipelineDescriptor()
        raster.vertexFunction = library.makeFunction(name: "stoneVertex")
        raster.fragmentFunction = library.makeFunction(name: "stoneFragment")
        raster.colorAttachments[0].pixelFormat = .rgba16Float
        raster.depthAttachmentPixelFormat = .depth32Float
        raster.rasterSampleCount = 4
        stoneRaster = try! device.makeRenderPipelineState(descriptor: raster)
        let depthTest = MTLDepthStencilDescriptor()
        depthTest.depthCompareFunction = .greater
        depthTest.isDepthWriteEnabled = true
        stoneDepth = device.makeDepthStencilState(descriptor: depthTest)!
        harmonicScale = Self.harmonicScales.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }
        func show(_ fragment: String) -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "displayVertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try! device.makeRenderPipelineState(descriptor: descriptor)
        }
        display = show("displayFragment")
        displayFX = show("displayFXFragment")
        bakedDisplay = show("bakedDisplayFragment")
        #if targetEnvironment(simulator)
        usesFX = false
        #else
        usesFX = MTLFXTemporalDenoisedScalerDescriptor.supportsDevice(device)
        #endif
        let pixels = Rock3DScene.surfacePixels
        color = Self.texture(pixels.colors, size: pixels.size, format: .rgba8Unorm_srgb, device: device)
        relief = Self.texture(pixels.relief, size: pixels.size, format: .rgba8Unorm, device: device)
    }

    var isLoaded: Bool {
        geometry != nil
    }

    /// Whether there's more to add to the picture: while MetalFX keeps up with the stones, there's the
    /// full picture to come.
    var isSettling: Bool {
        isBaking || (drewBaked ? stillFrames == 0 : (usesFX && !refining) || stillFrames < Self.samplesWhenStill)
    }

    func load(_ shapes: TraceGeometry) {
        func buffer<T>(_ values: [T]) -> MTLBuffer {
            values.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: max($0.count, 16))! }
        }
        let positions = buffer(shapes.positions)
        geometry = (buffer(shapes.nodes), buffer(shapes.triangles), buffer(shapes.indices), buffer(shapes.normals),
                    buffer(shapes.tangents), buffer(shapes.bitangents), buffer(shapes.coordinates), positions, shapes.stones)
        #if !targetEnvironment(simulator)
        buildShapes(shapes, positions: positions)
        #endif
        stillFrames = 0
        previousPlaces = []
        previousLight = []
        refining = false
    }

    #if !targetEnvironment(simulator)
    /// Builds each stone's triangles into a structure the GPU's ray tracing hardware searches.
    private func buildShapes(_ shapes: TraceGeometry, positions: MTLBuffer) {
        guard let queue = device.makeCommandQueue(), let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeAccelerationStructureCommandEncoder() else { return }
        var built: [MTLAccelerationStructure] = []
        var held: [MTLBuffer] = []
        for stone in shapes.stones {
            let range = Int(stone.first) * 3 ..< Int(stone.first + stone.count) * 3
            let local = shapes.indices[range].map { $0 - stone.vertexBase }
            guard let indexBuffer = local.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }) else { return }
            let triangles = MTLAccelerationStructureTriangleGeometryDescriptor()
            triangles.vertexBuffer = positions
            triangles.vertexBufferOffset = Int(stone.vertexBase) * MemoryLayout<SIMD4<Float>>.stride
            triangles.vertexStride = MemoryLayout<SIMD4<Float>>.stride
            triangles.vertexFormat = .float3
            triangles.indexBuffer = indexBuffer
            triangles.indexType = .uint32
            triangles.triangleCount = Int(stone.count)
            triangles.opaque = true
            let descriptor = MTLPrimitiveAccelerationStructureDescriptor()
            descriptor.geometryDescriptors = [triangles]
            let sizes = device.accelerationStructureSizes(descriptor: descriptor)
            guard let structure = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
                  let scratch = device.makeBuffer(length: max(sizes.buildScratchBufferSize, 16), options: .storageModePrivate) else { return }
            encoder.build(accelerationStructure: structure, descriptor: descriptor, scratchBuffer: scratch, scratchBufferOffset: 0)
            built.append(structure)
            held += [indexBuffer, scratch]
        }
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        _ = held
        self.shapes = built
        instances = (0..<3).compactMap { _ in
            device.makeBuffer(length: MemoryLayout<MTLAccelerationStructureInstanceDescriptor>.stride * built.count, options: .storageModeShared)
        }
    }

    /// Builds where the three stones stand into the structure the ray tracing hardware searches first.
    private func encodeScene(_ stones: [TraceStone], commands: MTLCommandBuffer) -> MTLAccelerationStructure? {
        guard shapes.count == stones.count, !shapes.isEmpty, !instances.isEmpty else { return nil }
        let buffer = instances[instanceTurn]
        instanceTurn = (instanceTurn + 1) % instances.count
        let pointer = buffer.contents().bindMemory(to: MTLAccelerationStructureInstanceDescriptor.self, capacity: stones.count)
        for (k, stone) in stones.enumerated() {
            var instance = MTLAccelerationStructureInstanceDescriptor()
            instance.accelerationStructureIndex = UInt32(k)
            instance.mask = 0xFF
            instance.options = .opaque
            instance.intersectionFunctionTableOffset = 0
            let m = stone.toWorld
            func column(_ c: Int) -> MTLPackedFloat3 {
                MTLPackedFloat3Make(m[c][0], m[c][1], m[c][2])
            }
            instance.transformationMatrix = MTLPackedFloat4x3(columns: (column(0), column(1), column(2), column(3)))
            pointer[k] = instance
        }
        let descriptor = MTLInstanceAccelerationStructureDescriptor()
        descriptor.instancedAccelerationStructures = shapes
        descriptor.instanceCount = stones.count
        descriptor.instanceDescriptorBuffer = buffer
        if scene == nil {
            let sizes = device.accelerationStructureSizes(descriptor: descriptor)
            guard let structure = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
                  let scratch = device.makeBuffer(length: max(sizes.buildScratchBufferSize, 16), options: .storageModePrivate) else { return nil }
            scene = (structure, scratch)
        }
        guard let scene, let encoder = commands.makeAccelerationStructureCommandEncoder() else { return nil }
        encoder.build(accelerationStructure: scene.structure, descriptor: descriptor, scratchBuffer: scene.scratch, scratchBufferOffset: 0)
        encoder.endEncoding()
        return scene.structure
    }
    #endif

    /// The stones where `transforms` put them, for the shaders.
    func stones(_ transforms: [simd_float4x4]) -> [TraceStone] {
        guard let geometry else { return [] }
        return zip(geometry.stones, transforms).enumerated().map { k, pair in
            let (stone, toWorld) = pair
            let middle = (stone.lower + stone.upper) / 2
            let world = toWorld * SIMD4(middle, 1)
            return TraceStone(toObject: toWorld.inverse, toWorld: toWorld,
                              bounds: SIMD4(world.x, world.y, world.z, length(stone.upper - stone.lower) / 2 + 0.002),
                              nodes: stone.nodes, triangles: stone.triangles, index: UInt32(k), first: stone.first)
        }
    }

    /// Adds samples to the picture `uniforms` and `stones` describe and draws it into `background`. Only
    /// `region`, around the stones, is traced; the rest of the scene, the sky and the ground lit by its map, is drawn as a backdrop. While nothing changes,
    /// the samples add up; when something does, the average carries on from as many as `changed` samples
    /// back (0 starts over), so it follows the change without starting from noise. `samples` is how many
    /// samples each pixel takes this frame. Where MetalFX can, it keeps up with the stones while they move;
    /// once they've been still a moment, the full picture takes over and is refined until it settles, as
    /// MetalFX's is softer, with faint dark rims along the stones' edges.
    func encode(_ uniforms: TraceUniforms, stones: [TraceStone], changed: UInt32, region: (x: Range<Int>, y: Range<Int>), samples: UInt32,
                bounces: UInt32, commands: MTLCommandBuffer, background: MTLTexture, grain: MTLTexture?, blank: MTLTexture) {
        guard geometry != nil else {
            encodeOpen(uniforms, commands: commands, background: background, grain: grain, blank: blank)
            return
        }
        defer {
            // A piece or two of the light being worked out, after this frame's own work.
            for _ in 0..<Self.bakeStepsPerFrame where !bakeSteps.isEmpty {
                bakeSteps.removeFirst()(commands)
            }
        }
        var uniforms = uniforms
        let screenWidth = Int(uniforms.viewSize.x), screenHeight = Int(uniforms.viewSize.y)
        // The stones' rectangle, in sizes that change seldom.
        let top = max(0, min(region.y.lowerBound, screenHeight - 32))
        let rows = min(screenHeight - top, (region.y.count + 31) / 32 * 32)
        let left = max(0, min(region.x.lowerBound, screenWidth - 32))
        let columns = min(screenWidth - left, (region.x.count + 31) / 32 * 32)
        uniforms.regionTop = UInt32(top)
        uniforms.regionHeight = UInt32(rows)
        uniforms.regionLeft = UInt32(left)
        uniforms.regionWidth = UInt32(columns)

        // Whether anything has changed since last frame; while nothing does, the samples add up.
        let light = Self.key(of: uniforms)
        let places = stones.flatMap { stone in (0..<4).flatMap { c in (0..<4).map { r in stone.toWorld[c][r] } } }
        let moved = places != previousPlaces || changed == 0
        let still = light == previousLight && !moved
        stillFrames = still ? stillFrames + 1 : 0
        previousLight = light
        previousPlaces = places
        uniforms.limit = still ? 1 << 20 : changed
        let before = previousStones.count == stones.count ? previousStones : stones
        previousStones = stones
        frame &+= 1
        uniforms.frame = frame
        uniforms.samples = samples
        uniforms.bounces = bounces

        var structure: MTLAccelerationStructure?
        #if !targetEnvironment(simulator)
        structure = stones.count == 3 ? encodeScene(stones, commands: commands) : nil
        #endif
        // With the light carried over, there's nothing to add up: a frame is as exact as it gets.
        drewBaked = isBaked && stones.count == 3
        if drewBaked {
            encodeBaked(uniforms, stones: stones, light: light, structure: structure, commands: commands, background: background,
                        grain: grain, blank: blank)
            refining = false
            return
        }
        guard let map = encodeGroundMap(uniforms, stones: stones, commands: commands, structure: structure),
              let backdrop = encodeBackdrop(uniforms, map: map, light: light, commands: commands) else { return }

        #if !targetEnvironment(simulator)
        if usesFX {
            if moved {
                refining = false
            }
            if !refining {
                encodeFX(uniforms, stones: stones, before: before, reset: changed == 0, structure: structure, map: map,
                         backdrop: backdrop, commands: commands, background: background, grain: grain, blank: blank)
                if stillFrames >= Self.framesBeforeRefining {
                    refining = true
                    refined = 0
                    stillFrames = 0
                    hold(background, commands: commands)
                }
                return
            }
        }
        #endif
        encodeTraced(uniforms, stones: stones, before: before, structure: structure, map: map, backdrop: backdrop,
                     commands: commands, background: background, grain: grain, blank: blank)
    }

    /// The stones' rectangle traced at full resolution, each pixel's samples averaged, and drawn over the
    /// backdrop; handed over from MetalFX, it starts afresh and fades in over what was shown.
    private func encodeTraced(_ uniforms: TraceUniforms, stones: [TraceStone], before: [TraceStone], structure: MTLAccelerationStructure?,
                              map: MTLTexture, backdrop: MTLTexture, commands: MTLCommandBuffer, background: MTLTexture,
                              grain: MTLTexture?, blank: MTLTexture) {
        guard let geometry else { return }
        var uniforms = uniforms
        let columns = Int(uniforms.regionWidth), rows = Int(uniforms.regionHeight)
        if columns != regionSize.width || rows != regionSize.height || history.isEmpty {
            regionSize = (columns, rows)
            let pixels = columns * rows
            history = (0..<2).map { _ in
                (device.makeBuffer(length: pixels * 8, options: .storageModePrivate)!,
                 device.makeBuffer(length: pixels * 8, options: .storageModePrivate)!)
            }
            guides = device.makeBuffer(length: pixels * 8, options: .storageModePrivate)
            denoised = (0..<2).map { _ in device.makeBuffer(length: pixels * 8, options: .storageModePrivate)! }
            uniforms.limit = 0
        }
        // The ground's map carries on; the picture starts afresh.
        if usesFX, refined == 0 {
            uniforms.limit = 0
        }
        // Each frame's samples from somewhere else in the pixel, spread evenly (the R2 sequence).
        let n = Float(frame % 4096)
        uniforms.jitter = SIMD2((0.5 + n * 0.754877666).truncatingRemainder(dividingBy: 1) - 0.5,
                                (0.5 + n * 0.569840291).truncatingRemainder(dividingBy: 1) - 0.5)
        let previous = history[current], next = history[1 - current]
        current = 1 - current
        guard let guides else { return }

        if let encoder = commands.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(trace)
            encoder.setTexture(map, index: 2)
            encoder.setBuffer(geometry.positions, offset: 0, index: 15)
            #if !targetEnvironment(simulator)
            if let structure {
                encoder.setAccelerationStructure(structure, bufferIndex: 16)
                for shape in shapes {
                    encoder.useResource(shape, usage: .read)
                }
            }
            #endif
            encoder.setBytes(&uniforms, length: MemoryLayout<TraceUniforms>.stride, index: 0)
            var now = stones, then = before
            while now.count < 3 { now.append(Self.absent) }
            while then.count < 3 { then.append(Self.absent) }
            encoder.setBytes(&now, length: MemoryLayout<TraceStone>.stride * 3, index: 1)
            encoder.setBytes(&then, length: MemoryLayout<TraceStone>.stride * 3, index: 2)
            for (index, buffer) in [geometry.nodes, geometry.triangles, geometry.indices, geometry.normals, geometry.tangents,
                                    geometry.bitangents, geometry.coordinates].enumerated() {
                encoder.setBuffer(buffer, offset: 0, index: 3 + index)
            }
            encoder.setBuffer(previous.color, offset: 0, index: 10)
            encoder.setBuffer(previous.details, offset: 0, index: 11)
            encoder.setBuffer(next.color, offset: 0, index: 12)
            encoder.setBuffer(next.details, offset: 0, index: 13)
            encoder.setBuffer(guides, offset: 0, index: 14)
            encoder.setTexture(color, index: 0)
            encoder.setTexture(relief, index: 1)
            let grid = MTLSize(width: columns, height: rows, depth: 1)
            let group = MTLSize(width: 8, height: 8, depth: 1)
            encoder.dispatchThreads(grid, threadsPerThreadgroup: group)

            // The denoiser, over the same pixels.
            encoder.setComputePipelineState(variance)
            encoder.setBytes(&uniforms, length: MemoryLayout<TraceUniforms>.stride, index: 0)
            encoder.setBuffer(next.color, offset: 0, index: 1)
            encoder.setBuffer(next.details, offset: 0, index: 2)
            encoder.setBuffer(guides, offset: 0, index: 3)
            encoder.setBuffer(denoised[0], offset: 0, index: 4)
            encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
            encoder.setComputePipelineState(atrous)
            for (pass, var step) in [Int32(1), 2, 4, 8].enumerated() {
                encoder.setBytes(&step, length: MemoryLayout<Int32>.stride, index: 1)
                encoder.setBuffer(denoised[pass % 2], offset: 0, index: 2)
                encoder.setBuffer(next.details, offset: 0, index: 3)
                encoder.setBuffer(guides, offset: 0, index: 4)
                encoder.setBuffer(denoised[1 - pass % 2], offset: 0, index: 5)
                encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
            }
            encoder.endEncoding()
        }

        // Handed over from MetalFX, it fades in once enough samples are in to look as clean.
        let t = usesFX ? min(1, max(0, Float(refined - 32) / 32)) : 1
        var fade = t * t * (3 - 2 * t)
        refined += 1
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = background
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
            encoder.setRenderPipelineState(display)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TraceUniforms>.stride, index: 0)
            encoder.setFragmentBuffer(next.color, offset: 0, index: 1)
            encoder.setFragmentBuffer(guides, offset: 0, index: 3)
            encoder.setFragmentBuffer(denoised[0], offset: 0, index: 4)
            encoder.setFragmentBytes(&fade, length: MemoryLayout<Float>.stride, index: 5)
            encoder.setFragmentTexture(grain ?? blank, index: 0)
            encoder.setFragmentTexture(backdrop, index: 1)
            encoder.setFragmentTexture(shownBefore ?? blank, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
    }

    /// Until the stones are there to trace: the sky, and the ground as open to it as it is away from them.
    private func encodeOpen(_ uniforms: TraceUniforms, commands: MTLCommandBuffer, background: MTLTexture, grain: MTLTexture?,
                            blank: MTLTexture) {
        var uniforms = uniforms
        uniforms.regionTop = 0
        uniforms.regionHeight = 0
        uniforms.regionLeft = 0
        uniforms.regionWidth = 0
        if openGround == nil {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
            d.usage = .shaderRead
            openGround = device.makeTexture(descriptor: d)
        }
        guard let openGround else { return }
        let open = uniforms.skyIrradiance + uniforms.keyIrradiance
        var texel = [Float16(open.x), Float16(open.y), Float16(open.z), 1]
        openGround.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &texel, bytesPerRow: 8)
        guard let backdrop = encodeBackdrop(uniforms, map: openGround, light: Self.key(of: uniforms), commands: commands) else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = background
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
            encoder.setRenderPipelineState(bakedDisplay)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TraceUniforms>.stride, index: 0)
            encoder.setFragmentTexture(backdrop, index: 0)
            encoder.setFragmentTexture(blank, index: 1)
            encoder.setFragmentTexture(grain ?? blank, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
    }

    /// Keeps what `background` shows now, for the picture that takes over to fade in over.
    private func hold(_ background: MTLTexture, commands: MTLCommandBuffer) {
        if shownBefore?.width != background.width || shownBefore?.height != background.height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: background.pixelFormat, width: background.width,
                                                             height: background.height, mipmapped: false)
            d.usage = .shaderRead
            d.storageMode = .private
            shownBefore = device.makeTexture(descriptor: d)
        }
        guard let shownBefore, let blit = commands.makeBlitCommandEncoder() else { return }
        blit.copy(from: background, to: shownBefore)
        blit.endEncoding()
    }

    /// The scene away from the stones: the sky, and the ground lit by `map`, seen through the mist, which
    /// is worked out again only when the light changes.
    private func encodeBackdrop(_ uniforms: TraceUniforms, map: MTLTexture, light: [Float], commands: MTLCommandBuffer) -> MTLTexture? {
        let width = Int(uniforms.viewSize.x), height = Int(uniforms.viewSize.y)
        if backdrop?.width != width || backdrop?.height != height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            backdrop = device.makeTexture(descriptor: d)
            mist = device.makeTexture(descriptor: d)
            mistLight = []
        }
        guard let backdrop, let mist else { return nil }
        var whole = uniforms
        let grid = MTLSize(width: width, height: height, depth: 1), group = MTLSize(width: 8, height: 8, depth: 1)
        if light != mistLight, let encoder = commands.makeComputeCommandEncoder() {
            mistLight = light
            encoder.setComputePipelineState(mistPipeline)
            encoder.setBytes(&whole, length: MemoryLayout<TraceUniforms>.stride, index: 0)
            encoder.setTexture(mist, index: 0)
            encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
            encoder.endEncoding()
        }
        if let encoder = commands.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(backdropFX)
            encoder.setBytes(&whole, length: MemoryLayout<TraceUniforms>.stride, index: 0)
            encoder.setTexture(backdrop, index: 0)
            encoder.setTexture(map, index: 1)
            encoder.setTexture(mist, index: 2)
            encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
            encoder.endEncoding()
        }
        return backdrop
    }

    /// Adds a sample to every texel of the ground's light map, carried on from the last frame as far as
    /// `uniforms.limit` says. The map to read this frame.
    private func encodeGroundMap(_ uniforms: TraceUniforms, stones: [TraceStone], commands: MTLCommandBuffer,
                                 structure: MTLAccelerationStructure?) -> MTLTexture? {
        guard let geometry else { return nil }
        if groundMaps.isEmpty {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: Self.groundMapSize,
                                                             height: Self.groundMapSize, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            groundMaps = (0..<2).compactMap { _ in device.makeTexture(descriptor: d) }
        }
        guard groundMaps.count == 2, let encoder = commands.makeComputeCommandEncoder() else { return groundMaps.first }
        let before = groundMaps[groundMapTurn], after = groundMaps[1 - groundMapTurn]
        groundMapTurn = 1 - groundMapTurn
        var uniforms = uniforms
        encoder.setComputePipelineState(groundMapPipeline)
        encoder.setBytes(&uniforms, length: MemoryLayout<TraceUniforms>.stride, index: 0)
        var now = stones
        while now.count < 3 { now.append(Self.absent) }
        encoder.setBytes(&now, length: MemoryLayout<TraceStone>.stride * 3, index: 1)
        for (index, buffer) in [geometry.nodes, geometry.triangles, geometry.indices, geometry.normals, geometry.tangents,
                                geometry.bitangents, geometry.coordinates].enumerated() {
            encoder.setBuffer(buffer, offset: 0, index: 3 + index)
        }
        encoder.setBuffer(geometry.positions, offset: 0, index: 15)
        #if !targetEnvironment(simulator)
        if let structure {
            encoder.setAccelerationStructure(structure, bufferIndex: 16)
            for shape in shapes {
                encoder.useResource(shape, usage: .read)
            }
        }
        #endif
        encoder.setTexture(color, index: 0)
        encoder.setTexture(relief, index: 1)
        encoder.setTexture(before, index: 2)
        encoder.setTexture(after, index: 3)
        encoder.dispatchThreads(MTLSize(width: Self.groundMapSize, height: Self.groundMapSize, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
        return after
    }

    #if !targetEnvironment(simulator)
    /// Traces one sample a pixel of the stones' rectangle at half the screen's resolution and has MetalFX
    /// denoise it and scale it up, carrying the picture along from frame to frame; then draws it over the
    /// backdrop into `background`.
    private func encodeFX(_ uniforms: TraceUniforms, stones: [TraceStone], before: [TraceStone], reset: Bool,
                          structure: MTLAccelerationStructure?, map: MTLTexture, backdrop: MTLTexture, commands: MTLCommandBuffer,
                          background: MTLTexture, grain: MTLTexture?, blank: MTLTexture) {
        var uniforms = uniforms
        let outputWidth = Int(uniforms.regionWidth), outputHeight = Int(uniforms.regionHeight)
        let width = outputWidth / 2, height = outputHeight / 2
        var reset = reset
        if fx?.output.width != outputWidth || fx?.output.height != outputHeight {
            fx = makeFX(width: width, height: height, outputWidth: outputWidth, outputHeight: outputHeight)
            reset = true
        }
        guard let fx, let geometry else { return }

        let screenUniforms = uniforms
        // The stones' rectangle as a view of its own, at half the resolution, each frame's samples from
        // somewhere else in the pixel (the R2 sequence).
        uniforms.center -= SIMD2(Float(uniforms.regionLeft), Float(uniforms.regionTop)) / uniforms.pixelsPerPoint
        uniforms.viewSize = SIMD2(Float(width), Float(height))
        uniforms.pixelsPerPoint *= Float(width) / Float(outputWidth)
        let n = Float(frame % 4096)
        uniforms.jitter = SIMD2((0.5 + n * 0.754877666).truncatingRemainder(dividingBy: 1) - 0.5,
                                (0.5 + n * 0.569840291).truncatingRemainder(dividingBy: 1) - 0.5)
        if let encoder = commands.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(traceFX)
            encoder.setBytes(&uniforms, length: MemoryLayout<TraceUniforms>.stride, index: 0)
            var now = stones, then = before
            while now.count < 3 { now.append(Self.absent) }
            while then.count < 3 { then.append(Self.absent) }
            encoder.setBytes(&now, length: MemoryLayout<TraceStone>.stride * 3, index: 1)
            encoder.setBytes(&then, length: MemoryLayout<TraceStone>.stride * 3, index: 2)
            for (index, buffer) in [geometry.nodes, geometry.triangles, geometry.indices, geometry.normals, geometry.tangents,
                                    geometry.bitangents, geometry.coordinates].enumerated() {
                encoder.setBuffer(buffer, offset: 0, index: 3 + index)
            }
            encoder.setBuffer(geometry.positions, offset: 0, index: 15)
            #if !targetEnvironment(simulator)
            if let structure {
                encoder.setAccelerationStructure(structure, bufferIndex: 16)
                for shape in shapes {
                    encoder.useResource(shape, usage: .read)
                }
            }
            #endif
            encoder.setTexture(color, index: 0)
            encoder.setTexture(relief, index: 1)
            for (index, texture) in [fx.radiance, fx.depth, fx.motion, fx.albedo, fx.specular, fx.normal, fx.roughness].enumerated() {
                encoder.setTexture(texture, index: 2 + index)
            }
            encoder.setTexture(map, index: 9)
            encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            encoder.endEncoding()
        }

        let scaler = fx.scaler
        scaler.colorTexture = fx.radiance
        scaler.depthTexture = fx.depth
        scaler.motionTexture = fx.motion
        scaler.diffuseAlbedoTexture = fx.albedo
        scaler.specularAlbedoTexture = fx.specular
        scaler.normalTexture = fx.normal
        scaler.roughnessTexture = fx.roughness
        scaler.outputTexture = fx.output
        scaler.exposureTexture = fx.exposure
        // Sampling a little to one side of the pixel's middle moves the picture the other way.
        scaler.jitterOffsetX = -uniforms.jitter.x
        scaler.jitterOffsetY = -uniforms.jitter.y
        scaler.motionVectorScaleX = 1
        scaler.motionVectorScaleY = 1
        scaler.isDepthReversed = true
        scaler.shouldResetHistory = reset
        let (view, projection) = Self.camera(uniforms, outputWidth: outputWidth, outputHeight: outputHeight)
        scaler.worldToViewMatrix = view
        scaler.viewToClipMatrix = projection
        scaler.encode(commandBuffer: commands)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = background
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
            var shown = screenUniforms
            encoder.setRenderPipelineState(displayFX)
            encoder.setFragmentBytes(&shown, length: MemoryLayout<TraceUniforms>.stride, index: 0)
            encoder.setFragmentTexture(fx.output, index: 0)
            encoder.setFragmentTexture(grain ?? blank, index: 1)
            encoder.setFragmentTexture(backdrop, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
    }

    private func makeFX(width: Int, height: Int, outputWidth: Int, outputHeight: Int) -> FX? {
        let descriptor = MTLFXTemporalDenoisedScalerDescriptor()
        descriptor.colorTextureFormat = .rgba16Float
        descriptor.depthTextureFormat = .r32Float
        descriptor.motionTextureFormat = .rg16Float
        descriptor.diffuseAlbedoTextureFormat = .rgba16Float
        descriptor.specularAlbedoTextureFormat = .rgba16Float
        descriptor.normalTextureFormat = .rgba16Float
        descriptor.roughnessTextureFormat = .r16Float
        descriptor.outputTextureFormat = .rgba16Float
        descriptor.inputWidth = width
        descriptor.inputHeight = height
        descriptor.outputWidth = outputWidth
        descriptor.outputHeight = outputHeight
        guard let scaler = descriptor.makeTemporalDenoisedScaler(device: device) else { return nil }
        func texture(_ format: MTLPixelFormat, _ usage: MTLTextureUsage, width: Int, height: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.usage = usage.union([.shaderRead, .shaderWrite])
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let radiance = texture(.rgba16Float, scaler.colorTextureUsage, width: width, height: height),
              let depth = texture(.r32Float, scaler.depthTextureUsage, width: width, height: height),
              let motion = texture(.rg16Float, scaler.motionTextureUsage, width: width, height: height),
              let albedo = texture(.rgba16Float, scaler.diffuseAlbedoTextureUsage, width: width, height: height),
              let specular = texture(.rgba16Float, scaler.specularAlbedoTextureUsage, width: width, height: height),
              let normal = texture(.rgba16Float, scaler.normalTextureUsage, width: width, height: height),
              let roughness = texture(.r16Float, scaler.roughnessTextureUsage, width: width, height: height),
              let output = texture(.rgba16Float, scaler.outputTextureUsage, width: outputWidth, height: outputHeight) else { return nil }
        let exposureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: 1, height: 1, mipmapped: false)
        exposureDescriptor.usage = .shaderRead
        guard let exposure = device.makeTexture(descriptor: exposureDescriptor) else { return nil }
        var one = Float16(1)
        exposure.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &one, bytesPerRow: 2)
        return FX(scaler: scaler, radiance: radiance, depth: depth, motion: motion, albedo: albedo, specular: specular,
                  normal: normal, roughness: roughness, output: output, exposure: exposure)
    }

    /// The camera as MetalFX takes it: from the world into its own frame (right, up, ahead), and from there
    /// onto the screen, off center where the stones are, with depth reversed (far is 0) and no far plane.
    private static func camera(_ u: TraceUniforms, outputWidth: Int, outputHeight: Int) -> (simd_float4x4, simd_float4x4) {
        let right = SIMD3(u.right.x, u.right.y, u.right.z), up = SIMD3(u.up.x, u.up.y, u.up.z)
        let ahead = SIMD3(u.forward.x, u.forward.y, u.forward.z), eye = SIMD3(u.eye.x, u.eye.y, u.eye.z)
        let view = simd_float4x4(columns: (SIMD4(right.x, up.x, ahead.x, 0), SIMD4(right.y, up.y, ahead.y, 0),
                                           SIMD4(right.z, up.z, ahead.z, 0),
                                           SIMD4(-simd_dot(right, eye), -simd_dot(up, eye), -simd_dot(ahead, eye), 1)))
        let points = SIMD2(Float(outputWidth), Float(outputHeight)) / (u.pixelsPerPoint * Float(outputWidth) / u.viewSize.x)
        let projection = simd_float4x4(columns: (SIMD4(2 * u.focal / points.x, 0, 0, 0), SIMD4(0, 2 * u.focal / points.y, 0, 0),
                                                 SIMD4(2 * u.center.x / points.x - 1, 1 - 2 * u.center.y / points.y, 0, 1),
                                                 SIMD4(0, 0, 0.05, 0)))
        return (view, projection)
    }
    #endif

    // MARK: Light carried over

    /// Matches `BakeSettings` in PathTracer.metal.
    private struct BakeSettings {
        var round: UInt32 = 0
        var samples: UInt32
        var first: UInt32 = 0
        var count: UInt32 = 0
        var bases: SIMD4<UInt32>
        var stoneAlbedo: Float
        var groundSize: UInt32
        var unused = SIMD2<UInt32>.zero
    }

    /// Where each stone's vertices begin, and how many there are in all.
    private var vertexBases: SIMD4<UInt32> {
        guard let geometry, geometry.stones.count == 3 else { return .zero }
        let stones = geometry.stones
        return SIMD4(stones[0].vertexBase, stones[1].vertexBase, stones[2].vertexBase, stones[2].vertexBase + stones[2].vertexCount)
    }

    /// The stones' shapes and where they are, `stones`, for a kernel that traces rays among them.
    private func bindGeometry(_ encoder: MTLComputeCommandEncoder, stones: [TraceStone], structure: MTLAccelerationStructure?) {
        guard let geometry else { return }
        var now = stones
        while now.count < 3 { now.append(Self.absent) }
        encoder.setBytes(&now, length: MemoryLayout<TraceStone>.stride * 3, index: 1)
        for (index, buffer) in [geometry.nodes, geometry.triangles, geometry.indices, geometry.normals, geometry.tangents,
                                geometry.bitangents, geometry.coordinates].enumerated() {
            encoder.setBuffer(buffer, offset: 0, index: 3 + index)
        }
        encoder.setBuffer(geometry.positions, offset: 0, index: 15)
        #if !targetEnvironment(simulator)
        if let structure {
            encoder.setAccelerationStructure(structure, bufferIndex: 16)
            for shape in shapes {
                encoder.useResource(shape, usage: .read)
            }
        }
        #endif
    }

    #if targetEnvironment(simulator)
    private static let bakeStepsPerFrame = 1
    #else
    private static let bakeStepsPerFrame = 2
    #endif

    /// Holds the resting stones as the ray tracing hardware searches them, once built, with what built it.
    private final class Resting {
        var structure: MTLAccelerationStructure?
        var held: [MTLBuffer] = []
    }

    /// Works out, once, what reaches each point of the stones and of the ground around them from each
    /// direction, for each of `poses` (resting, paused and focusing, the stack turned to the front), in
    /// three rounds, each adding a bounce between the stones and the ground; the stones throw back
    /// `stoneAlbedo` of the light that falls on them. It's done a piece a frame, so the scene keeps
    /// moving meanwhile, and kept on disk for next time. Then `done`.
    func bake(poses: [[TraceStone]], stoneAlbedo: Float, done: @escaping @MainActor () -> Void) {
        guard let geometry, !isBaking, transfers.isEmpty, poses.count == 3, poses.allSatisfy({ $0.count == 3 }) else { return }
        let key = bakeKey(poses: poses, stoneAlbedo: stoneAlbedo)
        if let kept = loadBake(key) {
            transfers = kept
            done()
            return
        }
        let vertexCount = Int(vertexBases.w), size = Self.bakedGroundSize
        let stoneBytes = vertexCount * Self.transferSize * 2, groundBytes = size * size * Self.transferSize * 2
        let triangleCount = UInt32(geometry.stones.reduce(0) { max($0, Int($1.first + $1.count)) })
        var steps: [(MTLCommandBuffer) -> Void] = []
        var results: [(stones: MTLBuffer, ground: MTLBuffer)] = []
        for pose in poses {
            guard let s0 = device.makeBuffer(length: stoneBytes, options: .storageModePrivate),
                  let s1 = device.makeBuffer(length: stoneBytes, options: .storageModePrivate),
                  let g0 = device.makeBuffer(length: groundBytes, options: .storageModePrivate),
                  let g1 = device.makeBuffer(length: groundBytes, options: .storageModePrivate) else { return }
            let resting = Resting()
            #if !targetEnvironment(simulator)
            steps.append { [weak self] commands in
                self?.buildResting(pose, into: resting, commands: commands)
            }
            #endif
            var stonesBefore = s0, stonesAfter = s1, groundBefore = g0, groundAfter = g1
            for round in 0..<3 {
                let base = BakeSettings(round: UInt32(round), samples: Self.bakeSamples, bases: vertexBases, stoneAlbedo: stoneAlbedo,
                                        groundSize: UInt32(size))
                let (before, after, groundSeen, groundMade) = (stonesBefore, stonesAfter, groundBefore, groundAfter)
                let chunk = 4096
                for first in stride(from: 0, to: vertexCount, by: chunk) {
                    var settings = base
                    settings.first = UInt32(first)
                    settings.count = UInt32(min(chunk, vertexCount - first))
                    steps.append { [weak self] commands in
                        guard let self, let encoder = commands.makeComputeCommandEncoder() else { return }
                        encoder.setComputePipelineState(bakeStones)
                        encoder.setBytes(&settings, length: MemoryLayout<BakeSettings>.stride, index: 0)
                        bindGeometry(encoder, stones: pose, structure: resting.structure)
                        encoder.setBuffer(harmonicScale, offset: 0, index: 17)
                        encoder.setBuffer(before, offset: 0, index: 18)
                        encoder.setBuffer(groundSeen, offset: 0, index: 19)
                        encoder.setBuffer(after, offset: 0, index: 20)
                        encoder.dispatchThreads(MTLSize(width: Int(settings.count), height: 1, depth: 1),
                                                threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
                        encoder.endEncoding()
                    }
                }
                let rows = 16
                for first in stride(from: 0, to: size, by: rows) {
                    var settings = base
                    settings.first = UInt32(first)
                    settings.count = UInt32(min(rows, size - first))
                    steps.append { [weak self] commands in
                        guard let self, let encoder = commands.makeComputeCommandEncoder() else { return }
                        encoder.setComputePipelineState(bakeGround)
                        encoder.setBytes(&settings, length: MemoryLayout<BakeSettings>.stride, index: 0)
                        bindGeometry(encoder, stones: pose, structure: resting.structure)
                        encoder.setBuffer(harmonicScale, offset: 0, index: 17)
                        encoder.setBuffer(before, offset: 0, index: 18)
                        encoder.setBuffer(groundMade, offset: 0, index: 20)
                        encoder.dispatchThreads(MTLSize(width: size, height: Int(settings.count), depth: 1),
                                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
                        encoder.endEncoding()
                    }
                }
                swap(&stonesBefore, &stonesAfter)
                swap(&groundBefore, &groundAfter)
            }
            let kept = (stones: stonesBefore, ground: groundBefore)
            steps.append { [weak self] commands in
                guard let self, let encoder = commands.makeComputeCommandEncoder() else { return }
                var triangles = triangleCount
                var bases = vertexBases
                var now = pose
                encoder.setComputePipelineState(fillBuried)
                encoder.setBytes(&triangles, length: MemoryLayout<UInt32>.stride, index: 0)
                encoder.setBytes(&now, length: MemoryLayout<TraceStone>.stride * 3, index: 1)
                encoder.setBuffer(geometry.indices, offset: 0, index: 5)
                encoder.setBuffer(geometry.positions, offset: 0, index: 15)
                encoder.setBytes(&bases, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 19)
                encoder.setBuffer(kept.stones, offset: 0, index: 20)
                encoder.dispatchThreads(MTLSize(width: Int(triangles), height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
                encoder.endEncoding()
                commands.addCompletedHandler { _ in
                    _ = resting
                }
            }
            results.append(kept)
        }
        steps.append { [weak self] commands in
            commands.addCompletedHandler { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    transfers = results
                    isBaking = false
                    saveBake(key)
                    done()
                }
            }
        }
        bakeSteps = steps
        isBaking = true
    }

    #if !targetEnvironment(simulator)
    /// Builds the stones resting as `stones` into a structure the ray tracing hardware searches, into
    /// `resting`, ahead of the work in `commands` that uses it.
    private func buildResting(_ stones: [TraceStone], into resting: Resting, commands: MTLCommandBuffer) {
        guard shapes.count == stones.count, !shapes.isEmpty,
              let buffer = device.makeBuffer(length: MemoryLayout<MTLAccelerationStructureInstanceDescriptor>.stride * stones.count,
                                             options: .storageModeShared) else { return }
        let pointer = buffer.contents().bindMemory(to: MTLAccelerationStructureInstanceDescriptor.self, capacity: stones.count)
        for (k, stone) in stones.enumerated() {
            var instance = MTLAccelerationStructureInstanceDescriptor()
            instance.accelerationStructureIndex = UInt32(k)
            instance.mask = 0xFF
            instance.options = .opaque
            let m = stone.toWorld
            func column(_ c: Int) -> MTLPackedFloat3 {
                MTLPackedFloat3Make(m[c][0], m[c][1], m[c][2])
            }
            instance.transformationMatrix = MTLPackedFloat4x3(columns: (column(0), column(1), column(2), column(3)))
            pointer[k] = instance
        }
        let descriptor = MTLInstanceAccelerationStructureDescriptor()
        descriptor.instancedAccelerationStructures = shapes
        descriptor.instanceCount = stones.count
        descriptor.instanceDescriptorBuffer = buffer
        let sizes = device.accelerationStructureSizes(descriptor: descriptor)
        guard let structure = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
              let scratch = device.makeBuffer(length: max(sizes.buildScratchBufferSize, 16), options: .storageModePrivate),
              let encoder = commands.makeAccelerationStructureCommandEncoder() else { return }
        encoder.build(accelerationStructure: structure, descriptor: descriptor, scratchBuffer: scratch, scratchBufferOffset: 0)
        encoder.endEncoding()
        resting.structure = structure
        resting.held = [buffer, scratch]
    }
    #endif

    /// What names a bake: the stones' shapes and poses and how it's worked out.
    private func bakeKey(poses: [[TraceStone]], stoneAlbedo: Float) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ bytes: UnsafeRawBufferPointer) {
            for byte in bytes {
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            }
        }
        if let geometry {
            mix(UnsafeRawBufferPointer(start: geometry.positions.contents(), count: geometry.positions.length))
        }
        for pose in poses {
            for stone in pose {
                var m = stone.toWorld
                withUnsafeBytes(of: &m) { mix($0) }
            }
        }
        var settings = (stoneAlbedo, Self.bakeSamples, UInt32(Self.transferSize), UInt32(Self.bakedGroundSize), UInt32(2))
        withUnsafeBytes(of: &settings) { mix($0) }
        return String(hash, radix: 16)
    }

    private static func bakeURL(_ key: String) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("StoneLight-\(key).bin")
    }

    /// A bake kept on disk under `key`, if there is one.
    private func loadBake(_ key: String) -> [(stones: MTLBuffer, ground: MTLBuffer)]? {
        guard let url = Self.bakeURL(key), let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let stoneBytes = Int(vertexBases.w) * Self.transferSize * 2, groundBytes = Self.bakedGroundSize * Self.bakedGroundSize * Self.transferSize * 2
        guard data.count == 3 * (stoneBytes + groundBytes) else { return nil }
        return data.withUnsafeBytes { raw -> [(stones: MTLBuffer, ground: MTLBuffer)]? in
            var kept: [(stones: MTLBuffer, ground: MTLBuffer)] = []
            for pose in 0..<3 {
                let at = pose * (stoneBytes + groundBytes)
                guard let base = raw.baseAddress,
                      let stones = device.makeBuffer(bytes: base + at, length: stoneBytes, options: .storageModeShared),
                      let ground = device.makeBuffer(bytes: base + at + stoneBytes, length: groundBytes, options: .storageModeShared) else { return nil }
                kept.append((stones, ground))
            }
            return kept
        }
    }

    /// Keeps the bake on disk under `key`, copied off the GPU first.
    private func saveBake(_ key: String) {
        guard let url = Self.bakeURL(key), let queue = device.makeCommandQueue(), let commands = queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else { return }
        var copies: [MTLBuffer] = []
        for (stones, ground) in transfers {
            for buffer in [stones, ground] {
                guard let copy = device.makeBuffer(length: buffer.length, options: .storageModeShared) else { return }
                blit.copy(from: buffer, sourceOffset: 0, to: copy, destinationOffset: 0, size: buffer.length)
                copies.append(copy)
            }
        }
        blit.endEncoding()
        commands.addCompletedHandler { _ in
            var data = Data()
            for copy in copies {
                data.append(Data(bytes: copy.contents(), count: copy.length))
            }
            try? data.write(to: url, options: .atomic)
            // Only this one is any use now: the light worked out for stones as they were, and the shading
            // kept by earlier versions, go.
            let folder = url.deletingLastPathComponent()
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            where name.hasPrefix("Stone") && name.hasSuffix(".bin") && name != url.lastPathComponent {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
        }
        commands.commit()
    }

    /// Draws the scene with the light carried over: each stone vertex's light and the ground's, summed
    /// from what they keep and the light around the stack turned into its frame, with the key light's
    /// shadows traced; the backdrop; the stones drawn over it, four samples a pixel; and all of it as the
    /// screen shows it, into `background`.
    private func encodeBaked(_ uniforms: TraceUniforms, stones: [TraceStone], light: [Float], structure: MTLAccelerationStructure?,
                             commands: MTLCommandBuffer, background: MTLTexture, grain: MTLTexture?, blank: MTLTexture) {
        guard let geometry, transfers.count == 3 else { return }
        var uniforms = uniforms
        let from = transfers[min(max(poseBlend.from, 0), 2)], to = transfers[min(max(poseBlend.to, 0), 2)]
        var blend = min(max(poseBlend.progress, 0), 1)
        if environment?.light != light {
            let around = Self.environment(uniforms)
            environment = (light, around.rest, around.key, around.around)
        }
        guard let environment else { return }
        // The light around the stack in its own frame, turned the other way.
        let packed = Self.turned(environment.rest, by: -turn).map { SIMD4($0, 0) }
            + Self.turned(environment.key, by: -turn).map { SIMD4($0, 0) } + [uniforms.groundAlbedo, SIMD4(stoneBounce, 0, 0, 0)]
        var bases = vertexBases
        let vertexCount = Int(bases.w)
        if vertexLight == nil {
            vertexLight = device.makeBuffer(length: max(vertexCount, 1) * 2 * MemoryLayout<SIMD4<Float>>.stride, options: .storageModePrivate)
        }
        if bakedMaps == nil {
            func map(_ size: Int) -> MTLTexture? {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: size, height: size, mipmapped: false)
                d.usage = [.shaderRead, .shaderWrite]
                d.storageMode = .private
                return device.makeTexture(descriptor: d)
            }
            if let kept = map(Self.bakedGroundSize), let key = map(Self.bakedGroundSize), let world = map(Self.groundMapSize) {
                bakedMaps = (kept, key, world)
            }
        }
        guard let vertexLight, let bakedMaps, let encoder = commands.makeComputeCommandEncoder() else { return }
        let size = Self.bakedGroundSize
        let line = MTLSize(width: 64, height: 1, depth: 1), square = MTLSize(width: 8, height: 8, depth: 1)

        encoder.setComputePipelineState(stoneLight)
        encoder.setBytes(&uniforms, length: MemoryLayout<TraceUniforms>.stride, index: 0)
        bindGeometry(encoder, stones: stones, structure: structure)
        packed.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 17) }
        encoder.setBuffer(from.stones, offset: 0, index: 18)
        encoder.setBytes(&bases, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 19)
        encoder.setBuffer(vertexLight, offset: 0, index: 20)
        encoder.setBuffer(to.stones, offset: 0, index: 21)
        encoder.setBytes(&blend, length: MemoryLayout<Float>.stride, index: 22)
        encoder.dispatchThreads(MTLSize(width: vertexCount, height: 1, depth: 1), threadsPerThreadgroup: line)

        encoder.setComputePipelineState(groundHarmonics)
        packed.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 17) }
        encoder.setBuffer(from.ground, offset: 0, index: 18)
        encoder.setBuffer(to.ground, offset: 0, index: 21)
        encoder.setBytes(&blend, length: MemoryLayout<Float>.stride, index: 22)
        encoder.setTexture(bakedMaps.kept, index: 0)
        encoder.dispatchThreads(MTLSize(width: size, height: size, depth: 1), threadsPerThreadgroup: square)

        encoder.setComputePipelineState(groundKey)
        encoder.setBytes(&uniforms, length: MemoryLayout<TraceUniforms>.stride, index: 0)
        bindGeometry(encoder, stones: stones, structure: structure)
        encoder.setTexture(bakedMaps.key, index: 0)
        encoder.dispatchThreads(MTLSize(width: size, height: size, depth: 1), threadsPerThreadgroup: square)

        encoder.setComputePipelineState(groundBaked)
        encoder.setBytes(&uniforms, length: MemoryLayout<TraceUniforms>.stride, index: 0)
        var turning = SIMD2(cos(turn), sin(turn))
        encoder.setBytes(&turning, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.setTexture(bakedMaps.kept, index: 0)
        encoder.setTexture(bakedMaps.key, index: 1)
        encoder.setTexture(bakedMaps.map, index: 2)
        encoder.dispatchThreads(MTLSize(width: Self.groundMapSize, height: Self.groundMapSize, depth: 1), threadsPerThreadgroup: square)
        encoder.endEncoding()

        guard let backdrop = encodeBackdrop(uniforms, map: bakedMaps.map, light: light, commands: commands),
              let targets = stoneTargets(width: Int(uniforms.regionWidth), height: Int(uniforms.regionHeight)) else { return }

        // The stones, four samples a pixel, kept only as each pixel's average.
        let drawing = MTLRenderPassDescriptor()
        drawing.colorAttachments[0].texture = targets.samples
        drawing.colorAttachments[0].resolveTexture = targets.color
        drawing.colorAttachments[0].loadAction = .clear
        drawing.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        drawing.colorAttachments[0].storeAction = .multisampleResolve
        drawing.depthAttachment.texture = targets.zBuffer
        drawing.depthAttachment.loadAction = .clear
        drawing.depthAttachment.clearDepth = 0
        drawing.depthAttachment.storeAction = .dontCare
        if let encoder = commands.makeRenderCommandEncoder(descriptor: drawing) {
            encoder.setRenderPipelineState(stoneRaster)
            encoder.setDepthStencilState(stoneDepth)
            encoder.setCullMode(.none)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<TraceUniforms>.stride, index: 0)
            for (index, buffer) in [geometry.positions, geometry.normals, geometry.tangents, geometry.bitangents,
                                    geometry.coordinates, vertexLight].enumerated() {
                encoder.setVertexBuffer(buffer, offset: 0, index: 2 + index)
            }
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TraceUniforms>.stride, index: 0)
            let world = environment.around.map { SIMD4($0, 0) }
            world.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
            encoder.setFragmentBuffer(harmonicScale, offset: 0, index: 2)
            encoder.setFragmentTexture(color, index: 0)
            encoder.setFragmentTexture(relief, index: 1)
            for (k, stone) in stones.enumerated() {
                var toWorld = stone.toWorld
                encoder.setVertexBytes(&toWorld, length: MemoryLayout<simd_float4x4>.stride, index: 1)
                let shape = geometry.stones[k]
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: Int(shape.count) * 3, indexType: .uint32,
                                              indexBuffer: geometry.indices, indexBufferOffset: Int(shape.first) * 3 * MemoryLayout<UInt32>.stride)
            }
            encoder.endEncoding()
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = background
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
            encoder.setRenderPipelineState(bakedDisplay)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TraceUniforms>.stride, index: 0)
            encoder.setFragmentTexture(backdrop, index: 0)
            encoder.setFragmentTexture(targets.color, index: 1)
            encoder.setFragmentTexture(grain ?? blank, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
    }

    /// What the stones are drawn into, `width` by `height` pixels: the samples only while they're drawn,
    /// where the GPU can keep them on chip, and the average each pixel resolves to.
    private func stoneTargets(width: Int, height: Int) -> (color: MTLTexture, samples: MTLTexture, zBuffer: MTLTexture)? {
        if let stoneTargets, stoneTargets.color.width == width, stoneTargets.color.height == height {
            return stoneTargets
        }
        func target(_ format: MTLPixelFormat, samples: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.usage = samples > 1 ? .renderTarget : [.renderTarget, .shaderRead]
            if samples > 1 {
                d.textureType = .type2DMultisample
                d.sampleCount = samples
                d.storageMode = .memoryless
                if let texture = device.makeTexture(descriptor: d) {
                    return texture
                }
            }
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let color = target(.rgba16Float, samples: 1), let samples = target(.rgba16Float, samples: 4),
              let zBuffer = target(.depth32Float, samples: 4) else { return nil }
        stoneTargets = (color, samples, zBuffer)
        return stoneTargets
    }

    /// The factor that brings each real spherical harmonic (see `harmonics` in PathTracer.metal) to unit
    /// size over the sphere.
    nonisolated static let harmonicScales: [Float] = {
        func factorial(_ n: Int) -> Double {
            n <= 1 ? 1 : Double(n) * factorial(n - 1)
        }
        var scales = [Float](repeating: 0, count: harmonicCount)
        for l in 0..<harmonicOrder {
            for m in -l...l {
                let k = (Double(2 * l + 1) / (4 * .pi) * factorial(l - abs(m)) / factorial(l + abs(m))).squareRoot()
                scales[l * l + l + m] = Float(m == 0 ? k : k * 2.0.squareRoot())
            }
        }
        return scales
    }()

    /// The real spherical harmonics toward `d`, into `y`: the same as `harmonics` in PathTracer.metal.
    nonisolated static func harmonics(_ d: SIMD3<Float>, into y: inout [Float]) {
        let scales = harmonicScales
        let px = d.x, py = -d.z, pz = d.y
        var c: Float = 1, s: Float = 0, pmm: Float = 1
        for m in 0..<harmonicOrder {
            if m > 0 {
                let nc = c * px - s * py
                s = c * py + s * px
                c = nc
                pmm *= Float(2 * m - 1)
            }
            var before: Float = 0, last: Float = 0
            for l in m..<harmonicOrder {
                let p: Float = l == m ? pmm : l == m + 1 ? pz * Float(2 * m + 1) * pmm
                    : (Float(2 * l - 1) * pz * last - Float(l + m - 1) * before) / Float(l - m)
                before = last
                last = p
                let i = l * l + l
                if m == 0 {
                    y[i] = scales[i] * p
                } else {
                    y[i + m] = scales[i + m] * p * c
                    y[i - m] = scales[i - m] * p * s
                }
            }
        }
    }

    /// The directions the sky is summed over, a grid in height and around, with the solid angle each
    /// stands for and the harmonics toward each, worked out once.
    private static let skyGrid: (directions: [SIMD3<Float>], weights: [Float], basis: [Float]) = {
        let rows = 32, columns = 64
        var directions: [SIMD3<Float>] = [], weights: [Float] = [], basis: [Float] = []
        var y = [Float](repeating: 0, count: harmonicCount)
        for i in 0..<rows {
            let polar = (Float(i) + 0.5) / Float(rows) * .pi
            let height = cos(polar), out = sin(polar)
            for j in 0..<columns {
                let around = (Float(j) + 0.5) / Float(columns) * 2 * .pi
                let d = SIMD3(out * cos(around), height, out * sin(around))
                directions.append(d)
                weights.append(out * (.pi / Float(rows)) * (2 * .pi / Float(columns)))
                harmonics(d, into: &y)
                basis += y
            }
        }
        return (directions, weights, basis)
    }()

    /// The light around the stones as harmonics in the world: the sky with its glow, as `sky` in
    /// PathTracer.metal has it, above the horizon (below it is the ground, whose light the stones and the
    /// ground keep a share for); the key light on its own, the same across its disc, as far as bounced
    /// light needs it; and all of it with the ground below the horizon as pale as the sky there.
    private static func environment(_ u: TraceUniforms) -> (rest: [SIMD3<Float>], key: [SIMD3<Float>], around: [SIMD3<Float>]) {
        func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
            let t = min(1, max(0, (x - a) / (b - a)))
            return t * t * (3 - 2 * t)
        }
        var rest = [SIMD3<Float>](repeating: .zero, count: harmonicCount), key = rest, below = rest
        let horizon = SIMD3(u.skyHorizon.x, u.skyHorizon.y, u.skyHorizon.z), top = SIMD3(u.skyTop.x, u.skyTop.y, u.skyTop.z)
        let glow = SIMD3(u.glow.x, u.glow.y, u.glow.z), center = SIMD3(u.glowCenter.x, u.glowCenter.y, u.glowCenter.z)
        let grid = skyGrid
        grid.basis.withUnsafeBufferPointer { basis in
            for (n, d) in grid.directions.enumerated() {
                let y = basis.baseAddress! + n * harmonicCount
                if d.y > 0 {
                    let elevation = asin(d.y)
                    var color = horizon + (top - horizon) * smoothstep(0, 0.55, elevation)
                    color *= 1 + (u.zenith - 1) * smoothstep(u.zenithFrom, u.zenithTo, elevation)
                    let angle = acos(min(1, max(-1, simd_dot(d, center))))
                    let radiance = (color + glow * exp(-angle * angle / (u.glow.w * u.glow.w))) * grid.weights[n]
                    for k in 0..<harmonicCount {
                        rest[k] += radiance * y[k]
                    }
                } else {
                    let radiance = horizon * grid.weights[n]
                    for k in 0..<harmonicCount {
                        below[k] += radiance * y[k]
                    }
                }
            }
        }
        // Only bounced light comes of the key light's harmonics (its straight light is traced), and bounced
        // light needs only the first few.
        let axis = SIMD3(u.key.x, u.key.y, u.key.z), radiance = SIMD3(u.keyRadiance.x, u.keyRadiance.y, u.keyRadiance.z)
        let samples = 256, solid = 2 * Float.pi * (1 - u.key.w)
        let helper = abs(axis.y) < 0.99 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
        let t = simd_normalize(simd_cross(helper, axis)), b = simd_cross(axis, t)
        var y = [Float](repeating: 0, count: harmonicCount)
        for s in 0..<samples {
            let v = (Float(s) + 0.5) / Float(samples)
            let c = 1 - v * (1 - u.key.w), sine = (max(0, 1 - c * c)).squareRoot()
            let phi = 2 * Float.pi * (Float(s) * 0.6180339887).truncatingRemainder(dividingBy: 1)
            let d = t * (sine * cos(phi)) + b * (sine * sin(phi)) + axis * c
            guard d.y > 0 else { continue }
            harmonics(d, into: &y)
            for k in 0..<9 {
                key[k] += radiance * (y[k] * solid / Float(samples))
            }
        }
        return (rest, key, (0..<harmonicCount).map { rest[$0] + key[$0] + below[$0] })
    }

    /// `coefficients` of the harmonics turned by `angle` about the vertical.
    private static func turned(_ coefficients: [SIMD3<Float>], by angle: Float) -> [SIMD3<Float>] {
        var out = coefficients
        for l in 1..<harmonicOrder {
            let i = l * l + l
            for m in 1...l {
                let a = coefficients[i + m], b = coefficients[i - m]
                let c = cos(Float(m) * angle), s = sin(Float(m) * angle)
                out[i + m] = a * c - b * s
                out[i - m] = a * s + b * c
            }
        }
        return out
    }


    /// A stone that isn't there: nothing meets it.
    private static let absent = TraceStone(toObject: matrix_identity_float4x4, toWorld: matrix_identity_float4x4,
                                           bounds: SIMD4(0, -100, 0, 0), nodes: 0, triangles: 0, index: 0, first: 0)

    /// Everything in `uniforms` that changes the picture: not where in the pixel, which frame, or which
    /// part of the view; and only changes big enough to see (as the sky drifts through the day).
    private static func key(of uniforms: TraceUniforms) -> [Float] {
        var copy = uniforms
        copy.jitter = .zero
        copy.frame = 0
        copy.limit = 0
        copy.regionTop = 0
        copy.regionHeight = 0
        copy.regionLeft = 0
        copy.regionWidth = 0
        copy.samples = 0
        copy.bounces = 0
        return withUnsafeBytes(of: &copy) { Array($0.bindMemory(to: Float.self)) }.map { ($0 * 1024).rounded() / 1024 }
    }

    private static func texture(_ pixels: [UInt8], size: Int, format: MTLPixelFormat, device: MTLDevice) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size, height: size, mipmapped: true)
        descriptor.usage = .shaderRead
        let texture = device.makeTexture(descriptor: descriptor)!
        pixels.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: size * 4)
        }
        if let queue = device.makeCommandQueue(), let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            commands.commit()
        }
        return texture
    }
}

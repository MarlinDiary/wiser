//
//  Pebble.swift
//  Wiser
//
//  Created by Marlin on 18/10/2026.
//

import simd
import UIKit

/// A smooth pebble whose front view matches the silhouette of a stone image.
///
/// The outline is traced from the image's alpha channel, then the shape is inflated front and back
/// like a soft pillow, so the stone keeps its drawn outline but has real depth when it turns.
///
/// Lengths are in points of the image: x points right, y up and z toward the viewer, with the origin
/// in the middle of the image.
nonisolated struct Pebble: Sendable {
    struct Shape {
        /// Half the stone's thickness in front of the outline.
        var front: Float
        /// Half the stone's thickness behind the outline, in the middle; toward the edge it eases to match
        /// the front, so the two faces meet without a crease.
        var back: Float
        /// How far the surface swells and dips, as a fraction of the thickness.
        var bumpiness: Float = 0
        /// Exponent of the cross section: 2 is an ellipse, higher flattens the faces.
        var profile: Float = 2
        /// How far the stone's widest outline wanders in front of and behind a flat plane, as a share of
        /// its thickness, as it would on a real pebble.
        var wander: Float = 0
        /// How worn the outline is: how far round, in degrees, each of its turns is eased.
        var wear: Float = 0
        var inflation: Inflation = .membrane
        var seed: UInt64 = 1
    }

    /// How the outline is filled out into a stone.
    enum Inflation {
        /// Each ray out from the middle of a face its own quarter ellipse: full right out to the ends, but
        /// where the outline bulges, a ridge runs out to the bulge.
        case rays
        /// A membrane over the outline, pushed up evenly: smooth all over, whatever the outline.
        case membrane
    }

    struct Surface {
        var positions: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var textureCoordinates: [SIMD2<Float>]
        /// Triangles, counterclockwise as seen from outside.
        var indices: [UInt32]
    }

    let surface: Surface
    /// For a stone of even density.
    let volume: Float
    let centerOfMass: SIMD3<Float>

    /// - Parameters:
    ///   - imageName: an asset whose alpha channel is the stone's silhouette, one pixel per point.
    ///   - pointsPerTexture: texture coordinates repeat every this many points of surface,
    ///     so a texture has the same scale everywhere on every stone.
    init?(imageName: String, shape: Shape, pointsPerTexture: Float = 512) {
        guard let silhouette = Silhouette(imageName: imageName) else { return nil }
        surface = Self.surface(radii: Self.worn(silhouette.outline(samples: 256), by: shape.wear), center: silhouette.centroid,
                               width: Float(silhouette.width), height: Float(silhouette.height),
                               shape: shape, pointsPerTexture: pointsPerTexture)
        (volume, centerOfMass) = Self.massProperties(of: surface)
    }

    private init(surface: Surface) {
        self.surface = surface
        (volume, centerOfMass) = Self.massProperties(of: surface)
    }

    /// The same stone with a seat worn into its underside where, placed at `pose`, it would otherwise
    /// pass into `lower` placed at `lowerPose`, so that it rests on it snugly instead: a shallow dish worn
    /// smooth, as water wears a stone, that leaves `clearance` points between the stones and eases out
    /// over `blend` points across and up, so the underside stays as rounded as the rest of the stone.
    func seated(at pose: StoneStack.Pose, on lower: StoneStack.Stone, at lowerPose: StoneStack.Pose,
                clearance: Float = 0.3, blend: Float) -> Pebble {
        let points = surface.positions.map(pose.apply)
        let lifts = StoneStack.lift(points, outOf: lower, at: lowerPose, clearance: clearance)
        let seat = lifts.indices.filter { lifts[$0] > 0 }
        guard !seat.isEmpty else { return self }

        // A map of how far up the underside has to go, across the ground under the stone.
        let cell: Float = 2
        let reach = Int((blend / cell).rounded(.up))
        var low = SIMD2<Float>(repeating: .infinity), high = SIMD2<Float>(repeating: -.infinity)
        for i in seat {
            low = simd_min(low, SIMD2(points[i].x, points[i].z))
            high = simd_max(high, SIMD2(points[i].x, points[i].z))
        }
        low -= blend + 2 * cell
        high += blend + 2 * cell
        let columns = Int(((high.x - low.x) / cell).rounded(.up)) + 1, rows = Int(((high.y - low.y) / cell).rounded(.up)) + 1
        var field = [Float](repeating: 0, count: columns * rows)
        for i in seat {
            let c = Int(((points[i].x - low.x) / cell).rounded()), r = Int(((points[i].z - low.y) / cell).rounded())
            field[r * columns + c] = max(field[r * columns + c], lifts[i])
        }
        // Spread out so each spot takes the most of what's around it, falling off smoothly within
        // `blend` (a bump that's the same both ways, so this is exact taken one way and then the other);
        // then softened, so where two spots' bumps meet there's no crease.
        func pass(_ values: [Float], kernel: [Float], combine: (Float, Float) -> Float, start: Float) -> [Float] {
            var result = values
            let half = kernel.count / 2
            for horizontal in [true, false] {
                let source = result
                for r in 0..<rows {
                    for c in 0..<columns {
                        var value = start
                        for d in -half...half {
                            let rr = horizontal ? r : r + d, cc = horizontal ? c + d : c
                            guard rr >= 0, rr < rows, cc >= 0, cc < columns else { continue }
                            value = combine(value, source[rr * columns + cc] * kernel[d + half])
                        }
                        result[r * columns + c] = value
                    }
                }
            }
            return result
        }
        let bump = (-reach...reach).map { d -> Float in
            let s = Float(d) / Float(reach)
            return (1 - s * s) * (1 - s * s)
        }
        let soft = reach / 3
        let gauss = (-soft...soft).map { d -> Float in exp(-Float(d * d) / Float(2 * max(soft * soft / 4, 1))) }
        let total = gauss.reduce(0, +)
        field = pass(pass(field, kernel: bump, combine: max, start: 0), kernel: gauss.map { $0 / total }, combine: +, start: 0)
        func spread(at x: Float, _ z: Float) -> Float {
            let p = (SIMD2(x, z) - low) / cell
            let c = Int(p.x.rounded(.down)), r = Int(p.y.rounded(.down))
            guard c >= 0, r >= 0, c + 1 < columns, r + 1 < rows else { return 0 }
            let t = p - SIMD2(Float(c), Float(r))
            let top = field[r * columns + c] * (1 - t.x) + field[r * columns + c + 1] * t.x
            let bottom = field[(r + 1) * columns + c] * (1 - t.x) + field[(r + 1) * columns + c + 1] * t.x
            return top * (1 - t.y) + bottom * t.y
        }
        // Softening brings the most down a little; bring it back up so the stones still don't meet.
        let short = seat.map { lifts[$0] / max(spread(at: points[$0].x, points[$0].z), 1e-4) }.max() ?? 1
        let scale = max(1, short)

        // Only the underside moves: the lift eases out above the seat, over the same distance as across.
        let seatTop = seat.map { points[$0].y }.max()!
        let down = pose.rotation.inverse
        var surface = surface
        var lifted = [Float](repeating: 0, count: points.count)
        for i in points.indices {
            let above = (points[i].y - seatTop) / blend
            guard above < 1 else { continue }
            let fade = above > 0 ? 1 - above : 1
            lifted[i] = spread(at: points[i].x, points[i].z) * scale * fade * fade * (3 - 2 * fade)
            if lifted[i] > 0 {
                surface.positions[i] += down.act(SIMD3(0, lifted[i], 0))
            }
        }
        // Where the seat's wall turns into the rest of the underside it leaves a sharp lip; that's worn
        // round, as water would wear it, where the seat rises steeply and a little way around.
        surface.positions = Self.lipsWorn(surface.positions, indices: surface.indices, lifted: lifted, passes: 30)
        surface.normals = Self.weldedNormals(positions: surface.positions, indices: surface.indices)
        return Pebble(surface: surface)
    }

    /// `positions` with the sharp lips of a seat worn round: where `lifted` changes steeply from one point
    /// to the next, and a little way around, each point moves toward the middle of its neighbors, a bit
    /// at a time over `passes` passes. Points in the same place (along the rim) move together.
    private static func lipsWorn(_ positions: [SIMD3<Float>], indices: [UInt32], lifted: [Float], passes: Int) -> [SIMD3<Float>] {
        guard passes > 0 else { return positions }
        // One slot for each place, so the faces stay joined at the rim.
        var slots: [SIMD3<Int32>: Int] = [:]
        let slot = positions.map { p -> Int in
            let key = SIMD3<Int32>((p * 1000).rounded(.toNearestOrAwayFromZero))
            if let existing = slots[key] { return existing }
            slots[key] = slots.count
            return slots.count - 1
        }
        let n = slots.count
        var places = [SIMD3<Float>](repeating: .zero, count: n), lift = [Float](repeating: 0, count: n)
        for i in positions.indices {
            places[slot[i]] = positions[i]
            lift[slot[i]] = max(lift[slot[i]], lifted[i])
        }
        var neighbors = [Set<Int>](repeating: [], count: n)
        for t in stride(from: 0, to: indices.count, by: 3) {
            let a = slot[Int(indices[t])], b = slot[Int(indices[t + 1])], c = slot[Int(indices[t + 2])]
            neighbors[a].formUnion([b, c])
            neighbors[b].formUnion([a, c])
            neighbors[c].formUnion([a, b])
        }
        // In order, so the stones come out the same to the last bit on every launch.
        let around = neighbors.map { $0.sorted() }
        // How steeply the seat rises at each place, and from that how much it's worn there, spread a few
        // places around and softened so the wearing fades out.
        var wear = (0..<n).map { i -> Float in
            let steepest = around[i].map { abs(lift[$0] - lift[i]) / max(length(places[$0] - places[i]), 1e-3) }.max() ?? 0
            let t = min(1, max(0, (steepest - 0.25) / 0.5))
            return t * t * (3 - 2 * t)
        }
        for _ in 0..<3 {
            wear = (0..<n).map { i in around[i].reduce(wear[i]) { max($0, wear[$1]) } }
        }
        for _ in 0..<3 {
            wear = (0..<n).map { i in (around[i].reduce(wear[i]) { $0 + wear[$1] }) / Float(around[i].count + 1) }
        }
        for _ in 0..<passes {
            let before = places
            for i in 0..<n where wear[i] > 0 && !around[i].isEmpty {
                let middle = around[i].reduce(SIMD3<Float>.zero) { $0 + before[$1] } / Float(around[i].count)
                places[i] = before[i] + (middle - before[i]) * 0.5 * wear[i]
            }
        }
        return positions.indices.map { places[slot[$0]] }
    }

    /// The same stone with its lowest `depth` points worn flat, the face a stone at the bottom of a
    /// stack lies on.
    func flattened(by depth: Float) -> Pebble {
        let floor = surface.positions.map(\.y).min()! + depth
        var surface = surface
        for i in surface.positions.indices where surface.positions[i].y < floor {
            surface.positions[i].y = floor
        }
        surface.normals = Self.weldedNormals(positions: surface.positions, indices: surface.indices)
        return Pebble(surface: surface)
    }

    /// How far along the line from `origin` in `direction` it first meets the surface, if it does.
    func hit(from origin: SIMD3<Float>, toward direction: SIMD3<Float>) -> Float? {
        var nearest: Float?
        let p = surface.positions
        for i in stride(from: 0, to: surface.indices.count, by: 3) {
            let a = p[Int(surface.indices[i])], b = p[Int(surface.indices[i + 1])], c = p[Int(surface.indices[i + 2])]
            // Möller–Trumbore.
            let ab = b - a, ac = c - a
            let h = cross(direction, ac)
            let determinant = dot(ab, h)
            guard abs(determinant) > 1e-8 else { continue }
            let s = origin - a
            let u = dot(s, h) / determinant
            guard u >= 0, u <= 1 else { continue }
            let q = cross(s, ab)
            let v = dot(direction, q) / determinant
            guard v >= 0, u + v <= 1 else { continue }
            let t = dot(ac, q) / determinant
            if t > 0, t < (nearest ?? .infinity) {
                nearest = t
            }
        }
        return nearest
    }

    /// The directions along the surface in which its texture coordinates grow, at each point: the
    /// texture's relief tilts the surface along these.
    static func textureDirections(of surface: Surface) -> (across: [SIMD3<Float>], up: [SIMD3<Float>]) {
        let positions = surface.positions, normals = surface.normals, coordinates = surface.textureCoordinates
        var across = [SIMD3<Float>](repeating: .zero, count: positions.count)
        var up = across
        for i in stride(from: 0, to: surface.indices.count, by: 3) {
            let a = Int(surface.indices[i]), b = Int(surface.indices[i + 1]), c = Int(surface.indices[i + 2])
            let e1 = positions[b] - positions[a], e2 = positions[c] - positions[a]
            let d1 = coordinates[b] - coordinates[a], d2 = coordinates[c] - coordinates[a]
            let determinant = d1.x * d2.y - d2.x * d1.y
            guard abs(determinant) > 1e-12 else { continue }
            let u = (e1 * d2.y - e2 * d1.y) / determinant
            let v = (e2 * d1.x - e1 * d2.x) / determinant
            for k in [a, b, c] {
                across[k] += u
                up[k] += v
            }
        }
        for k in positions.indices {
            let n = normals[k]
            var t = across[k] - n * dot(n, across[k])
            if length(t) < 1e-9 {
                t = abs(n.x) < 0.9 ? cross(n, [1, 0, 0]) : cross(n, [0, 1, 0])
            }
            t = normalize(t)
            var b = up[k] - n * dot(n, up[k]) - t * dot(t, up[k])
            if length(b) < 1e-9 {
                b = cross(n, t)
            }
            across[k] = t
            up[k] = normalize(b)
        }
        return (across, up)
    }

    /// The surface of a stone whose outline lies `radii` out from `center`, at evenly spaced angles, in
    /// an image `width` by `height` points.
    private static func surface(radii: [Float], center: SIMD2<Float>, width: Float, height: Float,
                                shape: Shape, pointsPerTexture: Float) -> Surface {
        let angles = radii.count
        let rings = 32
        let size = max(width, height)

        // Each face is a disc of rings around its middle. Rings are spaced evenly in angle on a
        // quarter circle, so they bunch up near the rim where the surface curves the most.
        let perFace = 1 + rings * angles
        func index(face: Int, ring: Int, angle: Int) -> Int {
            face * perFace + (ring == 0 ? 0 : 1 + (ring - 1) * angles + angle % angles)
        }
        var positions = [SIMD3<Float>](repeating: .zero, count: 2 * perFace)
        var uvs = [SIMD2<Float>](repeating: .zero, count: 2 * perFace)
        var indices: [UInt32] = []

        // Where each point of a face lies within the outline, the same on both faces, and the face's
        // triangles, counterclockwise as seen from the front.
        let (flats, faceTriangles) = Self.disc(radii: radii, center: center, rings: rings, profile: shape.profile)

        // How far each point stands out from the rim, from 0 there to 1 at the most. With a membrane over
        // the outline, pushed up evenly: over an ellipse it's a paraboloid, so its square root makes an
        // ellipsoid, as smooth as a pebble worn by water; over any other outline it's just as smooth, with
        // no ridges running out to the bulges of the outline or creases between them.
        let rise: [Float]
        switch shape.inflation {
        case .membrane:
            rise = Self.rise(radii: radii, center: center, rings: rings, profile: shape.profile)
        case .rays:
            rise = (0..<perFace).map { i in
                let ring = i == 0 ? 0 : (i - 1) / angles + 1
                return pow(max(0, cos(Float(ring) / Float(rings) * .pi / 2)), 2 / shape.profile)
            }
        }

        // Where the widest outline sits, front to back, going around the stone: a few gentle waves
        // around it, fading toward the middle of the faces.
        var random = SeededRandom(seed: shape.seed &* 31)
        let waves = (1...3).map { harmonic in
            (harmonic: Float(harmonic), phase: Float.random(in: 0..<2 * .pi, using: &random), weight: 1 / Float(harmonic * harmonic))
        }
        let total = waves.reduce(0) { $0 + $1.weight }
        let middle = radii.reduce(0, +) / Float(angles)
        func wander(_ flat: SIMD2<Float>, ring: Int, theta: Float) -> Float {
            switch shape.inflation {
            case .membrane:
                let d = flat - center
                let theta = atan2(-d.y, d.x), r = length(d) / middle
                return shape.front * shape.wander * waves.reduce(0) { $0 + $1.weight * pow(r, $1.harmonic) * sin($1.harmonic * theta + $1.phase) } / total
            case .rays:
                let reach = Self.reach(ring, of: rings, profile: shape.profile)
                return shape.front * shape.wander * waves.reduce(0) { $0 + $1.weight * sin($1.harmonic * theta + $1.phase) } / total * reach * reach
            }
        }

        for face in 0..<2 {
            let isFront = face == 0
            let swell = Swell(seed: shape.seed &+ UInt64(face) &* 0x9E37, size: size)
            // The back's texture comes from elsewhere in the texture, so it doesn't mirror the front.
            let textureOrigin = center + (isFront ? .zero : SIMD2(pointsPerTexture * 0.37, pointsPerTexture * 0.61))
            for angle in 0..<angles {
                let theta = Float(angle) / Float(angles) * 2 * .pi
                let direction = SIMD2(cos(theta), -sin(theta))
                var previous = SIMD3<Float>.zero
                var distance: Float = 0
                for ring in 0...rings {
                    let k = index(face: 0, ring: ring, angle: angle)
                    let flat = flats[k], bulge = rise[k]
                    // The back is a little thinner, easing to the front's thickness toward the rim so the
                    // faces meet without a crease.
                    let depth = isFront ? shape.front : -(shape.front - (shape.front - shape.back) * bulge * bulge)
                    let z = depth * bulge * (1 + shape.bumpiness * swell(flat)) + wander(flat, ring: ring, theta: theta)
                    let point = SIMD3(flat.x - width / 2, height / 2 - flat.y, z)
                    if ring > 0 { distance += length(point - previous) }
                    previous = point
                    let i = index(face: face, ring: ring, angle: angle)
                    positions[i] = point
                    // Unrolled along the surface, so the grain isn't stretched where the sides curve away.
                    uvs[i] = (textureOrigin + direction * distance) / pointsPerTexture
                }
            }
            // Counterclockwise as seen from outside: the back is seen from behind.
            for t in stride(from: 0, to: faceTriangles.count, by: 3) {
                let triangle = faceTriangles[t..<(t + 3)].map { $0 + UInt32(face * perFace) }
                indices += isFront ? triangle : triangle.reversed()
            }
        }

        var normals = smoothNormals(positions: positions, indices: indices)
        // Join the faces at the rim, so the light doesn't show a seam there.
        for angle in 0..<angles {
            let front = index(face: 0, ring: rings, angle: angle)
            let back = index(face: 1, ring: rings, angle: angle)
            let joined = normalize(normals[front] + normals[back])
            normals[front] = joined
            normals[back] = joined
        }
        return Surface(positions: positions, normals: normals, textureCoordinates: uvs, indices: indices)
    }

    /// The outline `radii` (out from the middle at evenly spaced angles) a little worn, as water wears a
    /// stone: its turns eased over about `degrees` either way, so nothing on it is sharp, while it keeps
    /// its shape, hollows and all.
    private static func worn(_ radii: [Float], by degrees: Float) -> [Float] {
        let n = radii.count
        let sigma = degrees / 360 * Float(n), half = Int((3 * sigma).rounded(.up))
        guard half > 0 else { return radii }
        let weights = (-half...half).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let total = weights.reduce(0, +)
        return (0..<n).map { i in
            zip(-half...half, weights).reduce(0) { $0 + radii[(i + $1.0 + n) % n] * $1.1 } / total
        }
    }

    /// A disc of `rings` rings around `center` out to the outline `radii` out at evenly spaced angles,
    /// spaced evenly in angle on a quarter circle so they bunch up near the rim, where the surface curves
    /// the most: where each point lies, the middle first and then ring by ring, and the triangles,
    /// counterclockwise as seen from the front.
    private static func disc(radii: [Float], center: SIMD2<Float>, rings: Int, profile: Float) -> (points: [SIMD2<Float>], triangles: [UInt32]) {
        let angles = radii.count
        func index(_ ring: Int, _ angle: Int) -> Int {
            ring == 0 ? 0 : 1 + (ring - 1) * angles + angle % angles
        }
        var points = [SIMD2<Float>](repeating: center, count: 1 + rings * angles)
        for angle in 0..<angles {
            let theta = Float(angle) / Float(angles) * 2 * .pi
            let direction = SIMD2(cos(theta), -sin(theta)) // image y points down
            for ring in 1...rings {
                points[index(ring, angle)] = center + direction * reach(ring, of: rings, profile: profile) * radii[angle]
            }
        }
        var triangles: [UInt32] = []
        for angle in 0..<angles {
            triangles += [0, UInt32(index(1, angle)), UInt32(index(1, angle + 1))]
            for ring in 1..<rings {
                triangles += [index(ring, angle), index(ring + 1, angle), index(ring + 1, angle + 1)].map { UInt32($0) }
                triangles += [index(ring, angle), index(ring + 1, angle + 1), index(ring, angle + 1)].map { UInt32($0) }
            }
        }
        return (points, triangles)
    }

    /// How far out toward the rim ring `ring` of `rings` lies, from 0 in the middle to 1.
    private static func reach(_ ring: Int, of rings: Int, profile: Float) -> Float {
        pow(sin(Float(ring) / Float(rings) * .pi / 2), 2 / profile)
    }

    /// How far each point of a disc (see `disc`) stands out from the rim, from 0 there to 1 at the most:
    /// the membrane over the outline, raised to the power that makes its cross section `profile`. It's
    /// worked out along every fourth ray, which follows the outline closely enough, and carried round to
    /// the rays between smoothly.
    private static func rise(radii: [Float], center: SIMD2<Float>, rings: Int, profile: Float) -> [Float] {
        let angles = radii.count, rays = angles / 4
        let (points, triangles) = disc(radii: (0..<rays).map { radii[$0 * 4] }, center: center, rings: rings, profile: profile)
        func index(_ ring: Int, _ ray: Int) -> Int {
            ring == 0 ? 0 : 1 + (ring - 1) * rays + (ray + rays) % rays
        }
        // Starting from the paraboloid that fits an ellipse, it settles within a couple of hundred steps.
        let guess = (0..<points.count).map { i -> Float in
            let reach = reach(i == 0 ? 0 : (i - 1) / rays + 1, of: rings, profile: profile)
            return 1 - reach * reach
        }
        let membrane = Self.membrane(over: points, triangles: triangles, rim: (0..<points.count).map { $0 >= index(rings, 0) },
                                     lines: (0..<rays).map { ray in (1..<rings).map { index($0, ray) } }, guess: guess)
        // Round each ring, through the rays it was worked out along (Catmull-Rom).
        var rise = [Float](repeating: 0, count: 1 + rings * angles)
        rise[0] = membrane[0]
        for ring in 1...rings {
            for angle in 0..<angles {
                let ray = angle / 4, t = Float(angle % 4) / 4
                let p0 = membrane[index(ring, ray - 1)], p1 = membrane[index(ring, ray)]
                let p2 = membrane[index(ring, ray + 1)], p3 = membrane[index(ring, ray + 2)]
                let value = 0.5 * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t + (3 * p1 - p0 - 3 * p2 + p3) * t * t * t)
                rise[1 + (ring - 1) * angles + angle] = max(0, value)
            }
        }
        let peak = rise.max() ?? 1
        return rise.map { pow(max(0, $0 / peak), 1 / profile) }
    }

    /// The membrane over a face: the solution of Poisson's equation with an even push, nothing along
    /// `rim`, over the face's `triangles` laid out at `points` (linear finite elements, solved by conjugate
    /// gradients). Along each of `lines`, chains of neighboring points, the points are tied most strongly,
    /// so each step solves along them exactly. `guess` is where to start from, and only its shape matters.
    private static func membrane(over points: [SIMD2<Float>], triangles: [UInt32], rim: [Bool], lines: [[Int]],
                                 guess: [Float]) -> [Float] {
        let n = points.count
        // How strongly each point is tied to its neighbors (half the cotangents of the angles facing each
        // edge), and how much of the push it takes (a third of the area around it).
        var ties = [[Int: Double]](repeating: [:], count: n)
        var push = [Double](repeating: 0, count: n)
        for t in stride(from: 0, to: triangles.count, by: 3) {
            let corners = [Int(triangles[t]), Int(triangles[t + 1]), Int(triangles[t + 2])]
            let p = corners.map { SIMD2<Double>(points[$0]) }
            let area = abs((p[1].x - p[0].x) * (p[2].y - p[0].y) - (p[2].x - p[0].x) * (p[1].y - p[0].y)) / 2
            guard area > 1e-12 else { continue }
            for k in 0..<3 {
                let a = p[k], b = p[(k + 1) % 3], c = p[(k + 2) % 3]
                // The angle at `a` faces the edge from b to c.
                let cotangent = simd_dot(b - a, c - a) / (2 * area)
                let i = corners[(k + 1) % 3], j = corners[(k + 2) % 3]
                ties[i][j, default: 0] += cotangent / 2
                ties[j][i, default: 0] += cotangent / 2
                push[corners[k]] += area / 3
            }
        }
        // The ties as rows of a sparse matrix, leaving out the rim, which stays at nothing. Taken in order,
        // so the sums come out the same to the last bit on every launch, and so does the light worked out
        // for the stones, which is kept by what they're made of.
        var starts = [Int](repeating: 0, count: n + 1)
        var columns: [Int] = [], weights: [Double] = []
        var diagonal = [Double](repeating: 1, count: n)
        for i in 0..<n {
            if !rim[i] {
                let row = ties[i].sorted { $0.key < $1.key }
                diagonal[i] = row.reduce(0) { $0 + $1.value }
                for (j, w) in row where !rim[j] {
                    columns.append(j)
                    weights.append(w)
                }
            }
            starts[i + 1] = columns.count
        }
        // Each line's part of the matrix, a tridiagonal one, factored once (the Thomas algorithm): the
        // entries beside the diagonal, what's taken off below it, and what's left on it.
        var inLine = [Bool](repeating: false, count: n)
        let factors = lines.map { members -> (beside: [Double], lower: [Double], pivots: [Double]) in
            var beside = [Double](repeating: 0, count: members.count), lower = beside, pivots = beside
            for (k, i) in members.enumerated() {
                inLine[i] = true
                pivots[k] = diagonal[i]
                if k > 0 {
                    beside[k] = -(ties[i][members[k - 1]] ?? 0)
                    lower[k] = beside[k] / pivots[k - 1]
                    pivots[k] -= lower[k] * beside[k]
                }
            }
            return (beside, lower, pivots)
        }
        func precondition(_ r: UnsafeMutableBufferPointer<Double>, into z: UnsafeMutableBufferPointer<Double>) {
            for i in 0..<n where !inLine[i] {
                z[i] = r[i] / diagonal[i]
            }
            for (members, factor) in zip(lines, factors) {
                for (k, i) in members.enumerated() {
                    z[i] = k > 0 ? r[i] - factor.lower[k] * z[members[k - 1]] : r[i]
                }
                for k in members.indices.reversed() {
                    let i = members[k]
                    z[i] = (k + 1 < members.count ? z[i] - factor.beside[k + 1] * z[members[k + 1]] : z[i]) / factor.pivots[k]
                }
            }
        }
        let b = (0..<n).map { rim[$0] ? 0 : push[$0] }
        let x = UnsafeMutableBufferPointer<Double>.allocate(capacity: n), r = UnsafeMutableBufferPointer<Double>.allocate(capacity: n)
        let z = UnsafeMutableBufferPointer<Double>.allocate(capacity: n), d = UnsafeMutableBufferPointer<Double>.allocate(capacity: n)
        let kd = UnsafeMutableBufferPointer<Double>.allocate(capacity: n)
        defer { [x, r, z, d, kd].forEach { $0.deallocate() } }
        func apply(_ v: UnsafeMutableBufferPointer<Double>, into out: UnsafeMutableBufferPointer<Double>) {
            columns.withUnsafeBufferPointer { columns in
                weights.withUnsafeBufferPointer { weights in
                    for i in 0..<n {
                        var sum = diagonal[i] * v[i]
                        for e in starts[i]..<starts[i + 1] {
                            sum -= weights[e] * v[columns[e]]
                        }
                        out[i] = rim[i] ? 0 : sum
                    }
                }
            }
        }
        func dot(_ u: UnsafeMutableBufferPointer<Double>, _ v: UnsafeMutableBufferPointer<Double>) -> Double {
            var sum: Double = 0
            for i in 0..<n {
                sum += u[i] * v[i]
            }
            return sum
        }

        // Conjugate gradients, from the guess scaled to fit as well as it can.
        for i in 0..<n {
            x[i] = rim[i] ? 0 : Double(guess[i])
        }
        apply(x, into: kd)
        var fit: Double = 0, size: Double = 0
        for i in 0..<n {
            fit += x[i] * b[i]
            size += x[i] * kd[i]
        }
        let scale = fit / max(size, 1e-300)
        for i in 0..<n {
            x[i] *= scale
            r[i] = b[i] - scale * kd[i]
        }
        precondition(r, into: z)
        for i in 0..<n {
            d[i] = z[i]
        }
        var rz = dot(r, z)
        // Close enough once what's left is a hundred-millionth of the push.
        let enough = (0..<n).reduce(0) { $0 + b[$1] * b[$1] / diagonal[$1] } * 1e-16
        for _ in 0..<3000 where rz > enough {
            apply(d, into: kd)
            let step = rz / max(dot(d, kd), 1e-300)
            for i in 0..<n {
                x[i] += step * d[i]
                r[i] -= step * kd[i]
            }
            precondition(r, into: z)
            let next = dot(r, z)
            for i in 0..<n {
                d[i] = z[i] + next / rz * d[i]
            }
            rz = next
        }
        return x.map { Float(max($0, 0)) }
    }

    private static func smoothNormals(positions: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for i in stride(from: 0, to: indices.count, by: 3) {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
            let n = cross(positions[b] - positions[a], positions[c] - positions[a])
            normals[a] += n
            normals[b] += n
            normals[c] += n
        }
        return normals.map { length($0) > 0 ? normalize($0) : SIMD3(0, 0, 1) }
    }

    /// Smooth normals that also blend across seams where separate vertices share a position.
    private static func weldedNormals(positions: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        var slots: [SIMD3<Int32>: Int] = [:]
        let slot = positions.map { p -> Int in
            let key = SIMD3<Int32>((p * 1000).rounded(.toNearestOrAwayFromZero))
            if let existing = slots[key] { return existing }
            slots[key] = slots.count
            return slots.count - 1
        }
        var sums = [SIMD3<Float>](repeating: .zero, count: slots.count)
        for i in stride(from: 0, to: indices.count, by: 3) {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
            let n = cross(positions[b] - positions[a], positions[c] - positions[a])
            sums[slot[a]] += n
            sums[slot[b]] += n
            sums[slot[c]] += n
        }
        return slot.map { length(sums[$0]) > 0 ? normalize(sums[$0]) : SIMD3(0, 0, 1) }
    }

    /// Volume and center of mass of a closed surface, from the tetrahedra between each triangle
    /// and the origin.
    private static func massProperties(of surface: Surface) -> (Float, SIMD3<Float>) {
        var volume: Float = 0
        var moment = SIMD3<Float>.zero
        let p = surface.positions
        for i in stride(from: 0, to: surface.indices.count, by: 3) {
            let a = p[Int(surface.indices[i])], b = p[Int(surface.indices[i + 1])], c = p[Int(surface.indices[i + 2])]
            let v = dot(a, cross(b, c)) / 6
            volume += v
            moment += v * (a + b + c) / 4
        }
        return (volume, volume > 0 ? moment / volume : .zero)
    }
}

/// SplitMix64, so the stones come out the same on every launch.
nonisolated struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A few long, gentle waves across the stone, between -1 and 1, so its faces aren't perfectly even.
nonisolated private struct Swell {
    private var waves: [(direction: SIMD2<Float>, phase: Float, weight: Float)] = []

    init(seed: UInt64, size: Float) {
        var random = SeededRandom(seed: seed)
        for i in 0..<3 {
            let angle = Float.random(in: 0..<2 * .pi, using: &random)
            let wavelength = size * Float.random(in: 0.9..<1.6, using: &random)
            let phase = Float.random(in: 0..<2 * .pi, using: &random)
            waves.append((SIMD2(cos(angle), sin(angle)) * 2 * .pi / wavelength, phase, 1 / Float(i + 1)))
        }
    }

    func callAsFunction(_ point: SIMD2<Float>) -> Float {
        let total = waves.reduce(0) { $0 + $1.weight }
        return waves.reduce(0) { $0 + $1.weight * sin(dot($1.direction, point) + $1.phase) } / total
    }
}

/// The opaque area of an image, read from its alpha channel.
nonisolated private struct Silhouette {
    let width: Int
    let height: Int
    private let alpha: [Float]

    init?(imageName: String) {
        guard let image = UIImage(named: imageName)?.cgImage else { return nil }
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        width = w
        height = h
        alpha = stride(from: 3, to: bytes.count, by: 4).map { Float(bytes[$0]) / 255 }
    }

    /// Alpha at a point in image coordinates (y down), interpolated between pixel centers.
    func alpha(x: Float, y: Float) -> Float {
        let fx = x - 0.5, fy = y - 0.5
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let tx = fx - Float(x0), ty = fy - Float(y0)
        func at(_ px: Int, _ py: Int) -> Float {
            guard px >= 0, py >= 0, px < width, py < height else { return 0 }
            return alpha[py * width + px]
        }
        let top = at(x0, y0) * (1 - tx) + at(x0 + 1, y0) * tx
        let bottom = at(x0, y0 + 1) * (1 - tx) + at(x0 + 1, y0 + 1) * tx
        return top * (1 - ty) + bottom * ty
    }

    var centroid: SIMD2<Float> {
        var sum = SIMD2<Float>.zero
        var total: Float = 0
        for y in 0..<height {
            for x in 0..<width {
                let a = alpha[y * width + x]
                sum += SIMD2(Float(x) + 0.5, Float(y) + 0.5) * a
                total += a
            }
        }
        return total > 0 ? sum / total : SIMD2(Float(width), Float(height)) / 2
    }

    /// Distance from the centroid to the edge of the silhouette, at evenly spaced angles
    /// (counterclockwise, starting to the right), lightly smoothed.
    func outline(samples: Int) -> [Float] {
        let c = centroid
        let limit = Float(max(width, height))
        var radii = (0..<samples).map { i -> Float in
            let theta = Float(i) / Float(samples) * 2 * .pi
            let direction = SIMD2(cos(theta), -sin(theta))
            var inside: Float = 0
            var r: Float = 0.5
            while r < limit, alpha(x: c.x + direction.x * r, y: c.y + direction.y * r) >= 0.5 {
                inside = r
                r += 0.5
            }
            // Refine the edge between the last point inside and the first point outside.
            var outside = r
            for _ in 0..<8 {
                let mid = (inside + outside) / 2
                if alpha(x: c.x + direction.x * mid, y: c.y + direction.y * mid) >= 0.5 { inside = mid } else { outside = mid }
            }
            return (inside + outside) / 2
        }
        radii = (0..<samples).map { i in
            (radii[(i + samples - 1) % samples] + 2 * radii[i] + radii[(i + 1) % samples]) / 4
        }
        return radii
    }
}

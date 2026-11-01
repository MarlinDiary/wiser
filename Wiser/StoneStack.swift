//
//  StoneStack.swift
//  Wiser
//
//  Created by Marlin on 18/10/2026.
//

import simd

/// Physics for stacked stones: how they touch and whether they're balanced.
///
/// Real stones never touch at a single point: tiny flat spots and grit give every contact a small patch
/// to stand on, and the bottom stone beds into the ground a little. So a stone counts as balanced when
/// the weight above it falls inside the patch where the surfaces are within `seat` of each other.
///
/// Lengths are in points, y up, with the ground at y = 0.
nonisolated enum StoneStack {
    /// How close two stones' surfaces must come to bear weight.
    static let seat: Float = 1
    /// How close the bottom stone must come to the ground to bear weight.
    static let bed: Float = 2
    struct Stone {
        var positions: [SIMD3<Float>]
        /// Triangles, counterclockwise as seen from outside.
        var indices: [UInt32]
        var mass: Float
        var centerOfMass: SIMD3<Float>
    }

    struct Pose {
        var rotation = simd_quatf(angle: 0, axis: [0, 1, 0])
        var translation = SIMD3<Float>.zero

        func apply(_ point: SIMD3<Float>) -> SIMD3<Float> {
            rotation.act(point) + translation
        }
    }

    /// The patch a stone stands on, seen from above, at the height where it bears.
    struct Footing: Sendable {
        /// Convex, counterclockwise, in x and z.
        var outline: [SIMD2<Float>]
        var height: Float

        var center: SIMD3<Float> {
            let middle = outline.reduce(.zero, +) / Float(max(outline.count, 1))
            return SIMD3(middle.x, height, middle.y)
        }

        /// The point on the patch's edge furthest in `direction` (x and z): a stone tipping that way
        /// pivots there.
        func edge(toward direction: SIMD2<Float>) -> SIMD3<Float> {
            let point = outline.max { dot($0, direction) < dot($1, direction) } ?? .zero
            return SIMD3(point.x, height, point.y)
        }
    }

    /// Where each stone stands: the bottom one on the ground, each of the others on the stone below.
    static func footings(of stones: [Stone], at poses: [Pose]) -> [Footing] {
        let points = stones[0].positions.map(poses[0].apply)
        let lowest = points.map(\.y).min()!
        var footings = [Footing(outline: convexHull(points.filter { $0.y < lowest + bed }.map { SIMD2($0.x, $0.z) }), height: lowest)]
        for k in 1..<stones.count {
            let grid = Grid(around: [k - 1, k].map { (stones[$0], poses[$0]) })
            let below = HeightField(stones[k - 1], poses[k - 1], grid: grid, top: true)
            let above = HeightField(stones[k], poses[k], grid: grid, top: false)
            let patch = contact(lower: below, upper: above, shift: .zero)?.patch ?? []
            let heights = patch.compactMap { below.height(at: $0) }
            footings.append(Footing(outline: convexHull(patch), height: heights.reduce(0, +) / Float(max(heights.count, 1))))
        }
        return footings
    }

    /// How far each point has to rise to sit `clearance` above `stone`, for points inside it now; zero
    /// for points that aren't.
    static func lift(_ points: [SIMD3<Float>], outOf stone: Stone, at pose: Pose, clearance: Float) -> [Float] {
        let grid = Grid(around: [(stone, pose)], margin: 2)
        let top = HeightField(stone, pose, grid: grid, top: true)
        let bottom = HeightField(stone, pose, grid: grid, top: false)
        return points.map { point in
            let place = SIMD2(point.x, point.z)
            guard let high = top.height(at: place), let low = bottom.height(at: place),
                  point.y > low - clearance, point.y < high + clearance else { return 0 }
            return high + clearance - point.y
        }
    }

    /// For each stone above the bottom one, and then for the stack on the ground, how far its weight
    /// (with everything above it) falls outside the patch it stands on; zero when it's balanced.
    static func imbalance(of stones: [Stone], at poses: [Pose]) -> [Float] {
        var results: [Float] = []
        for k in 1..<stones.count {
            let grid = Grid(around: [k - 1, k].map { (stones[$0], poses[$0]) })
            let below = HeightField(stones[k - 1], poses[k - 1], grid: grid, top: true)
            let above = HeightField(stones[k], poses[k], grid: grid, top: false)
            guard let contact = contact(lower: below, upper: above, shift: .zero) else { continue }
            results.append(length(correction(moving: horizontalCenter(of: Array(k..<stones.count), stones: stones, poses: poses), into: contact.patch)))
        }
        let points = stones[0].positions.map(poses[0].apply)
        let lowest = points.map(\.y).min()!
        let bed = points.filter { $0.y < lowest + Self.bed }.map { SIMD2($0.x, $0.z) }
        results.append(length(correction(moving: horizontalCenter(of: Array(stones.indices), stones: stones, poses: poses), into: bed)))
        return results
    }

    private static func centerOfMass(of group: [Int], stones: [Stone], poses: [Pose]) -> SIMD3<Float> {
        var weight: Float = 0
        var moment = SIMD3<Float>.zero
        for k in group {
            weight += stones[k].mass
            moment += stones[k].mass * poses[k].apply(stones[k].centerOfMass)
        }
        return moment / weight
    }

    private static func horizontalCenter(of group: [Int], stones: [Stone], poses: [Pose]) -> SIMD2<Float> {
        let center = centerOfMass(of: group, stones: stones, poses: poses)
        return SIMD2(center.x, center.z)
    }

    /// The smallest move that brings `point` inside the region spanned by `patch`, a little in from its
    /// edge; zero if it's inside already.
    private static func correction(moving point: SIMD2<Float>, into patch: [SIMD2<Float>]) -> SIMD2<Float> {
        let hull = convexHull(patch)
        guard hull.count >= 3 else {
            let middle = hull.reduce(.zero, +) / Float(max(hull.count, 1))
            return middle - point
        }
        let margin: Float = 1
        var inside = true
        var nearest = hull[0]
        var nearestDistance = Float.infinity
        for i in hull.indices {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            let edge = b - a
            // Counterclockwise hull: inside is to the left of every edge.
            let side = (edge.x * (point.y - a.y) - edge.y * (point.x - a.x)) / length(edge)
            if side < margin { inside = false }
            let t = min(1, max(0, dot(point - a, edge) / dot(edge, edge)))
            let closest = a + t * edge
            if length(point - closest) < nearestDistance {
                nearestDistance = length(point - closest)
                nearest = closest
            }
        }
        guard !inside else { return .zero }
        let middle = hull.reduce(.zero, +) / Float(hull.count)
        let inward = length(middle - nearest) > 0 ? normalize(middle - nearest) : .zero
        return nearest + inward * min(margin, length(middle - nearest)) - point
    }

    /// Andrew's monotone chain, counterclockwise.
    private static func convexHull(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let sorted = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard sorted.count > 2 else { return sorted }
        func turn(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [SIMD2<Float>] = []
        for p in sorted {
            while lower.count >= 2, turn(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [SIMD2<Float>] = []
        for p in sorted.reversed() {
            while upper.count >= 2, turn(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// How far `upper` has to rise (or may drop, if negative) to rest on `lower` when shifted by
    /// whole cells, and the patch where they then come within `seat` of each other.
    private static func contact(lower: HeightField, upper: HeightField, shift: SIMD2<Int>) -> (lift: Float, patch: [SIMD2<Float>])? {
        let grid = lower.grid
        var lift = -Float.infinity
        var overlaps: [(index: Int, difference: Float)] = []
        overlaps.reserveCapacity(upper.cells.count)
        for (index, height) in upper.cells {
            let column = index % grid.columns + shift.x
            let row = index / grid.columns + shift.y
            guard column >= 0, row >= 0, column < grid.columns, row < grid.rows else { continue }
            let target = row * grid.columns + column
            let top = lower.values[target]
            guard !top.isNaN else { continue }
            let difference = top - height
            lift = max(lift, difference)
            overlaps.append((target, difference))
        }
        guard lift > -.infinity else { return nil }
        let patch = overlaps.filter { $0.difference > lift - seat }.map { grid.center(of: $0.index) }
        return (lift, patch)
    }
}

/// Square cells over the ground, in points.
nonisolated private struct Grid {
    var minimum: SIMD2<Float>
    var cell: Float
    var columns: Int
    var rows: Int

    init(around stones: [(StoneStack.Stone, StoneStack.Pose)], margin: Float = 4, cell: Float = 1) {
        self.cell = cell
        var low = SIMD2<Float>(repeating: .infinity)
        var high = SIMD2<Float>(repeating: -.infinity)
        for (stone, pose) in stones {
            for point in stone.positions {
                let p = pose.apply(point)
                low = simd_min(low, SIMD2(p.x, p.z))
                high = simd_max(high, SIMD2(p.x, p.z))
            }
        }
        minimum = low - margin
        columns = Int(((high.x - low.x + 2 * margin) / cell).rounded(.up)) + 1
        rows = Int(((high.y - low.y + 2 * margin) / cell).rounded(.up)) + 1
    }

    func center(of index: Int) -> SIMD2<Float> {
        minimum + SIMD2(Float(index % columns), Float(index / columns)) * cell
    }
}

/// The top or bottom of a stone, as a height over each cell of a grid.
nonisolated private struct HeightField {
    let grid: Grid
    /// Not a number where the stone isn't over the cell.
    private(set) var values: [Float]
    /// The cells the stone covers, with their heights.
    private(set) var cells: [(index: Int, height: Float)] = []

    init(_ stone: StoneStack.Stone, _ pose: StoneStack.Pose, grid: Grid, top: Bool) {
        self.grid = grid
        values = [Float](repeating: .nan, count: grid.columns * grid.rows)
        let points = stone.positions.map(pose.apply)
        for i in stride(from: 0, to: stone.indices.count, by: 3) {
            let a = points[Int(stone.indices[i])], b = points[Int(stone.indices[i + 1])], c = points[Int(stone.indices[i + 2])]
            // Only triangles facing up can be the top, and only those facing down the bottom.
            let area = (b.z - a.z) * (c.x - a.x) - (b.x - a.x) * (c.z - a.z)
            guard top ? area > 1e-6 : area < -1e-6 else { continue }
            let low = (simd_min(simd_min(SIMD2(a.x, a.z), SIMD2(b.x, b.z)), SIMD2(c.x, c.z)) - grid.minimum) / grid.cell
            let high = (simd_max(simd_max(SIMD2(a.x, a.z), SIMD2(b.x, b.z)), SIMD2(c.x, c.z)) - grid.minimum) / grid.cell
            let first = SIMD2(max(0, Int(low.x.rounded(.up))), max(0, Int(low.y.rounded(.up))))
            let last = SIMD2(min(grid.columns - 1, Int(high.x.rounded(.down))), min(grid.rows - 1, Int(high.y.rounded(.down))))
            guard first.x <= last.x, first.y <= last.y else { continue }
            for row in first.y...last.y {
                for column in first.x...last.x {
                    let q = grid.minimum + SIMD2(Float(column), Float(row)) * grid.cell
                    // Barycentric weights of the cell center in the triangle seen from above.
                    let wb = ((q.x - a.x) * (c.z - a.z) - (c.x - a.x) * (q.y - a.z)) / -area
                    let wc = ((b.x - a.x) * (q.y - a.z) - (q.x - a.x) * (b.z - a.z)) / -area
                    let wa = 1 - wb - wc
                    guard wa >= -1e-4, wb >= -1e-4, wc >= -1e-4 else { continue }
                    let y = wa * a.y + wb * b.y + wc * c.y
                    let index = row * grid.columns + column
                    let current = values[index]
                    if current.isNaN || (top ? y > current : y < current) {
                        values[index] = y
                    }
                }
            }
        }
        for (index, value) in values.enumerated() where !value.isNaN {
            cells.append((index, value))
        }
    }

    /// The height at a point on the ground, interpolated between cell centers; nil off the stone.
    func height(at point: SIMD2<Float>) -> Float? {
        let cell = (point - grid.minimum) / grid.cell
        let column = Int(cell.x.rounded(.down)), row = Int(cell.y.rounded(.down))
        guard column >= 0, row >= 0, column + 1 < grid.columns, row + 1 < grid.rows else { return nil }
        let t = cell - SIMD2(Float(column), Float(row))
        let corners = [values[row * grid.columns + column], values[row * grid.columns + column + 1],
                       values[(row + 1) * grid.columns + column], values[(row + 1) * grid.columns + column + 1]]
        let known = corners.filter { !$0.isNaN }
        guard !known.isEmpty else { return nil }
        guard known.count == 4 else { return known.max() }
        return (corners[0] * (1 - t.x) + corners[1] * t.x) * (1 - t.y) + (corners[2] * (1 - t.x) + corners[3] * t.x) * t.y
    }
}

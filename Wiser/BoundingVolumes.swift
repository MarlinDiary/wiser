//
//  BoundingVolumes.swift
//  Wiser
//
//  Created by Marlin on 19/10/2026.
//

import simd

/// Boxes around a mesh's triangles, nested, so a ray can be traced against the mesh quickly: it only
/// looks inside the boxes it passes through. Each node either has two children, side by side in
/// `nodes`, or lists a few triangles, in the order `triangles` holds them.
nonisolated struct BoundingVolumes: Sendable {
    struct Node: Sendable {
        var lower: SIMD3<Float>
        var upper: SIMD3<Float>
        /// The first child's place in `nodes`, or for a leaf, its first triangle's place in `triangles`.
        var offset: UInt32
        /// How many triangles a leaf lists; 0 for a node with children.
        var count: UInt32
    }

    private(set) var nodes: [Node] = []
    /// The mesh's triangles, as their place in its index list divided by three, in the leaves' order.
    private(set) var triangles: [UInt32] = []

    /// Splits `indices`' triangles of `positions` up so that the boxes around each part are as small as
    /// they can be (the surface area heuristic, over a few candidate planes along each axis).
    init(positions: [SIMD3<Float>], indices: [UInt32]) {
        let count = indices.count / 3
        var lowers = [SIMD3<Float>](repeating: .zero, count: count)
        var uppers = lowers
        var centers = lowers
        for k in 0..<count {
            let a = positions[Int(indices[3 * k])], b = positions[Int(indices[3 * k + 1])], c = positions[Int(indices[3 * k + 2])]
            lowers[k] = simd_min(a, simd_min(b, c))
            uppers[k] = simd_max(a, simd_max(b, c))
            centers[k] = (lowers[k] + uppers[k]) / 2
        }
        var order = (0..<count).map { UInt32($0) }
        nodes.reserveCapacity(count)
        nodes.append(Node(lower: .zero, upper: .zero, offset: 0, count: 0))
        build(0, from: 0, to: count, depth: 0, order: &order, lowers: lowers, uppers: uppers, centers: centers)
        triangles = order
    }

    private static func area(_ lower: SIMD3<Float>, _ upper: SIMD3<Float>) -> Float {
        let d = simd_max(upper - lower, .zero)
        return d.x * d.y + d.y * d.z + d.z * d.x
    }

    private mutating func build(_ index: Int, from start: Int, to end: Int, depth: Int, order: inout [UInt32],
                                lowers: [SIMD3<Float>], uppers: [SIMD3<Float>], centers: [SIMD3<Float>]) {
        var lower = SIMD3<Float>(repeating: .infinity), upper = SIMD3<Float>(repeating: -.infinity)
        var centerLower = lower, centerUpper = upper
        for i in start..<end {
            let k = Int(order[i])
            lower = simd_min(lower, lowers[k])
            upper = simd_max(upper, uppers[k])
            centerLower = simd_min(centerLower, centers[k])
            centerUpper = simd_max(centerUpper, centers[k])
        }
        let n = end - start
        func leaf() {
            nodes[index] = Node(lower: lower, upper: upper, offset: UInt32(start), count: UInt32(n))
        }
        if n <= 2 || depth >= 40 {
            return leaf()
        }

        // The best of a dozen planes along each axis, splitting the triangles by where their middles are.
        let bins = 12
        var best = (cost: Float.infinity, axis: 0, plane: 0)
        let extent = centerUpper - centerLower
        for axis in 0..<3 where extent[axis] > 1e-9 {
            var binLower = [SIMD3<Float>](repeating: SIMD3(repeating: .infinity), count: bins)
            var binUpper = [SIMD3<Float>](repeating: SIMD3(repeating: -.infinity), count: bins)
            var binCount = [Int](repeating: 0, count: bins)
            let scale = Float(bins) / extent[axis]
            for i in start..<end {
                let k = Int(order[i])
                let b = min(bins - 1, Int((centers[k][axis] - centerLower[axis]) * scale))
                binCount[b] += 1
                binLower[b] = simd_min(binLower[b], lowers[k])
                binUpper[b] = simd_max(binUpper[b], uppers[k])
            }
            // The area and count on each side of each plane, swept from both ends.
            var leftArea = [Float](repeating: 0, count: bins), leftCount = [Int](repeating: 0, count: bins)
            var l = SIMD3<Float>(repeating: .infinity), u = SIMD3<Float>(repeating: -.infinity), c = 0
            for b in 0..<bins - 1 {
                c += binCount[b]
                l = simd_min(l, binLower[b])
                u = simd_max(u, binUpper[b])
                leftCount[b] = c
                leftArea[b] = c > 0 ? Self.area(l, u) : 0
            }
            l = SIMD3(repeating: .infinity)
            u = SIMD3(repeating: -.infinity)
            c = 0
            for b in stride(from: bins - 1, to: 0, by: -1) {
                c += binCount[b]
                l = simd_min(l, binLower[b])
                u = simd_max(u, binUpper[b])
                let cost = leftArea[b - 1] * Float(leftCount[b - 1]) + (c > 0 ? Self.area(l, u) : 0) * Float(c)
                if leftCount[b - 1] > 0, c > 0, cost < best.cost {
                    best = (cost, axis, b)
                }
            }
        }
        // Splitting costs a box test on each side; a leaf, a test of every triangle in it. Triangles whose
        // middles all coincide are split by count.
        if best.cost == .infinity {
            if n <= 4 {
                return leaf()
            }
        } else if n <= 4, Float(n) <= 1 + best.cost / max(Self.area(lower, upper), 1e-12) {
            return leaf()
        }

        var middle: Int
        if best.cost < .infinity {
            let axis = best.axis, scale = Float(bins) / extent[axis]
            var i = start, j = end - 1
            while i <= j {
                let k = Int(order[i])
                if min(bins - 1, Int((centers[k][axis] - centerLower[axis]) * scale)) < best.plane {
                    i += 1
                } else {
                    order.swapAt(i, j)
                    j -= 1
                }
            }
            middle = i
        } else {
            middle = (start + end) / 2
        }
        if middle == start || middle == end {
            middle = (start + end) / 2
        }

        let left = nodes.count
        nodes.append(Node(lower: .zero, upper: .zero, offset: 0, count: 0))
        nodes.append(Node(lower: .zero, upper: .zero, offset: 0, count: 0))
        nodes[index] = Node(lower: lower, upper: upper, offset: UInt32(left), count: 0)
        build(left, from: start, to: middle, depth: depth + 1, order: &order, lowers: lowers, uppers: uppers, centers: centers)
        build(left + 1, from: middle, to: end, depth: depth + 1, order: &order, lowers: lowers, uppers: uppers, centers: centers)
    }

    /// Fits every box to the triangles again once they've moved, connected the same way.
    mutating func refit(positions: [SIMD3<Float>], indices: [UInt32]) {
        // Children always come after their parent.
        for index in nodes.indices.reversed() {
            var node = nodes[index]
            if node.count > 0 {
                var lower = SIMD3<Float>(repeating: .infinity), upper = SIMD3<Float>(repeating: -.infinity)
                for i in Int(node.offset)..<Int(node.offset + node.count) {
                    let k = Int(triangles[i])
                    for corner in 0..<3 {
                        let p = positions[Int(indices[3 * k + corner])]
                        lower = simd_min(lower, p)
                        upper = simd_max(upper, p)
                    }
                }
                node.lower = lower
                node.upper = upper
            } else {
                let a = nodes[Int(node.offset)], b = nodes[Int(node.offset) + 1]
                node.lower = simd_min(a.lower, b.lower)
                node.upper = simd_max(a.upper, b.upper)
            }
            nodes[index] = node
        }
    }
}

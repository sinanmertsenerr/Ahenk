import CoreGraphics
import Foundation

/// Finds the colours of a piece of artwork: k-means in OKLab on a small
/// copy of the image, then colourful clusters first (by area), greys last.
///
/// Deterministic (fixed seed) and cheap: the image is reduced to at most
/// 48 × 48 pixels, so one extraction takes well under a millisecond's worth
/// of arithmetic per cluster pass. Runs once per cover, never per frame.
public enum PaletteExtractor {
    public static let sampleSide = 48
    public static let clusterCount = 8
    public static let maximumColors = 6
    /// Clusters closer than this (OKLab distance) count as one colour.
    static let mergeDistance = 0.06
    /// Below this chroma a colour counts as grey.
    static let neutralChroma = 0.035

    public struct Swatch: Hashable, Sendable {
        public var color: SRGBColor
        /// Share of the sampled pixels, `0...1`.
        public var population: Double
    }

    public static func palette(from image: CGImage) -> Palette {
        Palette(colors: swatches(from: image).map(\.color))
    }

    /// The ordered swatches behind `palette(from:)`; always at least three.
    public static func swatches(from image: CGImage) -> [Swatch] {
        let samples = pixels(of: image)
        guard !samples.isEmpty else { return Palette.neutral.colors.map { Swatch(color: $0, population: 0) } }
        let clusters = cluster(samples)
        return complete(rank(clusters))
    }

    // MARK: Sampling

    /// OKLab values of the opaque pixels of a reduced copy of `image`.
    static func pixels(of image: CGImage) -> [OKLab] {
        let longest = max(image.width, image.height)
        guard longest > 0 else { return [] }
        let scale = min(1, Double(sampleSide) / Double(longest))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return [] }
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return [] }
        var result: [OKLab] = []
        result.reserveCapacity(width * height)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Double(bytes[index + 3]) / 255
            guard alpha > 0.5 else { continue }
            // Un-premultiply.
            let color = SRGBColor(
                red: Double(bytes[index]) / 255 / alpha,
                green: Double(bytes[index + 1]) / 255 / alpha,
                blue: Double(bytes[index + 2]) / 255 / alpha
            )
            result.append(color.okLab)
        }
        return result
    }

    // MARK: Clustering

    struct Cluster {
        var center: OKLab
        var count: Int
    }

    static func cluster(_ points: [OKLab]) -> [Cluster] {
        let k = min(clusterCount, points.count)
        var centers = seed(points, count: k)
        var assignment = [Int](repeating: 0, count: points.count)
        for _ in 0..<12 {
            var changed = false
            for (index, point) in points.enumerated() {
                var best = 0
                var bestDistance = Double.infinity
                for (c, center) in centers.enumerated() {
                    let d = squaredDistance(point, center)
                    if d < bestDistance {
                        bestDistance = d
                        best = c
                    }
                }
                if assignment[index] != best {
                    assignment[index] = best
                    changed = true
                }
            }
            var sums = [OKLab](repeating: OKLab(l: 0, a: 0, b: 0), count: k)
            var counts = [Int](repeating: 0, count: k)
            for (index, point) in points.enumerated() {
                let c = assignment[index]
                sums[c].l += point.l
                sums[c].a += point.a
                sums[c].b += point.b
                counts[c] += 1
            }
            for c in 0..<k where counts[c] > 0 {
                let n = Double(counts[c])
                centers[c] = OKLab(l: sums[c].l / n, a: sums[c].a / n, b: sums[c].b / n)
            }
            if !changed { break }
        }
        var counts = [Int](repeating: 0, count: k)
        for c in assignment { counts[c] += 1 }
        let clusters = zip(centers, counts).filter { $0.1 > 0 }.map { Cluster(center: $0.0, count: $0.1) }
        return merge(clusters)
    }

    /// Deterministic k-means++: start at the point nearest the mean, then
    /// pick each next centre with probability proportional to its squared
    /// distance (fixed seed, so the same image gives the same palette).
    static func seed(_ points: [OKLab], count: Int) -> [OKLab] {
        var mean = OKLab(l: 0, a: 0, b: 0)
        for p in points {
            mean.l += p.l
            mean.a += p.a
            mean.b += p.b
        }
        let n = Double(points.count)
        mean = OKLab(l: mean.l / n, a: mean.a / n, b: mean.b / n)
        var centers = [points.min { squaredDistance($0, mean) < squaredDistance($1, mean) }!]
        var random = SplitMix64(seed: 0xC0_10_25)
        var distances = points.map { squaredDistance($0, centers[0]) }
        while centers.count < count {
            let total = distances.reduce(0, +)
            guard total > 1e-12 else { break }
            var target = Double(random.nextUnit()) * total
            var chosen = points.count - 1
            for (index, d) in distances.enumerated() {
                target -= d
                if target <= 0 {
                    chosen = index
                    break
                }
            }
            centers.append(points[chosen])
            for index in points.indices {
                distances[index] = min(distances[index], squaredDistance(points[index], points[chosen]))
            }
        }
        return centers
    }

    /// Merges clusters that are perceptually the same colour.
    static func merge(_ clusters: [Cluster]) -> [Cluster] {
        var result: [Cluster] = []
        for cluster in clusters.sorted(by: { $0.count > $1.count }) {
            if let index = result.firstIndex(where: { $0.center.distance(to: cluster.center) < mergeDistance }) {
                let a = Double(result[index].count)
                let b = Double(cluster.count)
                let total = a + b
                result[index].center = OKLab(
                    l: (result[index].center.l * a + cluster.center.l * b) / total,
                    a: (result[index].center.a * a + cluster.center.a * b) / total,
                    b: (result[index].center.b * a + cluster.center.b * b) / total
                )
                result[index].count += cluster.count
            } else {
                result.append(cluster)
            }
        }
        return result
    }

    private static func squaredDistance(_ x: OKLab, _ y: OKLab) -> Double {
        let dl = x.l - y.l
        let da = x.a - y.a
        let db = x.b - y.b
        return dl * dl + da * da + db * db
    }

    // MARK: Ranking

    /// Colourful clusters by area, then greys by area. Tiny specks (under
    /// 2 % of the picture) only count when nothing else is colourful.
    static func rank(_ clusters: [Cluster]) -> [Swatch] {
        let total = Double(clusters.reduce(0) { $0 + $1.count })
        guard total > 0 else { return [] }
        let swatches = clusters.map { cluster in
            (lab: cluster.center, share: Double(cluster.count) / total)
        }
        func isColorful(_ lab: OKLab) -> Bool {
            lab.chroma >= neutralChroma && lab.l > 0.12 && lab.l < 0.97
        }
        let colorful = swatches.filter { isColorful($0.lab) }.sorted { $0.share > $1.share }
        let significant = colorful.filter { $0.share >= 0.02 }
        let chosenColorful = significant.isEmpty ? Array(colorful.prefix(1)) : significant
        let neutrals = swatches.filter { !isColorful($0.lab) }.sorted { $0.share > $1.share }
        return (chosenColorful + neutrals)
            .prefix(maximumColors)
            .map { Swatch(color: SRGBColor(okLab: $0.lab), population: $0.share) }
    }

    /// Pads to three colours with lighter and darker shades of the first,
    /// for covers with only one or two colours.
    static func complete(_ swatches: [Swatch]) -> [Swatch] {
        var result = swatches
        guard !result.isEmpty else {
            return Palette.neutral.colors.map { Swatch(color: $0, population: 0) }
        }
        let base = result[0].color.okLab
        let shifts: [Double] = [0.18, -0.18, 0.32, -0.32]
        for shift in shifts where result.count < 3 {
            let lightness = min(0.95, max(0.08, base.l + shift))
            let shade = SRGBColor(okLab: base.with(lightness: lightness))
            if !result.contains(where: { $0.color.okLab.distance(to: shade.okLab) < mergeDistance }) {
                result.append(Swatch(color: shade, population: 0))
            }
        }
        return result
    }
}

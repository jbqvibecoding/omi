import AppKit
import CoreGraphics
import Foundation

/// Decides whether a watcher's sensor inputs changed enough since the last tick to be
/// worth another LLM call. Ported from Observer AI's change_detector: a perceptual dHash
/// on images (cheap) that escalates to an exact pixel diff only when the hash says
/// "suspiciously identical", plus Levenshtein similarity on text. Big token saver for
/// screen-watching agents.
struct WatcherSensorSnapshot {
    let text: String
    /// dHash of the first image (0 when no image).
    let imageHash: UInt64
    /// Small grayscale thumbnail bytes for the exact pixel-diff fallback.
    let thumbnail: [UInt8]
}

enum PerceptualChangeDetector {
    /// Text is "the same" at/above this Levenshtein similarity.
    static let textSimilarityThreshold = 0.90
    /// Image hash similarity below this ⇒ changed.
    static let imageHashChangedBelow = 0.90
    /// Hash similarity at/above this ⇒ suspiciously identical ⇒ escalate to pixel diff.
    static let imageHashIdenticalAtOrAbove = 0.998
    /// Thumbnail pixel-diff: fraction of differing pixels above which it's a real change.
    static let pixelDiffChangedAbove = 0.002

    static let thumbWidth = 32
    static let thumbHeight = 32

    /// Build a comparable snapshot from resolved sensor text + the first image (if any).
    static func snapshot(text: String, image: Data?) -> WatcherSensorSnapshot {
        guard let image, let cg = cgImage(from: image) else {
            return WatcherSensorSnapshot(text: text, imageHash: 0, thumbnail: [])
        }
        return WatcherSensorSnapshot(
            text: text, imageHash: dHash(cg), thumbnail: grayscaleThumbnail(cg))
    }

    /// True when either the text or the image changed meaningfully.
    static func isSignificant(previous: WatcherSensorSnapshot?, current: WatcherSensorSnapshot) -> Bool {
        guard let previous else { return true }  // first tick always runs

        let textSame = levenshteinSimilarity(previous.text, current.text) >= textSimilarityThreshold

        let imageSame: Bool
        if previous.imageHash == 0 && current.imageHash == 0 {
            imageSame = true  // no image sensor
        } else {
            let sim = hashSimilarity(previous.imageHash, current.imageHash)
            if sim < imageHashChangedBelow {
                imageSame = false
            } else if sim >= imageHashIdenticalAtOrAbove {
                // Perfect hash match can still hide tiny UI changes — confirm with pixels.
                imageSame = pixelDiffFraction(previous.thumbnail, current.thumbnail) <= pixelDiffChangedAbove
            } else {
                imageSame = true  // small hash drift = camera/render noise
            }
        }
        return !textSame || !imageSame
    }

    // MARK: - dHash

    /// 9×8 grayscale difference hash → 64-bit.
    static func dHash(_ image: CGImage) -> UInt64 {
        let w = 9, h = 8
        guard let gray = resizedGrayscale(image, width: w, height: h) else { return 0 }
        var hash: UInt64 = 0
        var bit = 0
        for row in 0..<h {
            for col in 0..<(w - 1) {
                let left = gray[row * w + col]
                let right = gray[row * w + col + 1]
                if left > right { hash |= (UInt64(1) << UInt64(bit)) }
                bit += 1
            }
        }
        return hash
    }

    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    static func hashSimilarity(_ a: UInt64, _ b: UInt64) -> Double {
        1.0 - Double(hammingDistance(a, b)) / 64.0
    }

    // MARK: - Text

    /// Normalized Levenshtein similarity in [0, 1].
    static func levenshteinSimilarity(_ a: String, _ b: String) -> Double {
        if a.isEmpty && b.isEmpty { return 1.0 }
        let s = Array(a), t = Array(b)
        let n = s.count, m = t.count
        if n == 0 || m == 0 { return 0.0 }
        var prev = Array(0...m)
        var cur = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            cur[0] = i
            for j in 1...m {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        let distance = Double(prev[m])
        return 1.0 - distance / Double(max(n, m))
    }

    // MARK: - Pixel fallback

    private static func pixelDiffFraction(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return a.count == b.count ? 0 : 1 }
        var diff = 0
        for i in 0..<a.count where abs(Int(a[i]) - Int(b[i])) > 8 { diff += 1 }
        return Double(diff) / Double(a.count)
    }

    private static func grayscaleThumbnail(_ image: CGImage) -> [UInt8] {
        resizedGrayscale(image, width: thumbWidth, height: thumbHeight) ?? []
    }

    // MARK: - CoreGraphics helpers

    static func cgImage(from data: Data) -> CGImage? {
        NSBitmapImageRep(data: data)?.cgImage
    }

    /// Downscale to width×height, 8-bit grayscale, row-major.
    private static func resizedGrayscale(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var buffer = [UInt8](repeating: 0, count: width * height)
        guard
            let ctx = CGContext(
                data: &buffer, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}

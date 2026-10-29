import CoreGraphics
import Foundation
import ImageIO

/// Shared image downscaling/compression for Gemini vision calls, so every screenshot
/// sent to a model pays the same, bounded payload cost.
///
/// The cap is on the **long edge**, not the width. Capping the width leaves a portrait
/// image untouched — a tall region crop at 900×2400 passes a `width > 1280` test and goes
/// out at full Retina size — and it scales a wide image by its least interesting
/// dimension. Long edge is the axis every vision model actually tiles on.
///
/// Two presets, because the lanes want opposite things:
/// - ``Preset/interactive`` for a snap, a region snap or a quick reply: the user pressed a
///   key and is waiting for one answer, and the answer is usually *read off the screen* —
///   code, a formula, a table. Legibility is the whole feature, so it gets more pixels and
///   less JPEG ringing.
/// - ``Preset/background`` for proactive assistants and watchers: these run on a loop, so
///   they keep the cheaper budget this file has always used.
enum GeminiImageCompression {

    struct Preset {
        let longEdge: Int
        let quality: Double

        /// A snap, a region snap, a quick reply — one call, user waiting, text to read.
        static let interactive = Preset(longEdge: 1568, quality: 0.6)
        /// Proactive assistants and watchers — on a loop, cost before legibility.
        static let background = Preset(longEdge: 1280, quality: 0.4)
    }

    /// Hard ceiling on the encoded payload. A busy screen at the interactive preset is
    /// well under this; the ceiling exists so a pathological frame can't blow up a request.
    static let maxEncodedBytes = 3 * 1024 * 1024
    /// Quality is stepped down at most this many times to get under the ceiling. Bounded
    /// because each step is a full re-encode.
    private static let maxQualitySteps = 2
    private static let qualityStep = 0.15
    private static let qualityFloor = 0.3

    /// Resize and compress an image for a Gemini vision call.
    static func compress(_ data: Data, preset: Preset = .background) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return encode(cgImage, preset: preset)
    }

    /// Resize and compress a `CGImage` directly.
    ///
    /// The capture paths use this so a screenshot is encoded **once**: going through
    /// `compress(_:)` meant encoding the full Retina frame to JPEG, immediately decoding
    /// it again, downscaling, and encoding a second time — two full-size encodes per snap.
    static func encode(_ image: CGImage, preset: Preset = .background) -> Data? {
        let size = targetSize(width: image.width, height: image.height, longEdge: preset.longEdge)
        guard let resized = redraw(image, to: size) else { return nil }

        var quality = preset.quality
        var encoded: Data?
        for step in 0...maxQualitySteps {
            guard let attempt = jpeg(resized, quality: quality) else { return nil }
            encoded = attempt
            if attempt.count <= maxEncodedBytes { break }
            if step == maxQualitySteps || quality <= qualityFloor {
                log(
                    "GeminiImageCompression: \(attempt.count / 1024) KB still over the "
                        + "\(maxEncodedBytes / 1024) KB ceiling at quality \(quality); sending anyway")
                break
            }
            quality = max(qualityFloor, quality - qualityStep)
        }
        return encoded
    }

    // MARK: - Geometry

    /// Scale so the long edge is at most `longEdge`, never upscaling.
    ///
    /// Both dimensions are clamped to at least one pixel: a sliver crop would otherwise
    /// round to a zero-height bitmap, `CGContext` would refuse to be built, and the caller
    /// — which falls back to the uncompressed original — would send the full frame.
    static func targetSize(width: Int, height: Int, longEdge: Int) -> (width: Int, height: Int) {
        let longest = max(width, height)
        guard longest > longEdge, longest > 0 else { return (width, height) }
        let scale = Double(longEdge) / Double(longest)
        return (
            max(1, Int((Double(width) * scale).rounded())),
            max(1, Int((Double(height) * scale).rounded()))
        )
    }

    private static func redraw(_ image: CGImage, to size: (width: Int, height: Int)) -> CGImage? {
        if size.width == image.width && size.height == image.height { return image }
        guard
            let context = CGContext(
                data: nil, width: size.width, height: size.height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context.makeImage()
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let mutableData = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                mutableData as CFMutableData, "public.jpeg" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }
}

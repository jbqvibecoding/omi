import CoreGraphics
import Foundation
import ImageIO

/// Shared image downscaling/compression for Gemini vision calls.
/// Used by proactive assistants and the copilot snap flow so every
/// screenshot sent to Gemini pays the same, bounded payload cost.
enum GeminiImageCompression {

    /// Resize and compress an image for Gemini analysis (max 1280px wide, JPEG quality 0.4)
    static func compress(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let maxWidth = 1280
        let width = cgImage.width
        let height = cgImage.height
        let scale = width > maxWidth ? Double(maxWidth) / Double(width) : 1.0
        let newWidth = Int(Double(width) * scale)
        let newHeight = Int(Double(height) * scale)

        guard let context = CGContext(
            data: nil, width: newWidth, height: newHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))

        guard let resized = context.makeImage() else { return nil }

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, resized, [kCGImageDestinationLossyCompressionQuality: 0.4] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }
}

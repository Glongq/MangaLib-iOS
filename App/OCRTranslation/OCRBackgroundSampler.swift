import UIKit

/// Best-effort "what color is the page right around this text" sampler —
/// backs the optional "erase original text" overlay mode (see
/// ExternalTranslationSettingsSheet): instead of a fixed-color plate, the
/// overlay is filled with whatever this returns, approximating the
/// original text being erased. Works well for the common case (flat
/// speech-bubble fills); on busy/textured art it's just a best guess, not
/// real content-aware reconstruction — there's no on-device inpainting
/// model available to do that properly.
enum OCRBackgroundSampler {

    /// `rect` — normalized (0...1), top-left origin, same convention as
    /// RecognizedTextBlock.rect. Samples a ring of pixels just OUTSIDE
    /// that box (avoiding the glyphs themselves) and returns the most
    /// common color found there.
    static func sample(rect: CGRect, in image: UIImage) -> OCRSampledColor? {
        guard let cgImage = image.cgImage else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width > 0, height > 0 else { return nil }

        let pixelRect = CGRect(x: rect.minX * width, y: rect.minY * height, width: rect.width * width, height: rect.height * height)
        let margin = max(3, pixelRect.height * 0.2)
        let outerRect = pixelRect.insetBy(dx: -margin, dy: -margin)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard outerRect.width >= 2, outerRect.height >= 2 else { return nil }

        let cropRect = outerRect.integral
        guard let cropped = cgImage.cropping(to: cropRect) else { return nil }

        // Downsample into a small, known-format (RGBA8) buffer for cheap
        // pixel access — a flip transform puts this context in the same
        // top-left/y-down convention as our normalized rects, avoiding
        // CGContext's default bottom-left/y-up orientation mismatch.
        let sampleSize = 24
        var pixels = [UInt8](repeating: 0, count: sampleSize * sampleSize * 4)
        guard let context = CGContext(
            data: &pixels, width: sampleSize, height: sampleSize, bitsPerComponent: 8,
            bytesPerRow: sampleSize * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(sampleSize))
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .low
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))

        // The original (unexpanded) bbox, in this downsampled crop's own
        // coordinate space — pixels inside it are the text itself and are
        // excluded from sampling.
        let scaleX = CGFloat(sampleSize) / cropRect.width
        let scaleY = CGFloat(sampleSize) / cropRect.height
        let innerInCrop = CGRect(
            x: (pixelRect.minX - cropRect.minX) * scaleX, y: (pixelRect.minY - cropRect.minY) * scaleY,
            width: pixelRect.width * scaleX, height: pixelRect.height * scaleY
        )

        // Bucket by a coarsely-quantized color so a handful of outlier
        // pixels (e.g. a bubble's outline stroke, or a stray glyph pixel
        // right at the edge) can't skew a plain average — the most
        // common bucket wins.
        var buckets: [UInt32: (count: Int, r: Int, g: Int, b: Int)] = [:]
        for y in 0..<sampleSize {
            for x in 0..<sampleSize {
                if innerInCrop.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) { continue }
                let offset = (y * sampleSize + x) * 4
                let alpha = pixels[offset + 3]
                guard alpha > 0 else { continue }
                let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
                let quantum = 24
                let key = UInt32((r / quantum) << 16 | (g / quantum) << 8 | (b / quantum))
                var bucket = buckets[key] ?? (0, 0, 0, 0)
                bucket.count += 1; bucket.r += r; bucket.g += g; bucket.b += b
                buckets[key] = bucket
            }
        }
        guard let best = buckets.values.max(by: { $0.count < $1.count }), best.count > 0 else { return nil }
        return OCRSampledColor(
            red: Double(best.r) / Double(best.count) / 255,
            green: Double(best.g) / Double(best.count) / 255,
            blue: Double(best.b) / Double(best.count) / 255
        )
    }
}

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct StillImageInfo {
    let creationDate: Date?
    let warnings: [String]
}

enum StillImageWriter {
    static func write(data: Data, to url: URL, identifier: String? = nil) throws -> StillImageInfo {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ConversionError.imageUnreadable
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [String: Any] ?? [:]
        let width = (sourceProperties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
        let height = (sourceProperties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0 else { throw ConversionError.imageUnreadable }
        guard width <= 32_768, height <= 32_768,
              Int64(width) * Int64(height) <= 250_000_000 else {
            throw ConversionError.imageTooLarge
        }
        let decodeOptions: [String: Any] = [
            kCGImageSourceShouldCache as String: true,
            kCGImageSourceShouldAllowFloat as String: false
        ]
        guard let decoded = CGImageSourceCreateImageAtIndex(source, index, decodeOptions as CFDictionary),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: decoded.width, height: decoded.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError.imageUnreadable
        }
        // An explicit 8-bit sRGB render avoids labelling HDR pixels as SDR. Gain
        // maps and auxiliary images are intentionally not copied into this JPEG.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ConversionError.imageWriteFailed
        }

        // Copy supported photographic metadata. Never copy the old Motion Photo
        // XMP offsets, Samsung maker note, thumbnail offsets, or auxiliary data.
        var properties: [String: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary,
                    kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                    kCGImagePropertyOrientation, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            properties[key as String] = sourceProperties[key as String]
        }
        if var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifMakerNote as String)
            exif[kCGImagePropertyExifColorSpace as String] = 1 // sRGB
            exif[kCGImagePropertyExifPixelXDimension as String] = image.width
            exif[kCGImagePropertyExifPixelYDimension as String] = image.height
            properties[kCGImagePropertyExifDictionary as String] = exif
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            // These describe byte locations in the input, not the new JPEG.
            for name in ["StripOffsets", "StripByteCounts", "TileOffsets", "TileByteCounts",
                         "JPEGInterchangeFormat", "JPEGInterchangeFormatLength", "ImageWidth", "ImageLength"] {
                tiff.removeValue(forKey: name)
            }
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if let identifier {
            properties[kCGImagePropertyMakerAppleDictionary as String] = ["17": identifier]
        }
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.98
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.imageWriteFailed }

        let capture = captureDate(from: sourceProperties)
        return StillImageInfo(creationDate: capture.date, warnings: capture.warnings)
    }

    static func captureDate(from properties: [String: Any]) -> (date: Date?, warnings: [String]) {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let candidates: [(String?, String?)] = [
            (exif[kCGImagePropertyExifDateTimeOriginal as String] as? String, exif["OffsetTimeOriginal"] as? String),
            (exif[kCGImagePropertyExifDateTimeDigitized as String] as? String, exif["OffsetTimeDigitized"] as? String),
            (tiff[kCGImagePropertyTIFFDateTime as String] as? String, exif["OffsetTime"] as? String)
        ]
        for (text, offset) in candidates {
            guard let text else { continue }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.isLenient = false
            if let offset, offset.range(of: #"^[+-]\d{2}:\d{2}$"#, options: .regularExpression) != nil {
                formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
                if let date = formatter.date(from: text + offset) { return (date, []) }
            }
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let date = formatter.date(from: text) {
                return (date, ["The capture date has no time zone. Your Mac’s time zone was used for the reported capture date."])
            }
        }
        return (nil, ["No readable capture date was found. Photo apps may use the import date."])
    }
}

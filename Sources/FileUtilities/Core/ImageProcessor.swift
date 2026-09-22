import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImageFormat: Identifiable, Hashable {
    let id: String          // UTType identifier
    let name: String
    let ext: String
    let lossy: Bool
    let viaFFmpeg: Bool

    var type: UTType? { UTType(id) }
}

enum ImageFormats {
    private static let known: [(id: String, name: String, ext: String, lossy: Bool)] = [
        ("public.jpeg", "JPEG", "jpg", true),
        ("public.png", "PNG", "png", false),
        ("public.heic", "HEIC", "heic", true),
        ("public.heif", "HEIF", "heif", true),
        ("public.avif", "AVIF", "avif", true),
        ("org.webmproject.webp", "WebP", "webp", true),
        ("public.tiff", "TIFF", "tiff", false),
        ("com.compuserve.gif", "GIF", "gif", false),
        ("com.microsoft.bmp", "BMP", "bmp", false),
        ("public.jpeg-2000", "JPEG 2000", "jp2", true),
        ("com.adobe.pdf", "PDF", "pdf", false),
        ("com.microsoft.ico", "ICO (≤256 px)", "ico", false),
        ("com.apple.icns", "ICNS", "icns", false),
        ("com.truevision.tga-image", "TGA", "tga", false),
        ("com.adobe.photoshop-image", "PSD", "psd", false),
        ("com.ilm.openexr-image", "OpenEXR", "exr", false),
        ("public.pbm", "PBM", "pbm", false),
    ]

    static let writableIDs: Set<String> = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    static let native: [ImageFormat] = known
        .filter { writableIDs.contains($0.id) }
        .map { ImageFormat(id: $0.id, name: $0.name, ext: $0.ext, lossy: $0.lossy, viaFFmpeg: false) }

    static func all() -> [ImageFormat] {
        var list = native
        let ff = FFmpeg.shared
        if !writableIDs.contains("org.webmproject.webp"), ff.has("libwebp") {
            list.append(ImageFormat(id: "org.webmproject.webp", name: "WebP (ffmpeg)", ext: "webp", lossy: true, viaFFmpeg: true))
        }
        if !writableIDs.contains("public.avif"), ff.has("libaom-av1") || ff.has("libsvtav1") {
            list.append(ImageFormat(id: "public.avif", name: "AVIF (ffmpeg)", ext: "avif", lossy: true, viaFFmpeg: true))
        }
        return list
    }

    static func format(id: String) -> ImageFormat? { all().first { $0.id == id } }

    static func canWrite(_ type: UTType) -> Bool { writableIDs.contains(type.identifier) }

    static func isLossy(_ type: UTType) -> Bool {
        known.first { $0.id == type.identifier }?.lossy ?? false
    }

    static func ext(for type: UTType, source: URL? = nil) -> String {
        if let source, UTType(filenameExtension: source.ext) == type { return source.pathExtension }
        return known.first { $0.id == type.identifier }?.ext ?? type.preferredFilenameExtension ?? "img"
    }
}

enum ImageProcessor {
    static let context = CIContext(options: [.cacheIntermediates: false])

    static func sourceType(of url: URL) -> UTType? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let id = CGImageSourceGetType(src) else { return nil }
        return UTType(id as String)
    }

    static func canRead(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(src) > 0 && CGImageSourceGetType(src) != nil
    }

    static func properties(of url: URL) -> [CFString: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
    }

    /// Upright image for previews, limited to `maxPixel`.
    static func thumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    /// Re-encodes `src` into `type`, optionally transforming it and dropping metadata.
    static func write(src: URL, to dst: URL, type: UTType, quality: Double?, stripMetadata: Bool,
                      transform: MediaTransform? = nil, tiffCompression: Bool = false) throws {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw AppError("Can't read this image")
        }
        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        guard let dest = CGImageDestinationCreateWithURL(dst as CFURL, type.identifier as CFString, 1, nil) else {
            throw AppError("Can't write \(type.localizedDescription ?? "this format") files")
        }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }

        let hasAlpha = (props[kCGImagePropertyHasAlpha] as? Bool) ?? false
        let flatten = hasAlpha && (type == .jpeg || type == .bmp)
        let transformed = !(transform?.isIdentity ?? true)

        if flatten || transformed {
            guard var image = CIImage(contentsOf: src, options: [.applyOrientationProperty: true]) else {
                throw AppError("Can't decode this image")
            }
            if let transform { image = transform.apply(image, even: false) }
            if flatten { image = image.composited(over: CIImage(color: .white).cropped(to: image.extent)) }
            let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
            guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space) else {
                throw AppError("Couldn't render the image")
            }
            if !stripMetadata {
                for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
                    if let value = props[key] { options[key] = value }
                }
                if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                    tiff[kCGImagePropertyTIFFOrientation] = 1
                    options[kCGImagePropertyTIFFDictionary] = tiff
                }
            }
            options[kCGImagePropertyOrientation] = 1
            addTIFFCompression(&options, tiffCompression)
            CGImageDestinationAddImage(dest, cg, options as CFDictionary)
        } else if stripMetadata {
            guard let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw AppError("Can't decode this image") }
            options[kCGImagePropertyOrientation] = props[kCGImagePropertyOrientation] ?? 1
            addTIFFCompression(&options, tiffCompression)
            CGImageDestinationAddImage(dest, cg, options as CFDictionary)
        } else {
            addTIFFCompression(&options, tiffCompression)
            CGImageDestinationAddImageFromSource(dest, source, 0, options as CFDictionary)
            if CGImageDestinationFinalize(dest) { return }
            // Some encoders (e.g. JPEG 2000) only accept decoded images.
            try? FileManager.default.removeItem(at: dst)
            guard let retry = CGImageDestinationCreateWithURL(dst as CFURL, type.identifier as CFString, 1, nil),
                  let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw AppError("Couldn't save as \(type.localizedDescription ?? "this format")")
            }
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                        kCGImagePropertyTIFFDictionary, kCGImagePropertyOrientation] {
                if options[key] == nil, let value = props[key] { options[key] = value }
            }
            CGImageDestinationAddImage(retry, cg, options as CFDictionary)
            if CGImageDestinationFinalize(retry) { return }
            // Last resort: bake the orientation into the pixels and write without metadata.
            try? FileManager.default.removeItem(at: dst)
            let longest = max(props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
            guard let plain = CGImageDestinationCreateWithURL(dst as CFURL, type.identifier as CFString, 1, nil),
                  let upright = thumbnail(src, maxPixel: max(longest, 1)) else {
                throw AppError("Couldn't save as \(type.localizedDescription ?? "this format")")
            }
            var plainOptions: [CFString: Any] = [:]
            if let quality { plainOptions[kCGImageDestinationLossyCompressionQuality] = quality }
            CGImageDestinationAddImage(plain, upright, plainOptions as CFDictionary)
            guard CGImageDestinationFinalize(plain) else {
                try? FileManager.default.removeItem(at: dst)
                throw AppError("Couldn't save as \(type.localizedDescription ?? "this format") (size or color type not supported)")
            }
            return
        }
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: dst)
            throw AppError("Couldn't save as \(type.localizedDescription ?? "this format") (size or color type not supported)")
        }
    }

    private static func addTIFFCompression(_ options: inout [CFString: Any], _ enabled: Bool) {
        guard enabled else { return }
        var tiff = (options[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
        tiff[kCGImagePropertyTIFFCompression] = 5 // LZW, lossless
        options[kCGImagePropertyTIFFDictionary] = tiff
    }

    static func writeCGImage(_ image: CGImage, to url: URL, type: UTType, quality: Double = 0.9) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw AppError("Can't write this image format")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw AppError("Couldn't save image") }
    }

    /// Decodes formats ImageIO can't read (via ffmpeg) into a temporary PNG.
    static func decodeWithFFmpeg(_ url: URL) async throws -> URL {
        guard FFmpeg.shared.isAvailable else { throw AppError("This image format can't be read. Setting up ffmpeg (Settings) may help.") }
        let tmp = Output.temporary(ext: "png")
        try await FFmpeg.shared.run(["-i", url.path, "-frames:v", "1", tmp.path])
        return tmp
    }

    /// Strips metadata without re-encoding when possible.
    static func stripMetadata(src: URL, to dst: URL, locationOnly: Bool) throws {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil), let typeID = CGImageSourceGetType(source) else {
            throw AppError("Can't read this image")
        }
        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        guard let dest = CGImageDestinationCreateWithURL(dst as CFURL, typeID, 1, nil) else {
            throw AppError("Can't write this image format")
        }
        var options: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
        if locationOnly {
            if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
                options[kCGImageDestinationMetadata] = metadata
            }
            options[kCGImageDestinationMergeMetadata] = false
        } else {
            let metadata = CGImageMetadataCreateMutable()
            if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation != 1 {
                CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary,
                                                             kCGImagePropertyTIFFOrientation, orientation as CFNumber)
            }
            options[kCGImageDestinationMetadata] = metadata
            options[kCGImageDestinationMergeMetadata] = false
        }
        if CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, nil) { return }

        // Lossless copy isn't supported for this format: re-encode at top quality.
        try? FileManager.default.removeItem(at: dst)
        try write(src: src, to: dst, type: UTType(typeID as String) ?? .png, quality: 1.0, stripMetadata: true)
    }
}

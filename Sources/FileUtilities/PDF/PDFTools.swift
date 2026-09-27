import AppKit
import CoreText
import Quartz
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

enum PDFTools {
    // MARK: Rendering

    static func displaySize(of page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox)
        return page.rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }

    /// Rasterizes a page (PDFKit applies the page rotation itself).
    static func render(_ page: PDFPage, dpi: CGFloat) -> CGImage? {
        let size = displaySize(of: page)
        let scale = dpi / 72
        let width = max(1, Int(size.width * scale)), height = max(1, Int(size.height * scale))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: ctx)
        return ctx.makeImage()
    }

    /// Writes a copy where annotations are burned into the page content.
    static func flatten(_ document: PDFDocument, to url: URL) throws {
        var mediaBox = CGRect.zero
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { throw AppError("Couldn't create PDF") }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var box = CGRect(origin: .zero, size: displaySize(of: page))
            ctx.beginPage(mediaBox: &box)
            page.draw(with: .cropBox, to: ctx)
            ctx.endPage()
        }
        ctx.closePDF()
    }

    // MARK: Compress

    enum CompressLevel: String, CaseIterable, Identifiable {
        case high = "High quality"
        case balanced = "Balanced"
        case small = "Smallest"
        var id: Self { self }
        /// JPEG quality for images inside the PDF, and the resolution they're reduced to.
        var quality: Double { [.high: 0.8, .balanced: 0.6, .small: 0.45][self]! }
        var dpi: Int { [.high: 200, .balanced: 150, .small: 110][self]! }
    }

    enum CompressOutcome {
        case compressed(note: String?)
        /// Nothing worth saving; `reason` explains why, in words worth showing the user.
        case notSmaller(reason: String)
    }

    /// How a page's content gets redrawn into the filtered context. Which one manages to
    /// re-encode the images differs between macOS versions, so they're tried in turn.
    enum CompressStrategy: CaseIterable {
        /// Core Graphics draws the page's content stream. Keeps annotations editable.
        case content
        /// PDFKit draws the page. Flattens annotations, but re-encodes images on macOS versions
        /// where the Core Graphics path copies them through untouched.
        case pdfKit
        /// Re-encode whole pages as JPEG. Only for scans — it would destroy selectable text.
        case raster
    }

    /// Recompresses the images inside a PDF. Text and vector graphics stay sharp.
    @discardableResult
    static func compress(_ src: URL, to dst: URL, level: CompressLevel,
                         allowRedrawingText: Bool = false,
                         strategies: [CompressStrategy] = CompressStrategy.allCases) throws -> CompressOutcome {
        guard let probe = PDFDocument(url: src) else { throw AppError("Can't open this PDF") }
        guard !probe.isLocked else { throw AppError("This PDF is password-protected") }
        guard let content = CGPDFDocument(src as CFURL), content.numberOfPages > 0 else {
            throw AppError("Can't read this PDF")
        }
        let images = imageCount(in: content)
        let hasText = !(probe.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let annotated = (0..<probe.pageCount).contains { probe.page(at: $0)?.annotations.isEmpty == false }
        // A saving of a few bytes isn't worth a second copy of the file.
        let worthwhile = Int64(Double(src.fileSize) * 0.97)

        for strategy in strategies {
            if strategy == .raster && ((hasText && !allowRedrawingText) || images == 0) { continue }
            try? FileManager.default.removeItem(at: dst)
            switch strategy {
            case .content, .pdfKit:
                try filterPages(src, to: dst, level: level, usePDFKitDrawing: strategy == .pdfKit)
            case .raster:
                // Page-sized JPEGs of sharp text are expensive, so drop the resolution
                // a step at a time until it's actually worth it.
                for dpi in [level.dpi, 110, 96] where dpi <= level.dpi {
                    try? FileManager.default.removeItem(at: dst)
                    try rasterize(src, to: dst, level: level, dpi: dpi)
                    if dst.fileSize < worthwhile { break }
                }
            }
            guard dst.fileSize > 0, dst.fileSize < worthwhile, PDFDocument(url: dst)?.pageCount == probe.pageCount else { continue }
            switch strategy {
            case .content: return .compressed(note: nil)
            case .pdfKit: return .compressed(note: annotated ? "Comments flattened into the page" : nil)
            case .raster: return .compressed(note: hasText ? "Pages re-encoded — text is now part of the image" : "Scanned pages re-encoded")
            }
        }
        try? FileManager.default.removeItem(at: dst)
        if images == 0 { return .notSmaller(reason: "No photos inside — already compact") }
        if hasText, !allowRedrawingText {
            return .notSmaller(reason: "Couldn't shrink further — try \"Re-encode pages\"")
        }
        return .notSmaller(reason: "Already as small as it gets")
    }

    /// Redraws every page through a Quartz filter that re-encodes the images it meets.
    private static func filterPages(_ src: URL, to dst: URL, level: CompressLevel, usePDFKitDrawing: Bool) throws {
        guard let source = PDFDocument(url: src), let content = CGPDFDocument(src as CFURL) else {
            throw AppError("Can't read this PDF")
        }
        let filterProperties: [AnyHashable: Any] = [
            "Name": "File Utilities Compress",
            "FilterType": 1,
            "Domains": ["Applications": true, "Printing": true],
            "FilterData": ["ColorSettings": ["ImageSettings": [
                "Compression Quality": level.quality,
                "ImageCompression": "ImageJPEGCompress",
                "ImageScaleSettings": [
                    "ImageResolution": level.dpi,
                    "ImageScaleInterpolate": true,
                    "ImageSizeMax": 4000,
                    "ImageSizeMin": 0,
                ],
            ]]],
        ]
        guard let filter = QuartzFilter(properties: filterProperties) else { throw AppError("Couldn't set up PDF compression") }

        var defaultBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(dst as CFURL, mediaBox: &defaultBox, nil) else { throw AppError("Couldn't create the PDF") }
        filter.apply(to: ctx)
        var rotations: [Int] = []
        for index in 1...content.numberOfPages {
            try Task.checkCancellation()
            guard let page = content.page(at: index) else { continue }
            let crop = page.getBoxRect(.cropBox)
            rotations.append(Int(page.rotationAngle))
            // Draw the page upright: under a rotated transform the filter leaves images untouched.
            var box = CGRect(origin: .zero, size: crop.size)
            ctx.beginPage(mediaBox: &box)
            ctx.saveGState()
            if usePDFKitDrawing, let kitPage = source.page(at: index - 1) {
                kitPage.rotation = 0
                kitPage.draw(with: .cropBox, to: ctx)
            } else {
                ctx.translateBy(x: -crop.minX, y: -crop.minY)
                ctx.drawPDFPage(page)
            }
            ctx.restoreGState()
            ctx.endPage()
        }
        ctx.closePDF()

        // Rotation and annotations need PDFKit to write them back, and that save can undo some of
        // the saving — so only do it when this document has something to restore.
        let needsRotation = rotations.contains { $0 % 360 != 0 }
        let keepsAnnotations = !usePDFKitDrawing   // the PDFKit path already drew them into the page
        let annotated = keepsAnnotations && (0..<source.pageCount).contains { source.page(at: $0)?.annotations.isEmpty == false }
        guard needsRotation || annotated else { return }

        guard let result = PDFDocument(url: dst) else { throw AppError("Couldn't finish the PDF") }
        for index in 0..<result.pageCount {
            guard let page = result.page(at: index) else { continue }
            if index < rotations.count { page.rotation = rotations[index] }
            guard keepsAnnotations, let original = source.page(at: index) else { continue }
            for annotation in original.annotations {
                original.removeAnnotation(annotation)
                page.addAnnotation(annotation)
            }
        }
        result.documentAttributes = source.documentAttributes
        guard result.write(to: dst) else { throw AppError("Couldn't save the compressed PDF") }
    }

    /// Last resort for scans: draw each page as a JPEG. Only used when there's no text to lose.
    private static func rasterize(_ src: URL, to dst: URL, level: CompressLevel, dpi: Int? = nil) throws {
        guard let source = PDFDocument(url: src) else { throw AppError("Can't read this PDF") }
        var defaultBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(dst as CFURL, mediaBox: &defaultBox, nil) else { throw AppError("Couldn't create the PDF") }
        for index in 0..<source.pageCount {
            try Task.checkCancellation()
            guard let page = source.page(at: index) else { continue }
            var box = CGRect(origin: .zero, size: displaySize(of: page))
            ctx.beginPage(mediaBox: &box)
            if let rendered = render(page, dpi: CGFloat(dpi ?? level.dpi)), let jpeg = jpegCopy(rendered, quality: level.quality) {
                ctx.draw(jpeg, in: box)
            }
            ctx.endPage()
        }
        ctx.closePDF()
    }

    /// Round-trips an image through JPEG so Quartz embeds the compressed data.
    private static func jpegCopy(_ image: CGImage, quality: Double) -> CGImage? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest), let source = CGImageSourceCreateWithData(data, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// How many image objects the document draws — 0 means there's nothing for compression to work on.
    static func imageCount(in document: CGPDFDocument) -> Int {
        /// Shared with the C callback, which can't capture context of its own.
        final class Scan {
            var images = 0
            var queue: [CGPDFDictionaryRef] = []   // resource dictionaries still to look at
        }
        let scan = Scan()

        func enqueueResources(_ resources: CGPDFDictionaryRef) {
            var xobjects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return }
            CGPDFDictionaryApplyFunction(xobjects, { _, object, info in
                guard let info else { return }
                let scan = Unmanaged<Scan>.fromOpaque(info).takeUnretainedValue()
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                      let dict = CGPDFStreamGetDictionary(stream) else { return }
                var subtype: UnsafePointer<Int8>?
                guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype else { return }
                switch String(cString: subtype) {
                case "Image":
                    scan.images += 1
                case "Form":
                    // A form can hold images of its own; queue its resources for the next round.
                    var nested: CGPDFDictionaryRef?
                    if CGPDFDictionaryGetDictionary(dict, "Resources", &nested), let nested {
                        scan.queue.append(nested)
                    }
                default:
                    break
                }
            }, Unmanaged.passUnretained(scan).toOpaque())
        }

        for index in 1...document.numberOfPages {
            guard let page = document.page(at: index), let dict = page.dictionary else { continue }
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources {
                scan.queue.append(resources)
            }
        }
        var rounds = 0
        while let next = scan.queue.popLast(), rounds < 2000 {
            rounds += 1
            enqueueResources(next)
        }
        return scan.images
    }

    // MARK: Images → PDF

    enum PageSize: String, CaseIterable, Identifiable {
        case fit = "Fit to image", a4 = "A4", letter = "US Letter"
        var id: Self { self }
        var size: CGSize? {
            switch self {
            case .fit: nil
            case .a4: CGSize(width: 595, height: 842)
            case .letter: CGSize(width: 612, height: 792)
            }
        }
    }

    static func imagesToPDF(_ urls: [URL], to dst: URL, pageSize: PageSize, margin: CGFloat, jpegQuality: Double?, progress: ProgressHandler?) throws {
        var mediaBox = CGRect.zero
        guard let ctx = CGContext(dst as CFURL, mediaBox: &mediaBox, nil) else { throw AppError("Couldn't create PDF") }
        for (index, url) in urls.enumerated() {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw AppError("Can't read \(url.lastPathComponent)")
            }
            let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
            if let quality = jpegQuality {
                // Re-encode as JPEG so Quartz embeds the compressed data directly.
                let data = NSMutableData()
                if let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                    if CGImageDestinationFinalize(dest), let src = CGImageSourceCreateWithData(data, nil),
                       let jpeg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                        image = jpeg
                    }
                }
            }
            let orientation = CGImagePropertyOrientation(rawValue: (props[kCGImagePropertyOrientation] as? UInt32) ?? 1) ?? .up
            let pixel = CGSize(width: image.width, height: image.height)
            let rawTransform = CIImage(cgImage: image).orientationTransform(for: orientation)
            let orientedRect = CGRect(origin: .zero, size: pixel).applying(rawTransform)
            let orientTransform = rawTransform.concatenating(CGAffineTransform(translationX: -orientedRect.minX, y: -orientedRect.minY))
            let upright = orientedRect.size

            var page: CGSize
            if let fixed = pageSize.size {
                page = upright.width > upright.height ? CGSize(width: fixed.height, height: fixed.width) : fixed
            } else {
                let longSide = 842.0
                let s = longSide / max(upright.width, upright.height)
                page = CGSize(width: (upright.width * s).rounded() + margin * 2, height: (upright.height * s).rounded() + margin * 2)
            }
            let area = CGRect(origin: .zero, size: page).insetBy(dx: margin, dy: margin)
            let scale = min(area.width / upright.width, area.height / upright.height)
            let drawSize = CGSize(width: upright.width * scale, height: upright.height * scale)
            let origin = CGPoint(x: area.midX - drawSize.width / 2, y: area.midY - drawSize.height / 2)

            var box = CGRect(origin: .zero, size: page)
            ctx.beginPage(mediaBox: &box)
            ctx.saveGState()
            ctx.translateBy(x: origin.x, y: origin.y)
            ctx.scaleBy(x: scale, y: scale)
            ctx.concatenate(orientTransform)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(origin: .zero, size: pixel))
            ctx.restoreGState()
            ctx.endPage()
            progress?(Double(index + 1) / Double(urls.count))
        }
        ctx.closePDF()
    }

    // MARK: PDF → images

    static func pdfToImages(_ url: URL, folder: URL?, format: ImageFormat, dpi: CGFloat, progress: ProgressHandler?) throws -> URL {
        guard let document = PDFDocument(url: url) else { throw AppError("Can't open this PDF") }
        guard !document.isLocked else { throw AppError("This PDF is password-protected") }
        guard let type = format.type else { throw AppError("Unknown image format") }
        let parent = folder ?? url.deletingLastPathComponent()
        let dir = Output.unique(parent.appendingPathComponent("\(url.baseName) pages"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let digits = max(2, String(document.pageCount).count)
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index), let image = render(page, dpi: dpi) else { continue }
            let name = String(format: "%@-%0\(digits)d", url.baseName, index + 1)
            try ImageProcessor.writeCGImage(image, to: dir.appendingPathComponent(name).appendingPathExtension(format.ext), type: type, quality: 0.9)
            progress?(Double(index + 1) / Double(document.pageCount))
        }
        return dir
    }

    // MARK: OCR

    static func ocr(_ url: URL, folder: URL?, exportText: Bool, progress: ProgressHandler?) throws -> URL {
        guard let document = PDFDocument(url: url) else { throw AppError("Can't open this PDF") }
        guard !document.isLocked else { throw AppError("This PDF is password-protected") }
        let dst = Output.destination(for: url, folder: folder, suffix: " (searchable)", ext: "pdf")
        var mediaBox = CGRect.zero
        guard let ctx = CGContext(dst as CFURL, mediaBox: &mediaBox, nil) else { throw AppError("Couldn't create PDF") }
        var allText = ""

        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let size = displaySize(of: page)
            var box = CGRect(origin: .zero, size: size)
            ctx.beginPage(mediaBox: &box)
            page.draw(with: .cropBox, to: ctx)

            if let image = render(page, dpi: 300) {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                try? VNImageRequestHandler(cgImage: image).perform([request])
                let observations = request.results ?? []
                ctx.saveGState()
                ctx.setTextDrawingMode(.invisible)
                for observation in observations {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let text = candidate.string
                    allText += text + "\n"
                    let r = observation.boundingBox
                    let rect = CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
                    guard rect.width > 1, rect.height > 1 else { continue }
                    let font = CTFontCreateWithName("Helvetica" as CFString, rect.height * 0.85, nil)
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
                    let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
                    let stretch = lineWidth > 0 ? rect.width / lineWidth : 1
                    ctx.textMatrix = CGAffineTransform(scaleX: stretch, y: 1)
                    ctx.textPosition = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.2)
                    CTLineDraw(line, ctx)
                }
                ctx.restoreGState()
                allText += "\n"
            }
            ctx.endPage()
            progress?(Double(index + 1) / Double(document.pageCount))
        }
        ctx.closePDF()
        if exportText {
            try allText.write(to: dst.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        }
        return dst
    }
}

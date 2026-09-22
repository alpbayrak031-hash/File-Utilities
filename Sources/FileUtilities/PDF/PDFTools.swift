import AppKit
import CoreText
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

import AppKit
import Observation
import PDFKit
import SwiftUI

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select, text, note, rectangle, ellipse, line, arrow, pen, highlight, underline, strikeout, eraser
    var id: Self { self }

    var title: String {
        switch self {
        case .select: "Select / Move"
        case .text: "Text"
        case .note: "Sticky Note"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .arrow: "Arrow"
        case .pen: "Pen"
        case .highlight: "Highlight Text"
        case .underline: "Underline Text"
        case .strikeout: "Strike Through Text"
        case .eraser: "Eraser (click an annotation)"
        }
    }

    var icon: String {
        switch self {
        case .select: "cursorarrow"
        case .text: "textformat"
        case .note: "note.text"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .pen: "scribble"
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strikeout: "strikethrough"
        case .eraser: "eraser"
        }
    }

    var isTextMarkup: Bool { [.highlight, .underline, .strikeout].contains(self) }
    var isDrawing: Bool { [.rectangle, .ellipse, .line, .arrow, .pen].contains(self) }
}

struct TextEditRequest: Identifiable {
    let id = UUID()
    var annotation: PDFAnnotation?
    var page: PDFPage
    var point: CGPoint
    var isNote: Bool
    var text: String
}

@Observable @MainActor
final class PDFEditorModel {
    var document: PDFDocument?
    var fileURL: URL?
    var tool: AnnotationTool = .select
    var strokeColor: Color = .red
    var fillEnabled = false
    var fillColor: Color = .yellow.opacity(0.35)
    var highlightColor: Color = .yellow
    var lineWidth: Double = 3
    var fontSize: Double = 18
    var fontName = "Helvetica"
    var showThumbnails = true
    var isDirty = false
    var textEdit: TextEditRequest?
    var errorMessage: String?
    /// Bumped whenever the selected annotation or its properties change, so the inspector refreshes.
    var revision = 0
    private(set) var selected: PDFAnnotation?

    @ObservationIgnored weak var pdfView: AnnotatingPDFView?

    var title: String { fileURL?.lastPathComponent ?? "Untitled" }

    // MARK: Files

    func open(_ url: URL) {
        guard let doc = PDFDocument(url: url) else {
            errorMessage = "Couldn't open \(url.lastPathComponent)"
            return
        }
        if doc.isLocked {
            errorMessage = "\(url.lastPathComponent) is password-protected. Unlock it in Preview first."
            return
        }
        document = doc
        fileURL = url
        isDirty = false
        select(nil)
        pdfView?.undoManager?.removeAllActions()
    }

    func openPanel() {
        if let url = Panels.openFiles(types: [.pdf], folders: false, multiple: false).first { open(url) }
    }

    func save() {
        guard let document else { return }
        guard let url = fileURL else { return saveAs() }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).pdf")
        guard document.write(to: temp) else {
            errorMessage = "Couldn't save the PDF"
            return
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            isDirty = false
        } catch {
            try? FileManager.default.removeItem(at: temp)
            errorMessage = error.localizedDescription
        }
    }

    func saveAs() {
        guard let document else { return }
        let name = fileURL.map { "\($0.baseName) edited.pdf" } ?? "Document.pdf"
        guard let url = Panels.save(name: name, type: .pdf, directory: fileURL?.deletingLastPathComponent()) else { return }
        if document.write(to: url) {
            // Reopen from the new location so later saves go there.
            fileURL = url
            isDirty = false
        } else {
            errorMessage = "Couldn't save the PDF"
        }
    }

    func exportFlattened() {
        guard let document else { return }
        let name = fileURL.map { "\($0.baseName) flattened.pdf" } ?? "Flattened.pdf"
        guard let url = Panels.save(name: name, type: .pdf, directory: fileURL?.deletingLastPathComponent()) else { return }
        do {
            try PDFTools.flatten(document, to: url)
            Panels.reveal([url])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Selection & edits

    func select(_ annotation: PDFAnnotation?) {
        selected = annotation
        revision += 1
        pdfView?.refreshOverlay()
    }

    private var undo: UndoManager? { pdfView?.undoManager }

    func add(_ annotation: PDFAnnotation, to page: PDFPage, actionName: String = "Add Annotation") {
        page.addAnnotation(annotation)
        changed(page)
        undo?.registerUndo(withTarget: self) { $0.remove(annotation, from: page) }
        undo?.setActionName(actionName)
    }

    func remove(_ annotation: PDFAnnotation, from page: PDFPage) {
        page.removeAnnotation(annotation)
        if selected === annotation { select(nil) }
        changed(page)
        undo?.registerUndo(withTarget: self) { $0.add(annotation, to: page) }
        undo?.setActionName("Delete Annotation")
    }

    func setBounds(_ annotation: PDFAnnotation, to bounds: CGRect, from old: CGRect) {
        annotation.bounds = bounds
        if let page = annotation.page { changed(page) }
        undo?.registerUndo(withTarget: self) { $0.setBounds(annotation, to: old, from: bounds) }
        undo?.setActionName("Move Annotation")
    }

    func deleteSelected() {
        guard let annotation = selected, let page = annotation.page else { return }
        remove(annotation, from: page)
    }

    func changed(_ page: PDFPage?) {
        isDirty = true
        revision += 1
        if let page { pdfView?.annotationsChanged(on: page) }
        pdfView?.refreshOverlay()
    }

    // MARK: Text

    func commitText(_ request: TextEditRequest, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let annotation = request.annotation {
            annotation.contents = text
            if annotation.type == "FreeText" { fit(annotation) }
            changed(annotation.page)
            return
        }
        guard !trimmed.isEmpty else { return }
        let annotation: PDFAnnotation
        if request.isNote {
            annotation = PDFAnnotation(bounds: CGRect(x: request.point.x, y: request.point.y - 24, width: 24, height: 24),
                                       forType: .text, withProperties: nil)
            annotation.iconType = .comment
            annotation.color = NSColor(highlightColor)
            annotation.contents = text
        } else {
            annotation = PDFAnnotation(bounds: CGRect(x: request.point.x, y: request.point.y - 20, width: 100, height: 20),
                                       forType: .freeText, withProperties: nil)
            annotation.contents = text
            annotation.font = NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
            annotation.fontColor = NSColor(strokeColor)
            annotation.color = fillEnabled ? NSColor(fillColor) : .clear
            let border = PDFBorder()
            border.lineWidth = 0
            annotation.border = border
            fit(annotation)
        }
        add(annotation, to: request.page, actionName: request.isNote ? "Add Note" : "Add Text")
        select(annotation)
    }

    /// Resizes a text box to its contents, keeping the top-left corner fixed.
    func fit(_ annotation: PDFAnnotation) {
        let font = annotation.font ?? .systemFont(ofSize: fontSize)
        let text = (annotation.contents?.isEmpty ?? true) ? " " : annotation.contents!
        let size = NSAttributedString(string: text, attributes: [.font: font])
            .boundingRect(with: CGSize(width: 600, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        let top = annotation.bounds.maxY
        annotation.bounds = CGRect(x: annotation.bounds.minX, y: top - ceil(size.height) - 6,
                                   width: ceil(size.width) + 14, height: ceil(size.height) + 6)
    }

    // MARK: Inspector helpers

    func applyStroke(_ color: Color) {
        guard let a = selected else { return }
        if a.type == "FreeText" { a.fontColor = NSColor(color) } else { a.color = NSColor(color) }
        changed(a.page)
    }

    func applyFill(_ color: Color?) {
        guard let a = selected else { return }
        if a.type == "FreeText" { a.color = color.map { NSColor($0) } ?? .clear } else { a.interiorColor = color.map { NSColor($0) } }
        changed(a.page)
    }

    func applyLineWidth(_ width: Double) {
        guard let a = selected else { return }
        let border = PDFBorder()
        border.lineWidth = width
        a.border = border
        changed(a.page)
    }

    func applyFontSize(_ size: Double) {
        guard let a = selected, a.type == "FreeText" else { return }
        a.font = NSFont(name: a.font?.fontName ?? fontName, size: size) ?? .systemFont(ofSize: size)
        fit(a)
        changed(a.page)
    }

    func editSelectedText() {
        guard let a = selected, let page = a.page, a.type == "FreeText" || a.type == "Text" else { return }
        textEdit = TextEditRequest(annotation: a, page: page, point: a.bounds.origin, isNote: a.type == "Text", text: a.contents ?? "")
    }
}

// MARK: - PDF view with drawing tools

final class AnnotatingPDFView: PDFView {
    weak var model: PDFEditorModel?
    private let overlay = OverlayView()
    private var observers: [NSObjectProtocol] = []
    private var observingScroll = false

    private var dragPage: PDFPage?
    private var dragStart = CGPoint.zero
    private var dragCurrent = CGPoint.zero
    private var inkPoints: [CGPoint] = []
    private var moving: PDFAnnotation?
    private var moveOrigin = CGRect.zero
    private var moveStart = CGPoint.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        overlay.host = self
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        for name in [Notification.Name.PDFViewScaleChanged, .PDFViewPageChanged, .PDFViewDocumentChanged, .PDFViewDisplayModeChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                self?.refreshOverlay()
            })
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override func layout() {
        super.layout()
        if subviews.last !== overlay { addSubview(overlay, positioned: .above, relativeTo: nil) }
        overlay.frame = bounds
        if !observingScroll, let clip = documentView?.enclosingScrollView?.contentView {
            observingScroll = true
            clip.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                self?.refreshOverlay()
            })
        }
    }

    func refreshOverlay() { overlay.needsDisplay = true }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Mouse

    private func pageAndPoint(_ event: NSEvent) -> (PDFPage, CGPoint)? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else { return nil }
        return (page, convert(viewPoint, to: page))
    }

    private func hitAnnotation(_ page: PDFPage, _ point: CGPoint) -> PDFAnnotation? {
        page.annotations.reversed().first { $0.type != "Widget" && $0.type != "Popup" && $0.bounds.insetBy(dx: -3, dy: -3).contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let model, document != nil, let (page, point) = pageAndPoint(event) else { return super.mouseDown(with: event) }
        switch model.tool {
        case .select:
            if let annotation = hitAnnotation(page, point) {
                model.select(annotation)
                if event.clickCount == 2 { model.editSelectedText(); return }
                moving = annotation
                moveOrigin = annotation.bounds
                moveStart = point
                dragPage = page
            } else {
                model.select(nil)
                super.mouseDown(with: event)
            }
        case .highlight, .underline, .strikeout:
            super.mouseDown(with: event)
        case .eraser:
            if let annotation = hitAnnotation(page, point) { model.remove(annotation, from: page) }
        case .text, .note:
            if let annotation = hitAnnotation(page, point), annotation.type == "FreeText" || annotation.type == "Text" {
                model.select(annotation)
                model.editSelectedText()
            } else {
                model.textEdit = TextEditRequest(annotation: nil, page: page, point: point, isNote: model.tool == .note, text: "")
            }
        case .rectangle, .ellipse, .line, .arrow, .pen:
            dragPage = page
            dragStart = point
            dragCurrent = point
            inkPoints = [point]
            refreshOverlay()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model else { return super.mouseDragged(with: event) }
        if model.tool == .select {
            guard let annotation = moving, let page = dragPage else { return super.mouseDragged(with: event) }
            let point = convert(convert(event.locationInWindow, from: nil), to: page)
            annotation.bounds = moveOrigin.offsetBy(dx: point.x - moveStart.x, dy: point.y - moveStart.y)
            annotationsChanged(on: page)
            refreshOverlay()
            return
        }
        guard model.tool.isDrawing, let page = dragPage else { return super.mouseDragged(with: event) }
        var point = convert(convert(event.locationInWindow, from: nil), to: page)
        if event.modifierFlags.contains(.shift) { point = constrained(point) }
        dragCurrent = point
        if model.tool == .pen { inkPoints.append(point) }
        refreshOverlay()
    }

    override func mouseUp(with event: NSEvent) {
        guard let model else { return super.mouseUp(with: event) }
        switch model.tool {
        case .select:
            if let annotation = moving {
                if annotation.bounds != moveOrigin { model.setBounds(annotation, to: annotation.bounds, from: moveOrigin) }
                moving = nil
                dragPage = nil
            } else {
                super.mouseUp(with: event)
            }
        case .highlight, .underline, .strikeout:
            super.mouseUp(with: event)
            addTextMarkup(model)
        case .rectangle, .ellipse, .line, .arrow, .pen:
            if let page = dragPage, let annotation = makeShape(model) {
                model.add(annotation, to: page, actionName: "Add \(model.tool.title)")
            }
            dragPage = nil
            inkPoints = []
            refreshOverlay()
        default:
            super.mouseUp(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let model else { return super.keyDown(with: event) }
        if event.keyCode == 51 || event.keyCode == 117, model.selected != nil {
            model.deleteSelected()
        } else if event.keyCode == 53 {
            model.select(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let tool = model?.tool else { return }
        if tool.isDrawing { addCursorRect(bounds, cursor: .crosshair) }
        if tool == .text { addCursorRect(bounds, cursor: .iBeam) }
        if tool == .note || tool == .eraser { addCursorRect(bounds, cursor: .pointingHand) }
    }

    private func constrained(_ point: CGPoint) -> CGPoint {
        let dx = point.x - dragStart.x, dy = point.y - dragStart.y
        switch model?.tool {
        case .rectangle, .ellipse:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: dragStart.x + (dx < 0 ? -side : side), y: dragStart.y + (dy < 0 ? -side : side))
        case .line, .arrow:
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            return CGPoint(x: dragStart.x + cos(angle) * length, y: dragStart.y + sin(angle) * length)
        default:
            return point
        }
    }

    // MARK: Building annotations

    private func makeShape(_ model: PDFEditorModel) -> PDFAnnotation? {
        let width = CGFloat(model.lineWidth)
        let rect = CGRect(x: min(dragStart.x, dragCurrent.x), y: min(dragStart.y, dragCurrent.y),
                          width: abs(dragCurrent.x - dragStart.x), height: abs(dragCurrent.y - dragStart.y))
        let border = PDFBorder()
        border.lineWidth = width
        let stroke = NSColor(model.strokeColor)

        switch model.tool {
        case .rectangle, .ellipse:
            guard rect.width > 3, rect.height > 3 else { return nil }
            let a = PDFAnnotation(bounds: rect.insetBy(dx: -width / 2, dy: -width / 2),
                                  forType: model.tool == .rectangle ? .square : .circle, withProperties: nil)
            a.color = stroke
            a.interiorColor = model.fillEnabled ? NSColor(model.fillColor) : nil
            a.border = border
            return a
        case .line, .arrow:
            guard hypot(rect.width, rect.height) > 4 else { return nil }
            let padded = rect.insetBy(dx: -(width * 4 + 6), dy: -(width * 4 + 6))
            let a = PDFAnnotation(bounds: padded, forType: .line, withProperties: nil)
            a.startPoint = CGPoint(x: dragStart.x - padded.minX, y: dragStart.y - padded.minY)
            a.endPoint = CGPoint(x: dragCurrent.x - padded.minX, y: dragCurrent.y - padded.minY)
            a.startLineStyle = .none
            a.endLineStyle = model.tool == .arrow ? .closedArrow : .none
            a.color = stroke
            a.interiorColor = stroke
            a.border = border
            return a
        case .pen:
            guard inkPoints.count > 1 else { return nil }
            let xs = inkPoints.map(\.x), ys = inkPoints.map(\.y)
            let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                .insetBy(dx: -width * 2, dy: -width * 2)
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: CGPoint(x: inkPoints[0].x - box.minX, y: inkPoints[0].y - box.minY))
            for p in inkPoints.dropFirst() { path.line(to: CGPoint(x: p.x - box.minX, y: p.y - box.minY)) }
            let a = PDFAnnotation(bounds: box, forType: .ink, withProperties: nil)
            a.add(path)
            a.color = stroke
            a.border = border
            return a
        default:
            return nil
        }
    }

    func addTextMarkup(_ model: PDFEditorModel) {
        guard let selection = currentSelection, !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let subtype: PDFAnnotationSubtype = model.tool == .highlight ? .highlight : (model.tool == .underline ? .underline : .strikeOut)
        let color = model.tool == .highlight ? NSColor(model.highlightColor).withAlphaComponent(0.45) : NSColor(model.strokeColor)
        var added: [(PDFAnnotation, PDFPage)] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let b = line.bounds(for: page)
                guard b.width > 0, b.height > 0 else { continue }
                let a = PDFAnnotation(bounds: b, forType: subtype, withProperties: nil)
                a.color = color
                a.quadrilateralPoints = [
                    NSValue(point: CGPoint(x: 0, y: b.height)), NSValue(point: CGPoint(x: b.width, y: b.height)),
                    NSValue(point: .zero), NSValue(point: CGPoint(x: b.width, y: 0)),
                ]
                added.append((a, page))
            }
        }
        undoManager?.beginUndoGrouping()
        for (a, page) in added { model.add(a, to: page, actionName: model.tool.title) }
        undoManager?.endUndoGrouping()
        clearSelection()
    }

    // MARK: Overlay drawing

    fileprivate func drawOverlay(in view: NSView) {
        guard let model else { return }
        func toOverlay(_ rect: CGRect, _ page: PDFPage) -> CGRect { view.convert(convert(rect, from: page), from: self) }
        func toOverlay(_ point: CGPoint, _ page: PDFPage) -> CGPoint { view.convert(convert(point, from: page), from: self) }

        if let annotation = model.selected, let page = annotation.page, page.document === document {
            let rect = toOverlay(annotation.bounds, page).insetBy(dx: -3, dy: -3)
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1.5
            path.setLineDash([5, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }

        guard let page = dragPage, model.tool.isDrawing else { return }
        let scale = scaleFactor
        let path = NSBezierPath()
        path.lineWidth = CGFloat(model.lineWidth) * scale
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let a = toOverlay(dragStart, page), b = toOverlay(dragCurrent, page)
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        switch model.tool {
        case .rectangle: path.appendRect(rect)
        case .ellipse: path.appendOval(in: rect)
        case .line, .arrow:
            path.move(to: a)
            path.line(to: b)
            if model.tool == .arrow {
                let angle = atan2(b.y - a.y, b.x - a.x), size = max(10, path.lineWidth * 4)
                path.move(to: b)
                path.line(to: CGPoint(x: b.x - size * cos(angle - .pi / 7), y: b.y - size * sin(angle - .pi / 7)))
                path.move(to: b)
                path.line(to: CGPoint(x: b.x - size * cos(angle + .pi / 7), y: b.y - size * sin(angle + .pi / 7)))
            }
        case .pen:
            if let first = inkPoints.first {
                path.move(to: toOverlay(first, page))
                for p in inkPoints.dropFirst() { path.line(to: toOverlay(p, page)) }
            }
        default: break
        }
        if model.fillEnabled, model.tool == .rectangle || model.tool == .ellipse {
            NSColor(model.fillColor).setFill()
            path.fill()
        }
        NSColor(model.strokeColor).setStroke()
        path.stroke()
    }

    private final class OverlayView: NSView {
        weak var host: AnnotatingPDFView?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) { host?.drawOverlay(in: self) }
    }
}

// MARK: - SwiftUI wrapper

struct PDFKitEditor: NSViewRepresentable {
    let model: PDFEditorModel

    final class Coordinator {
        var thumbWidth: NSLayoutConstraint?
        var thumbnails: PDFThumbnailView?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let pdfView = AnnotatingPDFView(frame: .zero)
        pdfView.model = model
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .underPageBackgroundColor
        pdfView.document = model.document
        model.pdfView = pdfView

        let thumbnails = PDFThumbnailView()
        thumbnails.pdfView = pdfView
        thumbnails.thumbnailSize = NSSize(width: 96, height: 128)
        thumbnails.backgroundColor = .windowBackgroundColor

        for view in [thumbnails, pdfView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        let width = thumbnails.widthAnchor.constraint(equalToConstant: model.showThumbnails ? 130 : 0)
        NSLayoutConstraint.activate([
            thumbnails.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            thumbnails.topAnchor.constraint(equalTo: container.topAnchor),
            thumbnails.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            width,
            pdfView.leadingAnchor.constraint(equalTo: thumbnails.trailingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: container.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        context.coordinator.thumbWidth = width
        context.coordinator.thumbnails = thumbnails
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let pdfView = model.pdfView else { return }
        if pdfView.document !== model.document { pdfView.document = model.document }
        context.coordinator.thumbWidth?.constant = model.showThumbnails ? 130 : 0
        context.coordinator.thumbnails?.isHidden = !model.showThumbnails
        _ = model.tool
        pdfView.window?.invalidateCursorRects(for: pdfView)
    }
}

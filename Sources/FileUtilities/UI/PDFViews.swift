import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Editor

struct PDFEditorView: View {
    @Bindable var model: PDFEditorModel
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if model.document != nil {
                toolBar
                Divider()
                HStack(spacing: 0) {
                    PDFKitEditor(model: model)
                    if model.selected != nil {
                        Divider()
                        AnnotationInspector(model: model).frame(width: 250)
                    }
                }
            } else {
                DropZone(hint: "Drop a PDF here to edit it",
                         detail: "Add text, shapes, arrows, freehand drawings, highlights and notes.",
                         targeted: targeted) { model.openPanel() }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.kind == .pdf }) else { return false }
            model.open(url)
            return true
        } isTargeted: { targeted = $0 }
        .sheet(item: $model.textEdit) { request in
            TextEditSheet(request: request) { model.commitText(request, text: $0) }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Image(systemName: Tool.pdfEditor.icon)
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 0) {
                Text(model.document == nil ? "PDF Editor" : model.title).font(.headline).lineLimit(1)
                if let doc = model.document {
                    Text("\(doc.pageCount) page\(doc.pageCount == 1 ? "" : "s")\(model.isDirty ? " · Edited" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { model.openPanel() } label: { Label("Open", systemImage: "folder") }
            if model.document != nil {
                Button { model.save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                    .disabled(!model.isDirty)
                Menu {
                    Button("Save As…") { model.saveAs() }
                    Button("Export Flattened Copy…") { model.exportFlattened() }
                    Divider()
                    Button("Show in Finder") { if let url = model.fileURL { Panels.reveal([url]) } }
                } label: { Label("More", systemImage: "ellipsis.circle") }
                .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var toolBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 2) {
                ForEach(AnnotationTool.allCases) { tool in
                    Button { model.tool = tool } label: {
                        Image(systemName: tool.icon)
                            .frame(width: 30, height: 26)
                            .background(model.tool == tool ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(model.tool == tool ? Color.accentColor : .primary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tool.title)
                    if tool == .note || tool == .pen || tool == .strikeout { Divider().frame(height: 18) }
                }
            }
            Divider().frame(height: 22)
            ColorPicker("Color", selection: $model.strokeColor).help("Stroke / text color")
            Toggle("Fill", isOn: $model.fillEnabled).toggleStyle(.checkbox)
            ColorPicker("Fill", selection: $model.fillColor).labelsHidden().disabled(!model.fillEnabled)
            if model.tool.isTextMarkup {
                ColorPicker("Highlight", selection: $model.highlightColor)
            }
            Menu("\(Int(model.lineWidth)) pt") {
                ForEach([1, 2, 3, 5, 8, 12], id: \.self) { w in Button("\(w) pt") { model.lineWidth = Double(w) } }
            }
            .fixedSize()
            .help("Line width")
            Menu("\(Int(model.fontSize)) pt text") {
                ForEach([10, 12, 14, 18, 24, 32, 48], id: \.self) { s in Button("\(s) pt") { model.fontSize = Double(s) } }
            }
            .fixedSize()
            Spacer()
            HStack(spacing: 4) {
                Button { model.pdfView?.zoomOut(nil) } label: { Image(systemName: "minus.magnifyingglass") }
                Button { model.pdfView?.autoScales = true } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                    .help("Fit")
                Button { model.pdfView?.zoomIn(nil) } label: { Image(systemName: "plus.magnifyingglass") }
                Button { model.showThumbnails.toggle() } label: { Image(systemName: "sidebar.left") }.help("Page thumbnails")
            }
            .buttonStyle(.borderless)
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .fixedSize(horizontal: false, vertical: true)
        .background(.background.secondary)
    }
}

struct AnnotationInspector: View {
    @Bindable var model: PDFEditorModel

    var body: some View {
        let _ = model.revision
        if let a = model.selected {
            let isText = a.type == "FreeText"
            let isNote = a.type == "Text"
            let isMarkup = ["Highlight", "Underline", "StrikeOut"].contains(a.type ?? "")
            Form {
                Section(name(for: a.type)) {
                    if isText || isNote {
                        Text(a.contents ?? "").lineLimit(4).foregroundStyle(.secondary)
                        Button("Edit Text…") { model.editSelectedText() }
                    }
                    ColorPicker(isText ? "Text color" : "Color", selection: Binding(
                        get: { Color(nsColor: (isText ? a.fontColor : a.color) ?? .black) },
                        set: { model.applyStroke($0) }))
                    if isText {
                        Stepper("Size: \(Int(a.font?.pointSize ?? 12)) pt", value: Binding(
                            get: { Double(a.font?.pointSize ?? 12) },
                            set: { model.applyFontSize($0) }), in: 6...96)
                    }
                    if ["Square", "Circle", "FreeText"].contains(a.type ?? "") {
                        let current: NSColor? = isText ? (a.color.alphaComponent > 0 ? a.color : nil) : a.interiorColor
                        Toggle("Fill", isOn: Binding(
                            get: { current != nil },
                            set: { model.applyFill($0 ? Color(nsColor: model.fillEnabled ? NSColor(model.fillColor) : NSColor.yellow.withAlphaComponent(0.35)) : nil) }))
                        if let current {
                            ColorPicker("Fill color", selection: Binding(get: { Color(nsColor: current) }, set: { model.applyFill($0) }))
                        }
                    }
                    if !isText && !isNote && !isMarkup {
                        Stepper("Width: \(Int(a.border?.lineWidth ?? 1)) pt", value: Binding(
                            get: { Double(a.border?.lineWidth ?? 1) },
                            set: { model.applyLineWidth($0) }), in: 1...24)
                    }
                }
                Section {
                    Button("Delete", role: .destructive) { model.deleteSelected() }
                    Caption("Drag with the Select tool to move. Press Delete to remove, ⌘Z to undo.")
                }
            }
            .formStyle(.grouped)
        }
    }

    private func name(for type: String?) -> String {
        switch type {
        case "FreeText": "Text"
        case "Square": "Rectangle"
        case "Circle": "Ellipse"
        case "Ink": "Drawing"
        case "Text": "Note"
        case .some(let t): t
        case .none: "Annotation"
        }
    }
}

struct TextEditSheet: View {
    let request: TextEditRequest
    let commit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.isNote ? "Sticky note" : (request.annotation == nil ? "Add text" : "Edit text")).font(.headline)
            TextEditor(text: $text)
                .font(.body)
                .frame(width: 420, height: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.annotation == nil ? "Add" : "Save") {
                    commit(text)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
            Caption("⌘↩ to confirm")
        }
        .padding(20)
        .onAppear { text = request.text }
    }
}

// MARK: - Pages (merge, split, reorder)

struct PDFPagesView: View {
    @Bindable var model: PDFPagesModel
    @State private var targeted = false
    @State private var splitEvery = 1

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(title: "Merge & Split", subtitle: "Combine PDFs and images, reorder, rotate, delete, extract or split pages.",
                       icon: Tool.pdfPages.icon)
            Divider()
            toolbar
            Divider()
            if model.pages.isEmpty {
                DropZone(hint: "Drop PDFs or images here", detail: "Pages from every file are added in order.", targeted: targeted) {
                    model.add(Panels.openFiles(types: [.pdf, .image]))
                }
            } else {
                grid
            }
            Divider()
            HStack {
                Text(model.status).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.selection.count) selected · ⌘-click or ⇧-click to select several · drag to reorder")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        } isTargeted: { targeted = $0 }
    }

    private var toolbar: some View {
        let none = model.selection.isEmpty
        return HStack(spacing: 12) {
            Button { model.add(Panels.openFiles(types: [.pdf, .image])) } label: { Label("Add Files", systemImage: "plus") }
            Divider().frame(height: 18)
            Group {
                Button { model.rotateSelected(by: -90) } label: { Image(systemName: "rotate.left") }.help("Rotate left")
                Button { model.rotateSelected(by: 90) } label: { Image(systemName: "rotate.right") }.help("Rotate right")
                Button { model.moveSelected(by: -1) } label: { Image(systemName: "arrow.left") }.help("Move earlier")
                Button { model.moveSelected(by: 1) } label: { Image(systemName: "arrow.right") }.help("Move later")
                Button { model.duplicateSelected() } label: { Image(systemName: "plus.square.on.square") }.help("Duplicate")
                Button(role: .destructive) { model.deleteSelected() } label: { Image(systemName: "trash") }.help("Delete pages")
            }
            .disabled(none)
            Button { model.insertBlankPage() } label: { Image(systemName: "doc.badge.plus") }.help("Insert blank page")
            Menu {
                Button("Select All") { model.selectAll() }
                Button("Reverse Order") { model.reverse() }
                Divider()
                Button("Remove All", role: .destructive) { model.clear() }
            } label: { Image(systemName: "ellipsis.circle") }
            .fixedSize()
            Spacer()
            Button("Extract Selected…") { model.extractSelected() }.disabled(none)
            Menu("Split…") {
                Button("Every page into its own PDF") { model.split(every: 1) }
                ForEach([2, 3, 5, 10], id: \.self) { n in
                    Button("Every \(n) pages") { model.split(every: n) }
                }
            }
            .fixedSize()
            .disabled(model.pages.isEmpty)
            Button { model.saveAll() } label: { Text("Save as PDF…") }
                .buttonStyle(.borderedProminent)
                .disabled(model.pages.isEmpty)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 18)], spacing: 18) {
                ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, item in
                    let selected = model.selection.contains(item.id)
                    VStack(spacing: 6) {
                        Image(nsImage: item.thumbnail)
                            .resizable().scaledToFit()
                            .frame(height: 190)
                            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
                        Text("\(index + 1)").font(.callout.weight(.semibold))
                        Text(item.source).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.click(item.id) }
                    .draggable(item.id.uuidString) {
                        Image(nsImage: item.thumbnail).resizable().scaledToFit().frame(height: 120)
                    }
                    .dropDestination(for: String.self) { ids, _ in
                        let dragged = ids.compactMap(UUID.init(uuidString:))
                        let moving = dragged.count == 1 && model.selection.contains(dragged[0]) ? Array(model.selection) : dragged
                        model.move(ids: moving, before: item.id)
                        return true
                    }
                }
            }
            .padding(20)
        }
        .onDeleteCommand { model.deleteSelected() }
    }
}

// MARK: - Convert & OCR

struct PDFConvertView: View {
    @Bindable var app: AppState
    @State private var mode = 0
    @State private var pageSize = PDFTools.PageSize.a4
    @State private var margin = 0.0
    @State private var compressImages = true
    @State private var jpegQuality = 0.8
    @State private var imageFormatID = "public.png"
    @State private var dpi = 150.0
    @State private var exportText = false
    @State private var status = ""

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                Text("Images → PDF").tag(0)
                Text("PDF → Images").tag(1)
                Text("OCR (make searchable)").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 440)
            .padding(.vertical, 8)
            Divider()
            switch mode {
            case 0: imagesToPDF
            case 1: pdfToImages
            default: ocr
            }
        }
    }

    private var imagesToPDF: some View {
        ToolLayout(title: "Images → PDF", subtitle: "Combine photos or scans into a single PDF, one image per page.", icon: "photo.on.rectangle") {
            OrderedFileList(model: app.imagesToPDF, hint: "Drop images here", detail: "Drag rows to set the page order.")
        } side: {
            Form {
                Section("Pages") {
                    Picker("Page size", selection: $pageSize) {
                        ForEach(PDFTools.PageSize.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Margin", selection: $margin) {
                        Text("None").tag(0.0)
                        Text("Small").tag(18.0)
                        Text("Normal").tag(36.0)
                    }
                    Caption("Landscape images get landscape pages automatically.")
                }
                Section("Size") {
                    Toggle("Compress images", isOn: $compressImages)
                    if compressImages {
                        QualitySlider(title: "JPEG quality", value: $jpegQuality, range: 0.4...0.95)
                    }
                }
                if !status.isEmpty { Section { Text(status).font(.callout) } }
            }
            .formStyle(.grouped)
            RunBar(model: app.imagesToPDF, label: "Create PDF…") {
                let name = (app.imagesToPDF.items.first?.url.deletingLastPathComponent().lastPathComponent ?? "Images") + ".pdf"
                guard let dst = Panels.save(name: name, type: .pdf, directory: app.imagesToPDF.items.first?.url.deletingLastPathComponent()) else { return }
                let size = pageSize, margin = CGFloat(margin), quality: Double? = compressImages ? jpegQuality : nil
                status = "Creating PDF…"
                app.imagesToPDF.runSingle({ urls, progress in
                    try await cleaningUp(dst) {
                        try PDFTools.imagesToPDF(urls, to: dst, pageSize: size, margin: margin, jpegQuality: quality, progress: progress)
                    }
                    return dst
                }, completion: { result in
                    switch result {
                    case .success(let url):
                        status = "Saved \(url.lastPathComponent) (\(formatBytes(url.fileSize)))"
                        Panels.reveal([url])
                    case .failure(let error):
                        status = "Failed: \(error.localizedDescription)"
                    }
                })
            }
        }
    }

    private var pdfToImages: some View {
        let formats = ImageFormats.native.filter { ["public.png", "public.jpeg", "public.heic", "public.tiff"].contains($0.id) }
        return ToolLayout(title: "PDF → Images", subtitle: "Save every page of a PDF as an image.", icon: "photo.stack") {
            BatchListView(model: app.pdfToImages, hint: "Drop PDFs here", detail: "Each PDF gets its own folder of page images.")
        } side: {
            Form {
                Section("Images") {
                    Picker("Format", selection: $imageFormatID) {
                        ForEach(formats) { Text($0.name).tag($0.id) }
                    }
                    Picker("Resolution", selection: $dpi) {
                        Text("72 dpi (screen)").tag(72.0)
                        Text("150 dpi (standard)").tag(150.0)
                        Text("300 dpi (print)").tag(300.0)
                        Text("600 dpi (high)").tag(600.0)
                    }
                }
                OutputSection(model: app.pdfToImages)
            }
            .formStyle(.grouped)
            RunBar(model: app.pdfToImages, label: "Export Pages") {
                guard let format = formats.first(where: { $0.id == imageFormatID }) else { return }
                let folder = app.pdfToImages.outputFolder, dpi = CGFloat(dpi)
                app.pdfToImages.run { url, progress in
                    let dir = try PDFTools.pdfToImages(url, folder: folder, format: format, dpi: dpi, progress: progress)
                    return JobResult(output: dir)
                }
            }
        }
    }

    private var ocr: some View {
        ToolLayout(title: "OCR", subtitle: "Recognize text in scanned PDFs so you can search, select and copy it.",
                   icon: "text.viewfinder") {
            BatchListView(model: app.ocr, hint: "Drop scanned PDFs here", detail: "Uses Apple's on-device text recognition. Nothing is uploaded.")
        } side: {
            Form {
                Section("Options") {
                    Toggle("Also save text as .txt", isOn: $exportText)
                    Caption("The page looks exactly the same; an invisible text layer is added on top. Languages are detected automatically.")
                }
                OutputSection(model: app.ocr)
            }
            .formStyle(.grouped)
            RunBar(model: app.ocr, label: "Make Searchable") {
                let folder = app.ocr.outputFolder, text = exportText
                app.ocr.concurrency = 1
                app.ocr.run { url, progress in
                    JobResult(output: try PDFTools.ocr(url, folder: folder, exportText: text, progress: progress))
                }
            }
        }
    }
}

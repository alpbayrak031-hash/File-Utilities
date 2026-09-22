import AppKit
import Observation
import SwiftUI

@main
struct FileUtilitiesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup("File Utilities") {
            ContentView(app: app)
                .frame(minWidth: 1080, minHeight: 680)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("Open PDF…") {
                    app.selection = .pdfEditor
                    app.pdfEditor.openPanel()
                }
                .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save PDF") { app.pdfEditor.save() }
                    .keyboardShortcut("s")
                    .disabled(app.selection != .pdfEditor || app.pdfEditor.document == nil)
                Button("Save PDF As…") { app.pdfEditor.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(app.selection != .pdfEditor || app.pdfEditor.document == nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum Tool: String, CaseIterable, Identifiable, Hashable {
    case compress, convert, transform, trim, merge, audio, metadata
    case pdfEditor, pdfPages, pdfConvert
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .compress: "Compress"
        case .convert: "Convert"
        case .transform: "Resize & Rotate"
        case .trim: "Trim & Clip"
        case .merge: "Merge Videos"
        case .audio: "Audio Converter"
        case .metadata: "Metadata & Rename"
        case .pdfEditor: "PDF Editor"
        case .pdfPages: "Merge & Split"
        case .pdfConvert: "PDF Convert & OCR"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .convert: "arrow.triangle.2.circlepath"
        case .transform: "crop.rotate"
        case .trim: "timeline.selection"
        case .merge: "film.stack"
        case .audio: "waveform"
        case .metadata: "tag"
        case .pdfEditor: "pencil.and.outline"
        case .pdfPages: "doc.on.doc"
        case .pdfConvert: "doc.text.viewfinder"
        case .settings: "gearshape"
        }
    }

    static let media: [Tool] = [.compress, .convert, .transform, .trim, .merge, .audio, .metadata]
    static let pdf: [Tool] = [.pdfEditor, .pdfPages, .pdfConvert]
}

/// Holds every tool's state so switching tabs never loses work.
@Observable @MainActor
final class AppState {
    var selection: Tool? = .compress
    var ffmpegAvailable = FFmpeg.shared.isAvailable

    let compress = BatchModel(accepted: [.image, .video])
    var compressOptions = CompressOptions()

    let convert = BatchModel(accepted: [.image, .video])
    var convertOptions = ConvertOptions()

    let transform = BatchModel(accepted: [.image, .video])
    var transformOptions = TransformOptions()

    let trim = TrimModel()

    let merge = BatchModel(accepted: [.video])
    var mergeCodec = VideoCodec.hevc
    var mergeContainer = VideoContainer.mp4

    let audio = BatchModel(accepted: [.audio, .video])
    var audioOptions = AudioOptions()

    let strip = BatchModel(accepted: [.image, .video])
    var stripOptions = StripOptions()
    let rename = RenameModel()

    let pdfEditor = PDFEditorModel()
    let pdfPages = PDFPagesModel()
    let imagesToPDF = BatchModel(accepted: [.image])
    let pdfToImages = BatchModel(accepted: [.pdf])
    let ocr = BatchModel(accepted: [.pdf])

    init() {
        if !ffmpegAvailable { audioOptions.format = .aac }
    }

    func refreshFFmpeg() {
        FFmpeg.shared.refresh()
        ffmpegAvailable = FFmpeg.shared.isAvailable
    }
}

struct ContentView: View {
    @Bindable var app: AppState

    var body: some View {
        NavigationSplitView {
            List(selection: $app.selection) {
                Section("Photos & Video") {
                    ForEach(Tool.media) { row($0) }
                }
                Section("PDF") {
                    ForEach(Tool.pdf) { row($0) }
                }
                Section {
                    row(.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            detail
                .navigationTitle(app.selection?.title ?? "File Utilities")
        }
        .onChange(of: app.selection, initial: true) {
            // Don't let the first text field grab focus (it scrolls the options panel).
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
    }

    private func row(_ tool: Tool) -> some View {
        NavigationLink(value: tool) {
            Label(tool.title, systemImage: tool.icon)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch app.selection ?? .compress {
        case .compress: CompressView(app: app)
        case .convert: ConvertView(app: app)
        case .transform: TransformView(app: app)
        case .trim: TrimView(app: app, model: app.trim)
        case .merge: MergeView(app: app)
        case .audio: AudioView(app: app)
        case .metadata: MetadataView(app: app)
        case .pdfEditor: PDFEditorView(model: app.pdfEditor)
        case .pdfPages: PDFPagesView(model: app.pdfPages)
        case .pdfConvert: PDFConvertView(app: app)
        case .settings: SettingsView(app: app)
        }
    }
}

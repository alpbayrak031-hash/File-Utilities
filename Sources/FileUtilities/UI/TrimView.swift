import AVFoundation
import AVKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable @MainActor
final class TrimModel {
    enum ClipMode: String, CaseIterable, Identifiable {
        case fast = "Fast (no quality loss)"
        case hevc = "Re-encode HEVC"
        case h264 = "Re-encode H.264"
        var id: Self { self }
    }

    var url: URL?
    var player: AVPlayer?
    var duration = 0.0
    var start = 0.0
    var end = 0.0
    var hasAudio = false
    var clipMode = ClipMode.fast
    var audioFormat = AudioFormat.aac
    var gifFPS = 12.0
    var gifWidth = 480.0
    var isWorking = false
    var progress = 0.0
    var status = ""
    var lastOutput: URL?
    private var task: Task<Void, Never>?

    var range: CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                    end: CMTime(seconds: max(end, start + 0.05), preferredTimescale: 600))
    }

    func load(_ url: URL) {
        Task {
            guard await VideoProcessor.canReadNatively(url) else {
                status = "\(url.lastPathComponent) can't be opened here. Convert it to MP4 first (Convert tab)."
                return
            }
            let asset = AVURLAsset(url: url)
            duration = (try? await asset.load(.duration).seconds) ?? 0
            hasAudio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
            self.url = url
            start = 0
            end = duration
            player = AVPlayer(url: url)
            status = ""
            lastOutput = nil
        }
    }

    var playhead: Double { player?.currentTime().seconds ?? 0 }

    func seek(_ seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setStartToPlayhead() { start = min(playhead, end - 0.1) }
    func setEndToPlayhead() { end = max(playhead, start + 0.1) }

    func cancel() { task?.cancel() }

    private func run(_ label: String, output: URL, _ work: @escaping @Sendable (@escaping ProgressHandler) async throws -> Void) {
        isWorking = true
        progress = 0
        status = label
        try? FileManager.default.removeItem(at: output)
        task = Task {
            do {
                try await cleaningUp(output) {
                    try await work { value in Task { @MainActor in self.progress = value } }
                }
                lastOutput = output
                status = "Saved \(output.lastPathComponent) (\(formatBytes(output.fileSize)))"
            } catch is CancellationError {
                status = "Cancelled"
            } catch {
                status = "Failed: \(error.localizedDescription)"
            }
            isWorking = false
        }
    }

    private func savePanel(_ suffix: String, ext: String) -> URL? {
        guard let url else { return nil }
        return Panels.save(name: "\(url.baseName) \(suffix).\(ext)", directory: url.deletingLastPathComponent())
    }

    func exportClip() {
        guard let src = url else { return }
        let ext = ["mov", "mp4", "m4v"].contains(src.ext) ? src.ext : "mp4"
        guard let dst = savePanel("clip", ext: ext) else { return }
        let range = range, mode = clipMode
        let fileType = VideoContainer.fileType(forExtension: dst.ext) ?? .mp4
        run("Exporting clip…", output: dst) { progress in
            let asset = AVURLAsset(url: src)
            if mode == .fast, await VideoProcessor.canPassthrough(asset, to: fileType) {
                try await VideoProcessor.export(asset: asset, preset: AVAssetExportPresetPassthrough, to: dst,
                                                fileType: fileType, timeRange: range, progress: progress)
            } else {
                var settings = VideoEncodeSettings()
                settings.codec = mode == .h264 ? .h264 : .hevc
                settings.fileType = fileType
                settings.timeRange = range
                try await VideoProcessor.transcode(src, to: dst, settings: settings, progress: progress)
            }
        }
    }

    func extractAudio() {
        guard let src = url, let dst = savePanel("audio", ext: audioFormat.ext) else { return }
        let settings = AudioSettings(format: audioFormat, bitrateKbps: 192, timeRange: range)
        run("Extracting audio…", output: dst) { progress in
            try await AudioProcessor.convert(src, to: dst, settings: settings, progress: progress)
        }
    }

    func makeGIF() {
        guard let src = url, let dst = savePanel("animation", ext: "gif") else { return }
        let range = range, fps = gifFPS, width = Int(gifWidth)
        run("Creating GIF…", output: dst) { progress in
            try await VideoProcessor.makeGIF(src, to: dst, range: range, fps: fps, maxWidth: width, progress: progress)
        }
    }

    func saveFrame() {
        guard let src = url else { return }
        let time = CMTime(seconds: playhead, preferredTimescale: 600)
        guard let dst = savePanel(String(format: "frame %.2fs", time.seconds), ext: "png") else { return }
        run("Saving frame…", output: dst) { progress in
            let image = try await VideoProcessor.frame(src, at: time)
            let type = UTType(filenameExtension: dst.ext) ?? .png
            try ImageProcessor.writeCGImage(image, to: dst, type: ImageFormats.canWrite(type) ? type : .png, quality: 0.95)
            progress(1)
        }
    }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFrameSteppingButtons = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

struct TrimView: View {
    @Bindable var app: AppState
    @Bindable var model: TrimModel
    @State private var targeted = false

    var body: some View {
        ToolLayout(title: "Trim & Clip", subtitle: "Cut a part of a video, extract its audio, make a GIF or grab a frame.",
                   icon: Tool.trim.icon) {
            VStack(spacing: 0) {
                if model.url != nil {
                    PlayerView(player: model.player)
                    Divider()
                    rangeControls.padding(16)
                } else {
                    DropZone(hint: "Drop a video here", detail: model.status.isEmpty ? "MP4, MOV, M4V and other formats macOS can play." : model.status,
                             targeted: targeted) {
                        if let url = Panels.openFiles(folders: false, multiple: false).first { model.load(url) }
                    }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, !model.isWorking else { return false }
                model.load(url)
                return true
            } isTargeted: { targeted = $0 }
        } side: {
            Form {
                Section("Clip") {
                    Picker("Mode", selection: $model.clipMode) {
                        ForEach(TrimModel.ClipMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Button("Export Clip…") { model.exportClip() }
                }
                Section("Audio") {
                    Picker("Format", selection: $model.audioFormat) {
                        ForEach(AudioFormat.allCases.filter { $0.isNative || app.ffmpegAvailable }) { Text($0.title).tag($0) }
                    }
                    Button("Extract Audio…") { model.extractAudio() }.disabled(!model.hasAudio)
                }
                Section("GIF") {
                    LabeledContent("Frame rate") {
                        Stepper("\(Int(model.gifFPS)) fps", value: $model.gifFPS, in: 5...30, step: 1)
                    }
                    LabeledContent("Width") {
                        Stepper("\(Int(model.gifWidth)) px", value: $model.gifWidth, in: 160...1280, step: 40)
                    }
                    Button("Create GIF…") { model.makeGIF() }
                    Caption("Keep GIFs short — they get large quickly.")
                }
                Section("Frame") {
                    Button("Save Current Frame…") { model.saveFrame() }
                    Caption("Saves the frame at the playhead as PNG (type .jpg or .heic in the name to change it).")
                }
            }
            .formStyle(.grouped)
            .disabled(model.url == nil || model.isWorking)
            statusBar
        }
    }

    private var rangeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Selection").font(.headline)
                Spacer()
                Text("\(formatDuration(model.start)) – \(formatDuration(model.end))  ·  \(formatDuration(model.end - model.start)) long")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            timeRow("Start", value: $model.start, range: 0...max(0.1, model.duration), set: model.setStartToPlayhead)
            timeRow("End", value: $model.end, range: 0...max(0.1, model.duration), set: model.setEndToPlayhead)
            HStack {
                Button("Play Selection") {
                    model.seek(model.start)
                    model.player?.play()
                }
                Button("Reset") { model.start = 0; model.end = model.duration }
                Spacer()
                Button("Open Another Video…") {
                    if let url = Panels.openFiles(folders: false, multiple: false).first { model.load(url) }
                }
            }
            .disabled(model.isWorking)
        }
    }

    private func timeRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, set: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(label).frame(width: 40, alignment: .leading)
            Slider(value: value, in: range) { editing in
                if !editing { model.seek(value.wrappedValue) }
            }
            Text(formatDuration(value.wrappedValue)).monospacedDigit().frame(width: 70, alignment: .trailing)
            Button("Use Playhead", action: set).controlSize(.small)
        }
        .onChange(of: value.wrappedValue) {
            if model.start > model.end - 0.05 {
                if label == "Start" { model.start = max(0, model.end - 0.05) } else { model.end = min(model.duration, model.start + 0.05) }
            }
        }
    }

    private var statusBar: some View {
        VStack(spacing: 8) {
            Divider()
            if model.isWorking {
                ProgressView(value: model.progress).padding(.horizontal, 16)
            }
            HStack {
                Text(model.status).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if model.isWorking {
                    Button("Cancel") { model.cancel() }
                } else if let output = model.lastOutput {
                    Button("Show in Finder") { Panels.reveal([output]) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }
}

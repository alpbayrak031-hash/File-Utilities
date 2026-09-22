import AVFoundation
import CoreImage
import SwiftUI

// MARK: - Compress

struct CompressView: View {
    @Bindable var app: AppState

    var body: some View {
        ToolLayout(title: "Compress", subtitle: "Make photos and videos smaller — same resolution, same frame rate.",
                   icon: Tool.compress.icon) {
            BatchListView(model: app.compress, hint: "Drop photos and videos here",
                          detail: "JPEG, HEIC, PNG, TIFF, MP4, MOV and more. Folders work too.")
        } side: {
            Form {
                Section("Photos") {
                    Picker("Save as", selection: $app.compressOptions.imageTarget) {
                        ForEach(CompressOptions.ImageTarget.allCases) { Text($0.rawValue).tag($0) }
                    }
                    QualitySlider(title: "Quality", value: $app.compressOptions.imageQuality, range: 0.4...0.95)
                    Caption("70–80% looks identical to the original for most photos. PNG is lossless, so pick HEIC or JPEG for big savings.")
                }
                Section("Videos") {
                    Picker("Codec", selection: $app.compressOptions.videoCodec) {
                        ForEach(VideoCodec.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Quality", selection: $app.compressOptions.videoLevel) {
                        ForEach(CompressOptions.Level.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Caption("HEVC files are typically 40–50% smaller than H.264 at the same quality and play everywhere on Apple devices.")
                }
                Section("Options") {
                    Toggle("Remove metadata (EXIF, location)", isOn: $app.compressOptions.stripMetadata)
                    Toggle("Keep original if the result isn't smaller", isOn: $app.compressOptions.onlyIfSmaller)
                }
                OutputSection(model: app.compress, suffix: $app.compressOptions.suffix)
            }
            .formStyle(.grouped)
            RunBar(model: app.compress, label: "Compress") {
                let options = app.compressOptions, folder = app.compress.outputFolder
                app.compress.run { url, progress in try await Jobs.compress(url, options, folder: folder, progress: progress) }
            }
        }
    }
}

// MARK: - Convert

struct ConvertView: View {
    @Bindable var app: AppState

    var body: some View {
        let imageFormats = ImageFormats.all()
        let selectedImage = imageFormats.first { $0.id == app.convertOptions.imageFormatID }
        ToolLayout(title: "Convert", subtitle: "Change photo and video formats. Photos and videos can be mixed.",
                   icon: Tool.convert.icon) {
            BatchListView(model: app.convert, hint: "Drop photos and videos here",
                          detail: "Each file is converted to the format chosen for its type.")
        } side: {
            Form {
                Section("Photos to") {
                    Picker("Format", selection: $app.convertOptions.imageFormatID) {
                        ForEach(imageFormats) { Text($0.name).tag($0.id) }
                    }
                    if selectedImage?.lossy == true {
                        QualitySlider(title: "Quality", value: $app.convertOptions.imageQuality, range: 0.4...1.0)
                    }
                }
                Section("Videos to") {
                    Picker("Format", selection: $app.convertOptions.videoContainer) {
                        ForEach(VideoContainer.allCases) { container in
                            Text(container.title + (container.isNative || app.ffmpegAvailable ? "" : " — needs ffmpeg"))
                                .tag(container)
                        }
                    }
                    if app.convertOptions.videoContainer.fileType != nil {
                        Picker("Encoding", selection: $app.convertOptions.videoMode) {
                            ForEach(VideoConvertMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Caption("Auto copies the video and audio streams without quality loss when the new format allows it.")
                    }
                    if !app.ffmpegAvailable {
                        FFmpegNotice(text: "MKV, WebM, AVI, WMV and other formats (as input or output) need ffmpeg — see Settings.")
                    }
                }
                OutputSection(model: app.convert, suffix: $app.convertOptions.suffix)
            }
            .formStyle(.grouped)
            RunBar(model: app.convert, label: "Convert") {
                let options = app.convertOptions, folder = app.convert.outputFolder
                app.convert.run { url, progress in try await Jobs.convert(url, options, folder: folder, progress: progress) }
            }
        }
        .onAppear {
            if !imageFormats.contains(where: { $0.id == app.convertOptions.imageFormatID }) {
                app.convertOptions.imageFormatID = imageFormats.first?.id ?? "public.jpeg"
            }
        }
    }
}

// MARK: - Resize & rotate

struct TransformView: View {
    @Bindable var app: AppState

    var body: some View {
        ToolLayout(title: "Resize & Rotate", subtitle: "Resize, crop, rotate and flip photos and videos in batches.",
                   icon: Tool.transform.icon) {
            VStack(spacing: 0) {
                BatchListView(model: app.transform, hint: "Drop photos and videos here",
                              detail: "The same changes are applied to every file.")
                if let first = app.transform.items.first?.url {
                    Divider()
                    TransformPreview(url: first, transform: app.transformOptions.transform)
                        .frame(height: 230)
                }
            }
        } side: {
            Form {
                Section("Resize") {
                    Picker("Mode", selection: $app.transformOptions.resizeMode) {
                        ForEach(TransformOptions.ResizeMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    switch app.transformOptions.resizeMode {
                    case .none: EmptyView()
                    case .percent:
                        LabeledContent("Scale") {
                            HStack {
                                Slider(value: $app.transformOptions.percent, in: 5...200, step: 5)
                                Text("\(Int(app.transformOptions.percent))%").monospacedDigit().frame(width: 44)
                            }
                        }
                    case .fit:
                        TextField("Max width (px)", value: $app.transformOptions.width, format: .number)
                        TextField("Max height (px)", value: $app.transformOptions.height, format: .number)
                        Caption("Keeps the aspect ratio and never enlarges.")
                    case .width:
                        TextField("Width (px)", value: $app.transformOptions.width, format: .number)
                    case .height:
                        TextField("Height (px)", value: $app.transformOptions.height, format: .number)
                    }
                }
                Section("Crop") {
                    Picker("Aspect", selection: $app.transformOptions.cropMode) {
                        ForEach(TransformOptions.CropMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if app.transformOptions.cropMode == .custom {
                        insetSlider("Top", $app.transformOptions.insetTop)
                        insetSlider("Bottom", $app.transformOptions.insetBottom)
                        insetSlider("Left", $app.transformOptions.insetLeft)
                        insetSlider("Right", $app.transformOptions.insetRight)
                    } else if app.transformOptions.cropMode != .none {
                        Caption("Crops from the center.")
                    }
                }
                Section("Rotate & Flip") {
                    Picker("Rotate", selection: $app.transformOptions.rotation) {
                        Text("0°").tag(0)
                        Text("90° ↻").tag(90)
                        Text("180°").tag(180)
                        Text("90° ↺").tag(270)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Flip horizontally", isOn: $app.transformOptions.flipH)
                    Toggle("Flip vertically", isOn: $app.transformOptions.flipV)
                }
                Section("Videos") {
                    Picker("Codec", selection: $app.transformOptions.videoCodec) {
                        ForEach(VideoCodec.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                OutputSection(model: app.transform, suffix: $app.transformOptions.suffix)
            }
            .formStyle(.grouped)
            RunBar(model: app.transform, label: "Apply", disabled: app.transformOptions.transform.isIdentity) {
                let options = app.transformOptions, folder = app.transform.outputFolder
                app.transform.run { url, progress in try await Jobs.transform(url, options, folder: folder, progress: progress) }
            }
        }
    }

    private func insetSlider(_ title: String, _ value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: 0...0.45)
                Text("\(Int(value.wrappedValue * 100))%").monospacedDigit().frame(width: 40)
            }
        }
    }
}

struct TransformPreview: View {
    let url: URL
    let transform: MediaTransform

    private struct Key: Equatable {
        let url: URL
        let transform: MediaTransform
    }

    @State private var before: NSImage?
    @State private var after: NSImage?
    @State private var sizes = ""

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 20) {
                pane(before, "Before")
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                pane(after, "After")
            }
            Text(sizes).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .task(id: Key(url: url, transform: transform)) { await render() }
    }

    private func pane(_ image: NSImage?, _ label: String) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().padding(6)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 260)
    }

    private func render() async {
        var source: CGImage?
        var fullSize = CGSize.zero
        switch url.kind {
        case .image:
            source = ImageProcessor.thumbnail(url, maxPixel: 700)
            let props = ImageProcessor.properties(of: url)
            let w = props[kCGImagePropertyPixelWidth] as? Double ?? 0, h = props[kCGImagePropertyPixelHeight] as? Double ?? 0
            let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
            fullSize = orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        case .video:
            source = try? await VideoProcessor.frame(url, at: CMTime(seconds: 1, preferredTimescale: 600))
            if let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
               let (natural, preferred) = try? await track.load(.naturalSize, .preferredTransform) {
                let r = CGRect(origin: .zero, size: natural).applying(preferred)
                fullSize = CGSize(width: abs(r.width), height: abs(r.height))
            }
        default: break
        }
        guard let source else {
            before = nil; after = nil; sizes = "No preview available"
            return
        }
        before = NSImage(cgImage: source, size: .zero)
        var previewTransform = transform
        previewTransform.resize = .none
        let output = previewTransform.apply(CIImage(cgImage: source), even: false)
        if let cg = ImageProcessor.context.createCGImage(output, from: output.extent) {
            after = NSImage(cgImage: cg, size: .zero)
        }
        if fullSize != .zero {
            let out = transform.outputSize(for: fullSize, even: url.kind == .video)
            sizes = "\(Int(fullSize.width))×\(Int(fullSize.height)) → \(Int(out.width))×\(Int(out.height)) px  ·  \(url.lastPathComponent)"
        }
    }
}

// MARK: - Merge

struct MergeView: View {
    @Bindable var app: AppState
    @State private var status = ""

    var body: some View {
        ToolLayout(title: "Merge Videos", subtitle: "Join clips into one video, in the order shown.", icon: Tool.merge.icon) {
            OrderedFileList(model: app.merge, hint: "Drop video clips here", detail: "Drag rows to change the order.")
        } side: {
            Form {
                Section("Output") {
                    Picker("Format", selection: $app.mergeContainer) {
                        ForEach([VideoContainer.mp4, .mov, .m4v]) { Text($0.title).tag($0) }
                    }
                    Picker("Codec", selection: $app.mergeCodec) {
                        ForEach(VideoCodec.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Caption("The output uses the first clip's size and orientation; other clips are scaled to fit with black bars if needed.")
                }
                if !status.isEmpty {
                    Section { Text(status).font(.callout) }
                }
            }
            .formStyle(.grouped)
            RunBar(model: app.merge, label: "Merge…", disabled: app.merge.items.count < 2) { merge() }
        }
    }

    private func merge() {
        let container = app.mergeContainer, codec = app.mergeCodec
        let firstName = app.merge.items.first?.url.baseName ?? "Merged"
        guard let dst = Panels.save(name: "\(firstName) merged.\(container.ext)", directory: app.merge.items.first?.url.deletingLastPathComponent()) else { return }
        try? FileManager.default.removeItem(at: dst)
        status = "Merging…"
        app.merge.runSingle({ urls, progress in
            try await cleaningUp(dst) {
                try await VideoProcessor.merge(urls, to: dst, fileType: container.fileType ?? .mp4, codec: codec, progress: progress)
            }
            return dst
        }, completion: { result in
            switch result {
            case .success(let url):
                status = "Saved \(url.lastPathComponent) (\(formatBytes(url.fileSize)))"
                Panels.reveal([url])
            case .failure(let error):
                status = error is CancellationError ? "Cancelled" : "Failed: \(error.localizedDescription)"
            }
        })
    }
}

// MARK: - Audio

struct AudioView: View {
    @Bindable var app: AppState

    var body: some View {
        let format = app.audioOptions.format
        ToolLayout(title: "Audio Converter", subtitle: "Convert audio files or pull the soundtrack out of videos.",
                   icon: Tool.audio.icon) {
            BatchListView(model: app.audio, hint: "Drop audio or video files here",
                          detail: "MP3, M4A, WAV, FLAC, AIFF… and videos to extract their audio.")
        } side: {
            Form {
                Section("Format") {
                    Picker("Save as", selection: $app.audioOptions.format) {
                        ForEach(AudioFormat.allCases) { f in
                            Text(f.title + (f.isNative || app.ffmpegAvailable ? "" : " — needs ffmpeg")).tag(f)
                        }
                    }
                    if format.isLossy {
                        Picker("Bitrate", selection: $app.audioOptions.bitrateKbps) {
                            ForEach([96, 128, 160, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
                        }
                    } else {
                        Caption("Lossless — no quality is lost, files are larger.")
                    }
                }
                Section("Advanced") {
                    Picker("Sample rate", selection: $app.audioOptions.sampleRate) {
                        Text("Keep original").tag(Double?.none)
                        Text("44.1 kHz").tag(Double?.some(44100))
                        Text("48 kHz").tag(Double?.some(48000))
                    }
                    Picker("Channels", selection: $app.audioOptions.channels) {
                        Text("Keep original").tag(Int?.none)
                        Text("Stereo").tag(Int?.some(2))
                        Text("Mono").tag(Int?.some(1))
                    }
                }
                if !format.isNative && !app.ffmpegAvailable {
                    Section { FFmpegNotice(text: "\(format.title) needs ffmpeg — see Settings. AAC, Apple Lossless, FLAC, WAV and AIFF work without it.") }
                }
                OutputSection(model: app.audio, suffix: $app.audioOptions.suffix)
            }
            .formStyle(.grouped)
            RunBar(model: app.audio, label: "Convert", disabled: !format.isNative && !app.ffmpegAvailable) {
                let options = app.audioOptions, folder = app.audio.outputFolder
                app.audio.run { url, progress in try await Jobs.audio(url, options, folder: folder, progress: progress) }
            }
        }
    }
}

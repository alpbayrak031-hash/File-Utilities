import AVFoundation
import UniformTypeIdentifiers

// MARK: - Options

struct CompressOptions {
    enum ImageTarget: String, CaseIterable, Identifiable {
        case keep = "Same format"
        case heic = "HEIC (smallest)"
        case jpeg = "JPEG (most compatible)"
        var id: Self { self }
    }

    enum Level: String, CaseIterable, Identifiable {
        case high = "High quality"
        case balanced = "Balanced"
        case small = "Smallest"
        var id: Self { self }
        var bitsPerPixel: Double { [.high: 0.09, .balanced: 0.055, .small: 0.033][self]! }
        var sourceCap: Double { [.high: 0.85, .balanced: 0.6, .small: 0.4][self]! }
        var crf: Int { [.high: 22, .balanced: 26, .small: 30][self]! }
        var audioKbps: Int { self == .small ? 128 : 160 }
    }

    var imageTarget = ImageTarget.keep
    var imageQuality = 0.75
    var stripMetadata = false
    var videoCodec = VideoCodec.hevc
    var videoLevel = Level.balanced
    var onlyIfSmaller = true
    var suffix = "-compressed"
}

struct ConvertOptions {
    var imageFormatID = "public.jpeg"
    var imageQuality = 0.9
    var videoContainer = VideoContainer.mp4
    var videoMode = VideoConvertMode.auto
    var suffix = ""
}

struct TransformOptions {
    enum ResizeMode: String, CaseIterable, Identifiable {
        case none = "Don't resize", percent = "Percentage", fit = "Fit within", width = "Width", height = "Height"
        var id: Self { self }
    }

    enum CropMode: String, CaseIterable, Identifiable {
        case none = "No crop", square = "1:1 Square", r43 = "4:3", r32 = "3:2", r169 = "16:9"
        case r916 = "9:16 Vertical", r45 = "4:5 Portrait", custom = "Custom edges"
        var id: Self { self }
        var ratio: Double? {
            switch self {
            case .square: 1
            case .r43: 4.0 / 3
            case .r32: 3.0 / 2
            case .r169: 16.0 / 9
            case .r916: 9.0 / 16
            case .r45: 4.0 / 5
            default: nil
            }
        }
    }

    var resizeMode = ResizeMode.none
    var percent = 50.0
    var width = 1920
    var height = 1080
    var cropMode = CropMode.none
    var insetTop = 0.0, insetLeft = 0.0, insetBottom = 0.0, insetRight = 0.0
    var rotation = 0
    var flipH = false
    var flipV = false
    var videoCodec = VideoCodec.hevc
    var suffix = "-edited"

    var transform: MediaTransform {
        var t = MediaTransform()
        switch resizeMode {
        case .none: t.resize = .none
        case .percent: t.resize = .percent(percent)
        case .fit: t.resize = .fit(width: width, height: height)
        case .width: t.resize = .width(width)
        case .height: t.resize = .height(height)
        }
        if let ratio = cropMode.ratio {
            t.crop = .aspect(ratio)
        } else if cropMode == .custom {
            t.crop = .insets(top: insetTop, left: insetLeft, bottom: insetBottom, right: insetRight)
        }
        t.rotation = rotation
        t.flipHorizontal = flipH
        t.flipVertical = flipV
        return t
    }
}

struct AudioOptions {
    var format = AudioFormat.mp3
    var bitrateKbps = 192
    var sampleRate: Double? = nil
    var channels: Int? = nil
    var suffix = ""
}

struct StripOptions {
    var locationOnly = false
    var replaceOriginals = false
    var suffix = "-clean"
}

// MARK: - Jobs

enum Jobs {
    // MARK: Compress

    static func compress(_ url: URL, _ o: CompressOptions, folder: URL?, progress: @escaping ProgressHandler) async throws -> JobResult {
        let out: URL
        switch url.kind {
        case .image:
            var input = url
            if !ImageProcessor.canRead(url) { input = try await ImageProcessor.decodeWithFFmpeg(url) }
            defer { if input != url { try? FileManager.default.removeItem(at: input) } }
            let source = ImageProcessor.sourceType(of: input) ?? .jpeg
            let type: UTType
            switch o.imageTarget {
            case .heic: type = .heic
            case .jpeg: type = .jpeg
            case .keep: type = ImageFormats.canWrite(source) ? source : .heic
            }
            out = Output.destination(for: url, folder: folder, suffix: o.suffix, ext: ImageFormats.ext(for: type, source: url))
            try ImageProcessor.write(src: input, to: out, type: type,
                                     quality: ImageFormats.isLossy(type) ? o.imageQuality : nil,
                                     stripMetadata: o.stripMetadata, tiffCompression: type == .tiff)
            progress(1)
        case .video:
            let keepExt = ["mp4", "mov", "m4v"].contains(url.ext)
            if await VideoProcessor.canReadNatively(url) {
                out = Output.destination(for: url, folder: folder, suffix: o.suffix, ext: keepExt ? url.ext : "mp4")
                var s = VideoEncodeSettings()
                s.codec = o.videoCodec
                s.bitsPerPixel = o.videoLevel.bitsPerPixel
                s.maxBitrateFraction = o.videoLevel.sourceCap
                s.fileType = VideoContainer.fileType(forExtension: out.ext) ?? .mp4
                s.audioBitrate = o.videoLevel.audioKbps * 1000
                s.stripMetadata = o.stripMetadata
                try await cleaningUp(out) { try await VideoProcessor.transcode(url, to: out, settings: s, progress: progress) }
            } else {
                let ff = FFmpeg.shared
                guard ff.isAvailable else { throw AppError.needsFFmpeg }
                out = Output.destination(for: url, folder: folder, suffix: o.suffix, ext: keepExt || url.ext == "mkv" ? url.ext : "mp4")
                let video = o.videoCodec == .hevc ? ff.hevcArgs(crf: o.videoLevel.crf) : ff.h264Args()
                let meta = o.stripMetadata ? ["-map_metadata", "-1"] : ["-map_metadata", "0"]
                try await cleaningUp(out) {
                    try await ff.run(["-i", url.path] + meta + video + ff.aacArgs(kbps: o.videoLevel.audioKbps) + [out.path], progress: progress)
                }
            }
        default:
            throw AppError("Unsupported file type")
        }
        if o.onlyIfSmaller, out.fileSize >= url.fileSize {
            try? FileManager.default.removeItem(at: out)
            return JobResult(output: nil, message: "Already optimized — original kept", skipped: true)
        }
        return JobResult(output: out)
    }

    // MARK: Convert

    static func convert(_ url: URL, _ o: ConvertOptions, folder: URL?, progress: @escaping ProgressHandler) async throws -> JobResult {
        switch url.kind {
        case .image:
            guard let format = ImageFormats.format(id: o.imageFormatID), let type = format.type else {
                throw AppError("Choose an output format")
            }
            var input = url
            if !ImageProcessor.canRead(url) { input = try await ImageProcessor.decodeWithFFmpeg(url) }
            defer { if input != url { try? FileManager.default.removeItem(at: input) } }
            let out = Output.destination(for: url, folder: folder, suffix: o.suffix, ext: format.ext)
            if format.viaFFmpeg {
                let tmp = Output.temporary(ext: "png")
                defer { try? FileManager.default.removeItem(at: tmp) }
                try ImageProcessor.write(src: input, to: tmp, type: .png, quality: nil, stripMetadata: false)
                let args: [String] = type.identifier == "public.avif"
                    ? ["-c:v", FFmpeg.shared.pick(["libsvtav1", "libaom-av1"]) ?? "libaom-av1", "-crf", "\(Int((1 - o.imageQuality) * 50) + 10)", "-still-picture", "1"]
                    : ["-c:v", "libwebp", "-quality", "\(Int(o.imageQuality * 100))"]
                try await cleaningUp(out) { try await FFmpeg.shared.run(["-i", tmp.path] + args + [out.path]) }
            } else {
                try ImageProcessor.write(src: input, to: out, type: type, quality: format.lossy ? o.imageQuality : nil,
                                         stripMetadata: false, tiffCompression: type == .tiff)
            }
            progress(1)
            return JobResult(output: out)

        case .video:
            let container = o.videoContainer
            let out = Output.destination(for: url, folder: folder, suffix: o.suffix, ext: container.ext)
            let native = await VideoProcessor.canReadNatively(url)
            try await cleaningUp(out) {
                if native, container == .gif {
                    try await VideoProcessor.makeGIF(url, to: out, range: nil, fps: 12, maxWidth: 480, progress: progress)
                } else if native, let fileType = container.fileType {
                    do {
                        try await VideoProcessor.convert(url, to: out, fileType: fileType, mode: o.videoMode, progress: progress)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch where FFmpeg.shared.isAvailable {
                        try? FileManager.default.removeItem(at: out)
                        try await FFmpeg.shared.convert(input: url, output: out, argSets: FFmpeg.shared.videoArgs(for: container), progress: progress)
                    }
                } else {
                    guard FFmpeg.shared.isAvailable else { throw AppError.needsFFmpeg }
                    var sets = FFmpeg.shared.videoArgs(for: container)
                    if o.videoMode != .auto, container.isNative, container != .gif {
                        let v = o.videoMode == .hevc ? FFmpeg.shared.hevcArgs(crf: 22) : FFmpeg.shared.h264Args()
                        sets = [["-map_metadata", "0"] + v + FFmpeg.shared.aacArgs() + ["-movflags", "+faststart"]]
                    }
                    try await FFmpeg.shared.convert(input: url, output: out, argSets: sets, progress: progress)
                }
            }
            return JobResult(output: out)

        default:
            throw AppError("Unsupported file type")
        }
    }

    // MARK: Resize / crop / rotate

    static func transform(_ url: URL, _ o: TransformOptions, folder: URL?, progress: @escaping ProgressHandler) async throws -> JobResult {
        let t = o.transform
        guard !t.isIdentity else { throw AppError("Nothing to change — pick a resize, crop, rotation or flip") }
        switch url.kind {
        case .image:
            var input = url
            if !ImageProcessor.canRead(url) { input = try await ImageProcessor.decodeWithFFmpeg(url) }
            defer { if input != url { try? FileManager.default.removeItem(at: input) } }
            let source = ImageProcessor.sourceType(of: input) ?? .png
            let type = ImageFormats.canWrite(source) ? source : .png
            let out = Output.destination(for: url, folder: folder, suffix: o.suffix, ext: ImageFormats.ext(for: type, source: url))
            try ImageProcessor.write(src: input, to: out, type: type, quality: ImageFormats.isLossy(type) ? 0.92 : nil,
                                     stripMetadata: false, transform: t)
            progress(1)
            return JobResult(output: out)

        case .video:
            if await VideoProcessor.canReadNatively(url) {
                let ext = ["mp4", "mov", "m4v"].contains(url.ext) ? url.ext : "mp4"
                let out = Output.destination(for: url, folder: folder, suffix: o.suffix, ext: ext)
                var s = VideoEncodeSettings()
                s.codec = o.videoCodec
                s.transform = t
                s.fileType = VideoContainer.fileType(forExtension: ext) ?? .mp4
                try await cleaningUp(out) { try await VideoProcessor.transcode(url, to: out, settings: s, progress: progress) }
                return JobResult(output: out)
            }
            let ff = FFmpeg.shared
            guard ff.isAvailable else { throw AppError.needsFFmpeg }
            let ext = ["mp4", "mov", "m4v", "mkv"].contains(url.ext) ? url.ext : "mp4"
            let out = Output.destination(for: url, folder: folder, suffix: o.suffix, ext: ext)
            let video = o.videoCodec == .hevc ? ff.hevcArgs(crf: 22) : ff.h264Args()
            try await cleaningUp(out) {
                try await ff.run(["-i", url.path, "-vf", ffmpegFilter(t), "-map_metadata", "0"] + video + ff.aacArgs() + [out.path], progress: progress)
            }
            return JobResult(output: out)

        default:
            throw AppError("Unsupported file type")
        }
    }

    static func ffmpegFilter(_ t: MediaTransform) -> String {
        var filters: [String] = []
        switch t.crop {
        case .none: break
        case .aspect(let r):
            filters.append("crop='if(gt(a,\(r)),ih*\(r),iw)':'if(gt(a,\(r)),ih,iw/\(r))'")
        case let .insets(top, left, bottom, right):
            filters.append("crop=iw*\(1 - left - right):ih*\(1 - top - bottom):iw*\(left):ih*\(top)")
        }
        if t.flipHorizontal { filters.append("hflip") }
        if t.flipVertical { filters.append("vflip") }
        switch ((t.rotation % 360) + 360) % 360 {
        case 90: filters.append("transpose=1")
        case 180: filters.append("hflip,vflip")
        case 270: filters.append("transpose=2")
        default: break
        }
        switch t.resize {
        case .none: break
        case .percent(let p): filters.append("scale=trunc(iw*\(p / 100)/2)*2:trunc(ih*\(p / 100)/2)*2:flags=lanczos")
        case let .fit(w, h): filters.append("scale=w='min(\(w),iw)':h='min(\(h),ih)':force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos")
        case .width(let w): filters.append("scale=\(w):-2:flags=lanczos")
        case .height(let h): filters.append("scale=-2:\(h):flags=lanczos")
        }
        filters.append("scale=trunc(iw/2)*2:trunc(ih/2)*2")
        return filters.joined(separator: ",")
    }

    // MARK: Audio

    static func audio(_ url: URL, _ o: AudioOptions, folder: URL?, progress: @escaping ProgressHandler) async throws -> JobResult {
        let out = Output.destination(for: url, folder: folder, suffix: o.suffix, ext: o.format.ext)
        let settings = AudioSettings(format: o.format, bitrateKbps: o.bitrateKbps, sampleRate: o.sampleRate, channels: o.channels)
        try await cleaningUp(out) { try await AudioProcessor.convert(url, to: out, settings: settings, progress: progress) }
        return JobResult(output: out)
    }

    // MARK: Metadata

    static func strip(_ url: URL, _ o: StripOptions, folder: URL?, progress: @escaping ProgressHandler) async throws -> JobResult {
        let out = o.replaceOriginals
            ? url.deletingLastPathComponent().appendingPathComponent(".\(url.baseName)-\(UUID().uuidString.prefix(8))").appendingPathExtension(url.pathExtension)
            : Output.destination(for: url, folder: folder, suffix: o.suffix, ext: url.pathExtension)
        try await cleaningUp(out) {
            switch url.kind {
            case .image: try ImageProcessor.stripMetadata(src: url, to: out, locationOnly: o.locationOnly)
            case .video: try await VideoProcessor.stripMetadata(url, to: out, locationOnly: o.locationOnly, progress: progress)
            default: throw AppError("Unsupported file type")
            }
        }
        progress(1)
        if o.replaceOriginals {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            try FileManager.default.moveItem(at: out, to: url)
            return JobResult(output: url, message: "Original moved to Trash")
        }
        return JobResult(output: out)
    }
}

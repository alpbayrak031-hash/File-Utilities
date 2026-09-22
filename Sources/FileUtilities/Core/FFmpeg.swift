import Foundation

/// Optional ffmpeg backend for formats Apple's frameworks can't read or write (MKV, WebM, AVI, MP3, OGG…).
final class FFmpeg: @unchecked Sendable {
    static let shared = FFmpeg()
    static let customPathKey = "ffmpegPath"

    private let lock = NSLock()
    private var _path: String?
    private var _encoders: Set<String> = []
    private var _version: String?

    private init() { refresh() }

    var path: String? { lock.withLock { _path } }
    var version: String? { lock.withLock { _version } }
    var isAvailable: Bool { path != nil }
    func has(_ encoder: String) -> Bool { lock.withLock { _encoders.contains(encoder) } }
    func pick(_ encoders: [String]) -> String? { encoders.first(where: has) }

    static var searchPaths: [String] {
        var paths: [String] = []
        if let custom = UserDefaults.standard.string(forKey: customPathKey), !custom.isEmpty { paths.append(custom) }
        // Each architecture gets its own bundled build; the slice we're running in picks its own.
        #if arch(x86_64)
        let bundledNames = ["ffmpeg-x86_64", "ffmpeg"]
        #else
        let bundledNames = ["ffmpeg", "ffmpeg-arm64"]
        #endif
        for name in bundledNames {
            if let bundled = Bundle.main.url(forAuxiliaryExecutable: name)?.path { paths.append(bundled) }
        }
        paths += ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg",
                  NSHomeDirectory() + "/bin/ffmpeg", NSHomeDirectory() + "/.local/bin/ffmpeg"]
        return paths
    }

    func refresh() {
        var found: String?
        var encoders: Set<String> = []
        var version: String?
        for candidate in Self.searchPaths where FileManager.default.isExecutableFile(atPath: candidate) {
            // Actually run it: a binary built for another CPU exists but can't execute.
            guard let banner = try? Self.runSync(candidate, ["-version"]),
                  banner.hasPrefix("ffmpeg version") else { continue }
            found = candidate
            version = banner.split(separator: "\n").first.map(String.init)
            let list = (try? Self.runSync(candidate, ["-hide_banner", "-encoders"])) ?? ""
            for line in list.split(separator: "\n") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 2, parts[0].count == 6, !parts[0].contains("=") { encoders.insert(String(parts[1])) }
            }
            break
        }
        lock.withLock {
            _path = found
            _encoders = encoders
            _version = version
        }
    }

    /// Runs a short command and returns stdout. Throws if the binary can't be launched at all.
    static func runSync(_ executable: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs ffmpeg with the given arguments. Reports progress using the input duration it prints.
    func run(_ args: [String], progress: ProgressHandler? = nil) async throws {
        guard let path else { throw AppError.needsFFmpeg }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-hide_banner", "-nostdin", "-y", "-progress", "pipe:1", "-nostats"] + args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let state = RunState()
        let throttle = ProgressThrottle(progress)

        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("out_time_us=") {
                if let micro = Double(line.dropFirst("out_time_us=".count)), let duration = state.duration, duration > 0 {
                    throttle.report(micro / 1_000_000 / duration)
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            state.append(String(decoding: data, as: UTF8.self))
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { proc in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    if proc.terminationReason == .uncaughtSignal || state.cancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if proc.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: AppError("ffmpeg: " + state.errorSummary))
                    }
                }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            state.cancelled = true
            if process.isRunning { process.terminate() }
        }
        throttle.report(1)
    }

    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var log = ""
        private var _duration: Double?
        private var _cancelled = false

        var duration: Double? { lock.withLock { _duration } }
        var cancelled: Bool {
            get { lock.withLock { _cancelled } }
            set { lock.withLock { _cancelled = newValue } }
        }

        func append(_ text: String) {
            lock.withLock {
                log += text
                if log.count > 40_000 { log = String(log.suffix(20_000)) }
                if _duration == nil, let range = log.range(of: "Duration: ") {
                    let stamp = log[range.upperBound...].prefix(11)
                    let parts = stamp.split(separator: ":").compactMap { Double($0) }
                    if parts.count == 3 { _duration = parts[0] * 3600 + parts[1] * 60 + parts[2] }
                }
            }
        }

        var errorSummary: String {
            lock.withLock {
                let lines = log.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                return lines.suffix(3).joined(separator: " — ")
            }
        }
    }
}

// MARK: - Argument builders

extension FFmpeg {
    func h264Args() -> [String] {
        if has("libx264") { return ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p"] }
        if has("h264_videotoolbox") { return ["-c:v", "h264_videotoolbox", "-q:v", "65", "-pix_fmt", "yuv420p"] }
        return ["-c:v", "mpeg4", "-q:v", "3"]
    }

    func hevcArgs(crf: Int) -> [String] {
        if has("libx265") { return ["-c:v", "libx265", "-crf", "\(crf)", "-preset", "medium", "-tag:v", "hvc1", "-pix_fmt", "yuv420p"] }
        if has("hevc_videotoolbox") { return ["-c:v", "hevc_videotoolbox", "-q:v", "\(max(30, 90 - crf * 2))", "-tag:v", "hvc1"] }
        return h264Args()
    }

    /// libvorbis if present, otherwise ffmpeg's built-in Vorbis encoder.
    func vorbisArgs(kbps: Int = 192) -> [String] {
        has("libvorbis") ? ["-c:a", "libvorbis", "-b:a", "\(kbps)k"] : ["-c:a", "vorbis", "-strict", "-2", "-ac", "2", "-b:a", "\(kbps)k"]
    }

    func aacArgs(kbps: Int = 192) -> [String] {
        ["-c:a", pick(["aac", "aac_at"]) ?? "aac", "-b:a", "\(kbps)k"]
    }

    /// Argument sets to try in order for converting video into `container`.
    func videoArgs(for container: VideoContainer) -> [[String]] {
        let meta = ["-map_metadata", "0"]
        let faststart = ["-movflags", "+faststart"]
        let standard = h264Args() + aacArgs()
        switch container {
        case .mp4, .mov, .m4v:
            return [meta + standard + faststart]
        case .threeGP, .flv:
            return [meta + standard]
        case .mkv:
            return [["-map", "0:v?", "-map", "0:a?", "-map", "0:s?", "-c", "copy"] + meta, meta + standard]
        case .webm:
            let video = has("libvpx-vp9") ? ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1"] : ["-c:v", "libvpx", "-crf", "10", "-b:v", "2M"]
            let audio = has("libopus") ? ["-c:a", "libopus", "-b:a", "128k"] : vorbisArgs()
            return [meta + video + audio]
        case .avi:
            let audio = has("libmp3lame") ? ["-c:a", "libmp3lame", "-q:a", "3"] : ["-c:a", "ac3", "-b:a", "192k"]
            return [meta + ["-c:v", "mpeg4", "-q:v", "3", "-vtag", "xvid"] + audio]
        case .wmv:
            return [meta + ["-c:v", "wmv2", "-b:v", "8M", "-c:a", "wmav2", "-b:a", "192k"]]
        case .mpg:
            return [meta + ["-c:v", "mpeg2video", "-q:v", "2", "-c:a", "mp2", "-ar", "48000", "-b:a", "224k"]]
        case .ts:
            return [meta + standard + ["-f", "mpegts"]]
        case .ogv:
            let video = has("libtheora") ? ["-c:v", "libtheora", "-q:v", "7"] : ["-c:v", "libvpx", "-crf", "10", "-b:v", "3M"]
            return [meta + video + vorbisArgs()]
        case .gif:
            return [["-vf", "fps=12,scale='min(480,iw)':-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop", "0"]]
        }
    }

    /// Converts using the first argument set that succeeds.
    func convert(input: URL, output: URL, argSets: [[String]], preInput: [String] = [], progress: ProgressHandler?) async throws {
        var lastError: Error = AppError("ffmpeg conversion failed")
        for args in argSets {
            do {
                try await run(preInput + ["-i", input.path] + args + [output.path], progress: progress)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: output)
            }
        }
        throw lastError
    }
}

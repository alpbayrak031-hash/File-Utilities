import AppKit
import UniformTypeIdentifiers

enum MediaKind: Hashable { case image, video, audio, pdf, other }

enum FileSupport {
    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "webm", "avi", "flv", "wmv", "mpg", "mpeg", "m2v", "ts", "mts", "m2ts",
        "vob", "ogv", "3gp", "3g2", "asf", "rm", "rmvb", "divx", "f4v", "mxf", "dv", "y4m", "hevc", "qt",
    ]
    static let audioExtensions: Set<String> = [
        "mp3", "ogg", "oga", "opus", "flac", "wma", "ape", "wv", "ac3", "eac3", "dts", "amr", "m4a", "m4b",
        "aac", "wav", "aif", "aiff", "aifc", "caf", "mka", "tta", "au", "snd", "mp2",
    ]

    static func kind(of url: URL) -> MediaKind {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .pdf) { return .pdf }
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
            if type.conforms(to: .audio) { return .audio }
        }
        return .other
    }
}

extension URL {
    var kind: MediaKind { FileSupport.kind(of: self) }
    var fileSize: Int64 { Int64((try? resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    var isDirectory: Bool { (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false }
    var ext: String { pathExtension.lowercased() }
    var baseName: String { deletingPathExtension().lastPathComponent }
}

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func formatDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let total = Int(seconds)
    let tenths = Int((seconds - Double(total)) * 10)
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d.%d", h, m, s, tenths) : String(format: "%d:%02d.%d", m, s, tenths)
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }

    static let needsFFmpeg = AppError("This format needs ffmpeg. Open Settings to set it up.")
}

enum Output {
    /// A non-existing destination next to the source (or in `folder`).
    static func destination(for src: URL, folder: URL?, suffix: String, ext: String) -> URL {
        let dir = folder ?? src.deletingLastPathComponent()
        return unique(dir.appendingPathComponent(src.baseName + suffix).appendingPathExtension(ext))
    }

    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent(), base = url.baseName, ext = url.pathExtension
        var i = 2
        while true {
            var candidate = dir.appendingPathComponent("\(base) \(i)")
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    static func temporary(ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FileUtilities-\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }
}

@MainActor
enum Panels {
    static func openFiles(types: [UTType] = [], folders: Bool = true, multiple: Bool = true) -> [URL] {
        let panel = NSOpenPanel()
        if !types.isEmpty { panel.allowedContentTypes = types }
        panel.canChooseFiles = true
        panel.canChooseDirectories = folders
        panel.allowsMultipleSelection = multiple
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func chooseFolder(prompt: String = "Choose") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func save(name: String, type: UTType? = nil, directory: URL? = nil) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        if let type { panel.allowedContentTypes = [type] }
        if let directory { panel.directoryURL = directory }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

/// Removes a partially written output when a job fails or is cancelled.
func cleaningUp<T>(_ url: URL, _ body: () async throws -> T) async throws -> T {
    do {
        return try await body()
    } catch {
        try? FileManager.default.removeItem(at: url)
        throw error
    }
}

/// Limits how often progress is reported (every ~0.5%).
final class ProgressThrottle: @unchecked Sendable {
    private let handler: ProgressHandler?
    private var last = -1.0
    private let lock = NSLock()
    init(_ handler: ProgressHandler?) { self.handler = handler }
    func report(_ value: Double) {
        let v = min(max(value, 0), 1)
        let shouldSend: Bool = lock.withLock {
            guard v - last >= 0.005 || v >= 1 else { return false }
            last = v
            return true
        }
        if shouldSend { handler?(v) }
    }
}

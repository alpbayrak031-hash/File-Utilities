import SwiftUI

struct SettingsView: View {
    @Bindable var app: AppState
    @State private var customPath = UserDefaults.standard.string(forKey: FFmpeg.customPathKey) ?? ""

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(title: "Settings", subtitle: "Optional add-ons and information.", icon: Tool.settings.icon)
            Divider()
            Form {
                Section("ffmpeg (optional)") {
                    LabeledContent("Status") {
                        if app.ffmpegAvailable {
                            Label("Found", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Label("Not installed", systemImage: "xmark.circle").foregroundStyle(.orange)
                        }
                    }
                    if let path = FFmpeg.shared.path {
                        LabeledContent("Location") { Text(path).textSelection(.enabled).foregroundStyle(.secondary) }
                    }
                    if let version = FFmpeg.shared.version, app.ffmpegAvailable {
                        LabeledContent("Version") { Text(version).lineLimit(1).foregroundStyle(.secondary) }
                    }
                    HStack {
                        Button("Choose ffmpeg File…") {
                            if let url = Panels.openFiles(folders: false, multiple: false).first {
                                customPath = url.path
                                UserDefaults.standard.set(url.path, forKey: FFmpeg.customPathKey)
                                app.refreshFFmpeg()
                            }
                        }
                        Button("Search Again") { app.refreshFFmpeg() }
                        if !customPath.isEmpty {
                            Button("Forget Custom Path") {
                                customPath = ""
                                UserDefaults.standard.removeObject(forKey: FFmpeg.customPathKey)
                                app.refreshFFmpeg()
                            }
                        }
                    }
                }
                Section("What ffmpeg adds") {
                    Text("Everything works without it using Apple's built-in frameworks: JPEG, HEIC, PNG, TIFF, GIF, BMP and more for photos; MP4, MOV and M4V for video; AAC, Apple Lossless, FLAC, WAV and AIFF for audio; and all PDF tools.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("With ffmpeg you also get MKV, WebM, AVI, WMV, FLV, MPEG, TS and OGV video; MP3, Ogg and Opus audio; and WebP images.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("To install it, either run `brew install ffmpeg` in Terminal (needs Homebrew), or download a macOS ffmpeg build and choose the file above. It's searched for in /opt/homebrew/bin, /usr/local/bin and inside the app.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section("About") {
                    LabeledContent("File Utilities") {
                        Text("Version 1.0").foregroundStyle(.secondary)
                    }
                    Text("All processing happens on this Mac. Nothing is uploaded.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }
}

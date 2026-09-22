import AVFoundation
import ImageIO
import SwiftUI

struct MetadataView: View {
    @Bindable var app: AppState
    @State private var mode = 0
    @State private var inspecting: InspectTarget?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $mode) {
                    Text("Remove Metadata").tag(0)
                    Text("Batch Rename").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)
            }
            .padding(.vertical, 8)
            Divider()
            if mode == 0 { stripView } else { RenameView(model: app.rename) }
        }
        .sheet(item: $inspecting) { target in MetadataInspector(url: target.url) }
    }

    private var stripView: some View {
        ToolLayout(title: "Remove Metadata", subtitle: "Strip camera info, dates and GPS location before sharing. Photos aren't re-compressed.",
                   icon: "eye.slash") {
            BatchListView(model: app.strip, hint: "Drop photos and videos here",
                          detail: "Right-click a file and choose Show Metadata… to see what it contains.",
                          inspect: { inspecting = InspectTarget(url: $0) })
        } side: {
            Form {
                Section("Remove") {
                    Picker("What", selection: $app.stripOptions.locationOnly) {
                        Text("Everything (keeps orientation)").tag(false)
                        Text("Location (GPS) only").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                }
                Section("Save") {
                    Picker("Mode", selection: $app.stripOptions.replaceOriginals) {
                        Text("Save cleaned copies").tag(false)
                        Text("Replace originals").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    if app.stripOptions.replaceOriginals {
                        Caption("Originals are moved to the Trash, so you can still get them back.")
                    }
                }
                if !app.stripOptions.replaceOriginals {
                    OutputSection(model: app.strip, suffix: $app.stripOptions.suffix)
                }
            }
            .formStyle(.grouped)
            RunBar(model: app.strip, label: "Remove Metadata") {
                let options = app.stripOptions, folder = app.strip.outputFolder
                app.strip.run { url, progress in try await Jobs.strip(url, options, folder: folder, progress: progress) }
            }
        }
    }
}

struct InspectTarget: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - Inspector

struct MetadataInspector: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [(String, String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading) {
                    Text(url.lastPathComponent).font(.headline)
                    Text(formatBytes(url.fileSize)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            if rows.isEmpty {
                Text("No metadata found").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(rows.indices, id: \.self) { i in
                    HStack(alignment: .top) {
                        Text(rows[i].0).foregroundStyle(.secondary).frame(width: 220, alignment: .leading)
                        Text(rows[i].1).textSelection(.enabled)
                    }
                    .font(.callout)
                }
            }
        }
        .frame(width: 620, height: 520)
        .task { await load() }
    }

    private func load() async {
        var result: [(String, String)] = []
        switch url.kind {
        case .image:
            func walk(_ dict: [String: Any], prefix: String) {
                for key in dict.keys.sorted() {
                    let label = prefix.isEmpty ? key : "\(prefix) › \(key)"
                    if let nested = dict[key] as? [String: Any] {
                        walk(nested, prefix: label.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: ""))
                    } else {
                        result.append((label, "\(dict[key]!)".replacingOccurrences(of: "\n", with: " ")))
                    }
                }
            }
            walk(ImageProcessor.properties(of: url) as NSDictionary as? [String: Any] ?? [:], prefix: "")
        case .video:
            let asset = AVURLAsset(url: url)
            for item in (try? await asset.load(.metadata)) ?? [] {
                let key = item.commonKey?.rawValue ?? item.identifier?.rawValue ?? "?"
                var value = (try? await item.load(.stringValue)) ?? nil
                if value == nil, let raw = try? await item.load(.value) { value = "\(raw)" }
                result.append((key, value ?? ""))
            }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let (size, fps, rate) = try? await track.load(.naturalSize, .nominalFrameRate, .estimatedDataRate) {
                result.append(("Video size", "\(Int(size.width))×\(Int(size.height))"))
                result.append(("Frame rate", String(format: "%.2f fps", fps)))
                result.append(("Video bitrate", String(format: "%.1f Mbps", rate / 1_000_000)))
            }
            if let duration = try? await asset.load(.duration) {
                result.append(("Duration", formatDuration(duration.seconds)))
            }
        default: break
        }
        rows = result
    }
}

// MARK: - Rename

struct RenameView: View {
    @Bindable var model: RenameModel
    @State private var targeted = false

    private let tokens = [("{name}", "Original name"), ("{n}", "Counter"), ("{date}", "Capture date"), ("{time}", "Capture time"),
                          ("{year}", "Year"), ("{month}", "Month"), ("{day}", "Day"), ("{folder}", "Folder name"), ("{ext}", "Extension")]

    var body: some View {
        ToolLayout(title: "Batch Rename", subtitle: "Rename many files at once using a pattern. Preview before applying.",
                   icon: "character.cursor.ibeam") {
            VStack(spacing: 0) {
                if model.files.isEmpty {
                    DropZone(hint: "Drop files or folders here", detail: "Any kind of file can be renamed.", targeted: targeted) {
                        model.add(Panels.openFiles())
                    }
                } else {
                    Table(model.rows) {
                        TableColumn("Original") { row in
                            Text(row.url.lastPathComponent).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        }
                        TableColumn("New name") { row in
                            HStack(spacing: 6) {
                                if row.conflict {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                                        .help("This name is duplicated or already exists")
                                }
                                Text(row.newName).lineLimit(1).truncationMode(.middle)
                                    .foregroundStyle(row.conflict ? .red : (row.changed ? .primary : .secondary))
                            }
                        }
                    }
                    Divider()
                    HStack {
                        Button { model.add(Panels.openFiles()) } label: { Label("Add", systemImage: "plus") }
                        Button("Clear") { model.clear() }
                        Spacer()
                        Text(model.status).foregroundStyle(.secondary).font(.callout)
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                model.add(urls)
                return true
            } isTargeted: { targeted = $0 }
        } side: {
            Form {
                Section("Pattern") {
                    TextField("Pattern", text: $model.pattern)
                        .font(.body.monospaced())
                    Menu("Insert Token") {
                        ForEach(tokens, id: \.0) { token in
                            Button("\(token.0)  —  \(token.1)") { model.pattern += token.0 }
                        }
                    }
                    Caption("Example: Trip-{date}-{n} → Trip-2026-09-21-001.jpg. The extension is kept automatically.")
                }
                Section("Counter") {
                    TextField("Start at", value: $model.start, format: .number)
                    Stepper("Digits: \(model.padding)", value: $model.padding, in: 1...6)
                    Picker("Order", selection: $model.sort) {
                        ForEach(RenameModel.SortOrder.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Section("Text") {
                    TextField("Find", text: $model.find)
                    TextField("Replace with", text: $model.replace)
                    Picker("Case", selection: $model.caseMode) {
                        ForEach(RenameModel.CaseMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    TextField("Date format", text: $model.dateFormat)
                }
            }
            .formStyle(.grouped)
            .onChange(of: model.pattern) { model.refresh() }
            .onChange(of: model.start) { model.refresh() }
            .onChange(of: model.padding) { model.refresh() }
            .onChange(of: model.sort) { model.refresh() }
            .onChange(of: model.find) { model.refresh() }
            .onChange(of: model.replace) { model.refresh() }
            .onChange(of: model.caseMode) { model.refresh() }
            .onChange(of: model.dateFormat) { model.refresh() }
            VStack(spacing: 8) {
                Divider()
                HStack {
                    Button("Undo Last Rename") { model.undo() }.disabled(model.lastRenames.isEmpty)
                    Spacer()
                    Button {
                        model.apply()
                    } label: {
                        Text("Rename \(model.changeCount) File\(model.changeCount == 1 ? "" : "s")").frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.changeCount == 0 || model.hasConflicts)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
    }
}

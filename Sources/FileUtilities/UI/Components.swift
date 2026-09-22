import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Layout

struct ToolLayout<Main: View, Side: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    @ViewBuilder var main: () -> Main
    @ViewBuilder var side: () -> Side

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(title: title, subtitle: subtitle, icon: icon)
            Divider()
            HStack(spacing: 0) {
                main().frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                VStack(spacing: 0) { side() }
                    .frame(width: 340)
                    .background(.background.secondary)
            }
        }
    }
}

struct ToolHeader: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - Drop zone

struct DropZone: View {
    let hint: String
    let detail: String
    var targeted = false
    let choose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
            Text(hint).font(.title3.weight(.medium))
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Choose Files…", action: choose).controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.35))
                .background(RoundedRectangle(cornerRadius: 14).fill(targeted ? Color.accentColor.opacity(0.07) : .clear))
                .padding(20)
        }
    }
}

// MARK: - Batch list

struct BatchListView: View {
    @Bindable var model: BatchModel
    var hint = "Drop files or folders here"
    var detail = "Folders are scanned for supported files."
    var inspect: ((URL) -> Void)?
    @State private var selection = Set<UUID>()
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            if model.items.isEmpty {
                DropZone(hint: hint, detail: detail, targeted: targeted, choose: choose)
            } else {
                table
                Divider()
                footer
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isRunning else { return false }
            model.add(urls)
            return true
        } isTargeted: { targeted = $0 }
    }

    private var table: some View {
        Table(model.items, selection: $selection) {
            TableColumn("File") { item in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                        .resizable().frame(width: 18, height: 18)
                    Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                }
                .help(item.url.path)
            }
            TableColumn("Size") { item in
                Text(formatBytes(item.originalSize)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80, max: 100)
            TableColumn("Result") { item in StatusCell(item: item) }
                .width(min: 150, ideal: 240)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            let items = model.items.filter { ids.contains($0.id) }
            Button("Show Original in Finder") { Panels.reveal(items.map(\.url)) }
            if items.contains(where: { $0.output != nil }) {
                Button("Show Result in Finder") { Panels.reveal(items.compactMap(\.output)) }
            }
            if let inspect, let first = items.first {
                Button("Show Metadata…") { inspect(first.url) }
            }
            Divider()
            Button("Remove from List") { model.remove(ids) }.disabled(model.isRunning)
        } primaryAction: { ids in
            let outputs = model.items.filter { ids.contains($0.id) }.compactMap(\.output)
            if !outputs.isEmpty { Panels.reveal(outputs) }
        }
        .onDeleteCommand { model.remove(selection) }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { choose() } label: { Label("Add", systemImage: "plus") }
            Button { model.remove(selection); selection = [] } label: { Label("Remove", systemImage: "minus") }
                .disabled(selection.isEmpty || model.isRunning)
            Button("Clear") { model.clear(); selection = [] }.disabled(model.isRunning)
            Spacer()
            if model.savedBytes > 0 {
                Text("Saved \(formatBytes(model.savedBytes))")
                    .foregroundStyle(.green).font(.callout.weight(.medium))
            }
            Text("\(model.items.count) file\(model.items.count == 1 ? "" : "s")").foregroundStyle(.secondary).font(.callout)
            if !model.outputs.isEmpty {
                Button { Panels.reveal(model.outputs) } label: { Label("Show Results", systemImage: "folder") }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func choose() {
        model.add(Panels.openFiles())
    }
}

struct StatusCell: View {
    let item: BatchItem

    var body: some View {
        switch item.status {
        case .pending:
            Text(item.message.isEmpty ? "Ready" : item.message).foregroundStyle(.secondary)
        case .running:
            ProgressView(value: item.progress).progressViewStyle(.linear)
        case .done:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                if item.outputSize > 0 {
                    Text(formatBytes(item.outputSize)).monospacedDigit()
                    if item.originalSize > 0, item.output != item.url {
                        let change = Double(item.outputSize - item.originalSize) / Double(item.originalSize) * 100
                        Text(String(format: "%+.0f%%", change))
                            .monospacedDigit()
                            .foregroundStyle(change <= 0 ? .green : .orange)
                    }
                }
                if !item.message.isEmpty { Text(item.message).foregroundStyle(.secondary).lineLimit(1) }
            }
        case .skipped:
            Label(item.message, systemImage: "arrow.uturn.left.circle").foregroundStyle(.secondary).lineLimit(1)
                .help(item.message)
        case .failed:
            Label(item.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).lineLimit(2).help(item.message)
        }
    }
}

// MARK: - Options helpers

struct OutputSection: View {
    @Bindable var model: BatchModel
    var suffix: Binding<String>?

    var body: some View {
        Section("Output") {
            LabeledContent("Save to") {
                Menu(model.outputFolder?.lastPathComponent ?? "Same folder as original") {
                    Button("Same folder as original") { model.outputFolder = nil }
                    Button("Choose Folder…") {
                        if let url = Panels.chooseFolder() { model.outputFolder = url }
                    }
                }
                .fixedSize()
            }
            if let suffix {
                TextField("Name ending", text: suffix, prompt: Text("none"))
            }
        }
    }
}

struct QualitySlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0.3...1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}

struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct FFmpegNotice: View {
    let text: String
    var body: some View {
        Label {
            Text(text).font(.caption)
        } icon: {
            Image(systemName: "puzzlepiece.extension").foregroundStyle(.orange)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct RunBar: View {
    @Bindable var model: BatchModel
    let label: String
    var disabled = false
    let start: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Divider()
            if model.isRunning {
                ProgressView(value: model.overallProgress)
                    .padding(.horizontal, 16)
            }
            HStack {
                if model.isRunning {
                    Button("Cancel", role: .cancel) { model.cancel() }
                    Spacer()
                    Text("\(model.doneCount) of \(model.items.count) done").foregroundStyle(.secondary).font(.callout)
                } else {
                    Spacer()
                    Button(action: start) {
                        Text(label).frame(minWidth: 140)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.items.isEmpty || disabled)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }
}

// MARK: - Reorderable file list (merge, images → PDF)

struct OrderedFileList: View {
    @Bindable var model: BatchModel
    var hint: String
    var detail: String
    @State private var targeted = false
    @State private var selection = Set<UUID>()

    var body: some View {
        VStack(spacing: 0) {
            if model.items.isEmpty {
                DropZone(hint: hint, detail: detail, targeted: targeted) { model.add(Panels.openFiles()) }
            } else {
                List(selection: $selection) {
                    ForEach(model.items) { item in
                        HStack(spacing: 10) {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 20, height: 20)
                            Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if item.status == .running {
                                ProgressView(value: item.progress).frame(width: 90)
                            } else if item.status == .failed {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(item.message)
                            }
                            Text(formatBytes(item.originalSize)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove { model.move(from: $0, to: $1) }
                }
                .onDeleteCommand { model.remove(selection) }
                Divider()
                HStack(spacing: 10) {
                    Button { model.add(Panels.openFiles()) } label: { Label("Add", systemImage: "plus") }
                    Button { model.remove(selection); selection = [] } label: { Label("Remove", systemImage: "minus") }
                        .disabled(selection.isEmpty)
                    Button("Clear") { model.clear() }
                    Button("Sort by Name") {
                        model.items.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
                    }
                    Spacer()
                    Text("Drag to reorder · \(model.items.count) files").foregroundStyle(.secondary).font(.callout)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .disabled(model.isRunning)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        } isTargeted: { targeted = $0 }
    }
}

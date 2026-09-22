import AVFoundation
import ImageIO
import Observation

@Observable @MainActor
final class RenameModel {
    enum CaseMode: String, CaseIterable, Identifiable {
        case keep = "Keep", lower = "lowercase", upper = "UPPERCASE", title = "Title Case"
        var id: Self { self }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case added = "Order added", name = "Name", date = "Capture date"
        var id: Self { self }
    }

    struct Row: Identifiable {
        let id = UUID()
        let url: URL
        let date: Date
        var newName: String
        var conflict = false
        var changed: Bool { newName != url.lastPathComponent }
    }

    var files: [URL] = []
    var dates: [URL: Date] = [:]
    var rows: [Row] = []
    var pattern = "{name}"
    var start = 1
    var padding = 3
    var find = ""
    var replace = ""
    var caseMode = CaseMode.keep
    var sort = SortOrder.added
    var dateFormat = "yyyy-MM-dd"
    var lastRenames: [(from: URL, to: URL)] = []
    var status = ""

    var hasConflicts: Bool { rows.contains { $0.conflict } }
    var changeCount: Int { rows.filter(\.changed).count }

    func add(_ urls: [URL]) {
        var known = Set(files)
        for url in urls {
            if url.isDirectory {
                let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                for item in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
                where !item.isDirectory && !known.contains(item) {
                    files.append(item); known.insert(item)
                }
            } else if !known.contains(url) {
                files.append(url); known.insert(url)
            }
        }
        Task { await loadDates(); refresh() }
        refresh()
    }

    func clear() {
        files = []; rows = []; dates = [:]; status = ""
    }

    private func loadDates() async {
        for url in files where dates[url] == nil {
            dates[url] = await Self.captureDate(url)
        }
    }

    static func captureDate(_ url: URL) async -> Date {
        let fallback = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
        switch url.kind {
        case .image:
            let props = ImageProcessor.properties(of: url)
            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
               let string = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                let f = DateFormatter()
                f.dateFormat = "yyyy:MM:dd HH:mm:ss"
                f.locale = Locale(identifier: "en_US_POSIX")
                if let date = f.date(from: string) { return date }
            }
        case .video:
            if let item = try? await AVURLAsset(url: url).load(.creationDate),
               let date = try? await item.load(.dateValue) {
                return date
            }
        default: break
        }
        return fallback
    }

    func refresh() {
        var ordered = files
        switch sort {
        case .added: break
        case .name: ordered.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        case .date: ordered.sort { (dates[$0] ?? .distantPast) < (dates[$1] ?? .distantPast) }
        }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = dateFormat
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH-mm-ss"

        var newRows: [Row] = []
        for (index, url) in ordered.enumerated() {
            let date = dates[url] ?? Date()
            let number = String(format: "%0\(max(1, padding))d", start + index)
            var base = pattern.isEmpty ? "{name}" : pattern
            let tokens: [String: String] = [
                "{name}": url.baseName,
                "{n}": number,
                "{date}": dateFormatter.string(from: date),
                "{time}": timeFormatter.string(from: date),
                "{year}": String(Calendar.current.component(.year, from: date)),
                "{month}": String(format: "%02d", Calendar.current.component(.month, from: date)),
                "{day}": String(format: "%02d", Calendar.current.component(.day, from: date)),
                "{folder}": url.deletingLastPathComponent().lastPathComponent,
                "{ext}": url.pathExtension,
            ]
            for (token, value) in tokens { base = base.replacingOccurrences(of: token, with: value) }
            if !find.isEmpty { base = base.replacingOccurrences(of: find, with: replace) }
            switch caseMode {
            case .keep: break
            case .lower: base = base.lowercased()
            case .upper: base = base.uppercased()
            case .title: base = base.capitalized
            }
            base = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let name = url.pathExtension.isEmpty ? base : "\(base).\(url.pathExtension)"
            newRows.append(Row(url: url, date: date, newName: name))
        }

        // Conflicts: duplicate names in the same folder, or an existing file that isn't being renamed.
        let sources = Set(files.map(\.path))
        var seen: [String: Int] = [:]
        for row in newRows {
            let key = row.url.deletingLastPathComponent().appendingPathComponent(row.newName).path.lowercased()
            seen[key, default: 0] += 1
        }
        for i in newRows.indices {
            let target = newRows[i].url.deletingLastPathComponent().appendingPathComponent(newRows[i].newName)
            let duplicate = seen[target.path.lowercased(), default: 0] > 1
            let existing = newRows[i].changed && FileManager.default.fileExists(atPath: target.path)
                && !sources.contains(target.path) && target.path.lowercased() != newRows[i].url.path.lowercased()
            newRows[i].conflict = duplicate || existing || newRows[i].newName.hasPrefix(".") || newRows[i].newName.isEmpty
        }
        rows = newRows
    }

    func apply() {
        guard !hasConflicts else { return }
        let fm = FileManager.default
        let changes = rows.filter(\.changed)
        var temps: [(temp: URL, final: URL, original: URL)] = []
        do {
            // Two phases so names can swap without collisions.
            for row in changes {
                let temp = row.url.deletingLastPathComponent().appendingPathComponent(".rename-\(UUID().uuidString)")
                try fm.moveItem(at: row.url, to: temp)
                temps.append((temp, row.url.deletingLastPathComponent().appendingPathComponent(row.newName), row.url))
            }
            for entry in temps { try fm.moveItem(at: entry.temp, to: entry.final) }
        } catch {
            for entry in temps where fm.fileExists(atPath: entry.temp.path) {
                try? fm.moveItem(at: entry.temp, to: entry.original)
            }
            status = "Rename failed: \(error.localizedDescription)"
            return
        }
        lastRenames = temps.map { ($0.original, $0.final) }
        let mapping = Dictionary(uniqueKeysWithValues: temps.map { ($0.original, $0.final) })
        files = files.map { mapping[$0] ?? $0 }
        dates = Dictionary(uniqueKeysWithValues: dates.map { (mapping[$0.key] ?? $0.key, $0.value) })
        status = "Renamed \(temps.count) file\(temps.count == 1 ? "" : "s")"
        refresh()
    }

    func undo() {
        let fm = FileManager.default
        var restored = 0
        for entry in lastRenames.reversed() where fm.fileExists(atPath: entry.to.path) && !fm.fileExists(atPath: entry.from.path) {
            if (try? fm.moveItem(at: entry.to, to: entry.from)) != nil { restored += 1 }
        }
        let mapping = Dictionary(uniqueKeysWithValues: lastRenames.map { ($0.to, $0.from) })
        files = files.map { mapping[$0] ?? $0 }
        dates = Dictionary(uniqueKeysWithValues: dates.map { (mapping[$0.key] ?? $0.key, $0.value) })
        lastRenames = []
        status = "Restored \(restored) name\(restored == 1 ? "" : "s")"
        refresh()
    }
}

import AppKit
import Observation
import PDFKit

@Observable @MainActor
final class PDFPagesModel {
    struct PageItem: Identifiable {
        let id = UUID()
        var page: PDFPage
        var thumbnail: NSImage
        var source: String
    }

    var pages: [PageItem] = []
    var selection: Set<UUID> = []
    var status = ""
    private var anchor: UUID?

    var selectedIndices: [Int] { pages.indices.filter { selection.contains(pages[$0].id) } }

    func add(_ urls: [URL]) {
        var skipped: [String] = []
        for url in urls {
            switch url.kind {
            case .pdf:
                guard let doc = PDFDocument(url: url), !doc.isLocked else { skipped.append(url.lastPathComponent); continue }
                for i in 0..<doc.pageCount {
                    if let page = doc.page(at: i)?.copy() as? PDFPage {
                        pages.append(PageItem(page: page, thumbnail: Self.thumbnail(page), source: "\(url.baseName) · p\(i + 1)"))
                    }
                }
            case .image:
                if let image = NSImage(contentsOf: url), let page = PDFPage(image: image) {
                    pages.append(PageItem(page: page, thumbnail: Self.thumbnail(page), source: url.lastPathComponent))
                } else {
                    skipped.append(url.lastPathComponent)
                }
            default:
                if url.isDirectory {
                    let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
                    add(items.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
                }
            }
        }
        status = skipped.isEmpty ? "\(pages.count) pages" : "Skipped (unreadable or locked): \(skipped.joined(separator: ", "))"
    }

    static func thumbnail(_ page: PDFPage) -> NSImage {
        page.thumbnail(of: NSSize(width: 240, height: 300), for: .cropBox)
    }

    // MARK: Selection

    func click(_ id: UUID) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else if flags.contains(.shift), let anchor, let a = pages.firstIndex(where: { $0.id == anchor }),
                  let b = pages.firstIndex(where: { $0.id == id }) {
            selection = Set(pages[min(a, b)...max(a, b)].map(\.id))
        } else {
            selection = [id]
            anchor = id
        }
    }

    func selectAll() { selection = Set(pages.map(\.id)) }

    // MARK: Editing

    func rotateSelected(by degrees: Int) {
        for i in selectedIndices {
            pages[i].page.rotation = ((pages[i].page.rotation + degrees) % 360 + 360) % 360
            pages[i].thumbnail = Self.thumbnail(pages[i].page)
        }
    }

    func deleteSelected() {
        pages.removeAll { selection.contains($0.id) }
        selection = []
        status = "\(pages.count) pages"
    }

    func duplicateSelected() {
        var inserted = 0
        for i in selectedIndices {
            let item = pages[i + inserted]
            if let copy = item.page.copy() as? PDFPage {
                pages.insert(PageItem(page: copy, thumbnail: item.thumbnail, source: item.source), at: i + inserted + 1)
                inserted += 1
            }
        }
    }

    func insertBlankPage() {
        let size = pages.last.map { $0.page.bounds(for: .mediaBox).size } ?? CGSize(width: 595, height: 842)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        guard let page = PDFPage(image: image) else { return }
        let index = (selectedIndices.last.map { $0 + 1 }) ?? pages.count
        pages.insert(PageItem(page: page, thumbnail: Self.thumbnail(page), source: "Blank"), at: index)
    }

    func moveSelected(by offset: Int) {
        let indices = selectedIndices
        guard !indices.isEmpty else { return }
        if offset < 0, indices.first! == 0 { return }
        if offset > 0, indices.last! == pages.count - 1 { return }
        let ordered = offset < 0 ? indices : indices.reversed()
        for i in ordered { pages.swapAt(i, i + offset) }
    }

    func move(ids: [UUID], before target: UUID) {
        let moving = pages.filter { ids.contains($0.id) }
        guard !moving.isEmpty, !ids.contains(target) else { return }
        pages.removeAll { ids.contains($0.id) }
        let index = pages.firstIndex { $0.id == target } ?? pages.count
        pages.insert(contentsOf: moving, at: index)
    }

    func reverse() { pages.reverse() }

    func clear() {
        pages = []
        selection = []
        status = ""
    }

    // MARK: Output

    private func document(for items: [PageItem]) -> PDFDocument {
        let doc = PDFDocument()
        for (i, item) in items.enumerated() {
            if let copy = item.page.copy() as? PDFPage { doc.insert(copy, at: i) }
        }
        return doc
    }

    func saveAll() {
        guard !pages.isEmpty, let url = Panels.save(name: "Combined.pdf", type: .pdf) else { return }
        write(document(for: pages), to: url)
    }

    func extractSelected() {
        let items = selectedIndices.map { pages[$0] }
        guard !items.isEmpty, let url = Panels.save(name: "Extracted pages.pdf", type: .pdf) else { return }
        write(document(for: items), to: url)
    }

    func split(every n: Int) {
        guard !pages.isEmpty, n > 0, let folder = Panels.chooseFolder(prompt: "Save Here") else { return }
        var outputs: [URL] = []
        let chunks = stride(from: 0, to: pages.count, by: n).map { Array(pages[$0..<min($0 + n, pages.count)]) }
        let digits = max(2, String(chunks.count).count)
        for (i, chunk) in chunks.enumerated() {
            let url = Output.unique(folder.appendingPathComponent(String(format: "Part %0\(digits)d.pdf", i + 1)))
            if document(for: chunk).write(to: url) { outputs.append(url) }
        }
        status = "Saved \(outputs.count) files"
        Panels.reveal(outputs)
    }

    private func write(_ doc: PDFDocument, to url: URL) {
        if doc.write(to: url) {
            status = "Saved \(doc.pageCount) pages to \(url.lastPathComponent)"
            Panels.reveal([url])
        } else {
            status = "Couldn't save \(url.lastPathComponent)"
        }
    }
}

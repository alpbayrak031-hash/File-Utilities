import Foundation
import Observation

typealias ProgressHandler = @Sendable (Double) -> Void

struct JobResult {
    var output: URL?
    var message: String = ""
    var skipped = false
}

typealias BatchJob = @Sendable (URL, @escaping ProgressHandler) async throws -> JobResult

@Observable @MainActor
final class BatchItem: Identifiable {
    enum Status { case pending, running, done, skipped, failed }

    let id = UUID()
    let url: URL
    let originalSize: Int64
    var status: Status = .pending
    var progress: Double = 0
    var output: URL?
    var outputSize: Int64 = 0
    var message = ""

    init(url: URL) {
        self.url = url
        originalSize = url.fileSize
    }
}

/// A list of input files plus a job runner with limited concurrency.
@Observable @MainActor
final class BatchModel {
    var items: [BatchItem] = []
    var isRunning = false
    var outputFolder: URL?
    var concurrency = 2
    let accepted: Set<MediaKind>
    private var task: Task<Void, Never>?

    init(accepted: Set<MediaKind>) {
        self.accepted = accepted
    }

    var urls: [URL] { items.map(\.url) }
    var outputs: [URL] { items.compactMap(\.output) }
    var doneCount: Int { items.filter { $0.status == .done }.count }
    var overallProgress: Double {
        guard !items.isEmpty else { return 0 }
        return items.reduce(0) { $0 + ($1.status == .pending ? 0 : ($1.status == .running ? $1.progress : 1)) } / Double(items.count)
    }
    var savedBytes: Int64 {
        items.filter { $0.status == .done && $0.outputSize > 0 }.reduce(0) { $0 + ($1.originalSize - $1.outputSize) }
    }

    func add(_ urls: [URL]) {
        var known = Set(items.map { $0.url.standardizedFileURL })
        for url in expand(urls) where accepted.contains(url.kind) {
            let key = url.standardizedFileURL
            guard !known.contains(key) else { continue }
            known.insert(key)
            items.append(BatchItem(url: url))
        }
    }

    private func expand(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            guard url.isDirectory else { result.append(url); continue }
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            var found: [URL] = []
            while let file = enumerator?.nextObject() as? URL {
                if !file.isDirectory { found.append(file) }
            }
            result += found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        return result
    }

    func remove(_ ids: Set<UUID>) {
        guard !isRunning else { return }
        items.removeAll { ids.contains($0.id) }
    }

    func clear() {
        guard !isRunning else { return }
        items.removeAll()
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    /// Runs `job` for every item that hasn't finished yet.
    func run(_ job: @escaping BatchJob) {
        guard !isRunning else { return }
        let pending = items.filter { $0.status != .done && $0.status != .skipped }
        guard !pending.isEmpty else { return }
        for item in pending {
            item.status = .pending
            item.progress = 0
            item.message = ""
        }
        isRunning = true
        let limit = max(1, concurrency)
        task = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for (index, item) in pending.enumerated() {
                    if index >= limit { await group.next() }
                    if Task.isCancelled { break }
                    group.addTask { await self?.process(item, job) }
                }
                await group.waitForAll()
            }
            self?.isRunning = false
            self?.task = nil
        }
    }

    /// Runs a single job for the whole list (e.g. combining files into one output).
    func runSingle(
        _ job: @escaping @Sendable ([URL], @escaping ProgressHandler) async throws -> URL,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) {
        guard !isRunning, !items.isEmpty else { return }
        isRunning = true
        let items = self.items
        for item in items { item.status = .running; item.progress = 0; item.message = "" }
        task = Task { [weak self] in
            do {
                let output = try await job(items.map(\.url)) { value in
                    Task { @MainActor in for item in items where item.status == .running { item.progress = value } }
                }
                for item in items { item.status = .done; item.progress = 1 }
                completion(.success(output))
            } catch {
                let cancelled = error is CancellationError
                for item in items {
                    item.status = cancelled ? .pending : .failed
                    item.message = cancelled ? "Cancelled" : error.localizedDescription
                }
                completion(.failure(error))
            }
            self?.isRunning = false
            self?.task = nil
        }
    }

    private func process(_ item: BatchItem, _ job: BatchJob) async {
        guard !Task.isCancelled else { return }
        item.status = .running
        do {
            let result = try await job(item.url) { value in
                Task { @MainActor in
                    if item.status == .running { item.progress = value }
                }
            }
            item.output = result.output
            item.outputSize = result.output?.fileSize ?? 0
            item.message = result.message
            item.status = result.skipped ? .skipped : .done
            item.progress = 1
        } catch is CancellationError {
            item.status = .pending
            item.message = "Cancelled"
        } catch {
            item.status = .failed
            item.message = error.localizedDescription
        }
    }

    func cancel() {
        task?.cancel()
    }
}

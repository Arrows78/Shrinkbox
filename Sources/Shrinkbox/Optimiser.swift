import Foundation

/// Limits how many files of a kind are processed at once: a video takes the whole media engine, an image does not.
actor Gate {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ n: Int) { available = n }
    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}

/// Remembers what Shrinkbox itself has just written, so a watched folder or the clipboard does not optimise a result again.
final class Protection: @unchecked Sendable {
    static let shared = Protection()
    private var written: [String: Date] = [:]
    private var signatures: Set<String> = []
    private let lock = NSLock()

    private func signature(_ url: URL) -> String {
        let a = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (a?[.size] as? NSNumber)?.int64Value ?? 0
        let m = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(size)|\(Int(m))"
    }

    /// A file Shrinkbox produced or left as it was: it is not processed again while its size and date are the same.
    func mark(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        written[url.path] = Date()
        signatures.insert(signature(url))
        if signatures.count > 5000 { signatures.removeAll(); written.removeAll() }
    }

    func isProtected(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let window = Double(Prefs.int("optimisedFileProtectionMs")) / 1000
        if let d = written[url.path], Date().timeIntervalSince(d) < window { return true }
        return signatures.contains(signature(url))
    }
}

enum Optimiser {
    private static let gates: [MediaKind: Gate] = [.image: Gate(4), .pdf: Gate(2), .audio: Gate(2), .video: Gate(1)]

    /// Runs `work` once the engine of that kind has room, like `run` does: many files at once must not all encode together.
    static func gated<T>(_ kind: MediaKind, _ work: () async throws -> T) async throws -> T {
        let gate = gates[kind]!
        await gate.acquire()
        defer { Task { await gate.release() } }
        return try await work()
    }

    /// Runs what a file gets from a source: the implicit conversion and optimisation, then the attached pipelines.
    static func run(_ file: URL, source: PipelineSource, copiedBy: String? = nil, forceTemporary: Bool = false, counter: Int = 1,
                    progress: (@Sendable (Double) -> Void)? = nil) async throws -> Outcome {
        guard let kind = Media.kind(of: file) else { throw ShrinkError.unsupported(L("%@ is not a supported file", file.lastPathComponent)) }
        let gate = gates[kind]!
        await gate.acquire()
        defer { Task { await gate.release() } }
        let list = Library.pipelines(for: file, kind: kind, source: source)
        var merged: Outcome?
        var current = file
        for (pipeline, _) in list {
            var ctx = RunContext(source: source)
            ctx.copiedBy = copiedBy; ctx.forceTemporary = forceTemporary; ctx.counter = counter; ctx.progress = progress
            let o = try await Runner.run(current, pipeline, context: ctx)
            if var m = merged {
                m.output = o.output; m.newSize = o.newSize; m.forks += o.forks; m.notes += o.notes
                m.skipped = m.skipped && o.skipped
                m.backup = m.backup ?? o.backup
                merged = m
            } else { merged = o }
            current = o.output
            if o.skipped && list.first?.0 == pipeline && o.output.path == file.path { /* a filter stopped the file: attached pipelines still get a chance */ }
        }
        guard let result = merged else { throw ShrinkError.failed(L("Nothing to do")) }
        Protection.shared.mark(result.output)
        for f in result.forks { Protection.shared.mark(f) }
        Log.write("\(file.lastPathComponent): \(Files.human(result.originalSize)) → \(Files.human(result.newSize))")
        return result
    }
}

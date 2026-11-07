import Foundation

/// Optional command-line tools that go further than macOS itself. Shrinkbox works without any of them and uses
/// them when they are installed (Homebrew, or a `bin` folder in its Application Support folder).
enum Tool: String, CaseIterable, Sendable {
    case ffmpeg, gs, pngquant, gifsicle, gifski, exiftool, jpegoptim, cwebp, heifEnc = "heif-enc", oxipng

    /// What it adds, shown in the settings.
    var purpose: String {
        switch self {
        case .ffmpeg: L("Software video encoders (HEVC, AV1, WebM), MP3 and Ogg audio, and formats macOS cannot read")
        case .gs: L("Stronger PDF compression")
        case .pngquant: L("Lossy PNG compression")
        case .gifsicle: L("Smaller animated GIFs")
        case .gifski: L("Higher quality video to GIF conversion")
        case .exiftool: L("Complete metadata removal")
        case .jpegoptim: L("Lossless JPEG optimisation")
        case .cwebp: L("WebP output")
        case .heifEnc: L("AVIF output")
        case .oxipng: L("Lossless PNG optimisation")
        }
    }

    /// The Homebrew formula that provides it.
    var formula: String {
        switch self {
        case .cwebp: "webp"
        case .heifEnc: "libheif"
        case .gs: "ghostscript"
        case let t: t.rawValue
        }
    }

    var url: URL? { Tools.locate(rawValue) }
    var available: Bool { url != nil }
}

enum Tools {
    nonisolated(unsafe) private static var cache: [String: URL?] = [:]
    private static let lock = NSLock()

    static var searchPaths: [String] {
        var paths: [String] = []
        if let p = ProcessInfo.processInfo.environment["SHRINKBOX_BIN"] { paths.append(p) }
        paths.append((NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Shrinkbox/bin"))
        paths += ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        return paths
    }

    static func locate(_ name: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[name] { return hit }
        let found = searchPaths.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        cache[name] = found
        return found
    }

    static func resetCache() { lock.lock(); cache = [:]; lock.unlock() }

    static func require(_ tool: Tool, for why: String) throws -> URL {
        guard let url = tool.url else { throw ShrinkError.missingTool(tool.rawValue, why) }
        return url
    }
}

struct ProcessResult: Sendable {
    var status: Int32
    var output: String
    var error: String
}

enum Run {
    /// Runs a command and waits. Output is captured; a cancelled task terminates the process.
    static func process(_ exe: URL, _ args: [String], environment: [String: String]? = nil, input: Data? = nil) async throws -> ProcessResult {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        if let environment { p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        let inPipe = Pipe()
        if input != nil { p.standardInput = inPipe } else { p.standardInput = FileHandle.nullDevice }
        let outBox = DataBox(), errBox = DataBox()
        out.fileHandleForReading.readabilityHandler = { h in outBox.append(h.availableData) }
        err.fileHandleForReading.readabilityHandler = { h in errBox.append(h.availableData) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<ProcessResult, Error>) in
                p.terminationHandler = { proc in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    outBox.append(out.fileHandleForReading.readDataToEndOfFile())
                    errBox.append(err.fileHandleForReading.readDataToEndOfFile())
                    c.resume(returning: ProcessResult(status: proc.terminationStatus, output: outBox.string, error: errBox.string))
                }
                do {
                    try p.run()
                    if let input { inPipe.fileHandleForWriting.write(input); try? inPipe.fileHandleForWriting.close() }
                } catch { c.resume(throwing: error) }
            }
        } onCancel: { if p.isRunning { p.terminate() } }
    }
}

private final class DataBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

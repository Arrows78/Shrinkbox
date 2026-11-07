import Foundation

/// A condition of an `if` / `ifNot` step. Every key present must hold.
struct Condition: Equatable, Codable, Sendable {
    var regex: String?
    var types: [String] = []
    var nameContains: String?
    var nameIs: String?
    var fileSizeGreaterThan: Int64?
    var fileSizeLowerThan: Int64?
    var minFileSize: Int64?
    var widthGreaterThan: Int?
    var widthLowerThan: Int?
    var heightGreaterThan: Int?
    var heightLowerThan: Int?
    var minResolution: String?
    var dpiGreaterThan: Int?
    var dpiLowerThan: Int?
    var copiedBy: String?
}

enum WatermarkPosition: String, Codable, Sendable { case bottomRight, bottomLeft, topRight, topLeft, center }

/// One step of a pipeline. Parameters left out take the settings' value.
enum Step: Equatable, Codable, Sendable {
    case optimise(encoder: String?, compression: String?, adaptive: Bool?, dpi: Int?, location: String?)
    case downscale(factor: Double, location: String?)
    case lowerBitrate(kbps: Int, location: String?)
    case convert(to: String, location: String?)
    case crop(spec: String, longEdge: Bool, smart: Bool, location: String?)
    case extractPagesAsImages(format: String, quality: String, location: String?)
    case targetSize(bytes: Int64, location: String?)
    case stripExif
    case watermark(image: String, position: WatermarkPosition, opacity: Double, scale: Double, location: String?)
    case removeAudio
    case changeSpeed(factor: Double, frames: String?)
    case capFps(Double)
    case normalize(lufs: Double)
    case filter(Condition, invert: Bool)
    case copy(to: String)
    case move(to: String)
    case rename(to: String)
    case delete(path: String)
    case runScript(String, isCode: Bool)
    case runShortcut(String)
    case copyToClipboard(format: String, relativeTo: String?)
    case fork(location: String?)
    case openWith(String)
    case shelveWith(String)
    case uploadWith(String)

    /// Steps that change the file's content and can share one encoding pass.
    var isProcessing: Bool {
        switch self {
        case .optimise, .downscale, .lowerBitrate, .convert, .crop, .removeAudio, .changeSpeed, .capFps: true
        default: false
        }
    }
}

struct Pipeline: Equatable, Codable, Sendable {
    var steps: [Step]
}

struct PipelineError: Error, LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }
    init(_ m: String) { message = m }
}

enum PipelineParser {
    /// "crop(longEdge: 1600) -> convert(to: webp)".
    static func parse(_ text: String) throws -> Pipeline {
        let parts = splitTopLevel(text, separator: "->")
        var steps: [Step] = []
        for raw in parts {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { continue }
            steps.append(try step(s))
        }
        guard !steps.isEmpty else { throw PipelineError(L("The pipeline has no step")) }
        return Pipeline(steps: steps)
    }

    /// Splits at `separator` outside quotes and parentheses.
    static func splitTopLevel(_ text: String, separator: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        let chars = Array(text)
        let sep = Array(separator)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                current.append(c)
                if c == "\\", i + 1 < chars.count { current.append(chars[i + 1]); i += 2; continue }
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c; current.append(c)
            } else if c == "(" { depth += 1; current.append(c) }
            else if c == ")" { depth -= 1; current.append(c) }
            else if depth == 0, chars[i...].starts(with: sep) { parts.append(current); current = ""; i += sep.count; continue }
            else { current.append(c) }
            i += 1
        }
        parts.append(current)
        return parts
    }

    static func arguments(_ body: String) throws -> [String: String] {
        var out: [String: String] = [:]
        for part in splitTopLevel(body, separator: ",") {
            let p = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.isEmpty { continue }
            guard let colon = p.firstIndex(of: ":") else { throw PipelineError(L("Expected key: value, got “%@”", p)) }
            let key = p[..<colon].trimmingCharacters(in: .whitespaces)
            var value = p[p.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2, let f = value.first, f == "\"" || f == "'", value.last == f { value = String(value.dropFirst().dropLast()) }
            out[key] = value
        }
        return out
    }

    private static func int(_ a: [String: String], _ k: String) -> Int? { a[k].flatMap { Int($0) } }
    private static func double(_ a: [String: String], _ k: String) -> Double? { a[k].flatMap { Double($0) } }
    private static func bool(_ a: [String: String], _ k: String) -> Bool? { a[k].map { $0.lowercased() == "true" || $0 == "1" } }

    static func step(_ s: String) throws -> Step {
        var name = s, body = ""
        if let open = s.firstIndex(of: "("), s.hasSuffix(")") {
            name = String(s[..<open]).trimmingCharacters(in: .whitespaces)
            body = String(s[s.index(after: open)..<s.index(before: s.endIndex)])
        }
        let a = try arguments(body)
        let loc = a["location"]
        func need(_ k: String) throws -> String {
            guard let v = a[k] else { throw PipelineError(L("%@ needs “%@”", name, k)) }
            return v
        }
        switch name {
        case "optimise", "optimize":
            return .optimise(encoder: a["encoder"], compression: a["compression"], adaptive: bool(a, "adaptive"), dpi: int(a, "dpi"), location: loc)
        case "downscale":
            guard let f = double(a, "factor"), f > 0, f <= 1 else { throw PipelineError(L("downscale needs a factor between 0 and 1")) }
            return .downscale(factor: f, location: loc)
        case "lowerBitrate":
            guard let k = int(a, "kbps"), k > 0 else { throw PipelineError(L("lowerBitrate needs kbps")) }
            return .lowerBitrate(kbps: k, location: loc)
        case "convert":
            return .convert(to: try need("to").lowercased(), location: loc)
        case "crop":
            var spec = ""
            var longEdge = false
            if let l = a["longEdge"] { spec = l; longEdge = true }
            else if let r = a["aspectRatio"] { spec = r }
            else {
                let w = a["width"], h = a["height"]
                guard w != nil || h != nil else { throw PipelineError(L("crop needs width, height, longEdge or aspectRatio")) }
                spec = "\(w ?? "")x\(h ?? "")"
                if h == nil { spec = w! }
            }
            guard CropSpec.parse(spec, longEdge: longEdge) != nil else { throw PipelineError(L("Invalid crop size “%@”", spec)) }
            return .crop(spec: spec, longEdge: longEdge, smart: bool(a, "smartCrop") ?? false, location: loc)
        case "extractPagesAsImages":
            return .extractPagesAsImages(format: a["format"] ?? "jpeg", quality: a["quality"] ?? "medium", location: loc)
        case "targetSize":
            guard let b = Files.parseSize(try need("size")), b > 0 else { throw PipelineError(L("Invalid size")) }
            return .targetSize(bytes: b, location: loc)
        case "stripExif": return .stripExif
        case "watermark":
            return .watermark(image: try need("image"), position: WatermarkPosition(rawValue: a["position"] ?? "bottomRight") ?? .bottomRight,
                              opacity: min(max(double(a, "opacity") ?? 1, 0), 1), scale: min(max(double(a, "scale") ?? 0.15, 0.01), 1), location: loc)
        case "removeAudio": return .removeAudio
        case "changeSpeed":
            guard let f = double(a, "factor"), f > 0 else { throw PipelineError(L("changeSpeed needs a factor")) }
            return .changeSpeed(factor: f, frames: a["frames"])
        case "capFps":
            guard let f = double(a, "fps"), f > 0 else { throw PipelineError(L("capFps needs fps")) }
            return .capFps(f)
        case "normalize": return .normalize(lufs: double(a, "lufs") ?? -16)
        case "if", "ifNot":
            var c = Condition()
            c.regex = a["regex"]
            c.types = (a["types"] ?? "").split(whereSeparator: { $0 == " " || $0 == "," }).map { Media.canonical(String($0)) }
            c.nameContains = a["nameContains"]; c.nameIs = a["nameIs"]
            c.fileSizeGreaterThan = a["fileSizeGreaterThan"].flatMap { Int64($0) }
            c.fileSizeLowerThan = a["fileSizeLowerThan"].flatMap { Int64($0) }
            c.minFileSize = a["minFileSize"].flatMap(Files.parseSize)
            c.widthGreaterThan = int(a, "widthGreaterThan"); c.widthLowerThan = int(a, "widthLowerThan")
            c.heightGreaterThan = int(a, "heightGreaterThan"); c.heightLowerThan = int(a, "heightLowerThan")
            c.minResolution = a["minResolution"]
            c.dpiGreaterThan = int(a, "dpiGreaterThan"); c.dpiLowerThan = int(a, "dpiLowerThan")
            c.copiedBy = a["copiedBy"]
            if let r = c.regex, (try? NSRegularExpression(pattern: r)) == nil { throw PipelineError(L("Invalid regular expression “%@”", r)) }
            return .filter(c, invert: name == "ifNot")
        case "copy": return .copy(to: try need("to"))
        case "move": return .move(to: try need("to"))
        case "rename": return .rename(to: try need("to"))
        case "delete": return .delete(path: try need("path"))
        case "runScript":
            if let c = a["code"] { return .runScript(c, isCode: true) }
            return .runScript(try need("path"), isCode: false)
        case "runShortcut": return .runShortcut(try need("name"))
        case "copyToClipboard": return .copyToClipboard(format: a["format"] ?? "path", relativeTo: a["relativeTo"])
        case "copyLinkForSending": throw PipelineError(L("Secure sending is not available in Shrinkbox"))
        case "fork": return .fork(location: loc)
        case "openWith": return .openWith(try need("app"))
        case "shelveWith": return .shelveWith(try need("app"))
        case "uploadWith": return .uploadWith(try need("app"))
        default: throw PipelineError(L("Unknown step “%@”", name))
        }
    }

    /// The text form of a pipeline, parsed back by `parse`.
    static func describe(_ p: Pipeline) -> String { p.steps.map(describe).joined(separator: " -> ") }

    static func describe(_ s: Step) -> String {
        func args(_ pairs: [(String, String?)]) -> String {
            let list = pairs.compactMap { k, v in v.map { "\(k): \($0)" } }
            return list.isEmpty ? "" : "(" + list.joined(separator: ", ") + ")"
        }
        func q(_ v: String) -> String { "\"\(v)\"" }
        switch s {
        case .optimise(let e, let c, let ad, let d, let l): return "optimise" + args([("encoder", e), ("compression", c), ("adaptive", ad.map { String($0) }), ("dpi", d.map(String.init)), ("location", l.map(q))])
        case .downscale(let f, let l): return "downscale" + args([("factor", String(f)), ("location", l.map(q))])
        case .lowerBitrate(let k, let l): return "lowerBitrate" + args([("kbps", String(k)), ("location", l.map(q))])
        case .convert(let t, let l): return "convert" + args([("to", t), ("location", l.map(q))])
        case .crop(let spec, let long, let smart, let l):
            let key = long ? "longEdge" : (spec.contains(":") ? "aspectRatio" : "width")
            var pairs: [(String, String?)] = []
            if !long, !spec.contains(":"), spec.contains("x") {
                let p = spec.split(separator: "x", omittingEmptySubsequences: false)
                pairs = [("width", p[0].isEmpty ? nil : String(p[0])), ("height", p.count > 1 && !p[1].isEmpty ? String(p[1]) : nil)]
            } else { pairs = [(key, spec)] }
            return "crop" + args(pairs + [("smartCrop", smart ? "true" : nil), ("location", l.map(q))])
        case .extractPagesAsImages(let f, let qlt, let l): return "extractPagesAsImages" + args([("format", f), ("quality", qlt), ("location", l.map(q))])
        case .targetSize(let b, let l): return "targetSize" + args([("size", String(b)), ("location", l.map(q))])
        case .stripExif: return "stripExif"
        case .watermark(let i, let p, let o, let sc, let l): return "watermark" + args([("image", q(i)), ("position", p.rawValue), ("opacity", String(o)), ("scale", String(sc)), ("location", l.map(q))])
        case .removeAudio: return "removeAudio"
        case .changeSpeed(let f, let fr): return "changeSpeed" + args([("factor", String(f)), ("frames", fr)])
        case .capFps(let f): return "capFps" + args([("fps", String(f))])
        case .normalize(let l): return "normalize" + args([("lufs", String(l))])
        case .filter(let c, let inv):
            var pairs: [(String, String?)] = [("regex", c.regex.map(q)), ("types", c.types.isEmpty ? nil : c.types.joined(separator: " ")), ("nameContains", c.nameContains.map(q)), ("nameIs", c.nameIs.map(q)),
                                              ("fileSizeGreaterThan", c.fileSizeGreaterThan.map(String.init)), ("fileSizeLowerThan", c.fileSizeLowerThan.map(String.init)),
                                              ("minFileSize", c.minFileSize.map(String.init)), ("widthGreaterThan", c.widthGreaterThan.map(String.init)), ("widthLowerThan", c.widthLowerThan.map(String.init)),
                                              ("heightGreaterThan", c.heightGreaterThan.map(String.init)), ("heightLowerThan", c.heightLowerThan.map(String.init)), ("minResolution", c.minResolution),
                                              ("dpiGreaterThan", c.dpiGreaterThan.map(String.init)), ("dpiLowerThan", c.dpiLowerThan.map(String.init)), ("copiedBy", c.copiedBy.map(q))]
            pairs = pairs.filter { $0.1 != nil }
            return (inv ? "ifNot" : "if") + args(pairs)
        case .copy(let t): return "copy" + args([("to", q(t))])
        case .move(let t): return "move" + args([("to", q(t))])
        case .rename(let t): return "rename" + args([("to", q(t))])
        case .delete(let p): return "delete" + args([("path", q(p))])
        case .runScript(let c, let isCode): return "runScript" + args([(isCode ? "code" : "path", q(c))])
        case .runShortcut(let n): return "runShortcut" + args([("name", q(n))])
        case .copyToClipboard(let f, let r): return "copyToClipboard" + args([("format", f), ("relativeTo", r.map(q))])
        case .fork(let l): return "fork" + args([("location", l.map(q))])
        case .openWith(let a): return "openWith" + args([("app", q(a))])
        case .shelveWith(let a): return "shelveWith" + args([("app", q(a))])
        case .uploadWith(let a): return "uploadWith" + args([("app", q(a))])
        }
    }
}

import Foundation
import AVFoundation
import CoreMedia
import ImageIO
import UniformTypeIdentifiers

enum VideoEncoder: String, Sendable {
    case hardware      // H.264 on the media engine: fast, larger
    case software      // x264/x265 through ffmpeg: slow, smaller
    case visuallyLossless
}

enum VideoCodec: String, Sendable {
    case h264, hevc, av1, vp9
}

struct VideoJob: Sendable {
    var level: Level = .value(50)
    var encoder: VideoEncoder = .hardware
    var codec: VideoCodec = .h264
    var downscale: Double?
    var crop: CropSpec?
    var removeAudio = false
    var speed: Double?
    var keepFrames = true
    var capFPS: Double?
    var minFPS: Double = 30
    var targetExtension: String?
    var stripMetadata = true
    var audioToAAC = false
    var targetBytes: Int64?
    /// Fraction of the bitrate budget to use: lowered by retries that must fit under a size.
    var budgetScale = 1.0
}

enum VideoEngine {
    static func canRead(_ ext: String) -> Bool { ["mp4", "mov", "m4v"].contains(ext.lowercased()) }

    static func process(_ src: URL, job: VideoJob, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let ext = (job.targetExtension ?? src.pathExtension).lowercased()
        if ext == "gif" { return try await toGIF(src, job: job, progress: progress) }
        let needsFFmpeg = !canRead(src.pathExtension) || job.encoder == .software || ["webm", "mkv", "avi", "mpg", "m2v"].contains(ext) || job.codec == .av1 || job.codec == .vp9
        if needsFFmpeg {
            return try await withFFmpeg(src, job: job, ext: ext, progress: progress)
        }
        return try await native(src, job: job, ext: ext, progress: progress)
    }

    // MARK: AVFoundation

    static func native(_ src: URL, job: VideoJob, ext: String, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        let asset = AVURLAsset(url: src)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let vTrack = tracks.first else { throw ShrinkError.unsupported(L("No video track in %@", src.lastPathComponent)) }
        let duration = try await asset.load(.duration)
        let natural = try await vTrack.load(.naturalSize)
        let transform = try await vTrack.load(.preferredTransform)
        let sourceFPS = Double(try await vTrack.load(.nominalFrameRate))
        let estimatedRate = Double(try await vTrack.load(.estimatedDataRate))
        let displayRect = CGRect(origin: .zero, size: natural).applying(transform)
        let display = (Int(abs(displayRect.width).rounded()), Int(abs(displayRect.height).rounded()))

        // Composition: the speed change lives here.
        let comp = AVMutableComposition()
        let full = CMTimeRange(start: .zero, duration: duration)
        guard let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw ShrinkError.failed(L("Cannot read the video")) }
        try cv.insertTimeRange(full, of: vTrack, at: .zero)
        let audioTracks = job.removeAudio ? [] : try await asset.loadTracks(withMediaType: .audio)
        var compAudio: [AVMutableCompositionTrack] = []
        for t in audioTracks {
            if let c = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) { try c.insertTimeRange(full, of: t, at: .zero); compAudio.append(c) }
        }
        var outDuration = duration
        if let s = job.speed, s > 0, s != 1 {
            outDuration = CMTimeMultiplyByFloat64(duration, multiplier: 1 / s)
            comp.scaleTimeRange(full, toDuration: outDuration)
        }

        // Geometry: crop region and output size, even numbers for the encoder.
        var region = CGRect(x: 0, y: 0, width: display.0, height: display.1)
        var outSize = display
        if let crop = job.crop, let p = ImageEngine.plan(crop, for: display) {
            region = p.region; outSize = p.output
            region.origin.x = (Double(display.0) - region.width) / 2
            region.origin.y = (Double(display.1) - region.height) / 2
        }
        if let f = job.downscale, f > 0, f < 1 { outSize = (max(2, Int(Double(outSize.0) * f)), max(2, Int(Double(outSize.1) * f))) }
        outSize = (outSize.0 & ~1, outSize.1 & ~1)
        outSize = (max(2, outSize.0), max(2, outSize.1))

        // Frame rate: a faster playback raises it unless frames are dropped.
        var fps = sourceFPS > 0 ? sourceFPS : 30
        if let s = job.speed, s > 1, job.keepFrames { fps *= s }
        let cap = job.capFPS ?? 0
        if cap > 0 { fps = min(fps, max(cap, job.minFPS)) }
        fps = min(max(fps, 1), 120)

        let videoComp = AVMutableVideoComposition()
        videoComp.renderSize = CGSize(width: outSize.0, height: outSize.1)
        videoComp.frameDuration = CMTime(value: 1000, timescale: CMTimeScale(max(1, fps * 1000)))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: outDuration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: cv)
        let scaleX = Double(outSize.0) / region.width, scaleY = Double(outSize.1) / region.height
        let t = transform.concatenating(CGAffineTransform(translationX: -region.minX, y: -region.minY)).concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))
        layer.setTransform(t, at: .zero)
        instruction.layerInstructions = [layer]
        videoComp.instructions = [instruction]

        // Reader.
        let reader = try AVAssetReader(asset: comp)
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: [cv], videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        vOut.videoComposition = videoComp
        guard reader.canAdd(vOut) else { throw ShrinkError.failed(L("Cannot read the video")) }
        reader.add(vOut)
        var aOut: AVAssetReaderAudioMixOutput?
        if !compAudio.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: compAudio, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                                                                                         AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            o.audioTimePitchAlgorithm = .spectral
            if reader.canAdd(o) { reader.add(o); aOut = o }
        }

        // Writer.
        let fileType: AVFileType = ext == "mov" ? .mov : (ext == "m4v" ? .m4v : .mp4)
        let out = Workspace.temp(ext: ext, name: src.deletingPathExtension().lastPathComponent)
        let writer = try AVAssetWriter(outputURL: out, fileType: fileType)
        let seconds = max(0.1, CMTimeGetSeconds(outDuration))
        let bitrate = Self.bitrate(job: job, size: outSize, fps: fps, sourceRate: estimatedRate, seconds: seconds)
        let codecKey: AVVideoCodecType = (job.codec == .hevc || job.encoder == .visuallyLossless) ? .hevc : .h264
        var compression: [String: Any] = [AVVideoAverageBitRateKey: bitrate, AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()), AVVideoMaxKeyFrameIntervalKey: Int(fps.rounded()) * 4]
        if codecKey == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        if job.encoder == .visuallyLossless { compression[AVVideoQualityKey] = 0.9; compression[AVVideoAverageBitRateKey] = nil }
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: codecKey, AVVideoWidthKey: outSize.0, AVVideoHeightKey: outSize.1, AVVideoCompressionPropertiesKey: compression])
        vIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn) else { throw ShrinkError.failed(L("Cannot encode the video")) }
        writer.add(vIn)
        var aIn: AVAssetWriterInput?
        if aOut != nil {
            let abr = job.level.strength > 0.6 ? 96_000 : 128_000
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2, AVSampleRateKey: 44_100, AVEncoderBitRateKey: abr])
            i.expectsMediaDataInRealTime = false
            if writer.canAdd(i) { writer.add(i); aIn = i }
        }
        if !job.stripMetadata { writer.metadata = try await asset.load(.metadata) }

        guard reader.startReading() else { throw ShrinkError.failed(reader.error?.localizedDescription ?? L("Cannot read the video")) }
        guard writer.startWriting() else { throw ShrinkError.failed(writer.error?.localizedDescription ?? L("Cannot encode the video")) }
        writer.startSession(atSourceTime: .zero)

        try await pump(reader: reader, writer: writer, video: (vOut, vIn), audio: aOut.flatMap { o in aIn.map { (o, $0) } }, seconds: seconds, progress: progress)
        return out
    }

    /// Average bitrate in bits per second: bits per pixel scale with the level; a size target sets it directly.
    static func bitrate(job: VideoJob, size: (Int, Int), fps: Double, sourceRate: Double, seconds: Double) -> Int {
        if let target = job.targetBytes {
            let audio = job.removeAudio ? 0 : 96_000.0
            return max(80_000, Int((Double(target) * 8 / seconds - audio) * 0.93 * job.budgetScale))
        }
        let pixels = Double(size.0 * size.1)
        let bpp: Double
        switch job.level {
        case .lossless: bpp = 0.30
        case .adaptive: bpp = 0.10
        case .value(let n): bpp = 0.24 - 0.20 * Double(min(max(n, 0), 100)) / 100   // 5 -> 0.23, 100 -> 0.04
        }
        var rate = pixels * fps * bpp * (job.codec == .hevc ? 0.65 : 1)
        // Never ask for more than the source had.
        if sourceRate > 0 { rate = min(rate, sourceRate * 0.9) }
        return max(150_000, Int(rate * job.budgetScale))
    }

    private static func pump(reader: AVAssetReader, writer: AVAssetWriter, video: (AVAssetReaderOutput, AVAssetWriterInput), audio: (AVAssetReaderOutput, AVAssetWriterInput)?, seconds: Double, progress: (@Sendable (Double) -> Void)?) async throws {
        let pump = Pump(reader: reader, writer: writer)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let group = DispatchGroup()
                func feed(_ output: AVAssetReaderOutput, _ input: AVAssetWriterInput, label: String, reportsProgress: Bool) {
                    group.enter()
                    let queue = DispatchQueue(label: "shrinkbox.\(label)")
                    input.requestMediaDataWhenReady(on: queue) {
                        while input.isReadyForMoreMediaData {
                            if pump.cancelled { input.markAsFinished(); group.leave(); return }
                            if let sample = output.copyNextSampleBuffer() {
                                if reportsProgress { progress?(min(1, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) / seconds)) }
                                if !input.append(sample) { input.markAsFinished(); group.leave(); return }
                            } else { input.markAsFinished(); group.leave(); return }
                        }
                    }
                }
                feed(video.0, video.1, label: "video", reportsProgress: true)
                if let a = audio { feed(a.0, a.1, label: "audio", reportsProgress: false) }
                group.notify(queue: .global()) {
                    if pump.cancelled { writer.cancelWriting(); c.resume(throwing: ShrinkError.cancelled); return }
                    if reader.status == .failed { writer.cancelWriting(); c.resume(throwing: ShrinkError.failed(reader.error?.localizedDescription ?? L("Cannot read the video"))); return }
                    writer.finishWriting {
                        if writer.status == .completed { progress?(1); c.resume() }
                        else { c.resume(throwing: ShrinkError.failed(writer.error?.localizedDescription ?? L("Cannot encode the video"))) }
                    }
                }
            }
        } onCancel: { pump.cancel() }
    }

    // MARK: ffmpeg

    static func withFFmpeg(_ src: URL, job: VideoJob, ext: String, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        let ff = try Tools.require(.ffmpeg, for: L("to read this video format or use software encoders"))
        let out = Workspace.temp(ext: ext, name: src.deletingPathExtension().lastPathComponent)
        var args = ["-y", "-hide_banner", "-loglevel", "error", "-progress", "pipe:1", "-i", src.path]
        var filters: [String] = []
        if let crop = job.crop { filters.append(ffmpegCrop(crop)) }
        if let f = job.downscale, f < 1 { filters.append("scale=trunc(iw*\(f)/2)*2:trunc(ih*\(f)/2)*2") }
        if let s = job.speed, s != 1 { filters.append("setpts=PTS/\(s)") }
        if let cap = job.capFPS, cap > 0 { filters.append("fps=fps=\(cap):round=down") }
        if !filters.isEmpty { args += ["-vf", filters.joined(separator: ",")] }
        let crf = Int(35 - 17 * job.level.strength + (job.level == .lossless ? -10 : 0))   // 18 ... 35
        switch job.codec {
        case .h264: args += ["-c:v", job.encoder == .hardware ? "h264_videotoolbox" : "libx264", job.encoder == .hardware ? "-q:v" : "-crf", job.encoder == .hardware ? String(max(20, 100 - Int(job.level.strength * 60))) : String(crf), "-pix_fmt", "yuv420p"]
        case .hevc: args += ["-c:v", job.encoder == .hardware ? "hevc_videotoolbox" : "libx265", job.encoder == .hardware ? "-q:v" : "-crf", job.encoder == .hardware ? String(max(20, 100 - Int(job.level.strength * 60))) : String(crf + 4), "-tag:v", "hvc1", "-pix_fmt", "yuv420p"]
        case .av1: args += ["-c:v", "libsvtav1", "-crf", String(crf + 10), "-pix_fmt", "yuv420p"]
        case .vp9: args += ["-c:v", "libvpx-vp9", "-crf", String(crf + 5), "-b:v", "0", "-pix_fmt", "yuv420p"]
        }
        if let t = job.targetBytes, let d = try? await AVURLAsset(url: src).load(.duration), CMTimeGetSeconds(d) > 0 {
            let rate = Int((Double(t) * 8 / CMTimeGetSeconds(d)) * 0.92 * job.budgetScale)
            args += ["-b:v", String(max(80_000, rate)), "-maxrate", String(max(80_000, rate)), "-bufsize", String(max(160_000, rate * 2))]
        }
        if job.removeAudio { args.append("-an") }
        else if ext == "webm" { args += ["-c:a", "libopus", "-b:a", "96k"] }
        else { args += ["-c:a", "aac", "-b:a", job.level.strength > 0.6 ? "96k" : "128k"] }
        if let s = job.speed, s != 1, !job.removeAudio { args += ["-af", atempoChain(s)] }
        if job.stripMetadata { args += ["-map_metadata", "-1"] }
        if ext == "mp4" || ext == "mov" || ext == "m4v" { args += ["-movflags", "+faststart"] }
        args.append(out.path)
        let r = try await Run.process(ff, args)
        guard r.status == 0 else { throw ShrinkError.failed(r.error.isEmpty ? L("ffmpeg failed") : String(r.error.suffix(300))) }
        progress?(1)
        return out
    }

    static func ffmpegCrop(_ c: CropSpec) -> String {
        if let a = c.aspect { return "crop='if(gt(iw/ih,\(a)),ih*\(a),iw)':'if(gt(iw/ih,\(a)),ih,iw/\(a))'" }
        if let l = c.longEdge { return "scale='if(gt(iw,ih),min(\(l),iw),-2)':'if(gt(iw,ih),-2,min(\(l),ih))'" }
        if let w = c.width, let h = c.height { return "scale=\(w):\(h):force_original_aspect_ratio=increase,crop=\(w):\(h)" }
        if let w = c.width { return "scale='min(\(w),iw)':-2" }
        if let h = c.height { return "scale=-2:'min(\(h),ih)'" }
        return "null"
    }

    /// atempo accepts 0.5...2 per instance.
    static func atempoChain(_ s: Double) -> String {
        var parts: [String] = []
        var rest = s
        while rest > 2 { parts.append("atempo=2.0"); rest /= 2 }
        while rest < 0.5 { parts.append("atempo=0.5"); rest /= 0.5 }
        parts.append("atempo=\(rest)")
        return parts.joined(separator: ",")
    }

    // MARK: GIF

    static func toGIF(_ src: URL, job: VideoJob, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        let asset = AVURLAsset(url: src)
        if !canRead(src.pathExtension) {
            guard Tool.ffmpeg.available else { throw ShrinkError.missingTool("ffmpeg", L("to read this video format")) }
            var j = job; j.targetExtension = "mp4"
            let mp4 = try await withFFmpeg(src, job: j, ext: "mp4", progress: nil)
            return try await toGIF(mp4, job: job, progress: progress)
        }
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        let fps = min(job.capFPS ?? 15, 15)
        let count = max(1, min(Int(duration * fps), 450))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        var maxWidth = 800.0
        if let f = job.downscale, f < 1 { maxWidth = max(64, 800 * f) }
        gen.maximumSize = CGSize(width: maxWidth, height: 0)
        let out = Workspace.temp(ext: "gif", name: src.deletingPathExtension().lastPathComponent)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, "com.compuserve.gif" as CFString, count, nil) else { throw ShrinkError.failed(L("Cannot write the GIF")) }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for i in 0..<count {
            try Task.checkCancellation()
            let time = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            guard let result = try? await gen.image(at: time) else { continue }
            var image = result.image
            if let c = job.crop { image = (try? ImageEngine.apply(c, to: image)) ?? image }
            CGImageDestinationAddImage(dest, image, frameProps)
            progress?(Double(i + 1) / Double(count))
        }
        guard CGImageDestinationFinalize(dest) else { throw ShrinkError.failed(L("Cannot write the GIF")) }
        if let g = Tool.gifsicle.url {
            let tmp = Workspace.temp(ext: "gif", name: "opt")
            let r = try await Run.process(g, ["-O3", "--lossy=\(Int(job.level.strength * 80))", out.path, "-o", tmp.path])
            if r.status == 0, Files.size(tmp) > 0, Files.size(tmp) < Files.size(out) { try? FileManager.default.removeItem(at: out); try FileManager.default.moveItem(at: tmp, to: out) }
        }
        return out
    }

    // MARK: Metadata

    /// A copy without metadata, re-muxed without re-encoding.
    static func stripMetadata(_ src: URL) async throws -> URL {
        let asset = AVURLAsset(url: src)
        let ext = src.pathExtension.lowercased()
        guard canRead(ext), let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            guard let ff = Tool.ffmpeg.url else { throw ShrinkError.missingTool("ffmpeg", L("to read this video format")) }
            let out = Workspace.temp(ext: ext, name: src.deletingPathExtension().lastPathComponent)
            let r = try await Run.process(ff, ["-y", "-loglevel", "error", "-i", src.path, "-map", "0", "-c", "copy", "-map_metadata", "-1", out.path])
            guard r.status == 0 else { throw ShrinkError.failed(String(r.error.suffix(300))) }
            return out
        }
        let out = Workspace.temp(ext: ext, name: src.deletingPathExtension().lastPathComponent)
        session.metadata = []
        session.shouldOptimizeForNetworkUse = true
        try await session.export(to: out, as: ext == "mov" ? .mov : (ext == "m4v" ? .m4v : .mp4))
        return out
    }
}

/// Lets a cancelled task stop the reader and the writer loops.
private final class Pump: @unchecked Sendable {
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let lock = NSLock()
    private var flag = false
    init(reader: AVAssetReader, writer: AVAssetWriter) { self.reader = reader; self.writer = writer }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock(); reader.cancelReading() }
}

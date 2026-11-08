import Foundation
import AVFoundation
import AudioToolbox
import AppKit
import ImageIO

struct AudioJob: Sendable {
    var level: Level = .value(34)
    var bitrateKbps: Int?
    var targetExtension: String?
    var speed: Double?
    var normalizeLUFS: Double?
    var coverArt: String = "optimise"   // optimise | remove | keep
    var stripMetadata = true
    var downscale: Double?              // applied to the bitrate
}

enum AudioEngine {
    static let lossless: Set<String> = ["wav", "aiff", "flac", "caf"]
    static let bitrates = [320, 256, 192, 160, 128, 112, 96, 80, 64, 48, 32]

    /// The bitrate a level gives, snapped to a normal value. Bitrates are never raised.
    static func bitrate(for level: Level, source: Int?, factor: Double?, explicit: Int?) -> Int {
        var kbps: Double
        if let e = explicit { kbps = Double(e) }
        else {
            switch level {
            case .lossless: kbps = 320
            case .adaptive: kbps = 128
            case .value(let n): kbps = 256 - 200 * Double(min(max(n, 0), 100)) / 100   // 5 -> 246, 100 -> 56
            }
            if let f = factor { kbps = Double(source ?? 192) * f }
        }
        if let s = source, s > 0 { kbps = min(kbps, Double(s)) }
        return bitrates.min { abs(Double($0) - kbps) < abs(Double($1) - kbps) } ?? 128
    }

    static func sourceBitrate(_ url: URL) async -> Int? {
        let asset = AVURLAsset(url: url)
        guard let t = try? await asset.loadTracks(withMediaType: .audio).first, let r = try? await t.load(.estimatedDataRate), r > 0 else { return nil }
        return Int(r / 1000)
    }

    static func process(_ src: URL, job: AudioJob, progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let srcExt = Media.canonical(src.pathExtension)
        let ext = Media.canonical(job.targetExtension ?? src.pathExtension)
        let asset = AVURLAsset(url: src)
        let readable = ((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty == false
        let native = ["m4a", "aac", "wav", "aiff", "flac", "caf"].contains(ext) && (readable)
        if !native || ["mp3", "ogg"].contains(ext) || (["mp3", "ogg"].contains(srcExt) && !readable) {
            return try await withFFmpeg(src, ext: ext, job: job)
        }
        let source = await sourceBitrate(src)
        let kbps = bitrate(for: job.level, source: source, factor: job.downscale, explicit: job.bitrateKbps)

        let composition = AVMutableComposition()
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)
        guard let track = tracks.first, let ct = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw ShrinkError.unsupported(L("No audio track in %@", src.lastPathComponent)) }
        try ct.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        var outDuration = duration
        if let s = job.speed, s > 0, s != 1 {
            outDuration = CMTimeMultiplyByFloat64(duration, multiplier: 1 / s)
            composition.scaleTimeRange(CMTimeRange(start: .zero, duration: duration), toDuration: outDuration)
        }
        let gain = try await normalizationGain(src, lufs: job.normalizeLUFS)

        let reader = try AVAssetReader(asset: composition)
        let mix = AVMutableAudioMix()
        if gain != 1 {
            let p = AVMutableAudioMixInputParameters(track: ct)
            p.setVolume(Float(gain), at: .zero)
            mix.inputParameters = [p]
        }
        let out = Workspace.temp(ext: ext, name: src.deletingPathExtension().lastPathComponent)
        let fileType: AVFileType = switch ext { case "wav": .wav; case "aiff": .aiff; case "caf": .caf; case "flac": AVFileType(rawValue: "org.xiph.flac"); case "aac": .m4a; default: .m4a }
        let writer = try AVAssetWriter(outputURL: out, fileType: fileType)
        var settings: [String: Any]
        let rate = 44_100.0
        switch ext {
        case "wav": settings = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2]
        case "aiff": settings = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2]
        case "caf": settings = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2]
        case "flac": settings = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2]
        default: settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: kbps * 1000]
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw ShrinkError.unsupported(L("Shrinkbox cannot write %@ files", ext.uppercased())) }
        writer.add(input)
        // All the tags when metadata is kept; only the cover art otherwise, unless it is to be removed.
        if job.coverArt != "remove" {
            let all = try await asset.load(.metadata)
            if job.coverArt == "optimise" { writer.metadata = (job.stripMetadata ? [] : all.filter { $0.commonKey != .commonKeyArtwork }) + (await optimisedArtwork(all)) }
            else { writer.metadata = job.stripMetadata && job.coverArt != "keep" ? all.filter { $0.commonKey == .commonKeyArtwork } : all }
        }

        let outputSettings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let output = AVAssetReaderAudioMixOutput(audioTracks: [ct], audioSettings: outputSettings)
        output.audioMix = gain != 1 ? mix : nil
        output.audioTimePitchAlgorithm = .spectral
        guard reader.canAdd(output) else { throw ShrinkError.failed(L("Cannot read the audio")) }
        reader.add(output)
        guard reader.startReading(), writer.startWriting() else { throw ShrinkError.failed(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? L("Cannot encode the audio")) }
        writer.startSession(atSourceTime: .zero)
        let seconds = max(0.1, CMTimeGetSeconds(outDuration))
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "shrinkbox.audio")
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if let sample = output.copyNextSampleBuffer() {
                        progress?(min(1, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) / seconds))
                        if !input.append(sample) { break }
                    } else {
                        input.markAsFinished()
                        writer.finishWriting {
                            if writer.status == .completed { c.resume() }
                            else { c.resume(throwing: ShrinkError.failed(writer.error?.localizedDescription ?? L("Cannot encode the audio"))) }
                        }
                        return
                    }
                }
            }
        }
        return out
    }

    /// The linear gain that brings a file's average level to the target loudness. This is an RMS estimate, not a
    /// full EBU R128 measurement.
    static func normalizationGain(_ url: URL, lufs: Double?) async throws -> Double {
        guard let target = lufs, let file = try? AVAudioFile(forReading: url) else { return 1 }
        let format = file.processingFormat
        let capacity: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return 1 }
        var sum = 0.0, count = 0.0
        var peak: Float = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: capacity)
            guard let data = buffer.floatChannelData else { break }
            for c in 0..<Int(format.channelCount) {
                for i in 0..<Int(buffer.frameLength) { let v = data[c][i]; sum += Double(v * v); count += 1; peak = max(peak, abs(v)) }
            }
        }
        guard count > 0, sum > 0 else { return 1 }
        let rmsDB = 10 * log10(sum / count)
        let currentLUFS = rmsDB - 0.7   // close to the K-weighted figure for music and speech
        var gain = pow(10, (target - currentLUFS) / 20)
        if peak > 0 { gain = min(gain, Double(0.98 / peak)) }   // never clip
        return gain
    }

    /// The cover art of a file, saved next to it as a JPEG ("song cover.jpg"), or nil when it has none.
    static func extractCover(_ url: URL) async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata) else { return nil }
        for item in items where item.commonKey == .commonKeyArtwork || item.identifier == .commonIdentifierArtwork || (item.identifier?.rawValue.contains("covr") ?? false) {
            guard let data = try? await item.load(.dataValue), let image = NSImage(data: data), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let out = Files.uniqueURL(url.deletingPathExtension().deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + " cover.jpg"))
            if (try? ImageEngine.writeImageIO(cg, type: "public.jpeg", properties: [:], quality: 0.92, to: out)) != nil { return out }
        }
        return nil
    }

    /// Cover art recompressed as a JPEG of at most 1000 px, the way "optimise" treats it.
    static func optimisedArtwork(_ items: [AVMetadataItem]) async -> [AVMetadataItem] {
        var out: [AVMetadataItem] = []
        for item in items where item.commonKey == .commonKeyArtwork {
            guard let data = try? await item.load(.dataValue), let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1000] as CFDictionary) else { out.append(item); continue }
            let mutable = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(mutable, "public.jpeg" as CFString, 1, nil) else { out.append(item); continue }
            CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            guard CGImageDestinationFinalize(dest), mutable.length < data.count else { out.append(item); continue }
            let m = AVMutableMetadataItem()
            m.identifier = .commonIdentifierArtwork
            m.dataType = kCMMetadataBaseDataType_JPEG as String
            m.value = mutable as Data as NSData
            out.append(m)
        }
        return out
    }

    static func withFFmpeg(_ src: URL, ext: String, job: AudioJob) async throws -> URL {
        let ff = try Tools.require(.ffmpeg, for: L("to read or write %@ audio", ext.uppercased()))
        let out = Workspace.temp(ext: ext, name: src.deletingPathExtension().lastPathComponent)
        let kbps = bitrate(for: job.level, source: await sourceBitrate(src), factor: job.downscale, explicit: job.bitrateKbps)
        var args = ["-y", "-loglevel", "error", "-i", src.path, "-vn"]
        switch ext {
        case "mp3": args += ["-c:a", "libmp3lame", "-b:a", "\(kbps)k"]
        case "ogg": args += ["-c:a", "libvorbis", "-b:a", "\(kbps)k"]
        case "flac": args += ["-c:a", "flac"]
        case "wav": args += ["-c:a", "pcm_s16le"]
        case "aiff": args += ["-c:a", "pcm_s16be"]
        default: args += ["-c:a", "aac", "-b:a", "\(kbps)k"]
        }
        var filters: [String] = []
        if let s = job.speed, s != 1 { filters.append(VideoEngine.atempoChain(s)) }
        if let l = job.normalizeLUFS { filters.append("loudnorm=I=\(l):TP=-1.5:LRA=11") }
        if !filters.isEmpty { args += ["-af", filters.joined(separator: ",")] }
        if job.stripMetadata { args += ["-map_metadata", "-1"] }
        if job.coverArt == "keep" || job.coverArt == "optimise" { args = ["-y", "-loglevel", "error", "-i", src.path] + args.dropFirst(5).filter { $0 != "-vn" } }
        args.append(out.path)
        let r = try await Run.process(ff, args)
        guard r.status == 0 else { throw ShrinkError.failed(String(r.error.suffix(300))) }
        return out
    }
}

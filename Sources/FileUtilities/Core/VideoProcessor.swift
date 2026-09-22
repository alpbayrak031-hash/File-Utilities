import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

enum VideoCodec: String, CaseIterable, Identifiable {
    case hevc = "HEVC (H.265)"
    case h264 = "H.264"
    var id: Self { self }
}

enum VideoContainer: String, CaseIterable, Identifiable {
    case mp4, mov, m4v, mkv, webm, avi, gif, flv, wmv, mpg, ts, ogv
    case threeGP = "3gp"
    var id: Self { self }

    var ext: String { rawValue }
    var title: String {
        switch self {
        case .mp4: "MP4"
        case .mov: "MOV (QuickTime)"
        case .m4v: "M4V"
        case .gif: "GIF (animated)"
        case .mkv: "MKV (Matroska)"
        case .webm: "WebM"
        case .avi: "AVI"
        case .flv: "FLV"
        case .wmv: "WMV"
        case .mpg: "MPEG-2 (.mpg)"
        case .ts: "MPEG-TS (.ts)"
        case .ogv: "OGV (Theora)"
        case .threeGP: "3GP"
        }
    }
    /// Writable with Apple frameworks (no ffmpeg needed).
    var isNative: Bool { [.mp4, .mov, .m4v, .gif].contains(self) }
    var fileType: AVFileType? {
        switch self {
        case .mp4: .mp4
        case .mov: .mov
        case .m4v: .m4v
        default: nil
        }
    }

    static func fileType(forExtension ext: String) -> AVFileType? {
        switch ext.lowercased() {
        case "mp4": .mp4
        case "mov", "qt": .mov
        case "m4v": .m4v
        default: nil
        }
    }
}

enum VideoConvertMode: String, CaseIterable, Identifiable {
    case auto = "Auto (lossless copy when possible)"
    case hevc = "Re-encode HEVC"
    case h264 = "Re-encode H.264"
    var id: Self { self }
}

struct VideoEncodeSettings {
    var codec: VideoCodec = .hevc
    /// Target bits per pixel per frame; nil keeps the source's bits-per-pixel.
    var bitsPerPixel: Double?
    /// Upper bound relative to the source bitrate.
    var maxBitrateFraction: Double?
    var fileType: AVFileType = .mp4
    var transform = MediaTransform()
    var timeRange: CMTimeRange?
    var includeAudio = true
    var audioBitrate = 160_000
    var stripMetadata = false
}

enum VideoProcessor {
    static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func canReadNatively(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isReadable)) == true else { return false }
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        return !tracks.isEmpty
    }

    static func hasAudioNatively(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isReadable)) == true else { return false }
        return !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty
    }

    // MARK: Transcode (compress / resize / rotate / re-encode)

    static func transcode(_ src: URL, to dst: URL, settings: VideoEncodeSettings, progress: ProgressHandler?) async throws {
        let asset = AVURLAsset(url: src, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw AppError("No video track found")
        }
        let audioTrack = settings.includeAudio ? try await asset.loadTracks(withMediaType: .audio).first : nil
        let (naturalSize, preferred, nominalFPS, dataRate, formats) = try await videoTrack.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate, .formatDescriptions)
        let duration = try await asset.load(.duration)
        let range = settings.timeRange ?? CMTimeRange(start: .zero, duration: duration)

        let upright = CGRect(origin: .zero, size: naturalSize).applying(preferred)
        let uprightSize = CGSize(width: abs(upright.width), height: abs(upright.height))
        let useCI = !settings.transform.isIdentity
        let outSize = useCI ? settings.transform.outputSize(for: uprightSize, even: true)
                            : CGSize(width: floor(naturalSize.width / 2) * 2, height: floor(naturalSize.height / 2) * 2)
        let fps = nominalFPS > 0 ? Double(nominalFPS) : 30
        let format = formats.first
        let hdr = isHDR(format)
        let tenBit = hdr && settings.codec == .hevc && !useCI

        // Bitrate
        let pixelsPerSecond = Double(outSize.width * outSize.height) * fps
        let sourceBPP = dataRate > 0 ? Double(dataRate) / (Double(naturalSize.width * naturalSize.height) * fps) : 0.1
        let codecFactor = settings.codec == .h264 ? 1.5 : 1.0
        var bitrate = (settings.bitsPerPixel.map { $0 * codecFactor } ?? min(sourceBPP, 0.15 * codecFactor)) * pixelsPerSecond
        if let fraction = settings.maxBitrateFraction, dataRate > 0 {
            let scaledSource = Double(dataRate) * (Double(outSize.width * outSize.height) / Double(naturalSize.width * naturalSize.height))
            bitrate = min(bitrate, scaledSource * fraction)
        }
        bitrate = max(bitrate, 250_000)

        // Reader
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let pixelFormat = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : (useCI ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw AppError("Can't decode this video") }
        reader.add(videoOutput)

        // Writer
        let writer = try AVAssetWriter(outputURL: dst, fileType: settings.fileType)
        writer.shouldOptimizeForNetworkUse = true
        if !settings.stripMetadata {
            writer.metadata = (try? await asset.load(.metadata)) ?? []
        }

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(bitrate),
            AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
            AVVideoMaxKeyFrameIntervalKey: max(1, Int((fps * 2).rounded())),
        ]
        if settings.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        } else if tenBit {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
        }
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: settings.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outSize.width),
            AVVideoHeightKey: Int(outSize.height),
            AVVideoCompressionPropertiesKey: compression,
        ]
        let colors = (useCI || (hdr && !tenBit)) ? rec709 : colorProperties(format)
        if let colors { videoSettings[AVVideoColorPropertiesKey] = colors }
        if !writer.canApply(outputSettings: videoSettings, forMediaType: .video) {
            videoSettings[AVVideoColorPropertiesKey] = nil
            compression[AVVideoProfileLevelKey] = nil
            videoSettings[AVVideoCompressionPropertiesKey] = compression
        }
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw AppError("This video size can't be encoded as \(settings.codec.rawValue)")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        if !useCI { videoInput.transform = preferred }
        guard writer.canAdd(videoInput) else { throw AppError("Can't write video to this container") }
        writer.add(videoInput)

        let adaptor: AVAssetWriterInputPixelBufferAdaptor? = useCI ? AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outSize.width),
                kCVPixelBufferHeightKey as String: Int(outSize.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]) : nil

        // Audio
        var audioOutput: AVAssetReaderOutput?
        var audioInput: AVAssetWriterInput?
        if let audioTrack {
            let audioFormats = try await audioTrack.load(.formatDescriptions)
            let sourceFormat = audioFormats.first
            let isAAC = sourceFormat.map { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC } ?? false
            if isAAC {
                let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: sourceFormat)
                if reader.canAdd(output), writer.canAdd(input) {
                    reader.add(output); writer.add(input)
                    audioOutput = output; audioInput = input
                }
            }
            if audioInput == nil {
                let asbd = sourceFormat.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
                let rate = asbd.map { [44100.0, 48000.0].contains($0.mSampleRate) ? $0.mSampleRate : 48000 } ?? 48000
                let channels = min(2, Int(asbd?.mChannelsPerFrame ?? 2))
                let output = AVAssetReaderAudioMixOutput(audioTracks: [audioTrack], audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: rate,
                    AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ])
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: rate,
                    AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: min(settings.audioBitrate, channels == 1 ? 128_000 : 320_000),
                ]
                if writer.canApply(outputSettings: audioSettings, forMediaType: .audio) {
                    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                    if reader.canAdd(output), writer.canAdd(input) {
                        reader.add(output); writer.add(input)
                        audioOutput = output; audioInput = input
                    }
                }
            }
        }

        guard reader.startReading() else { throw reader.error ?? AppError("Couldn't read the video") }
        guard writer.startWriting() else { throw writer.error ?? AppError("Couldn't start writing") }
        writer.startSession(atSourceTime: range.start)

        let total = max(range.duration.seconds, 0.001)
        let throttle = ProgressThrottle(progress)
        let renderSpace = CGColorSpace(name: CGColorSpace.itur_709)!
        let transform = settings.transform

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let group = DispatchGroup()

                group.enter()
                var videoDone = false
                videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "video.encode")) {
                    func finish() {
                        guard !videoDone else { return }
                        videoDone = true
                        videoInput.markAsFinished()
                        group.leave()
                    }
                    while videoInput.isReadyForMoreMediaData {
                        guard reader.status == .reading, let sample = videoOutput.copyNextSampleBuffer() else { return finish() }
                        let time = CMSampleBufferGetPresentationTimeStamp(sample)
                        var ok = true
                        if let adaptor {
                            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                            let frame = transform.apply(CIImage(cvPixelBuffer: buffer).applyingVideoTransform(preferred), even: true)
                            var outBuffer: CVPixelBuffer?
                            if let pool = adaptor.pixelBufferPool {
                                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
                            }
                            guard let outBuffer else { reader.cancelReading(); return finish() }
                            ciContext.render(frame, to: outBuffer, bounds: CGRect(origin: .zero, size: outSize), colorSpace: renderSpace)
                            CVBufferSetAttachment(outBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                            CVBufferSetAttachment(outBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                            CVBufferSetAttachment(outBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                            ok = adaptor.append(outBuffer, withPresentationTime: time)
                        } else {
                            ok = videoInput.append(sample)
                        }
                        if !ok { reader.cancelReading(); return finish() }
                        throttle.report((time - range.start).seconds / total * 0.99)
                    }
                }

                if let audioInput, let audioOutput {
                    group.enter()
                    var audioDone = false
                    audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "audio.encode")) {
                        func finish() {
                            guard !audioDone else { return }
                            audioDone = true
                            audioInput.markAsFinished()
                            group.leave()
                        }
                        while audioInput.isReadyForMoreMediaData {
                            guard reader.status == .reading, let sample = audioOutput.copyNextSampleBuffer() else { return finish() }
                            if !audioInput.append(sample) { reader.cancelReading(); return finish() }
                        }
                    }
                }

                group.notify(queue: .global()) {
                    if writer.status == .failed {
                        continuation.resume(throwing: writer.error ?? AppError("Encoding failed"))
                    } else if reader.status == .failed {
                        writer.cancelWriting()
                        continuation.resume(throwing: reader.error ?? AppError("Decoding failed"))
                    } else if reader.status == .cancelled {
                        writer.cancelWriting()
                        continuation.resume(throwing: CancellationError())
                    } else {
                        writer.finishWriting {
                            if writer.status == .completed {
                                continuation.resume()
                            } else {
                                continuation.resume(throwing: writer.error ?? AppError("Couldn't finish the file"))
                            }
                        }
                    }
                }
            }
        } onCancel: {
            reader.cancelReading()
        }
        throttle.report(1)
    }

    private static let rec709: [String: Any] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]

    private static func isHDR(_ format: CMFormatDescription?) -> Bool {
        guard let format, let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCVImageBufferTransferFunctionKey) as? String else {
            return false
        }
        return transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
            || transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
    }

    private static func colorProperties(_ format: CMFormatDescription?) -> [String: Any]? {
        guard let format,
              let primaries = CMFormatDescriptionGetExtension(format, extensionKey: kCVImageBufferColorPrimariesKey) as? String,
              let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCVImageBufferTransferFunctionKey) as? String,
              let matrix = CMFormatDescriptionGetExtension(format, extensionKey: kCVImageBufferYCbCrMatrixKey) as? String
        else { return nil }
        let okPrimaries = [AVVideoColorPrimaries_ITU_R_709_2, AVVideoColorPrimaries_P3_D65, AVVideoColorPrimaries_ITU_R_2020]
        let okTransfer = [AVVideoTransferFunction_ITU_R_709_2, AVVideoTransferFunction_ITU_R_2100_HLG, AVVideoTransferFunction_SMPTE_ST_2084_PQ]
        let okMatrix = [AVVideoYCbCrMatrix_ITU_R_709_2, AVVideoYCbCrMatrix_ITU_R_2020]
        guard okPrimaries.contains(primaries), okTransfer.contains(transfer), okMatrix.contains(matrix) else { return nil }
        return [AVVideoColorPrimariesKey: primaries, AVVideoTransferFunctionKey: transfer, AVVideoYCbCrMatrixKey: matrix]
    }

    // MARK: Export session helpers

    static func canPassthrough(_ asset: AVAsset, to fileType: AVFileType) async -> Bool {
        await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: fileType)
    }

    static func export(asset: AVAsset, preset: String, to dst: URL, fileType: AVFileType,
                       timeRange: CMTimeRange? = nil, metadata: [AVMetadataItem]? = nil, filterForSharing: Bool = false,
                       videoComposition: AVVideoComposition? = nil, progress: ProgressHandler?) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw AppError("Can't export this video")
        }
        guard session.supportedFileTypes.contains(fileType) else {
            throw AppError("Can't save this video as .\(dst.pathExtension) without re-encoding")
        }
        session.outputURL = dst
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true
        if let timeRange { session.timeRange = timeRange }
        if let metadata { session.metadata = metadata }
        if filterForSharing { session.metadataItemFilter = .forSharing() }
        if let videoComposition { session.videoComposition = videoComposition }

        let throttle = ProgressThrottle(progress)
        let poller = Task {
            while !Task.isCancelled {
                throttle.report(Double(session.progress) * 0.99)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { poller.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                session.exportAsynchronously { continuation.resume() }
            }
        } onCancel: {
            session.cancelExport()
        }
        switch session.status {
        case .completed: throttle.report(1)
        case .cancelled: throw CancellationError()
        default: throw session.error ?? AppError("Export failed")
        }
    }

    /// Changes container, copying streams when possible, otherwise re-encoding.
    static func convert(_ src: URL, to dst: URL, fileType: AVFileType, mode: VideoConvertMode, progress: ProgressHandler?) async throws {
        let asset = AVURLAsset(url: src)
        if mode == .auto, await canPassthrough(asset, to: fileType) {
            try await export(asset: asset, preset: AVAssetExportPresetPassthrough, to: dst, fileType: fileType, progress: progress)
            return
        }
        var settings = VideoEncodeSettings()
        settings.codec = mode == .h264 ? .h264 : .hevc
        settings.fileType = fileType
        try await transcode(src, to: dst, settings: settings, progress: progress)
    }

    // MARK: GIF / frames / merge

    static func makeGIF(_ src: URL, to dst: URL, range: CMTimeRange?, fps: Double, maxWidth: Int, progress: ProgressHandler?) async throws {
        let asset = AVURLAsset(url: src)
        let duration = try await asset.load(.duration)
        let range = range ?? CMTimeRange(start: .zero, duration: duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth * 4)

        let start = range.start.seconds, end = range.end.seconds
        let count = min(1500, max(1, Int(((end - start) * fps).rounded(.down))))
        guard let dest = CGImageDestinationCreateWithURL(dst as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw AppError("Couldn't create GIF")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: 1 / fps,
            kCGImagePropertyGIFUnclampedDelayTime: 1 / fps,
        ]] as CFDictionary
        let throttle = ProgressThrottle(progress)
        for i in 0..<count {
            try Task.checkCancellation()
            let time = CMTime(seconds: start + Double(i) / fps, preferredTimescale: 600)
            let (image, _) = try await generator.image(at: time)
            CGImageDestinationAddImage(dest, image, frameProps)
            throttle.report(Double(i + 1) / Double(count) * 0.95)
        }
        guard CGImageDestinationFinalize(dest) else { throw AppError("Couldn't write GIF") }
        throttle.report(1)
    }

    static func frame(_ src: URL, at time: CMTime) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: src))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: time).image
    }

    static func merge(_ urls: [URL], to dst: URL, fileType: AVFileType, codec: VideoCodec, progress: ProgressHandler?) async throws {
        let composition = AVMutableComposition()
        guard let videoComp = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AppError("Couldn't create composition")
        }
        let audioComp = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero
        var renderSize: CGSize?
        var maxFPS: Float = 24
        var instructions: [AVMutableVideoCompositionInstruction] = []

        for url in urls {
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw AppError("\(url.lastPathComponent) has no video (or isn't supported natively)")
            }
            let (natural, preferred, fps, trackRange) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .timeRange)
            let clipRange = CMTimeRange(start: trackRange.start, duration: trackRange.duration)
            try videoComp.insertTimeRange(clipRange, of: track, at: cursor)
            if let audio = try await asset.loadTracks(withMediaType: .audio).first {
                try? audioComp?.insertTimeRange(clipRange, of: audio, at: cursor)
            }
            maxFPS = max(maxFPS, fps)

            let rect = CGRect(origin: .zero, size: natural).applying(preferred)
            let upright = CGSize(width: abs(rect.width), height: abs(rect.height))
            if renderSize == nil {
                renderSize = CGSize(width: floor(upright.width / 2) * 2, height: floor(upright.height / 2) * 2)
            }
            let canvas = renderSize!
            let scale = min(canvas.width / upright.width, canvas.height / upright.height)
            let normalized = preferred.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            let placed = normalized
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: (canvas.width - upright.width * scale) / 2,
                                                 y: (canvas.height - upright.height * scale) / 2))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoComp)
            layer.setTransform(placed, at: cursor)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: clipRange.duration)
            instruction.layerInstructions = [layer]
            instructions.append(instruction)
            cursor = cursor + clipRange.duration
        }
        guard let renderSize else { throw AppError("No clips to merge") }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(min(60, maxFPS.rounded())))
        videoComposition.instructions = instructions

        let preset = codec == .hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        try await export(asset: composition, preset: preset, to: dst, fileType: fileType,
                         videoComposition: videoComposition, progress: progress)
    }

    // MARK: Metadata

    static func stripMetadata(_ src: URL, to dst: URL, locationOnly: Bool, progress: ProgressHandler?) async throws {
        let asset = AVURLAsset(url: src)
        guard let fileType = VideoContainer.fileType(forExtension: src.ext), await canPassthrough(asset, to: fileType) else {
            guard FFmpeg.shared.isAvailable else { throw AppError.needsFFmpeg }
            try await FFmpeg.shared.run(["-i", src.path, "-map", "0", "-map_metadata", "-1", "-map_chapters", "-1", "-c", "copy", dst.path], progress: progress)
            return
        }
        try await export(asset: asset, preset: AVAssetExportPresetPassthrough, to: dst, fileType: fileType,
                         metadata: locationOnly ? nil : [], filterForSharing: true, progress: progress)
    }
}

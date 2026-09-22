import AudioToolbox
import AVFoundation

enum AudioFormat: String, CaseIterable, Identifiable {
    case aac, alac, flac, wav, aiff, caf, mp3, ogg, opus
    var id: Self { self }

    var title: String {
        switch self {
        case .aac: "AAC (.m4a)"
        case .alac: "Apple Lossless (.m4a)"
        case .flac: "FLAC"
        case .wav: "WAV"
        case .aiff: "AIFF"
        case .caf: "CAF"
        case .mp3: "MP3"
        case .ogg: "Ogg Vorbis"
        case .opus: "Opus"
        }
    }
    var ext: String {
        switch self {
        case .aac, .alac: "m4a"
        default: rawValue
        }
    }
    var isLossy: Bool { [.aac, .mp3, .ogg, .opus].contains(self) }
    var isNative: Bool { ![.mp3, .ogg, .opus].contains(self) }
}

struct AudioSettings {
    var format: AudioFormat = .aac
    var bitrateKbps = 192
    var sampleRate: Double?
    var channels: Int?
    var timeRange: CMTimeRange?
}

enum AudioProcessor {
    static func convert(_ src: URL, to dst: URL, settings: AudioSettings, progress: ProgressHandler?) async throws {
        if settings.format.isNative, await VideoProcessor.hasAudioNatively(src) {
            do {
                try await convertNatively(src, to: dst, settings: settings, progress: progress)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch where FFmpeg.shared.isAvailable {
                try? FileManager.default.removeItem(at: dst)
            }
        }
        guard FFmpeg.shared.isAvailable else {
            throw settings.format.isNative
                ? AppError("This file's audio can't be read natively. Set up ffmpeg in Settings.")
                : AppError("\(settings.format.title) output needs ffmpeg. Open Settings to set it up.")
        }
        try await convertWithFFmpeg(src, to: dst, settings: settings, progress: progress)
    }

    private static func convertWithFFmpeg(_ src: URL, to dst: URL, settings: AudioSettings, progress: ProgressHandler?) async throws {
        var args: [String] = []
        if let range = settings.timeRange {
            args += ["-ss", String(format: "%.3f", range.start.seconds)]
        }
        args += ["-i", src.path]
        if let range = settings.timeRange {
            args += ["-t", String(format: "%.3f", range.duration.seconds)]
        }
        args += ["-vn", "-map", "0:a:0", "-map_metadata", "0"]
        if let channels = settings.channels { args += ["-ac", "\(channels)"] }
        if let rate = settings.sampleRate { args += ["-ar", "\(Int(rate))"] }
        let bitrate = "\(settings.bitrateKbps)k"
        switch settings.format {
        case .mp3: args += ["-c:a", "libmp3lame", "-b:a", bitrate]
        case .ogg: args += FFmpeg.shared.vorbisArgs(kbps: settings.bitrateKbps)
        case .opus: args += ["-c:a", "libopus", "-b:a", bitrate]
        case .aac: args += ["-c:a", FFmpeg.shared.pick(["aac_at", "aac"]) ?? "aac", "-b:a", bitrate]
        case .alac: args += ["-c:a", "alac"]
        case .flac: args += ["-c:a", "flac"]
        case .wav: args += ["-c:a", "pcm_s16le"]
        case .aiff: args += ["-c:a", "pcm_s16be"]
        case .caf: args += ["-c:a", "pcm_s16le", "-f", "caf"]
        }
        try await FFmpeg.shared.run(args + [dst.path], progress: progress)
    }

    private static func convertNatively(_ src: URL, to dst: URL, settings: AudioSettings, progress: ProgressHandler?) async throws {
        let asset = AVURLAsset(url: src)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw AppError("No audio track found") }
        let formats = try await track.load(.formatDescriptions)
        let source = formats.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        var sampleRate = settings.sampleRate ?? source?.mSampleRate ?? 44100
        if sampleRate <= 0 { sampleRate = 44100 }
        if settings.format == .aac { sampleRate = min(sampleRate, 48000) }
        let channels = UInt32(min(2, max(1, settings.channels ?? Int(source?.mChannelsPerFrame ?? 2))))

        let reader = try AVAssetReader(asset: asset)
        if let range = settings.timeRange { reader.timeRange = range }
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { throw AppError("Can't decode this audio") }
        reader.add(output)

        var client = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)

        var fileType: AudioFileTypeID
        var target = AudioStreamBasicDescription()
        target.mSampleRate = sampleRate
        target.mChannelsPerFrame = channels
        switch settings.format {
        case .wav, .aiff, .caf:
            let bigEndian = settings.format == .aiff
            fileType = settings.format == .wav ? kAudioFileWAVEType : (bigEndian ? kAudioFileAIFFType : kAudioFileCAFType)
            target.mFormatID = kAudioFormatLinearPCM
            target.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | (bigEndian ? kAudioFormatFlagIsBigEndian : 0)
            target.mBitsPerChannel = 16
            target.mBytesPerFrame = 2 * channels
            target.mBytesPerPacket = 2 * channels
            target.mFramesPerPacket = 1
        case .aac:
            fileType = kAudioFileM4AType
            target.mFormatID = kAudioFormatMPEG4AAC
            target.mFramesPerPacket = 1024
        case .alac:
            fileType = kAudioFileM4AType
            target.mFormatID = kAudioFormatAppleLossless
            target.mFormatFlags = kAppleLosslessFormatFlag_16BitSourceData
            target.mFramesPerPacket = 4096
        case .flac:
            fileType = kAudioFileFLACType
            target.mFormatID = kAudioFormatFLAC
            target.mFormatFlags = kAppleLosslessFormatFlag_16BitSourceData
            target.mFramesPerPacket = 4096
        default:
            throw AppError("Not a native format")
        }
        if target.mFormatID != kAudioFormatLinearPCM {
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &target)
        }

        var fileRef: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(dst as CFURL, fileType, &target, nil, AudioFileFlags.eraseFile.rawValue, &fileRef)
        guard status == noErr, let file = fileRef else { throw AppError("Couldn't create audio file (error \(status))") }
        defer { ExtAudioFileDispose(file) }
        status = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                         UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard status == noErr else { throw AppError("Unsupported audio conversion (error \(status))") }

        if settings.format == .aac {
            var converter: AudioConverterRef?
            var size = UInt32(MemoryLayout<AudioConverterRef?>.size)
            if ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &converter) == noErr, let converter {
                // Only some bitrates are valid for a given sample rate / channel count; pick the closest one.
                var bitrate = UInt32(settings.bitrateKbps * 1000)
                var listSize: UInt32 = 0
                if AudioConverterGetPropertyInfo(converter, kAudioConverterApplicableEncodeBitRates, &listSize, nil) == noErr, listSize > 0 {
                    var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(listSize) / MemoryLayout<AudioValueRange>.size)
                    if AudioConverterGetProperty(converter, kAudioConverterApplicableEncodeBitRates, &listSize, &ranges) == noErr {
                        let rates = ranges.map { UInt32($0.mMaximum) }.filter { $0 > 0 }
                        if let best = rates.filter({ $0 <= bitrate }).max() ?? rates.min() { bitrate = best }
                    }
                }
                if AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitrate) == noErr {
                    var config: CFArray?
                    ExtAudioFileSetProperty(file, kExtAudioFileProperty_ConverterConfig, UInt32(MemoryLayout<CFArray?>.size), &config)
                }
            }
        }

        guard reader.startReading() else { throw reader.error ?? AppError("Couldn't read audio") }
        let fullDuration = try await asset.load(.duration)
        let duration = (settings.timeRange?.duration ?? fullDuration).seconds
        let throttle = ProgressThrottle(progress)
        var written = 0.0

        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            var blockBuffer: CMBlockBuffer?
            var bufferList = AudioBufferList()
            let result = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sample, bufferListSizeNeededOut: nil, bufferListOut: &bufferList,
                bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil, flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: &blockBuffer)
            guard result == noErr else { continue }
            let frames = CMSampleBufferGetNumSamples(sample)
            status = ExtAudioFileWrite(file, UInt32(frames), &bufferList)
            guard status == noErr else { throw AppError("Audio encoding failed (error \(status))") }
            written += Double(frames) / sampleRate
            if duration > 0 { throttle.report(written / duration * 0.99) }
        }
        if reader.status == .failed { throw reader.error ?? AppError("Couldn't read audio") }
        throttle.report(1)
    }
}

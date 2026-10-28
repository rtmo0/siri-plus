import AVFoundation

/// Records the call and the microphone while a meeting runs, each to its own M4A track, then mixes them into one
/// M4A file. Both tracks follow the capture clock: pauses the capture skips are written as silence, so the voices
/// stay in step. Everything stays on this Mac.
final class MeetingRecorder: @unchecked Sendable {
    private final class Track {
        let url: URL
        let file: AVAudioFile
        var frames: AVAudioFramePosition = 0
        var converter: AVAudioConverter?

        init(url: URL, file: AVAudioFile) {
            self.url = url
            self.file = file
        }
    }

    private let lock = NSLock()
    private let directory: URL
    private var tracks: [Speaker: Track] = [:]
    /// Capture time of the first sound of either track: the start of the recording.
    private var origin: CMTime?
    private var failure: Error?

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "siriplus-recording-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Adds sound captured at `time`. Called on the capture queues.
    func append(_ buffer: AVAudioPCMBuffer, of speaker: Speaker, at time: CMTime) {
        guard buffer.frameLength > 0, time.isNumeric else { return }
        lock.withLock {
            guard failure == nil else { return }
            do {
                let origin = self.origin ?? time
                self.origin = origin
                let track = try tracks[speaker] ?? makeTrack(for: speaker, format: buffer.format)
                tracks[speaker] = track
                let format = track.file.processingFormat
                // A gap of more than 50 ms between where the track is and where this sound belongs is a pause.
                let position = AVAudioFramePosition((time - origin).seconds * format.sampleRate)
                if position - track.frames > AVAudioFramePosition(format.sampleRate / 20) {
                    try writeSilence(position - track.frames, to: track)
                }
                let samples = try converted(buffer, for: track)
                try track.file.write(from: samples)
                track.frames += AVAudioFramePosition(samples.frameLength)
            } catch {
                failure = error
            }
        }
    }

    /// Closes the tracks and writes them mixed into `url`. Writes nothing if no sound came.
    func finish(to url: URL) async throws {
        let (urls, failure): ([URL], Error?) = lock.withLock {
            let urls = tracks.values.map { track in
                track.file.close()
                return track.url
            }
            tracks = [:]
            return (urls, self.failure)
        }
        if let failure { throw failure }
        guard !urls.isEmpty else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        if urls.count == 1 {
            try FileManager.default.moveItem(at: urls[0], to: url)
            return
        }
        let composition = AVMutableComposition()
        for trackURL in urls {
            let asset = AVURLAsset(url: trackURL)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try target.insertTimeRange(CMTimeRange(start: .zero, duration: try await asset.load(.duration)), of: source, at: .zero)
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw MeetingError.recordingFailed
        }
        try await export.export(to: url, as: .m4a)
    }

    private func makeTrack(for speaker: Speaker, format: AVAudioFormat) throws -> Track {
        let url = directory.appending(path: "\(speaker.rawValue).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            // Speech: about 30 MB an hour per track, clear enough to listen back to.
            AVEncoderBitRateKey: 64_000 * Int(format.channelCount),
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        return Track(url: url, file: file)
    }

    private func writeSilence(_ frames: AVAudioFramePosition, to track: Track) throws {
        let format = track.file.processingFormat
        var remaining = frames
        while remaining > 0 {
            let count = AVAudioFrameCount(min(remaining, AVAudioFramePosition(format.sampleRate)))
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { throw MeetingError.recordingFailed }
            silence.frameLength = count
            // New buffers are not guaranteed to be zeroed.
            let buffers = UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList)
            for buffer in buffers { buffer.mData.map { memset($0, 0, Int(buffer.mDataByteSize)) } }
            try track.file.write(from: silence)
            track.frames += AVAudioFramePosition(count)
            remaining -= AVAudioFramePosition(count)
        }
    }

    /// The buffer in the track's format; capture may change format mid-call, for example a new microphone.
    private func converted(_ buffer: AVAudioPCMBuffer, for track: Track) throws -> AVAudioPCMBuffer {
        let format = track.file.processingFormat
        guard buffer.format != format else { return buffer }
        if track.converter?.inputFormat != buffer.format {
            track.converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter = track.converter else { throw MeetingError.recordingFailed }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw MeetingError.recordingFailed }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        return output
    }
}

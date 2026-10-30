import AVFoundation
import Foundation
import ScreenCaptureKit
import UserNotifications

struct TrackDiagnostics: Codable {
    var firstPTSSeconds: Double?
    var hostClockAnchorSeconds: Double?
    /// Frames implied by the PTS span (first PTS to end of last buffer) at 16 kHz.
    var expectedFrames: Int64 = 0
    /// Frames successfully written to the file (excludes padding).
    var writtenFrames: Int64 = 0
    var decodedDurationSeconds: Double = 0
    /// Silence frames actually inserted (always 0 while ptsPaddingEnabled is false).
    var paddingFrames: Int64 = 0
    /// Silence frames the PTS padding logic would have inserted.
    var wouldPadFrames: Int64 = 0
    /// Largest observed (PTS-expected frame - frames written so far), in frames.
    var maxDriftFrames: Int64 = 0
    /// Most negative observed (PTS-expected frame - frames written so far), in frames (signed; 0 if never negative).
    var minDriftFrames: Int64 = 0
    /// decodedDurationSeconds minus capture duration (from capture start). Measurement only; 0 when no capture duration is known.
    var finalSkewSeconds: Double = 0
    var damageCount = 0
    var firstError: String?
}

struct RecordingDiagnostics: Codable {
    var recordingStartEpochMs: Int64
    /// Host-clock seconds when startCapture() completed; compare with each track's firstPTSSeconds and hostClockAnchorSeconds. Measurement only.
    var hostClockAtCaptureStartSeconds: Double?
    var durationSeconds: Double
    var ptsPaddingEnabled: Bool
    var system: TrackDiagnostics
    var mic: TrackDiagnostics

    var damageCount: Int { system.damageCount + mic.damageCount }
}

struct RecordingResult {
    let systemURL: URL
    let micURL: URL?
    /// Capture-based: from startCapture() completing to stop.
    let duration: TimeInterval
    let diagnostics: RecordingDiagnostics

    var damageCount: Int { diagnostics.damageCount }
    var micMissing: Bool { diagnostics.mic.writtenFrames == 0 }

    /// User-facing warning for damage / missing mic, or nil.
    var warningText: String? {
        var warnings: [String] = []
        if damageCount > 0 {
            warnings.append("Recording had \(damageCount) audio write/convert errors; transcript may have gaps.")
        }
        if micMissing {
            warnings.append("Microphone recorded no audio; your own speech is not in this transcript.")
        }
        return warnings.isEmpty ? nil : warnings.joined(separator: " ")
    }
}


/// One recording, end to end. Owns its files, tracks, SCStream, startup task and clock anchors, and is the
/// SCStream's output and delegate, so every callback reaches the session that created the stream. After
/// finalize the files are closed and late callbacks are no-ops. `finish(reason:)` is idempotent: the first call
/// starts the single finalize, which calls `onFinished` once on the main actor.
final class RecordingSession: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    enum FinishReason { case user, streamError, startupFailure }

    // Stays off until a ~30 s diagnostic recording (see the _diag.json sidecar) shows
    // PTS and the host clock agree. Gate: keep padding off unless maxDriftFrames < 1600 (0.1 s)
    // and minDriftFrames > -1600 on both tracks and |mic.finalSkewSeconds - system.finalSkewSeconds| < 0.1 s.
    private static let ptsPaddingEnabled = false

    private static let float16kFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: true)!
    private static let int16Format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    /// Per-track state. Every field is guarded by `lock`.
    private final class Track {
        var file: AVAudioFile?
        var converter: AVAudioConverter?
        var converterSrcFormat: AVAudioFormat?
        var diag = TrackDiagnostics()
        var lastEndPTS: Double?
        var virtualPadFrames: Int64 = 0
        /// Host-clock seconds when the stream was set up.
        var ptsAnchorSeconds: Double?

        func recordDamage(_ message: String) {
            diag.damageCount += 1
            if diag.firstError == nil { diag.firstError = message }
        }
    }

    let systemURL: URL
    let micURL: URL
    private let systemTrack = Track()
    private let micTrack = Track()
    private let systemQueue = DispatchQueue(label: "audio.system")
    private let micQueue = DispatchQueue(label: "audio.mic")
    private let screenQueue = DispatchQueue(label: "audio.screen")
    private let startTime = Date()
    private let lock = NSLock()

    // Guarded by lock
    private var stream: SCStream?
    private var startupTask: Task<Void, Never>?
    private var startupError: String?
    /// Set when finalize stops waiting for startup or begins closing files; a late startStream() must then leave nothing running.
    private var startupAbandoned = false
    /// Set when finalize snapshots the diagnostics; damage recorded after that has no result left to carry it.
    private var diagnosticsSnapshotted = false
    private var finishReason: FinishReason?
    private var onFinished: (@MainActor (RecordingSession, RecordingResult?, String?) -> Void)?
    /// Monotonic (systemUptime) seconds when startCapture() completed.
    private var captureStartUptime: Double?
    private var recordingStartEpochMs: Int64 = 0
    private var hostClockAtCaptureStart: Double?

    /// Opens both WAV files; throws if either cannot be created.
    init(systemURL: URL = RecordingSession.newRecordingURL()) throws {
        self.systemURL = systemURL
        micURL = URL(fileURLWithPath: systemURL.deletingPathExtension().path + "_mic.wav")
        super.init()
        systemTrack.file = try AVAudioFile(
            forWriting: systemURL,
            settings: Self.wavSettings(sampleRate: 16000),
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        micTrack.file = try AVAudioFile(
            forWriting: micURL,
            settings: Self.wavSettings(sampleRate: 16000),
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
    }

    // MARK: - Lifecycle

    func start(onFinished: @escaping @MainActor (RecordingSession, RecordingResult?, String?) -> Void) {
        lock.withLock {
            self.onFinished = onFinished
            startupTask = Task {
                do {
                    try await self.startStream()
                } catch {
                    self.lock.withLock { self.startupError = error.localizedDescription }
                    self.finish(reason: .startupFailure)
                }
            }
        }
    }

    /// The first call starts the single finalize; later calls do nothing. Returns whether this call was the first.
    @discardableResult
    func finish(reason: FinishReason) -> Bool {
        let first = lock.withLock { () -> Bool in
            if finishReason != nil { return false }
            finishReason = reason
            return true
        }
        guard first else { return false }
        Task { await self.finalize() }
        return true
    }

    private func startStream() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        if lock.withLock({ startupAbandoned }) { return }

        guard let display = content.displays.first else {
            throw RecorderError.noDisplayFound
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        var scStream = try makeStream(filter: filter, includeMic: true)

        let abandonedBeforeStart = lock.withLock { () -> Bool in
            if startupAbandoned { return true }
            let anchor = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
            systemTrack.ptsAnchorSeconds = anchor
            micTrack.ptsAnchorSeconds = anchor
            // Assigned before startCapture() so finalize can stop it even if startCapture() throws.
            stream = scStream
            return false
        }
        if abandonedBeforeStart { return }
        do {
            try await scStream.startCapture()
        } catch {
            let nsError = error as NSError
            guard #available(macOS 15.0, *),
                  nsError.domain == SCStreamErrorDomain,
                  nsError.code == SCStreamError.Code.failedToStartMicrophoneCapture.rawValue else { throw error }
            // Retry once without the microphone so system audio is still recorded.
            print("[AudioRecorder] microphone capture failed to start: \(error.localizedDescription); retrying without mic")
            // Stop the failed stream and drop it as the session's stream so its late callbacks are ignored.
            do { try await scStream.stopCapture() } catch {
                print("[AudioRecorder] failed mic-start stream stop failed: \(error.localizedDescription)")
                recordSystemDamageIfOpen("stopCapture failed on mic-start stream: \(error.localizedDescription)")
            }
            lock.withLock { stream = nil }
            let retryStream = try makeStream(filter: filter, includeMic: false)
            let abandonedBeforeRetry = lock.withLock { () -> Bool in
                if startupAbandoned { return true }
                micTrack.recordDamage("microphone capture failed to start: \(error.localizedDescription)")
                // The failed stream was already stopped and cleared above; finalize stops only the retry stream.
                stream = retryStream
                return false
            }
            if abandonedBeforeRetry { return }
            scStream = retryStream
            try await scStream.startCapture()
        }
        let hostClockNow = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let abandonedAfterStart = lock.withLock { () -> Bool in
            if startupAbandoned { return true }
            hostClockAtCaptureStart = hostClockNow
            // Capture start = startCapture() completing, on the monotonic uptime clock (durations must not follow wall-clock changes). Kept separate from host-clock/PTS values.
            captureStartUptime = ProcessInfo.processInfo.systemUptime
            recordingStartEpochMs = Int64(Date().timeIntervalSince1970 * 1000)
            return false
        }
        if abandonedAfterStart {
            // Finalize gave up on this startup; this call started the stream, so it must stop it.
            do { try await scStream.stopCapture() } catch {
                print("[AudioRecorder] late-started stream stop failed: \(error.localizedDescription)")
                // Logged either way; recorded as damage only if finalize has not already snapshotted the diagnostics.
                recordSystemDamageIfOpen("stopCapture failed on late-started stream: \(error.localizedDescription)")
            }
            print("[AudioRecorder] late-started stream stopped (startup was abandoned)")
        }
    }

    private func recordSystemDamageIfOpen(_ message: String) {
        lock.withLock { if !diagnosticsSnapshotted { systemTrack.recordDamage(message) } }
    }

    private func makeStream(filter: SCContentFilter, includeMic: Bool) throws -> SCStream {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        if includeMic, #available(macOS 15.0, *) {
            config.captureMicrophone = true
        }
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let scStream = SCStream(filter: filter, configuration: config, delegate: self)
        try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
        try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
        if includeMic, #available(macOS 15.0, *) {
            do {
                try scStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)
            } catch {
                print("[AudioRecorder] mic output unavailable: \(error.localizedDescription); continuing with system audio only")
                lock.withLock { micTrack.recordDamage("mic output unavailable: \(error.localizedDescription)") }
            }
        }
        return scStream
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard lock.withLock({ self.stream === stream }) else { return }
        switch outputType {
        case .audio:
            writeSampleBuffer(sampleBuffer, isMic: false)
        case .screen:
            break
        default:
            // .microphone (only added on macOS 15+)
            writeSampleBuffer(sampleBuffer, isMic: true)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard lock.withLock({ self.stream === stream }) else { return }
        if finish(reason: .streamError) { Self.sendDropNotification() }
    }

    // MARK: - Audio Writing

    private func writeSampleBuffer(_ sampleBuffer: CMSampleBuffer, isMic: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let track = isMic ? micTrack : systemTrack
        // File is nil once finalized: late buffers are dropped.
        guard track.file != nil else { return }

        guard let formatDesc = sampleBuffer.formatDescription else {
            track.recordDamage("sample buffer has no format description")
            return
        }
        let srcFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)
        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frameCount > 0 else { return }

        // One converter per track, recreated only when the source format changes, so resampler state carries across buffers.
        if track.converter == nil || track.converterSrcFormat != srcFormat {
            flushConverter(of: track)
            guard let converter = AVAudioConverter(from: srcFormat, to: Self.float16kFormat) else {
                track.recordDamage("could not create AVAudioConverter from \(srcFormat)")
                return
            }
            track.converter = converter
            track.converterSrcFormat = srcFormat
        }
        guard let converter = track.converter else { return }

        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            track.recordDamage("could not allocate source buffer")
            return
        }
        srcBuffer.frameLength = frameCount

        // Per-buffer byte count for numSamples frames (mBytesPerFrame is per channel when non-interleaved).
        let expectedBytes = Int(frameCount) * Int(srcFormat.streamDescription.pointee.mBytesPerFrame)
        var problem: String?
        do {
            try sampleBuffer.withAudioBufferList { abl, _ in
                let srcABL = UnsafeMutableAudioBufferListPointer(srcBuffer.mutableAudioBufferList)
                guard abl.count == srcABL.count else { problem = "malformed sample buffer (buffer count mismatch)"; return }
                for i in 0 ..< abl.count {
                    guard let src = abl[i].mData, let dst = srcABL[i].mData else { problem = "malformed sample buffer (nil data)"; return }
                    let capacity = Int(srcABL[i].mDataByteSize)
                    guard Int(abl[i].mDataByteSize) == expectedBytes else { problem = "sample buffer size mismatch (\(abl[i].mDataByteSize) bytes, expected \(expectedBytes))"; return }
                    guard Int(abl[i].mDataByteSize) <= capacity else { problem = "sample buffer larger than destination (\(abl[i].mDataByteSize) > \(capacity) bytes)"; return }
                    memcpy(dst, src, Int(abl[i].mDataByteSize))
                    srcABL[i].mDataByteSize = abl[i].mDataByteSize
                }
            }
        } catch {
            track.recordDamage("copying sample buffer failed: \(error.localizedDescription)")
            return
        }
        if let problem {
            track.recordDamage(problem)
            return
        }

        // Headroom beyond the exact ratio for the resampler.
        let outputCapacity = AVAudioFrameCount(
            ceil(Double(frameCount) * Self.float16kFormat.sampleRate / srcFormat.sampleRate)
        ) + 256
        var inputSupplied = false
        var outBuffers: [AVAudioPCMBuffer] = []
        // A full output buffer may mean more is pending: keep converting until the resampler runs dry.
        while true {
            guard let floatBuffer = AVAudioPCMBuffer(pcmFormat: Self.float16kFormat, frameCapacity: outputCapacity) else {
                track.recordDamage("could not allocate converter output buffer")
                return
            }
            var convertError: NSError?
            // .noDataNow (never .endOfStream) keeps the resampler state for the next buffer.
            let status = converter.convert(to: floatBuffer, error: &convertError) { _, outStatus in
                if inputSupplied { outStatus.pointee = .noDataNow; return nil }
                inputSupplied = true
                outStatus.pointee = .haveData
                return srcBuffer
            }
            if status == .error || status == .endOfStream || convertError != nil {
                track.recordDamage("convert failed: \(convertError?.localizedDescription ?? "status \(status.rawValue)")")
                return
            }
            if floatBuffer.frameLength > 0 {
                guard let int16Buffer = makeInt16Buffer(from: floatBuffer, track: track) else { return }
                outBuffers.append(int16Buffer)
            }
            if !(status == .haveData && floatBuffer.frameLength == floatBuffer.frameCapacity) { break }
        }
        guard !outBuffers.isEmpty else { return }

        // PTS bookkeeping (diagnostics always; silence insertion only if ptsPaddingEnabled).
        let ptsSeconds = CMTimeGetSeconds(sampleBuffer.presentationTimeStamp)
        if !ptsSeconds.isNaN && !ptsSeconds.isInfinite {
            if track.diag.firstPTSSeconds == nil { track.diag.firstPTSSeconds = ptsSeconds }
            track.lastEndPTS = ptsSeconds + Double(sampleBuffer.numSamples) / srcFormat.sampleRate
            if let anchor = track.ptsAnchorSeconds {
                let expectedFrame = Int64(max(0.0, (ptsSeconds - anchor) * 16000.0))
                let effective = track.diag.writtenFrames + track.diag.paddingFrames + track.virtualPadFrames
                let gap = expectedFrame - effective
                track.diag.maxDriftFrames = max(track.diag.maxDriftFrames, gap)
                track.diag.minDriftFrames = min(track.diag.minDriftFrames, gap)
                if gap > 0 {
                    if Self.ptsPaddingEnabled {
                        // Bound the pad by capture wall-clock elapsed time so a corrupt PTS can't allocate unbounded silence.
                        let elapsedSeconds = Date().timeIntervalSince(startTime)
                        let maxFrames = Int64((elapsedSeconds + 5.0) * 16000.0)
                        let padFrames = max(0, min(gap, maxFrames - effective))
                        writeSilenceFrames(padFrames, to: track)
                    } else {
                        track.virtualPadFrames += gap
                    }
                }
            }
        }

        for outBuffer in outBuffers { writeInt16(outBuffer, to: track) }
    }

    /// Float32 -> Int16 with clamp only; no gain change. Records damage and returns nil on failure. Caller holds lock.
    private func makeInt16Buffer(from floatBuffer: AVAudioPCMBuffer, track: Track) -> AVAudioPCMBuffer? {
        let outFrames = floatBuffer.frameLength
        guard let floatData = floatBuffer.floatChannelData?[0] else {
            track.recordDamage("converter output has no channel data")
            return nil
        }
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: Self.int16Format, frameCapacity: outFrames),
              let int16Data = outBuffer.int16ChannelData?[0] else {
            track.recordDamage("could not allocate Int16 buffer")
            return nil
        }
        outBuffer.frameLength = outFrames
        for i in 0 ..< Int(outFrames) {
            let v = floatData[i]
            int16Data[i] = v.isNaN ? 0 : Int16(max(Float(Int16.min), min(Float(Int16.max), v * Float(Int16.max))))
        }
        return outBuffer
    }

    /// Caller holds lock.
    private func writeInt16(_ buffer: AVAudioPCMBuffer, to track: Track) {
        do {
            try track.file?.write(from: buffer)
            track.diag.writtenFrames += Int64(buffer.frameLength)
        } catch {
            track.recordDamage("write failed: \(error.localizedDescription)")
        }
    }

    /// Drains the resampler tail of the track's converter (end of stream) and writes it. Caller holds lock.
    private func flushConverter(of track: Track) {
        guard let converter = track.converter else { return }
        // Keep pulling until the resampler reports end of stream (or yields nothing).
        while true {
            guard let floatBuffer = AVAudioPCMBuffer(pcmFormat: Self.float16kFormat, frameCapacity: 4096) else {
                track.recordDamage("could not allocate converter flush buffer")
                return
            }
            var convertError: NSError?
            let status = converter.convert(to: floatBuffer, error: &convertError) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if status == .error || convertError != nil {
                track.recordDamage("converter flush failed: \(convertError?.localizedDescription ?? "status error")")
                return
            }
            if floatBuffer.frameLength > 0, let outBuffer = makeInt16Buffer(from: floatBuffer, track: track) {
                writeInt16(outBuffer, to: track)
            }
            if status == .endOfStream || floatBuffer.frameLength == 0 { break }
        }
    }

    /// Caller holds lock.
    private func writeSilenceFrames(_ count: Int64, to track: Track) {
        guard let file = track.file, count > 0 else { return }
        let blockSize: AVAudioFrameCount = 16000
        var remaining = count
        while remaining > 0 {
            let thisBlock = AVAudioFrameCount(min(Int64(blockSize), remaining))
            guard let buf = AVAudioPCMBuffer(pcmFormat: Self.int16Format, frameCapacity: thisBlock) else {
                track.recordDamage("could not allocate silence buffer")
                return
            }
            buf.frameLength = thisBlock
            guard let ptr = buf.int16ChannelData?[0] else {
                track.recordDamage("silence buffer has no channel data")
                return
            }
            memset(ptr, 0, Int(thisBlock) * MemoryLayout<Int16>.size)
            do {
                try file.write(from: buf)
                track.diag.paddingFrames += Int64(thisBlock)
            } catch {
                track.recordDamage("silence write failed: \(error.localizedDescription)")
                return
            }
            remaining -= Int64(thisBlock)
        }
    }

    // MARK: - Finalize

    private func drain(_ queue: DispatchQueue) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { c.resume() }
        }
    }

    /// Races stopCapture() against a timeout so a hung ScreenCaptureKit shutdown cannot block finalizing. Returns a failure message, or nil on success.
    private static func stopCapture(of s: SCStream, timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            let lock = NSLock()
            var resumed = false
            func finish(_ result: String?) {
                let first = lock.withLock { () -> Bool in
                    defer { resumed = true }
                    return !resumed
                }
                if first { c.resume(returning: result) }
            }
            s.stopCapture { error in
                finish(error.map { "stopCapture failed: \($0.localizedDescription)" })
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish("stopCapture timed out after \(Int(timeout)) s")
            }
        }
    }

    /// Races the startup task against a timeout so a hung ScreenCaptureKit startup cannot block finalizing. Returns false on timeout.
    private static func awaitStartup(_ task: Task<Void, Never>, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let lock = NSLock()
            var resumed = false
            func finish(_ completed: Bool) {
                let first = lock.withLock { () -> Bool in
                    defer { resumed = true }
                    return !resumed
                }
                if first { c.resume(returning: completed) }
            }
            Task {
                await task.value
                finish(true)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(false)
            }
        }
    }

    /// Waits for startup, stops capture, waits for in-flight sample handlers, closes the files, then calls `onFinished` once on the main actor.
    private func finalize() async {
        // Startup has either succeeded or failed once this returns, so finalize never races startCapture().
        // Bounded: a stuck startup is treated as a startup failure and nothing is recorded.
        let startup = lock.withLock { startupTask }
        var startupTimedOut = false
        if let startup {
            startupTimedOut = !(await Self.awaitStartup(startup, timeout: 10))
            if startupTimedOut {
                print("[AudioRecorder] startup timed out after 10 s")
                lock.withLock { startupAbandoned = true }
                startup.cancel()
            }
        }

        let (s, duration, startEpochMs, hostClockAtStart, captured, reason, startupError) = lock.withLock {
            // Fence any startStream() still in flight: from here on it assigns nothing and stops its own stream.
            startupAbandoned = true
            return (stream, captureStartUptime.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0, recordingStartEpochMs, hostClockAtCaptureStart,
             captureStartUptime != nil && !startupTimedOut, finishReason,
             startupTimedOut ? "Audio capture did not start within 10 s; nothing was recorded." : self.startupError)
        }
        var stopFailure: String?
        if let s {
            stopFailure = await Self.stopCapture(of: s, timeout: 5)
            if let stopFailure { print("[AudioRecorder] \(stopFailure)") }
        }
        await drain(systemQueue)
        await drain(micQueue)

        let diagnostics = lock.withLock { () -> RecordingDiagnostics in
            let anchor = systemTrack.ptsAnchorSeconds
            diagnosticsSnapshotted = true
            if let stopFailure { systemTrack.recordDamage(stopFailure) }
            func finish(_ t: Track) -> TrackDiagnostics {
                flushConverter(of: t)
                var d = t.diag
                d.hostClockAnchorSeconds = anchor
                if let first = d.firstPTSSeconds, let end = t.lastEndPTS {
                    d.expectedFrames = Int64(max(0, (end - first) * 16000.0).rounded())
                }
                d.decodedDurationSeconds = Double(d.writtenFrames) / 16000.0
                d.finalSkewSeconds = duration > 0 ? d.decodedDurationSeconds - duration : 0
                d.wouldPadFrames = d.paddingFrames + t.virtualPadFrames
                t.file = nil
                t.converter = nil
                t.converterSrcFormat = nil
                return d
            }
            let result = RecordingDiagnostics(
                recordingStartEpochMs: startEpochMs,
                hostClockAtCaptureStartSeconds: hostClockAtStart,
                durationSeconds: duration,
                ptsPaddingEnabled: Self.ptsPaddingEnabled,
                system: finish(systemTrack),
                mic: finish(micTrack)
            )
            stream = nil
            startupTask = nil
            return result
        }

        writeDiagnosticsSidecar(diagnostics)
        let sys = diagnostics.system, mic = diagnostics.mic
        print("[AudioRecorder] stop: dur=\(String(format: "%.1f", duration))s startMs=\(startEpochMs) " +
              "sys written=\(sys.writtenFrames) expected=\(sys.expectedFrames) wouldPad=\(sys.wouldPadFrames) maxDrift=\(sys.maxDriftFrames) minDrift=\(sys.minDriftFrames) skew=\(String(format: "%.3f", sys.finalSkewSeconds))s damage=\(sys.damageCount) | " +
              "mic written=\(mic.writtenFrames) expected=\(mic.expectedFrames) wouldPad=\(mic.wouldPadFrames) maxDrift=\(mic.maxDriftFrames) minDrift=\(mic.minDriftFrames) skew=\(String(format: "%.3f", mic.finalSkewSeconds))s damage=\(mic.damageCount) | " +
              "padding=\(Self.ptsPaddingEnabled ? "on" : "off")")

        let result: RecordingResult? = captured ? RecordingResult(
            systemURL: systemURL,
            micURL: micURL,
            duration: diagnostics.durationSeconds,
            diagnostics: diagnostics
        ) : nil
        let message: String?
        if result == nil {
            message = startupError ?? "Recording stopped before audio capture started; nothing was recorded."
        } else if reason == .streamError {
            message = "Recording was interrupted (audio capture stopped unexpectedly); the note contains audio up to that point."
        } else {
            message = nil
        }

        let callback = lock.withLock { () -> (@MainActor (RecordingSession, RecordingResult?, String?) -> Void)? in
            defer { onFinished = nil }
            return onFinished
        }
        await MainActor.run { callback?(self, result, message) }
    }

    private func writeDiagnosticsSidecar(_ diagnostics: RecordingDiagnostics) {
        let url = URL(fileURLWithPath: systemURL.deletingPathExtension().path + "_diag.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(diagnostics).write(to: url)
        } catch {
            print("[AudioRecorder] diag sidecar write failed: \(error.localizedDescription)")
        }
    }

    private static func sendDropNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Recording Interrupted"
        content.body = "Audio capture stopped unexpectedly. OnlyNotes could not resume."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static func wavSettings(sampleRate: Double) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    private static func newRecordingURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OnlyNotes/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stamp = "recording_\(formatter.string(from: Date()))"
        // Never overwrite an existing recording: check both the system file and its _mic sibling.
        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(name).wav").path)
                || FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(name)_mic.wav").path)
        }
        var name = stamp
        var n = 2
        while exists(name) {
            name = "\(stamp)_\(n)"
            n += 1
        }
        return dir.appendingPathComponent("\(name).wav")
    }
}

@MainActor
final class AudioRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var elapsedTime: TimeInterval = 0

    /// Called exactly once per recording, after its files are finalized. The result is nil if capture never
    /// started; the message is nil for a user stop, otherwise a warning (interruption) or the failure reason.
    var onRecordingFinished: ((RecordingResult?, _ message: String?) -> Void)?

    private var currentSession: RecordingSession?
    private var timer: Timer?
    nonisolated init() {}

    /// Throws .busy until the previous recording has delivered its result.
    func startRecording() throws {
        guard currentSession == nil else { throw RecorderError.busy }
        let session = try RecordingSession()
        currentSession = session
        session.start { [weak self] session, result, message in
            self?.sessionFinished(session, result: result, message: message)
        }
        let start = Date()
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.currentSession === session else { return }
                self.elapsedTime = Date().timeIntervalSince(start)
            }
        }
    }

    /// Requests a stop; the result arrives via onRecordingFinished.
    func stopRecording() {
        currentSession?.finish(reason: .user)
    }

    private func sessionFinished(_ session: RecordingSession, result: RecordingResult?, message: String?) {
        guard session === currentSession else { return }
        currentSession = nil
        timer?.invalidate()
        timer = nil
        elapsedTime = 0
        isRecording = false
        onRecordingFinished?(result, message)
    }
}

enum RecorderError: LocalizedError {
    case formatConversionFailed
    case noDisplayFound
    case screenCapturePermissionDenied
    case busy

    var errorDescription: String? {
        switch self {
        case .formatConversionFailed: return "Failed to set up audio format conversion."
        case .noDisplayFound: return "No display found for audio capture. Ensure you have a monitor connected."
        case .busy: return "Still finishing the previous recording — try again in a moment."
        case .screenCapturePermissionDenied:
            return "Screen recording permission is required to capture meeting audio. Grant access in System Settings → Privacy & Security → Screen Recording, then restart OnlyNotes."
        }
    }
}

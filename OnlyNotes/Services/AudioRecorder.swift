import AVFoundation
import Foundation
import ScreenCaptureKit
import UserNotifications

struct RecordingResult {
    let systemURL: URL
    let micURL: URL?
    let duration: TimeInterval
}

class AudioRecorder: NSObject, ObservableObject, SCStreamDelegate, SCStreamOutput {
    @Published var isRecording = false
    @Published var elapsedTime: TimeInterval = 0

    var currentFilePath: String?
    var micFilePath: String?
    var onUnexpectedStop: ((String?) -> Void)?

    // MARK: - Private state

    private var stream: SCStream?
    private var systemAudioFile: AVAudioFile?
    private var micAudioFile: AVAudioFile?
    private var timer: Timer?
    private var startTime: Date?
    private let writeLock = NSLock()

    // MARK: - Public API

    func startRecording() throws {
        let systemURL = Self.newRecordingURL()
        let micURL = URL(fileURLWithPath: systemURL.deletingPathExtension().path + "_mic.wav")
        currentFilePath = systemURL.path
        micFilePath = micURL.path

        systemAudioFile = try AVAudioFile(
            forWriting: systemURL,
            settings: Self.wavSettings(sampleRate: 16000),
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        micAudioFile = try AVAudioFile(
            forWriting: micURL,
            settings: Self.wavSettings(sampleRate: 16000),
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        startTime = Date()
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let start = self.startTime else { return }
            self.elapsedTime = Date().timeIntervalSince(start)
        }

        Task {
            do {
                try await self.startStream()
            } catch {
                await MainActor.run {
                    self.teardown()
                    self.onUnexpectedStop?(error.localizedDescription)
                }
            }
        }
    }

    func stopRecording() -> RecordingResult? {
        let duration = elapsedTime
        teardown()
        guard let systemPath = currentFilePath else { return nil }
        return RecordingResult(
            systemURL: URL(fileURLWithPath: systemPath),
            micURL: micFilePath.map { URL(fileURLWithPath: $0) },
            duration: duration
        )
    }

    // MARK: - SCStream Setup

    private func startStream() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let display = content.displays.first else {
            throw RecorderError.noDisplayFound
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        if #available(macOS 15.0, *) {
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
        try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "audio.system"))
        try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "audio.screen"))
        if #available(macOS 15.0, *) {
            try scStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: DispatchQueue(label: "audio.mic"))
        }

        try await scStream.startCapture()
        stream = scStream
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard isRecording else { return }

        switch outputType {
        case .audio:
            writeSampleBuffer(sampleBuffer, isMic: false)
        case .screen:
            break
        default:
            // .microphone (macOS 14.2+)
            writeSampleBuffer(sampleBuffer, isMic: true)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard isRecording else { return }
        DispatchQueue.main.async { [weak self] in
            self?.sendDropNotification()
            self?.failRecording()
        }
    }

    // MARK: - Audio Writing

    private func writeSampleBuffer(_ sampleBuffer: CMSampleBuffer, isMic: Bool) {
        guard let formatDesc = sampleBuffer.formatDescription else { return }
        let srcFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)
        guard let convertFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: srcFormat, to: convertFormat)
        else { return }

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frameCount > 0 else { return }

        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else { return }
        srcBuffer.frameLength = frameCount

        do {
            try sampleBuffer.withAudioBufferList { abl, _ in
                let srcABL = UnsafeMutableAudioBufferListPointer(srcBuffer.mutableAudioBufferList)
                for i in 0 ..< min(abl.count, srcABL.count) {
                    guard let src = abl[i].mData, let dst = srcABL[i].mData else { continue }
                    memcpy(dst, src, Int(abl[i].mDataByteSize))
                    srcABL[i].mDataByteSize = abl[i].mDataByteSize
                }
            }
        } catch { return }

        let outputCapacity = AVAudioFrameCount(
            ceil(Double(frameCount) * convertFormat.sampleRate / srcFormat.sampleRate)
        ) + 1

        guard let floatBuffer = AVAudioPCMBuffer(pcmFormat: convertFormat, frameCapacity: outputCapacity) else { return }
        var inputConsumed = false
        converter.convert(to: floatBuffer, error: nil) { _, outStatus in
            if inputConsumed { outStatus.pointee = .noDataNow; return nil }
            outStatus.pointee = .haveData
            inputConsumed = true
            return srcBuffer
        }

        guard let channelData = floatBuffer.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(floatBuffer.frameLength)))

        // Soft limiter: only attenuate if peak exceeds 90% of full scale
        var normalized = samples
        let peak = normalized.map { abs($0) }.max() ?? 0
        if peak > 0.9 {
            let gain = 0.9 / peak
            for i in 0..<normalized.count {
                normalized[i] = normalized[i] * gain
            }
        }

        // Convert Float32 samples → Int16 AVAudioPCMBuffer
        guard let int16Format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                              sampleRate: 16000, channels: 1, interleaved: true),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: int16Format, frameCapacity: AVAudioFrameCount(normalized.count))
        else { return }
        outBuffer.frameLength = AVAudioFrameCount(normalized.count)
        if let ptr = outBuffer.int16ChannelData?[0] {
            for (i, sample) in normalized.enumerated() {
                ptr[i] = Int16(max(Float(Int16.min), min(Float(Int16.max), sample * Float(Int16.max))))
            }
        }
        writeLock.lock()
        if isMic {
            try? micAudioFile?.write(from: outBuffer)
        } else {
            try? systemAudioFile?.write(from: outBuffer)
        }
        writeLock.unlock()
    }

    // MARK: - Teardown

    private func teardown() {
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
        writeLock.lock()
        systemAudioFile = nil
        micAudioFile = nil
        writeLock.unlock()
        timer?.invalidate()
        timer = nil
        isRecording = false
        elapsedTime = 0
        startTime = nil
    }

    private func failRecording() {
        teardown()
        onUnexpectedStop?(nil)
    }

    // MARK: - Helpers

    private func sendDropNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Recording Interrupted"
        content.body = "Audio capture stopped unexpectedly. OnlyNotes could not resume."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static func newRecordingURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OnlyNotes/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return dir.appendingPathComponent("recording_\(formatter.string(from: Date())).wav")
    }

    static func wavSettings(sampleRate: Double) -> [String: Any] {
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
}

enum RecorderError: LocalizedError {
    case formatConversionFailed
    case noDisplayFound
    case screenCapturePermissionDenied

    var errorDescription: String? {
        switch self {
        case .formatConversionFailed: return "Failed to set up audio format conversion."
        case .noDisplayFound: return "No display found for audio capture. Ensure you have a monitor connected."
        case .screenCapturePermissionDenied:
            return "Screen recording permission is required to capture meeting audio. Grant access in System Settings → Privacy & Security → Screen Recording, then restart OnlyNotes."
        }
    }
}

import AVFoundation
import Foundation
import UserNotifications

class AudioRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var elapsedTime: TimeInterval = 0

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var audioConverter: AVAudioConverter?
    private var recordingFormat: AVAudioFormat?
    private var timer: Timer?
    private var startTime: Date?
    private var engineObserver: NSObjectProtocol?

    var currentFilePath: String?
    var onUnexpectedStop: (() -> Void)?

    deinit {
        removeEngineObserver()
    }

    func startRecording() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        // Record at 16kHz mono int16 — compact, Google STT compatible
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        )!

        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw RecorderError.formatConversionFailed
        }
        audioConverter = converter
        recordingFormat = targetFormat

        let fileURL = Self.newRecordingURL()
        currentFilePath = fileURL.path

        let file = try AVAudioFile(
            forWriting: fileURL,
            settings: Self.wavSettings(sampleRate: 16000),
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        audioFile = file

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.convert(buffer: buffer, to: file, using: converter, targetFormat: targetFormat)
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine

        installEngineObserver(on: engine)

        startTime = Date()
        isRecording = true

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let start = self.startTime else { return }
            self.elapsedTime = Date().timeIntervalSince(start)
        }
    }

    func stopRecording() -> (url: URL, duration: TimeInterval)? {
        let duration = elapsedTime
        teardown()
        guard let path = currentFilePath else { return nil }
        return (URL(fileURLWithPath: path), duration)
    }

    // MARK: - Private

    private func convert(
        buffer: AVAudioPCMBuffer,
        to file: AVAudioFile,
        using converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        let inputSampleRate = buffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(
            ceil(Double(buffer.frameLength) * targetFormat.sampleRate / inputSampleRate)
        ) + 1

        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            consumed = true
            return buffer
        }

        if error == nil {
            try? file.write(from: converted)
        }
    }

    private func installEngineObserver(on engine: AVAudioEngine) {
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    private func removeEngineObserver() {
        if let obs = engineObserver {
            NotificationCenter.default.removeObserver(obs)
            engineObserver = nil
        }
    }

    private func handleConfigurationChange() {
        guard isRecording else { return }
        sendDropNotification()

        // Try to restart with new hardware config, writing to the same file
        removeEngineObserver()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.isRecording, let file = self.audioFile,
                  let targetFormat = self.recordingFormat else { return }
            do {
                let engine = AVAudioEngine()
                let inputNode = engine.inputNode
                let hwFormat = inputNode.outputFormat(forBus: 0)

                guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
                    self.failRecording()
                    return
                }
                self.audioConverter = converter

                inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
                    self?.convert(buffer: buffer, to: file, using: converter, targetFormat: targetFormat)
                }

                engine.prepare()
                try engine.start()
                self.audioEngine = engine
                self.installEngineObserver(on: engine)
            } catch {
                self.failRecording()
            }
        }
    }

    private func failRecording() {
        teardown()
        onUnexpectedStop?()
    }

    private func teardown() {
        removeEngineObserver()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil
        audioConverter = nil
        recordingFormat = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        elapsedTime = 0
        startTime = nil
    }

    private func sendDropNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Recording Interrupted"
        content.body = "Audio device changed. OnlyNotes is attempting to resume your recording."
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

    var errorDescription: String? {
        "Failed to set up audio format conversion."
    }
}

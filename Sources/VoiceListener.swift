import AVFoundation
import Speech

/// Turns speech into text on the phone, live, while the person talks.
@MainActor
final class VoiceListener: ObservableObject {
    enum Phase: Equatable { case idle, listening, denied, unavailable }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript = ""
    /// 0...1, how loud the voice is right now; drives the listening ring.
    @Published private(set) var level: Double = 0

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Names and shops worth hearing right: friends' names are easy to mishear.
    var hints: [String] = []

    func start() async {
        guard phase != .listening else { return }
        transcript = ""
        guard await Self.authorized() else { phase = .denied; return }
        guard let recognizer, recognizer.isAvailable else { phase = .unavailable; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            request.addsPunctuation = true
            request.contextualStrings = hints + ["Trader Joe's", "Costco", "Whole Foods", "split", "Venmo"]
            self.request = request

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                request.append(buffer)
                let loudness = Self.loudness(buffer)
                Task { @MainActor in self?.level = self.map { $0.level * 0.6 + loudness * 0.4 } ?? 0 }
            }
            engine.prepare()
            try engine.start()
            phase = .listening

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let done = error != nil || (result?.isFinal ?? false)
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.transcript = text }
                    if done { self.finish() }
                }
            }
        } catch {
            finish()
            phase = .unavailable
        }
    }

    /// Stops listening; the transcript stays.
    func stop() {
        request?.endAudio()
        finish()
    }

    private func finish() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request = nil
        level = 0
        if phase == .listening { phase = .idle }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func authorized() async -> Bool {
        let speech = await withCheckedContinuation { done in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    nonisolated private static func loudness(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        // About -50 dB is silence, -10 dB is shouting.
        return Double(max(0, min(1, (20 * log10(max(rms, 0.000_01)) + 50) / 40)))
    }
}

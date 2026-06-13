@preconcurrency import AVFoundation
import Foundation
import Speech
import WhisperKit

struct Segment: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    var text: String
    var translation: String?
    var isEnglish: Bool
}

// Whisper 模式的语音缓冲：音频线程写入，主线程轮询。
// 简单能量 VAD：检测到说话后开始累积，静音前保留 0.5s 预滚动避免吃掉开头。
final class VoiceBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var preRoll: [Float] = []
    private var speechDetected = false
    private var lastSpeechAt: Date?
    private let sampleRate: Double = 16000
    private let speechThreshold: Float = 0.015

    struct State {
        let hasSpeech: Bool
        let duration: Double
        let silence: Double
    }

    func ingest(_ chunk: [Float]) {
        var energy: Float = 0
        for s in chunk { energy += s * s }
        let rms = (energy / Float(max(chunk.count, 1))).squareRoot()
        lock.lock()
        defer { lock.unlock() }
        if speechDetected {
            samples.append(contentsOf: chunk)
            if rms > speechThreshold { lastSpeechAt = Date() }
        } else if rms > speechThreshold {
            speechDetected = true
            lastSpeechAt = Date()
            samples = preRoll + chunk
            preRoll = []
        } else {
            preRoll.append(contentsOf: chunk)
            let maxPre = Int(sampleRate / 2)
            if preRoll.count > maxPre { preRoll.removeFirst(preRoll.count - maxPre) }
        }
    }

    func state() -> State {
        lock.lock()
        defer { lock.unlock() }
        guard speechDetected else { return State(hasSpeech: false, duration: 0, silence: 0) }
        return State(
            hasSpeech: true,
            duration: Double(samples.count) / sampleRate,
            silence: lastSpeechAt.map { Date().timeIntervalSince($0) } ?? 0
        )
    }

    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        samples = []
        preRoll = []
        speechDetected = false
        lastSpeechAt = nil
    }
}

// 播报英文期间用于屏蔽麦克风输入（仅在系统回声消除不可用时启用）
final class MicGate: @unchecked Sendable {
    private let lock = NSLock()
    private var _muted = false
    private var _aecActive = false
    var muted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _muted }
        set { lock.lock(); _muted = newValue; lock.unlock() }
    }
    // 系统回声消除已开启时不再静音收音
    var aecActive: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _aecActive }
        set { lock.lock(); _aecActive = newValue; lock.unlock() }
    }
}

final class EnglishSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    var onSpeakingChanged: ((Bool) -> Void)?
    var voiceIdentifier: String?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    private var voice: AVSpeechSynthesisVoice? {
        if let id = voiceIdentifier, let v = AVSpeechSynthesisVoice(identifier: id) {
            return v
        }
        return AVSpeechSynthesisVoice(language: "en-US")
    }

    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        synthesizer.speak(utterance)
    }

    func preview(_ text: String) {
        stop()
        speak(text)
    }

    // 静音念一个词把音色加载进内存，消除首次真实播报的载入延迟
    func warmUp() {
        let utterance = AVSpeechUtterance(string: "Hi")
        utterance.voice = voice
        utterance.volume = 0
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        onSpeakingChanged?(true)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onSpeakingChanged?(false)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onSpeakingChanged?(false)
    }
}

@MainActor
final class TranscriptionEngine: ObservableObject {
    enum Backend: String {
        case apple
        case whisper
    }

    @Published var segments: [Segment] = []
    @Published var volatileText = ""
    @Published var status = "就绪"
    @Published var isRunning = false
    @Published var sessionStart: Date?
    @Published var downloadProgress: Double?
    @Published var audioLevel: Double = 0

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private let micGate = MicGate()
    private let speaker = EnglishSpeaker()
    private var backend: Backend = .apple
    private var whisperKit: WhisperKit?
    private let voiceBuffer = VoiceBuffer()
    private var whisperLoop: Task<Void, Never>?

    private var rebuildTap: (() -> Void)?
    private var configRestoreTask: Task<Void, Never>?

    init() {
        speaker.onSpeakingChanged = { [micGate] speaking in
            micGate.muted = speaking && !micGate.aecActive
        }
        // 蓝牙耳机连接/断开等设备变化会让音频引擎停摆，监听后自动恢复
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.handleConfigurationChange() }
        }
    }

    // 注：系统语音处理 setVoiceProcessingEnabled 需要引擎输出端同时运行才会触发输入回调，
    // 而我们用独立的 AVSpeechSynthesizer 播放，启用后麦克风只会收到静音。故关闭它，
    // 改用 micGate 在播报期间静音收音来防回声（aecActive=false）。
    private func disableVoiceProcessing() {
        let input = audioEngine.inputNode
        if input.isVoiceProcessingEnabled {
            try? input.setVoiceProcessingEnabled(false)
        }
        micGate.aecActive = false
    }

    private func handleConfigurationChange() {
        guard isRunning else { return }
        configRestoreTask?.cancel()
        configRestoreTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled, self.isRunning else { return }
            self.status = "检测到音频设备变化，正在恢复…"
            self.audioEngine.stop()
            self.audioEngine.inputNode.removeTap(onBus: 0)
            self.rebuildTap?()
            self.audioEngine.prepare()
            do {
                try self.audioEngine.start()
                self.status = self.backend == .whisper ? "正在聆听…（Whisper · 中英自动识别）" : "正在聆听…"
            } catch {
                self.status = "设备切换后麦克风恢复失败：\(error.localizedDescription)"
            }
        }
    }

    func speak(_ text: String) {
        speaker.speak(text)
    }

    func previewVoice(_ text: String) {
        speaker.preview(text)
    }

    func setEnglishVoice(identifier: String) {
        speaker.voiceIdentifier = identifier.isEmpty ? nil : identifier
        if !isRunning {
            speaker.warmUp()
        }
    }

    func start(localeID: String, backend: Backend) async {
        guard !isRunning else { return }
        self.backend = backend
        segments = []
        volatileText = ""
        sessionStart = Date()

        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            status = "麦克风权限被拒绝：请在系统设置中开启麦克风权限"
            return
        }

        #if os(iOS)
        do {
            try configureAudioSession()
        } catch {
            status = "音频会话启动失败：\(error.localizedDescription)"
            return
        }
        #endif

        switch backend {
        case .apple:
            await startApple(localeID: localeID)
        case .whisper:
            await startWhisper()
        }
    }

    #if os(iOS)
    // iOS 必须显式配置音频会话才能边录边放；.defaultToSpeaker 让英文播报走扬声器
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        try session.setActive(true)
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    #endif

    private func startApple(localeID: String) async {
        let locale = Locale(identifier: localeID)
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        self.transcriber = transcriber

        do {
            try await ensureModel(for: transcriber, locale: locale)
        } catch {
            status = "语音模型不可用：\(error.localizedDescription)"
            return
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            status = "无法确定识别音频格式"
            return
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        self.volatileText = ""
                        if !text.isEmpty {
                            self.segments.append(Segment(
                                time: Date(),
                                text: text,
                                translation: nil,
                                isEnglish: Self.looksEnglish(text)
                            ))
                        }
                    } else {
                        self.volatileText = text
                    }
                }
            } catch {
                if !(error is CancellationError) {
                    self?.status = "识别中断：\(error.localizedDescription)"
                }
            }
        }

        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            status = "识别器启动失败：\(error.localizedDescription)"
            return
        }

        disableVoiceProcessing()
        rebuildTap = { [weak self] in
            guard let self else { return }
            let input = self.audioEngine.inputNode
            let micFormat = input.outputFormat(forBus: 0)
            guard micFormat.sampleRate > 0,
                  let converter = AVAudioConverter(from: micFormat, to: analyzerFormat) else { return }
            let gate = self.micGate
            input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buffer, _ in
                if gate.muted { return }
                self?.reportLevel(from: buffer)
                if let converted = Self.convert(buffer, using: converter, to: analyzerFormat) {
                    continuation.yield(AnalyzerInput(buffer: converted))
                }
            }
        }
        rebuildTap?()
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            audioEngine.inputNode.removeTap(onBus: 0)
            status = "麦克风启动失败：\(error.localizedDescription)"
            return
        }

        isRunning = true
        status = "正在聆听…"
    }

    // MARK: - Whisper 后端

    // 解码管线内置的自动检测不可靠（失败时回退英文会把中文意译掉），
    // 改为每句话先用独立检测，en 之外一律按 zh 解码（zh 解码英文语音仍输出英文原文，反向则会翻译）
    private var utteranceLang: String?

    // iPhone 用量化版（更小、编译更快、内存占用更低）；Mac 用完整版
    nonisolated static var whisperVariant: String {
        #if os(iOS)
        return "large-v3_turbo_954"
        #else
        return "large-v3_turbo"
        #endif
    }

    nonisolated static var whisperModelDownloaded: Bool {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-\(whisperVariant)")
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent("TextDecoder.mlmodelc").path)
    }

    private func downloadWhisperModel() async throws {
        downloadProgress = 0
        defer { downloadProgress = nil }
        let onProgress: (Progress) -> Void = { [weak self] p in
            let fraction = p.fractionCompleted
            Task { @MainActor in self?.downloadProgress = fraction }
        }
        do {
            status = "正在下载 Whisper 识别模型（约 1GB，仅首次）…"
            _ = try await WhisperKit.download(variant: Self.whisperVariant, progressCallback: onProgress)
        } catch {
            // 国内网络直连 HuggingFace 常失败，自动切换镜像源重试
            status = "官方源连接失败，改用国内镜像下载…"
            _ = try await WhisperKit.download(
                variant: Self.whisperVariant,
                endpoint: "https://hf-mirror.com",
                progressCallback: onProgress
            )
        }
    }

    private func ensureWhisper() async throws -> WhisperKit {
        if let whisperKit { return whisperKit }
        if !Self.whisperModelDownloaded {
            try await downloadWhisperModel()
        }
        status = "正在加载 Whisper 模型（首次需编译优化，可能要几分钟）…"
        let config = WhisperKitConfig(
            model: Self.whisperVariant,
            verbose: false,
            logLevel: .error,
            prewarm: true
        )
        let wk = try await WhisperKit(config)
        whisperKit = wk
        return wk
    }

    private func startWhisper() async {
        let wk: WhisperKit
        do {
            wk = try await ensureWhisper()
        } catch {
            status = "Whisper 模型加载失败：\(error.localizedDescription)"
            return
        }

        guard let whisperFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
        ) else {
            status = "无法创建 16kHz 音频格式"
            return
        }

        voiceBuffer.reset()
        utteranceLang = nil
        disableVoiceProcessing()
        rebuildTap = { [weak self] in
            guard let self else { return }
            let input = self.audioEngine.inputNode
            let micFormat = input.outputFormat(forBus: 0)
            guard micFormat.sampleRate > 0,
                  let converter = AVAudioConverter(from: micFormat, to: whisperFormat) else { return }
            let gate = self.micGate
            let vb = self.voiceBuffer
            input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buffer, _ in
                if gate.muted { return }
                self?.reportLevel(from: buffer)
                guard let converted = Self.convert(buffer, using: converter, to: whisperFormat),
                      let ch = converted.floatChannelData else { return }
                vb.ingest(Array(UnsafeBufferPointer(start: ch[0], count: Int(converted.frameLength))))
            }
        }
        rebuildTap?()
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            audioEngine.inputNode.removeTap(onBus: 0)
            status = "麦克风启动失败：\(error.localizedDescription)"
            return
        }

        var lastInterimDuration = 0.0
        whisperLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, !Task.isCancelled else { return }
                let st = self.voiceBuffer.state()
                guard st.hasSpeech else { continue }
                if st.silence > 0.85 || st.duration > 28 {
                    let samples = self.voiceBuffer.snapshot()
                    self.voiceBuffer.reset()
                    lastInterimDuration = 0
                    self.volatileText = ""
                    // 有效语音太短的（不足 0.35s）当作噪音丢弃
                    if st.duration - st.silence > 0.35 {
                        await self.whisperTranscribe(samples, with: wk, final: true)
                    }
                } else if st.silence < 0.4, st.duration > 1.0, st.duration - lastInterimDuration > 0.8 {
                    // 仅在用户仍在说话时跑临时稿，避免临时识别占住引擎、拖慢定稿
                    lastInterimDuration = st.duration
                    await self.whisperTranscribe(self.voiceBuffer.snapshot(), with: wk, final: false)
                }
            }
        }

        isRunning = true
        status = "正在聆听…（Whisper · 中英自动识别）"
    }

    private func whisperTranscribe(_ samples: [Float], with wk: WhisperKit, final: Bool) async {
        if utteranceLang == nil {
            if let (raw, _) = try? await wk.detectLangauge(audioArray: samples) {
                utteranceLang = raw == "en" ? "en" : "zh"
            }
        }
        let lang = utteranceLang ?? "zh"
        // withoutTimestamps：单窗口语句不需要时间戳 token，省 20-30% 解码时间
        let options = DecodingOptions(
            task: .transcribe,
            language: lang,
            temperature: 0,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        let results: [TranscriptionResult]
        do {
            results = try await wk.transcribe(audioArray: samples, decodeOptions: options)
        } catch {
            return
        }
        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if final {
            utteranceLang = nil
            guard !text.isEmpty else { return }
            let isEn = lang == "en" || Self.looksEnglish(text)
            segments.append(Segment(time: Date(), text: text, translation: nil, isEnglish: isEn))
        } else if !text.isEmpty {
            volatileText = text
        }
    }

    func stop() async {
        guard isRunning else { return }
        configRestoreTask?.cancel()
        configRestoreTask = nil
        rebuildTap = nil
        speaker.stop()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        status = "正在收尾…"
        switch backend {
        case .apple:
            inputContinuation?.finish()
            inputContinuation = nil
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
            resultsTask?.cancel()
            resultsTask = nil
            analyzer = nil
            transcriber = nil
        case .whisper:
            whisperLoop?.cancel()
            whisperLoop = nil
            let st = voiceBuffer.state()
            let samples = voiceBuffer.snapshot()
            voiceBuffer.reset()
            volatileText = ""
            if st.hasSpeech, st.duration - st.silence > 0.35, let wk = whisperKit {
                await whisperTranscribe(samples, with: wk, final: true)
            }
        }
        isRunning = false
        audioLevel = 0
        #if os(iOS)
        deactivateAudioSession()
        #endif
        status = "已停止"
    }

    private func ensureModel(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        let target = locale.identifier(.bcp47)
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == target }) else {
            throw NSError(domain: "LiveTranscriber", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "系统暂不支持「\(target)」的本地识别"
            ])
        }
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == target }) { return }
        status = "首次使用该语言，正在下载语音模型…"
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    // 音频线程调用：抽样算 RMS 音量，回主线程驱动电平动画（带衰减平滑）
    nonisolated private func reportLevel(from buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        guard n > 16 else { return }
        var sum: Float = 0
        var count = 0
        var i = 0
        while i < n {
            sum += ch[0][i] * ch[0][i]
            count += 1
            i += 16
        }
        let level = min(1.0, Double((sum / Float(count)).squareRoot()) * 18)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.audioLevel = max(level, self.audioLevel * 0.72)
        }
    }

    nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error ? nil : out
    }

    // 字母字符里 ASCII 占比超过 70% 即视为英文段落（中文汉字也属于 letters）
    nonisolated static func looksEnglish(_ text: String) -> Bool {
        var ascii = 0, total = 0
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            total += 1
            if scalar.isASCII { ascii += 1 }
        }
        guard total >= 2 else { return false }
        return Double(ascii) / Double(total) > 0.7
    }

    func markdown() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm:ss"
        var lines = ["# 现场转录 \(df.string(from: sessionStart ?? Date()))", ""]
        for seg in segments {
            lines.append("- **[\(tf.string(from: seg.time))]** \(seg.text)")
            if let t = seg.translation, !t.isEmpty {
                lines.append(seg.isEnglish ? "  > 译：\(t)" : "  > EN: \(t)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    nonisolated static var transcriptsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("实时转录", isDirectory: true)
    }

    @discardableResult
    func saveMarkdown() -> URL? {
        guard !segments.isEmpty else { return nil }
        let dir = Self.transcriptsDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd_HHmmss"
            let url = dir.appendingPathComponent("转录_\(df.string(from: sessionStart ?? Date())).md")
            try markdown().write(to: url, atomically: true, encoding: .utf8)
            status = "已停止，转录已保存"
            return url
        } catch {
            status = "保存失败：\(error.localizedDescription)"
            return nil
        }
    }
}

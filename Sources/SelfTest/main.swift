// 离线自检：用音频文件验证转录链路（不需要麦克风）
// 用法: scribe-test <音频文件> <locale|whisper>
//   例: scribe-test /tmp/t.aiff zh-CN      — 苹果 SpeechAnalyzer
//       scribe-test /tmp/t.aiff whisper    — WhisperKit (large-v3-turbo)
import AVFoundation
import Foundation
import Speech
import WhisperKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: scribe-test <audiofile> <localeID|whisper>")
    exit(1)
}
let fileURL = URL(fileURLWithPath: args[1])

if args[2] == "whisper" {
    let forcedLang: String? = args.count >= 4 ? args[3] : nil
    let config = WhisperKitConfig(
        model: "large-v3_turbo",
        verbose: false,
        logLevel: .error,
        prewarm: true
    )
    print("loading WhisperKit (large-v3_turbo)…")
    let whisper = try await WhisperKit(config)
    print("model folder:", whisper.modelFolder?.path ?? "?")
    let audioBuffer = try AudioProcessor.loadAudio(fromPath: fileURL.path, endTime: 30.0)
    let audioArray = AudioProcessor.convertBufferToArray(buffer: audioBuffer)
    let (detected, _) = try await whisper.detectLangauge(audioArray: audioArray)
    let clamped = detected == "en" ? "en" : "zh"
    print("detect: raw=\(detected) -> clamped=\(clamped)")

    let opts = DecodingOptions(
        task: .transcribe,
        language: forcedLang ?? clamped,
        temperature: 0,
        detectLanguage: false,
        skipSpecialTokens: true
    )
    for round in 1...2 {
        let start = Date()
        let results: [TranscriptionResult] = try await whisper.transcribe(audioPath: fileURL.path, decodeOptions: opts)
        let dt = Date().timeIntervalSince(start)
        for r in results {
            print("round\(round) WHISPER[lang=\(r.language)]:", r.text)
        }
        print(String(format: "round%d transcribe time: %.2fs", round, dt))
    }
    exit(0)
}

let locale = Locale(identifier: args[2])
let target = locale.identifier(.bcp47)

let transcriber = SpeechTranscriber(
    locale: locale,
    transcriptionOptions: [],
    reportingOptions: [],
    attributeOptions: []
)

let supported = await SpeechTranscriber.supportedLocales
guard supported.contains(where: { $0.identifier(.bcp47) == target }) else {
    print("FAIL: locale \(target) not supported")
    exit(2)
}

let installed = await SpeechTranscriber.installedLocales
if !installed.contains(where: { $0.identifier(.bcp47) == target }) {
    print("downloading model for \(target)…")
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        try await request.downloadAndInstall()
    }
    print("model installed")
}

let analyzer = SpeechAnalyzer(modules: [transcriber])
let file = try AVAudioFile(forReading: fileURL)

let collector = Task {
    var finals: [String] = []
    do {
        for try await result in transcriber.results where result.isFinal {
            finals.append(String(result.text.characters))
        }
    } catch {
        print("results error:", error)
    }
    return finals
}

if let last = try await analyzer.analyzeSequence(from: file) {
    try await analyzer.finalizeAndFinish(through: last)
} else {
    try await analyzer.finalizeAndFinishThroughEndOfInput()
}

let finals = await collector.value
print("TRANSCRIPT[\(target)]:", finals.joined(separator: " | "))

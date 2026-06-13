import AVFoundation
import SwiftUI
import Translation
import UIKit

struct ContentView: View {
    @StateObject private var engine = TranscriptionEngine()
    @AppStorage("appleLocaleID") private var localeID = "zh-CN"
    @AppStorage("backend") private var backendID = "whisper"
    @AppStorage("interpreterMode") private var interpreterMode = true
    @AppStorage("englishVoiceID") private var englishVoiceID = ""
    @AppStorage("appearanceMode") private var appearanceMode = "auto"
    @AppStorage("transcriptFontID") private var fontID = "system"
    @AppStorage("transcriptFontSize") private var fontSize = 16.0
    @AppStorage("transcriptColorHex") private var colorHex = ""
    @State private var englishVoices: [AVSpeechSynthesisVoice] = []
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var translationSession: TranslationSession?
    @State private var zhEnConfig: TranslationSession.Configuration?
    @State private var zhEnSession: TranslationSession?
    @State private var pendingTranslations: Set<UUID> = []
    @State private var savedURL: URL?
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showWhisperDownloadPrompt = false
    @State private var shareItems: [Any]?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                transcriptList
                bottomBar
            }
            .navigationTitle("实时转录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showHistory = true } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }
        }
        .preferredColorScheme(appearanceMode == "light" ? .light : appearanceMode == "dark" ? .dark : nil)
        .onAppear(perform: setup)
        .translationTask(translationConfig) { session in
            translationSession = session
            try? await session.prepareTranslation()
            translateNewSegments()
        }
        .translationTask(zhEnConfig) { session in
            zhEnSession = session
            try? await session.prepareTranslation()
            translateNewSegments()
        }
        .onChange(of: engine.segments.count) { _, _ in translateNewSegments() }
        .onChange(of: englishVoiceID) { _, v in engine.setEnglishVoice(identifier: v) }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(engine: engine, voices: englishVoices)
        }
        .sheet(isPresented: $showHistory) {
            HistorySheet()
        }
        .sheet(item: Binding(
            get: { shareItems.map { ShareItems(items: $0) } },
            set: { shareItems = $0?.items }
        )) { wrapper in
            ShareSheet(items: wrapper.items)
        }
        .alert("需要下载语音识别模型", isPresented: $showWhisperDownloadPrompt) {
            Button("下载并开始") { Task { await start() } }
            Button("改用苹果引擎（免下载）") {
                backendID = "apple"
                Task { await start() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("首次使用 Whisper 引擎需下载约 1.6GB 识别模型，仅需一次，之后完全离线运行。也可改用系统自带的苹果引擎，无需下载。")
        }
    }

    // MARK: - 顶部状态

    private var statusBar: some View {
        HStack(spacing: 6) {
            Circle().fill(engine.isRunning ? .red : .gray.opacity(0.4)).frame(width: 7, height: 7)
            Text(engine.status)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let p = engine.downloadProgress {
                ProgressView(value: p).frame(width: 90)
                Text("\(Int(p * 100))%").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer()
            if interpreterMode {
                Text("对话翻译")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(.blue.opacity(0.12)))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    // MARK: - 转录列表

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if engine.segments.isEmpty && engine.volatileText.isEmpty {
                        emptyState
                    }
                    ForEach(engine.segments) { seg in
                        if interpreterMode {
                            HStack(spacing: 0) {
                                if !seg.isEnglish { Spacer(minLength: 50) }
                                BubbleCard(segment: seg, conversational: true,
                                           fontID: fontID, fontSize: fontSize, colorHex: colorHex)
                                if seg.isEnglish { Spacer(minLength: 50) }
                            }
                        } else {
                            BubbleCard(segment: seg, conversational: false,
                                       fontID: fontID, fontSize: fontSize, colorHex: colorHex)
                        }
                    }
                    if !engine.volatileText.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(engine.volatileText)
                                .font(transcriptFont(id: fontID, size: fontSize - 1))
                                .italic().foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .onChange(of: engine.segments.count) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: engine.volatileText) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(brandGradient)
            Text("点按下方按钮开始")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            Text("对方说英文自动附中文译文\n你说中文自动翻成英文并朗读给对方\n停止后可导出 Markdown")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: - 底部录音区

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if !engine.segments.isEmpty && !engine.isRunning {
                HStack(spacing: 18) {
                    Button { exportShare() } label: {
                        Label("导出", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        UIPasteboard.general.string = engine.markdown()
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                }
                .font(.system(size: 13))
            }
            HStack(spacing: 20) {
                LevelMeter(level: engine.audioLevel).opacity(engine.isRunning ? 1 : 0)
                recordButton
                LevelMeter(level: engine.audioLevel).opacity(engine.isRunning ? 1 : 0)
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var recordButton: some View {
        Button {
            if engine.isPreparing {
                return   // 下载/加载中，忽略点击
            } else if engine.isRunning {
                Task {
                    await engine.stop()
                    savedURL = engine.saveMarkdown()
                }
            } else if backendID == "whisper" && !TranscriptionEngine.whisperModelDownloaded {
                showWhisperDownloadPrompt = true
            } else {
                Task { await start() }
            }
        } label: {
            ZStack {
                if engine.isRunning { PulsingRing() }
                Circle()
                    .fill(engine.isRunning
                        ? AnyShapeStyle(LinearGradient(colors: [.red, Color(red: 0.85, green: 0.15, blue: 0.3)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing))
                        : AnyShapeStyle(brandGradient))
                    .frame(width: 66, height: 66)
                    .shadow(color: engine.isRunning ? .red.opacity(0.45) : .blue.opacity(0.35), radius: 12, y: 2)
                    .opacity(engine.isPreparing ? 0.5 : 1)
                if engine.isPreparing {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                } else {
                    Image(systemName: engine.isRunning ? "stop.fill" : "mic.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(engine.isPreparing)
    }

    // MARK: - 逻辑

    private func setup() {
        translationConfig = .init(source: .init(identifier: "en"), target: .init(identifier: "zh-Hans"))
        zhEnConfig = .init(source: .init(identifier: "zh-Hans"), target: .init(identifier: "en"))
        englishVoices = loadEnglishVoices()
        if englishVoiceID.isEmpty || !englishVoices.contains(where: { $0.identifier == englishVoiceID }) {
            englishVoiceID = AVSpeechSynthesisVoice(language: "en-US")?.identifier ?? englishVoices.first?.identifier ?? ""
        }
        engine.setEnglishVoice(identifier: englishVoiceID)
    }

    private func start() async {
        savedURL = nil
        pendingTranslations = []
        await engine.start(localeID: localeID, backend: backendID == "whisper" ? .whisper : .apple)
    }

    private func exportShare() {
        let url = savedURL ?? engine.saveMarkdown()
        if let url { shareItems = [url] }
    }

    private func translateNewSegments() {
        for seg in engine.segments where seg.translation == nil && !pendingTranslations.contains(seg.id) {
            let id = seg.id
            let text = seg.text
            if seg.isEnglish {
                guard let session = translationSession else { continue }
                pendingTranslations.insert(id)
                Task {
                    guard let r = try? await session.translate(text) else { return }
                    if let i = engine.segments.firstIndex(where: { $0.id == id }) {
                        engine.segments[i].translation = r.targetText
                    }
                }
            } else if interpreterMode {
                guard let session = zhEnSession else { continue }
                pendingTranslations.insert(id)
                Task {
                    guard let r = try? await session.translate(text) else { return }
                    if let i = engine.segments.firstIndex(where: { $0.id == id }) {
                        engine.segments[i].translation = r.targetText
                    }
                    engine.speak(r.targetText)
                }
            }
        }
    }
}

struct ShareItems: Identifiable {
    let id = UUID()
    let items: [Any]
}

// MARK: - 气泡卡片

struct BubbleCard: View {
    let segment: Segment
    let conversational: Bool
    let fontID: String
    let fontSize: Double
    let colorHex: String
    @Environment(\.colorScheme) private var colorScheme

    private static let tf: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private var accent: Color {
        segment.isEnglish ? Color(red: 0.25, green: 0.48, blue: 0.98) : Color(red: 0.18, green: 0.62, blue: 0.41)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(Self.tf.string(from: segment.time))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(conversational ? (segment.isEnglish ? "对方" : "我") : (segment.isEnglish ? "EN" : "中"))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(accent.opacity(0.12), in: Capsule())
            }
            Text(segment.text)
                .font(transcriptFont(id: fontID, size: fontSize))
                .foregroundStyle(legibleTextColor(hex: colorHex, scheme: colorScheme))
                .textSelection(.enabled)
            if let t = segment.translation {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5).fill(accent.opacity(0.65)).frame(width: 3)
                    Text(t)
                        .font(transcriptFont(id: fontID, size: max(fontSize - 1, 10)))
                        .foregroundStyle(accent)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: conversational ? nil : .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(conversational ? AnyShapeStyle(accent.opacity(0.1)) : AnyShapeStyle(Color(.secondarySystemBackground)))
        )
    }
}

struct LevelMeter: View {
    let level: Double
    private let base: [CGFloat] = [10, 20, 28, 20, 10]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                Capsule().fill(brandGradient).frame(width: 3, height: 4 + base[i] * CGFloat(level))
            }
        }
        .frame(height: 32)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

struct PulsingRing: View {
    @State private var animate = false
    var body: some View {
        Circle()
            .stroke(Color.red.opacity(0.5), lineWidth: 2)
            .frame(width: 66, height: 66)
            .scaleEffect(animate ? 1.5 : 1)
            .opacity(animate ? 0 : 0.8)
            .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: animate)
            .onAppear { animate = true }
    }
}

// MARK: - 音色工具（与 macOS 版一致）

func loadEnglishVoices() -> [AVSpeechSynthesisVoice] {
    let all = AVSpeechSynthesisVoice.speechVoices()
        .filter { $0.language.hasPrefix("en") }
        .filter { !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice) }
    let good = all.filter { $0.quality != .default }
    return (good.isEmpty ? all : good).sorted { a, b in
        if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue > b.quality.rawValue }
        if (a.language == "en-US") != (b.language == "en-US") { return a.language == "en-US" }
        return a.name < b.name
    }
}

func voiceLabel(_ v: AVSpeechSynthesisVoice) -> String {
    let region: String
    switch v.language {
    case "en-US": region = "美"
    case "en-GB": region = "英"
    case "en-AU": region = "澳"
    case "en-CA": region = "加"
    case "en-IE": region = "爱尔兰"
    case "en-IN": region = "印度"
    case "en-ZA": region = "南非"
    default: region = v.language
    }
    let quality = v.quality == .premium ? "·高级" : v.quality == .enhanced ? "·增强" : ""
    return "\(v.name)（\(region)\(quality)）"
}

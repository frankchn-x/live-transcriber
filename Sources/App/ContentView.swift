import AppKit
import AVFoundation
import SwiftUI
import Translation

private let brandGradient = LinearGradient(
    colors: [Color(red: 0.25, green: 0.48, blue: 0.98), Color(red: 0.55, green: 0.36, blue: 0.96)],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
)

// 转录文字样式（字体/字号/颜色），全局 AppStorage 持久化
func transcriptFont(id: String, size: Double) -> Font {
    switch id {
    case "system": return .system(size: size)
    case "mono": return .system(size: size, design: .monospaced)
    default: return .custom(id, size: size)
    }
}

// 自定义颜色的相对亮度（0 黑 ~ 1 白），用于深浅色模式下的可读性保护
func hexLuminance(_ hex: String) -> Double? {
    guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
    let r = Double((v >> 16) & 0xFF) / 255
    let g = Double((v >> 8) & 0xFF) / 255
    let b = Double(v & 0xFF) / 255
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

// 在当前模式下对比度不足的自定义颜色回退为默认色，避免深色模式黑字、浅色模式白字
func legibleTextColor(hex: String, scheme: ColorScheme) -> Color {
    guard let c = Color(hex: hex), let lum = hexLuminance(hex) else { return .primary }
    if scheme == .dark && lum < 0.3 { return .primary }
    if scheme == .light && lum > 0.8 { return .primary }
    return c
}

extension Color {
    init?(hex: String) {
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }

    var hexString: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "" }
        return String(
            format: "%02X%02X%02X",
            Int(round(c.redComponent * 255)),
            Int(round(c.greenComponent * 255)),
            Int(round(c.blueComponent * 255))
        )
    }
}

struct ContentView: View {
    @StateObject private var engine = TranscriptionEngine()
    @AppStorage("appleLocaleID") private var localeID = "zh-CN"
    @AppStorage("backend") private var backendID = "whisper"
    @AppStorage("interpreterMode") private var interpreterMode = true
    @AppStorage("englishVoiceID") private var englishVoiceID = ""
    @State private var englishVoices: [AVSpeechSynthesisVoice] = []
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var translationSession: TranslationSession?
    @State private var zhEnConfig: TranslationSession.Configuration?
    @State private var zhEnSession: TranslationSession?
    @State private var pendingTranslations: Set<UUID> = []
    @State private var savedURL: URL?
    @State private var copied = false
    @State private var showWhisperDownloadPrompt = false
    @State private var showFontSettings = false
    @State private var showHistory = false
    @State private var obsidianDone = false
    @State private var exportError: String?
    @AppStorage("obsidianVaultPath") private var obsidianVaultPath = ""
    @AppStorage("transcriptFontID") private var transcriptFontID = "system"
    @AppStorage("transcriptFontSize") private var transcriptFontSize = 14.0
    @AppStorage("appearanceMode") private var appearanceMode = "auto"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            transcriptList
            footer
        }
        .frame(minWidth: 660, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(appearanceMode == "light" ? .light : appearanceMode == "dark" ? .dark : nil)
        .onAppear {
            translationConfig = TranslationSession.Configuration(
                source: Locale.Language(identifier: "en"),
                target: Locale.Language(identifier: "zh-Hans")
            )
            zhEnConfig = TranslationSession.Configuration(
                source: Locale.Language(identifier: "zh-Hans"),
                target: Locale.Language(identifier: "en")
            )
            englishVoices = loadEnglishVoices()
            if englishVoiceID.isEmpty || !englishVoices.contains(where: { $0.identifier == englishVoiceID }) {
                englishVoiceID = AVSpeechSynthesisVoice(language: "en-US")?.identifier
                    ?? englishVoices.first?.identifier ?? ""
            }
            engine.setEnglishVoice(identifier: englishVoiceID)
        }
        .onChange(of: englishVoiceID) { _, newValue in
            engine.setEnglishVoice(identifier: newValue)
        }
        .translationTask(translationConfig) { session in
            translationSession = session
            try? await session.prepareTranslation()
            // 会话就绪后补翻启动初期被跳过的段落
            translateNewSegments()
        }
        .translationTask(zhEnConfig) { session in
            zhEnSession = session
            try? await session.prepareTranslation()
            translateNewSegments()
        }
        .onChange(of: engine.segments.count) { _, _ in
            translateNewSegments()
        }
        .onChange(of: engine.segments) { _, _ in
            // 停止后才补完的译文也写回已保存的文件，保证复盘记录完整
            if !engine.isRunning, savedURL != nil {
                savedURL = engine.saveMarkdown()
            }
        }
        .alert("需要下载语音识别模型", isPresented: $showWhisperDownloadPrompt) {
            Button("下载并开始") {
                Task { await startTranscription() }
            }
            Button("改用苹果引擎（免下载）") {
                backendID = "apple"
                Task { await startTranscription() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("首次使用 Whisper 引擎需要下载约 1.6GB 的识别模型，仅需一次，之后完全离线运行。\n\n也可以改用系统自带的苹果引擎，无需下载大模型，但中英混合识别准确率稍低。")
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(brandGradient)
            VStack(alignment: .leading, spacing: 3) {
                Text("实时转录")
                    .font(.system(size: 15, weight: .semibold))
                HStack(spacing: 5) {
                    statusPill(
                        color: .green,
                        text: backendID == "whisper" ? "Whisper · 本地运行，数据不出本机" : "苹果引擎 · 本地运行，数据不出本机"
                    )
                    if interpreterMode {
                        statusPill(color: .blue, text: "对话翻译")
                    }
                }
            }
            Spacer(minLength: 20)

            Button {
                showHistory = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .help("历史转录记录")
            .sheet(isPresented: $showHistory) {
                HistoryView()
            }

            Button {
                showFontSettings.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .help("设置：识别引擎、对话翻译、播报音色、外观与文字")
            .popover(isPresented: $showFontSettings, arrowEdge: .bottom) {
                SettingsView(engine: engine, voices: englishVoices)
            }
        }
        .padding(.leading, 78)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .gesture(WindowDragGesture())
    }

    private func statusPill(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 4, height: 4)
            Text(text)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.1)))
    }

    // MARK: - 转录区

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
                                if !seg.isEnglish { Spacer(minLength: 80) }
                                SegmentCard(segment: seg, conversational: true)
                                if seg.isEnglish { Spacer(minLength: 80) }
                            }
                        } else {
                            SegmentCard(segment: seg)
                        }
                    }
                    if !engine.volatileText.isEmpty {
                        volatileCard
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: engine.segments.count) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: engine.volatileText) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(brandGradient.opacity(0.85))
            Text("点击下方按钮开始")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text("英文发言自动附中文翻译 · 开启「对话翻译」后你的中文会翻成英文播报\n停止后自动保存为 Markdown")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    private var volatileCard: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
            Text(engine.volatileText)
                .font(transcriptFont(id: transcriptFontID, size: max(transcriptFontSize - 1, 10)))
                .italic()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }

    // MARK: - 底部

    private var footer: some View {
        ZStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(engine.isRunning ? Color.red : Color.gray.opacity(0.45))
                    .frame(width: 7, height: 7)
                Text(engine.status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let p = engine.downloadProgress {
                    ProgressView(value: p)
                        .frame(width: 110)
                    Text("\(Int(p * 100))%")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()

                if let url = savedURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("在 Finder 中显示已保存的 Markdown")

                    Button {
                        do {
                            try Obsidian.export(file: url, customPath: obsidianVaultPath)
                            obsidianDone = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                obsidianDone = false
                            }
                        } catch {
                            exportError = error.localizedDescription
                        }
                    } label: {
                        Image(systemName: obsidianDone ? "checkmark.circle.fill" : "tray.and.arrow.up")
                            .font(.system(size: 14))
                            .foregroundStyle(obsidianDone ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    }
                    .buttonStyle(.plain)
                    .help("存入 Obsidian 并打开")
                    .alert("导出失败", isPresented: Binding(
                        get: { exportError != nil },
                        set: { if !$0 { exportError = nil } }
                    )) {
                        Button("好", role: .cancel) {}
                    } message: {
                        Text(exportError ?? "")
                    }
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(engine.markdown(), forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.system(size: 14))
                        .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .disabled(engine.segments.isEmpty)
                .help("复制 Markdown")
            }

            HStack(spacing: 14) {
                LevelMeter(level: engine.audioLevel)
                    .opacity(engine.isRunning ? 1 : 0)
                recordButton
                LevelMeter(level: engine.audioLevel)
                    .opacity(engine.isRunning ? 1 : 0)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private var recordButton: some View {
        Button {
            if engine.isRunning {
                Task {
                    await engine.stop()
                    savedURL = engine.saveMarkdown()
                }
            } else if backendID == "whisper" && !TranscriptionEngine.whisperModelDownloaded {
                showWhisperDownloadPrompt = true
            } else {
                Task { await startTranscription() }
            }
        } label: {
            ZStack {
                if engine.isRunning {
                    PulsingRing()
                }
                Circle()
                    .fill(engine.isRunning
                        ? AnyShapeStyle(LinearGradient(colors: [.red, Color(red: 0.85, green: 0.15, blue: 0.3)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing))
                        : AnyShapeStyle(brandGradient))
                    .frame(width: 54, height: 54)
                    .shadow(color: engine.isRunning ? .red.opacity(0.45) : .blue.opacity(0.35),
                            radius: engine.isRunning ? 12 : 8, y: 2)
                Image(systemName: engine.isRunning ? "stop.fill" : "mic.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .help(engine.isRunning ? "停止并保存" : "开始转录")
    }

    private func startTranscription() async {
        savedURL = nil
        pendingTranslations = []
        await engine.start(
            localeID: localeID,
            backend: backendID == "whisper" ? .whisper : .apple
        )
    }

    private func translateNewSegments() {
        for seg in engine.segments where seg.translation == nil && !pendingTranslations.contains(seg.id) {
            let id = seg.id
            let text = seg.text
            if seg.isEnglish {
                // 对方说英文 → 显示中文译文
                guard let session = translationSession else { continue }
                pendingTranslations.insert(id)
                Task {
                    guard let response = try? await session.translate(text) else { return }
                    if let idx = engine.segments.firstIndex(where: { $0.id == id }) {
                        engine.segments[idx].translation = response.targetText
                    }
                }
            } else if interpreterMode {
                // 对话模式：我说中文 → 翻成英文并语音播报
                guard let session = zhEnSession else { continue }
                pendingTranslations.insert(id)
                Task {
                    guard let response = try? await session.translate(text) else { return }
                    if let idx = engine.segments.firstIndex(where: { $0.id == id }) {
                        engine.segments[idx].translation = response.targetText
                    }
                    engine.speak(response.targetText)
                }
            }
        }
    }

}

// MARK: - 音色工具

func loadEnglishVoices() -> [AVSpeechSynthesisVoice] {
    let all = AVSpeechSynthesisVoice.speechVoices()
        .filter { $0.language.hasPrefix("en") }
        .filter { !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice) }
    // 只展示增强/高级音质；一台机器上一个都没装时退回完整列表
    let good = all.filter { $0.quality != .default }
    return (good.isEmpty ? all : good)
        .sorted { a, b in
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
    case "en-SG": region = "新加坡"
    default: region = v.language
    }
    let quality: String
    switch v.quality {
    case .premium: quality = "·高级"
    case .enhanced: quality = "·增强"
    default: quality = ""
    }
    return "\(v.name)（\(region)\(quality)）"
}

// MARK: - Obsidian 导出

enum Obsidian {
    struct ExportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // 优先使用手动指定的库路径；否则从 Obsidian 配置里找当前打开的库
    static func vaultURL(customPath: String) -> URL? {
        if !customPath.isEmpty {
            return URL(fileURLWithPath: customPath)
        }
        let cfg = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: cfg),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = json["vaults"] as? [String: [String: Any]] else { return nil }
        let entries = Array(vaults.values)
        if let open = entries.first(where: { ($0["open"] as? Bool) == true }),
           let path = open["path"] as? String {
            return URL(fileURLWithPath: path)
        }
        let newest = entries.max { (($0["ts"] as? Double) ?? 0) < (($1["ts"] as? Double) ?? 0) }
        guard let path = newest?["path"] as? String else { return nil }
        return URL(fileURLWithPath: path)
    }

    @discardableResult
    static func export(file: URL, customPath: String) throws -> URL {
        guard let vault = vaultURL(customPath: customPath) else {
            throw ExportError(message: "未找到 Obsidian 库：请先安装并打开过 Obsidian，或在设置里手动选择库目录")
        }
        let dir = vault.appendingPathComponent("实时转录", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(file.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: file, to: dest)
        openInObsidian(dest: dest, vault: vault)
        return dest
    }

    static func openInObsidian(dest: URL, vault: URL) {
        var comps = URLComponents()
        comps.scheme = "obsidian"
        comps.host = "open"
        comps.queryItems = [
            URLQueryItem(name: "vault", value: vault.lastPathComponent),
            URLQueryItem(name: "file", value: "实时转录/" + dest.deletingPathExtension().lastPathComponent),
        ]
        if let url = comps.url {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - 历史记录

struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("obsidianVaultPath") private var obsidianVaultPath = ""
    @State private var files: [URL] = []
    @State private var selected: URL?
    @State private var content = ""
    @State private var feedback: String?
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("历史记录")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(files.count) 条")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            if files.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("还没有转录记录")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(selection: $selected) {
                        ForEach(files, id: \.self) { url in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title(for: url))
                                    .font(.system(size: 13, weight: .medium))
                                Text(subtitle(for: url))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                            .tag(url)
                        }
                    }
                    .frame(minWidth: 210, idealWidth: 230, maxWidth: 300)
                    detail
                }
            }
        }
        .frame(width: 780, height: 520)
        .onAppear { reload() }
        .onChange(of: selected) { _, _ in
            feedback = nil
            loadContent()
        }
        .confirmationDialog("确定删除这条转录记录？该操作不可撤销。", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { deleteSelected() }
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(content)
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            Divider()
            HStack(spacing: 10) {
                if let feedback {
                    Text(feedback)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("在 Finder 中显示") {
                    if let selected {
                        NSWorkspace.shared.activateFileViewerSelecting([selected])
                    }
                }
                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                    feedback = "已复制"
                }
                Button("存入 Obsidian") {
                    guard let selected else { return }
                    do {
                        try Obsidian.export(file: selected, customPath: obsidianVaultPath)
                        feedback = "已存入 Obsidian 并打开"
                    } catch {
                        feedback = error.localizedDescription
                    }
                }
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Text("删除")
                }
            }
            .controlSize(.small)
            .padding(10)
        }
    }

    private func reload() {
        let dir = TranscriptionEngine.transcriptsDirectory
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        files = items.filter { $0.pathExtension == "md" }
            .sorted { (modified($0) ?? .distantPast) > (modified($1) ?? .distantPast) }
        if selected == nil || !files.contains(selected!) {
            selected = files.first
        }
        loadContent()
    }

    private func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func loadContent() {
        guard let selected else {
            content = ""
            return
        }
        content = (try? String(contentsOf: selected, encoding: .utf8)) ?? ""
    }

    private func deleteSelected() {
        guard let selected else { return }
        try? FileManager.default.removeItem(at: selected)
        self.selected = nil
        reload()
    }

    private func title(for url: URL) -> String {
        // 转录_2026-06-12_183005 → 2026-06-12 18:30
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "_")
        if parts.count >= 3, parts[2].count >= 4 {
            let t = parts[2]
            let hh = t.prefix(2), mm = t.dropFirst(2).prefix(2)
            return "\(parts[1]) \(hh):\(mm)"
        }
        return name
    }

    private func subtitle(for url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let kb = max(1, size / 1024)
        if let d = modified(url) {
            let f = DateFormatter()
            f.dateFormat = "MM-dd HH:mm"
            return "\(kb) KB · 修改于 \(f.string(from: d))"
        }
        return "\(kb) KB"
    }
}

// MARK: - 组件

struct SettingsView: View {
    @ObservedObject var engine: TranscriptionEngine
    let voices: [AVSpeechSynthesisVoice]
    @AppStorage("backend") private var backendID = "whisper"
    @AppStorage("appleLocaleID") private var localeID = "zh-CN"
    @AppStorage("interpreterMode") private var interpreterMode = true
    @AppStorage("englishVoiceID") private var englishVoiceID = ""
    @AppStorage("transcriptFontID") private var fontID = "system"
    @AppStorage("transcriptFontSize") private var fontSize = 14.0
    @AppStorage("transcriptColorHex") private var colorHex = ""
    @AppStorage("appearanceMode") private var appearanceMode = "auto"
    @AppStorage("obsidianVaultPath") private var obsidianVaultPath = ""
    @Environment(\.colorScheme) private var colorScheme

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: colorHex) ?? .primary },
            set: { colorHex = $0.hexString }
        )
    }

    private var vaultDisplayName: String {
        if let vault = Obsidian.vaultURL(customPath: obsidianVaultPath) {
            return vault.lastPathComponent + (obsidianVaultPath.isEmpty ? "（自动）" : "")
        }
        return "未检测到 Obsidian 库"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("转录")
            row("识别引擎") {
                Picker("", selection: $backendID) {
                    Text("Whisper（中英自动）").tag("whisper")
                    Text("苹果（快速）").tag("apple")
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .disabled(engine.isRunning)
            }
            if backendID == "apple" {
                row("识别语言") {
                    Picker("", selection: $localeID) {
                        Text("中文（可中英混说）").tag("zh-CN")
                        Text("English").tag("en-US")
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .disabled(engine.isRunning)
                }
            }
            row("对话翻译") {
                Toggle("", isOn: $interpreterMode)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("开启后：你说的中文会自动翻成英文并语音播报给对方（播报期间暂停收音，避免回声）")
                Spacer()
            }
            if interpreterMode {
                row("播报音色") {
                    Picker("", selection: $englishVoiceID) {
                        ForEach(voices, id: \.identifier) { v in
                            Text(voiceLabel(v)).tag(v.identifier)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .help("更多高质量音色：系统设置 › 辅助功能 › 朗读内容 › 系统声音 中下载，完成后自动出现在此列表")
                    Button {
                        engine.previewVoice("Hello! This is how I sound. Nice to meet you.")
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(brandGradient)
                    }
                    .buttonStyle(.plain)
                    .help("试听所选音色")
                }
            }

            Divider()

            sectionTitle("外观与文字")
            row("外观") {
                Picker("", selection: $appearanceMode) {
                    Text("跟随系统").tag("auto")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
            }
            row("字体") {
                Picker("", selection: $fontID) {
                    Text("系统默认").tag("system")
                    Text("苹方").tag("PingFang SC")
                    Text("宋体").tag("Songti SC")
                    Text("楷体").tag("Kaiti SC")
                    Text("圆体").tag("Yuanti SC")
                    Text("等宽").tag("mono")
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
            row("字号") {
                Slider(value: $fontSize, in: 11...24, step: 1)
                Text("\(Int(fontSize))")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .trailing)
            }
            row("颜色") {
                ColorPicker("", selection: colorBinding, supportsOpacity: false)
                    .labelsHidden()
                    .help("在当前外观下看不清的颜色会自动回退为默认色")
                Spacer()
                Button("恢复默认") {
                    fontID = "system"
                    fontSize = 14
                    colorHex = ""
                }
                .controlSize(.small)
            }

            Divider()

            sectionTitle("导出")
            row("Obsidian") {
                Text(vaultDisplayName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !obsidianVaultPath.isEmpty {
                    Button("自动") { obsidianVaultPath = "" }
                        .controlSize(.small)
                        .help("恢复自动检测当前打开的 Obsidian 库")
                }
                Button("选择…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.prompt = "选择 Obsidian 库目录"
                    if panel.runModal() == .OK, let url = panel.url {
                        obsidianVaultPath = url.path
                    }
                }
                .controlSize(.small)
            }

            Divider()

            Text("预览：实时转录 Live Transcription")
                .font(transcriptFont(id: fontID, size: fontSize))
                .foregroundStyle(legibleTextColor(hex: colorHex, scheme: colorScheme))
                .lineLimit(1)
        }
        .padding(16)
        .frame(width: 330)
        .preferredColorScheme(appearanceMode == "light" ? .light : appearanceMode == "dark" ? .dark : nil)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            content()
        }
    }
}

struct SegmentCard: View {
    let segment: Segment
    var conversational = false
    @AppStorage("transcriptFontID") private var fontID = "system"
    @AppStorage("transcriptFontSize") private var fontSize = 14.0
    @AppStorage("transcriptColorHex") private var colorHex = ""
    @Environment(\.colorScheme) private var colorScheme

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var accent: Color {
        segment.isEnglish ? Color(red: 0.25, green: 0.48, blue: 0.98) : Color(red: 0.18, green: 0.62, blue: 0.41)
    }

    // 对话模式：对方（英文）靠左小尾巴，我（中文）靠右小尾巴
    private var bubbleShape: UnevenRoundedRectangle {
        guard conversational else {
            return UnevenRoundedRectangle(cornerRadii: .init(
                topLeading: 12, bottomLeading: 12, bottomTrailing: 12, topTrailing: 12))
        }
        return segment.isEnglish
            ? UnevenRoundedRectangle(cornerRadii: .init(
                topLeading: 12, bottomLeading: 4, bottomTrailing: 12, topTrailing: 12))
            : UnevenRoundedRectangle(cornerRadii: .init(
                topLeading: 12, bottomLeading: 12, bottomTrailing: 4, topTrailing: 12))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(Self.timeFormatter.string(from: segment.time))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(conversational ? (segment.isEnglish ? "对方" : "我") : (segment.isEnglish ? "EN" : "中"))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(accent.opacity(0.12), in: Capsule())
            }
            Text(segment.text)
                .font(transcriptFont(id: fontID, size: fontSize))
                .foregroundStyle(legibleTextColor(hex: colorHex, scheme: colorScheme))
                .lineSpacing(3)
                .textSelection(.enabled)
            if let t = segment.translation {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(accent.opacity(0.65))
                        .frame(width: 3)
                    Text(t)
                        .font(transcriptFont(id: fontID, size: max(fontSize - 1, 10)))
                        .lineSpacing(3)
                        .foregroundStyle(accent)
                        .textSelection(.enabled)
                }
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: conversational ? nil : .infinity, alignment: .leading)
        .background(
            bubbleShape
                .fill(conversational
                    ? AnyShapeStyle(accent.opacity(0.09))
                    : AnyShapeStyle(Color(nsColor: .textBackgroundColor)))
                .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        )
        .overlay {
            if conversational {
                bubbleShape.strokeBorder(accent.opacity(0.18), lineWidth: 1)
            }
        }
    }
}

struct LevelMeter: View {
    let level: Double
    private let base: [CGFloat] = [10, 20, 28, 20, 10]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(brandGradient)
                    .frame(width: 3, height: 4 + base[i] * CGFloat(level))
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
            .frame(width: 54, height: 54)
            .scaleEffect(animate ? 1.55 : 1)
            .opacity(animate ? 0 : 0.8)
            .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: animate)
            .onAppear { animate = true }
    }
}

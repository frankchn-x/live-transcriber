import AVFoundation
import SwiftUI

struct SettingsSheet: View {
    @ObservedObject var engine: TranscriptionEngine
    let voices: [AVSpeechSynthesisVoice]
    @Environment(\.dismiss) private var dismiss
    @AppStorage("backend") private var backendID = "whisper"
    @AppStorage("appleLocaleID") private var localeID = "zh-CN"
    @AppStorage("interpreterMode") private var interpreterMode = true
    @AppStorage("englishVoiceID") private var englishVoiceID = ""
    @AppStorage("appearanceMode") private var appearanceMode = "auto"
    @AppStorage("transcriptFontID") private var fontID = "system"
    @AppStorage("transcriptFontSize") private var fontSize = 16.0
    @AppStorage("transcriptColorHex") private var colorHex = ""
    @Environment(\.colorScheme) private var colorScheme

    private var colorBinding: Binding<Color> {
        Binding(get: { Color(hex: colorHex) ?? .primary }, set: { colorHex = $0.hexString })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("转录") {
                    Picker("识别引擎", selection: $backendID) {
                        Text("Whisper（中英自动）").tag("whisper")
                        Text("苹果（快速）").tag("apple")
                    }
                    .disabled(engine.isRunning)
                    if backendID == "apple" {
                        Picker("识别语言", selection: $localeID) {
                            Text("中文（可中英混说）").tag("zh-CN")
                            Text("English").tag("en-US")
                        }
                        .disabled(engine.isRunning)
                    }
                    Toggle("对话翻译", isOn: $interpreterMode)
                }

                if interpreterMode {
                    Section {
                        Picker("播报音色", selection: $englishVoiceID) {
                            ForEach(voices, id: \.identifier) { v in
                                Text(voiceLabel(v)).tag(v.identifier)
                            }
                        }
                        Button {
                            engine.previewVoice("Hello! This is how I sound. Nice to meet you.")
                        } label: {
                            Label("试听所选音色", systemImage: "play.circle.fill")
                        }
                    } header: {
                        Text("英文播报")
                    } footer: {
                        Text("更多高质量音色：设置 › 辅助功能 › 朗读内容 › 声音 中下载，完成后自动出现在此列表。")
                    }
                }

                Section("外观与文字") {
                    Picker("外观", selection: $appearanceMode) {
                        Text("跟随系统").tag("auto")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    Picker("字体", selection: $fontID) {
                        Text("系统默认").tag("system")
                        Text("苹方").tag("PingFang SC")
                        Text("宋体").tag("Songti SC")
                        Text("楷体").tag("Kaiti SC")
                        Text("圆体").tag("Yuanti SC")
                        Text("等宽").tag("mono")
                    }
                    HStack {
                        Text("字号")
                        Slider(value: $fontSize, in: 12...26, step: 1)
                        Text("\(Int(fontSize))").monospacedDigit().foregroundStyle(.secondary)
                    }
                    ColorPicker("文字颜色", selection: colorBinding, supportsOpacity: false)
                    Button("恢复默认样式") {
                        fontID = "system"; fontSize = 16; colorHex = ""
                    }
                }

                Section {
                    Text("预览：实时转录 Live Transcription")
                        .font(transcriptFont(id: fontID, size: fontSize))
                        .foregroundStyle(legibleTextColor(hex: colorHex, scheme: colorScheme))
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}

import SwiftUI
import UIKit

let brandGradient = LinearGradient(
    colors: [Color(red: 0.25, green: 0.48, blue: 0.98), Color(red: 0.55, green: 0.36, blue: 0.96)],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
)

// 转录文字样式（字体/字号），与 macOS 版保持一致
func transcriptFont(id: String, size: Double) -> Font {
    switch id {
    case "system": return .system(size: size)
    case "mono": return .system(size: size, design: .monospaced)
    default: return .custom(id, size: size)
    }
}

func hexLuminance(_ hex: String) -> Double? {
    guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
    let r = Double((v >> 16) & 0xFF) / 255
    let g = Double((v >> 8) & 0xFF) / 255
    let b = Double(v & 0xFF) / 255
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

// 当前模式下对比度不足的自定义颜色回退默认色，避免深色黑字/浅色白字
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
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X",
                      Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }
}

// 系统分享面板：用于把转录 Markdown 导出到「文件」/ Obsidian / 微信等
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

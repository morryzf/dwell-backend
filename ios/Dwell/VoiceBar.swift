import SwiftUI

/// 语音回复的那条语音条，照网页的 .vb 画：粉色 ▶、一段声纹、秒数，右边一个小 T 展开文字。
/// 声纹按消息 id 生成，同一条每次看都是同一个形状。
struct VoiceBar<Expanded: View>: View {
    let messageID: String
    let text: String
    /// 还在说（流式中）：三个粉点在跳，不能播。
    let pending: Bool
    @ViewBuilder var expanded: Expanded

    @ObservedObject private var player = VoicePlayer.shared
    @State private var showText = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                playButton
                wave
                Text(timeLabel)
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(Theme.bubbleText.opacity(0.6))
                if !pending {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { showText.toggle() }
                    } label: {
                        Text("T")
                            .font(.system(size: 12, weight: .semibold, design: .serif))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Theme.bubble))
                            .overlay(Circle().stroke(Theme.accent.opacity(showText ? 0.6 : 0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showText ? "收起文字" : "展开文字")
                }
            }
            .padding(.leading, 11)
            .padding(.trailing, 14)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.bubble))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.bubbleBorder, lineWidth: 1))
            .shadow(color: Theme.bubbleShadow, radius: 10, y: 6)

            if showText || isError {
                expanded
            }
        }
    }

    private var state: VoicePlayer.State { player.state(for: messageID) }

    private var isError: Bool {
        if case .error = state { return true }
        return false
    }

    @ViewBuilder
    private var playButton: some View {
        if pending {
            HStack(spacing: 2.5) {
                ForEach(0..<3) { index in
                    Circle().fill(Theme.accent).frame(width: 3.5, height: 3.5)
                        .phaseAnimator([0.35, 1.0]) { dot, phase in
                            dot.opacity(phase)
                        } animation: { _ in .easeInOut(duration: 0.55).delay(Double(index) * 0.15) }
                }
            }
            .frame(width: 20, height: 22)
        } else {
            Button {
                player.toggle(messageID)
            } label: {
                Group {
                    if state == .loading {
                        ProgressView().controlSize(.mini).tint(Theme.accent)
                    } else {
                        Image(systemName: state == .playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(isError ? Theme.bubbleText.opacity(0.45) : Theme.accent)
                    }
                }
                .frame(width: 20, height: 22)
                .contentShape(Rectangle().inset(by: -10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state == .playing ? "暂停" : "播放语音")
        }
    }

    private var duration: TimeInterval {
        player.durations[messageID] ?? Self.estimate(text)
    }

    private var timeLabel: String {
        if pending { return "" }
        if case .error = state { return "语音没出来" }
        let shown = (state == .playing || state == .paused) && player.elapsed > 0 ? player.elapsed : duration
        return "\(max(1, Int(shown.rounded())))’"
    }

    private var wave: some View {
        let count = Int(min(30, max(12, 10 + duration * 1.1)).rounded())
        let heights = Self.shape(messageID, count: pending ? 16 : count)
        let lit = state == .playing || state == .paused ? Int((player.progress * Double(heights.count)).rounded()) : 0
        return HStack(spacing: 2.5) {
            ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
                RoundedRectangle(cornerRadius: 2)
                    .fill(index < lit ? Theme.accent : Theme.bubbleText.opacity(0.32))
                    .frame(width: 2.5, height: max(3, height * 18))
            }
        }
        .frame(height: 22)
    }

    /// 跟网页 voiceEstimate 一样估秒数：英文按词、中文按字。
    static func estimate(_ text: String) -> TimeInterval {
        let words = text.matches(of: #/[A-Za-z']+/#).count
        let cjk = text.unicodeScalars.filter { (0x3400...0x9FFF).contains($0.value) }.count
        return max(1, (Double(words) / 2.6 + Double(cjk) / 4.5).rounded())
    }

    /// 跟网页 voiceShape 一样：FNV 哈希起头、xorshift 滚，两头收、中间高。
    static func shape(_ id: String, count: Int) -> [Double] {
        var h: UInt32 = 2166136261
        for unit in id.utf16 {
            h ^= UInt32(unit)
            h = h &* 16777619
        }
        var out: [Double] = []
        for i in 0..<count {
            h ^= h << 13
            h ^= h >> 17
            h ^= h << 5
            let r = Double(h % 1000) / 1000
            let envelope = sin(Double.pi * (Double(i) + 0.5) / Double(count))
            out.append(0.28 + 0.72 * (0.35 + 0.65 * r) * (0.45 + 0.55 * envelope))
        }
        return out
    }
}

extension VoiceBar where Expanded == EmptyView {
    init(messageID: String, text: String, pending: Bool) {
        self.init(messageID: messageID, text: text, pending: pending, expanded: { EmptyView() })
    }
}

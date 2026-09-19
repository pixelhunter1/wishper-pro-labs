import AppKit
import SwiftUI

struct VoiceBubbleView: View {
    let phase: DictationPhase
    let mode: BubbleMode
    let level: Double
    let liveText: String
    let appName: String?
    let appIcon: NSImage?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var showsLiveText: Bool {
        mode == .liveText && phase == .listening && !liveText.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                leading
                if showsLiveText, let appName {
                    Spacer(minLength: 12)
                    targetApp(appName)
                }
            }
            if showsLiveText {
                Text(liveText)
                    .font(.callout)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: showsLiveText ? 440 : nil)
        .modifier(BubbleBackground(reduceTransparency: reduceTransparency, highContrast: contrast == .increased))
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: showsLiveText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var leading: some View {
        switch phase {
        case .idle, .listening:
            BrandMarkView(size: 16)
            WaveformBars(level: level, animated: !reduceMotion)
        case .finalizing:
            ProgressView()
                .controlSize(.small)
            Text("A finalizar")
                .font(.callout.weight(.medium))
        case .done(let message):
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
                .font(.callout.weight(.medium))
        case .failed(let message):
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout.weight(.medium))
                .lineLimit(2)
        }
    }

    private func targetApp(_ name: String) -> some View {
        HStack(spacing: 5) {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 14, height: 14)
            }
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var accessibilityText: String {
        switch phase {
        case .idle, .listening:
            return showsLiveText ? "Wishper Pro, a ouvir: \(liveText)" : "Wishper Pro, a ouvir"
        case .finalizing:
            return "Wishper Pro, a finalizar"
        case .done(let message), .failed(let message):
            return "Wishper Pro, \(message)"
        }
    }
}

/// The bubble during a screen recording: countdown, time and level, saving, saved or why it stopped.
struct RecordingBubbleView: View {
    let phase: RecordingPhase
    let level: Double
    let elapsed: TimeInterval
    let notice: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                leading
            }
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .modifier(BubbleBackground(reduceTransparency: reduceTransparency, highContrast: contrast == .increased))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var leading: some View {
        switch phase {
        case .countdown(let seconds):
            Text("A gravar em \(seconds)")
                .font(.callout.weight(.medium))
                .monospacedDigit()
            WaveformBars(level: level, animated: !reduceMotion)
        case .recording:
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
            Text(RecordingClock.text(elapsed))
                .font(.callout.weight(.medium))
                .monospacedDigit()
            WaveformBars(level: level, animated: !reduceMotion)
        case .saving:
            ProgressView()
                .controlSize(.small)
            Text("A guardar…")
                .font(.callout.weight(.medium))
        case .saved:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Gravação guardada")
                .font(.callout.weight(.medium))
        case .translating(let progress):
            ProgressView()
                .controlSize(.small)
            Text("A preparar o vídeo traduzido…" + (progress.map { " \(Int(($0 * 100).rounded()))%" } ?? ""))
                .font(.callout.weight(.medium))
                .monospacedDigit()
        case .translated(_, let missing):
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Vídeo traduzido guardado")
                    .font(.callout.weight(.medium))
                if missing > 0 {
                    Text(Self.missingText(missing))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout.weight(.medium))
                .lineLimit(2)
        case .idle, .choosing:
            EmptyView()
        }
    }

    private var accessibilityText: String {
        switch phase {
        case .countdown(let seconds):
            return "Wishper Pro, a gravar em \(seconds)"
        case .recording:
            return "Wishper Pro, a gravar, \(RecordingClock.text(elapsed))"
        case .saving:
            return "Wishper Pro, a guardar a gravação"
        case .saved:
            return "Wishper Pro, gravação guardada"
        case .translating:
            return "Wishper Pro, a preparar o vídeo traduzido"
        case .translated(_, let missing):
            return "Wishper Pro, vídeo traduzido guardado" + (missing > 0 ? ". \(Self.missingText(missing))" : "")
        case .failed(let message):
            return "Wishper Pro, \(message)"
        case .idle, .choosing:
            return "Wishper Pro"
        }
    }

    static func missingText(_ count: Int) -> String {
        count == 1 ? "1 frase ficou por traduzir." : "\(count) frases ficaram por traduzir."
    }
}

private struct WaveformBars: View {
    let level: Double
    let animated: Bool
    private let weights: [Double] = [0.55, 0.85, 1.0, 0.75, 0.5]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(weights.indices, id: \.self) { index in
                Capsule()
                    .frame(width: 3, height: 4 + 14 * CGFloat(min(level * weights[index] * 1.6, 1)))
            }
        }
        .frame(height: 18)
        .animation(animated ? .easeOut(duration: 0.12) : nil, value: level)
    }
}

private struct BubbleBackground: ViewModifier {
    let reduceTransparency: Bool
    let highContrast: Bool

    func body(content: Content) -> some View {
        background(for: content)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(highContrast ? 0.6 : 0), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    @ViewBuilder
    private func background(for content: Content) -> some View {
        if reduceTransparency {
            content.background(
                Color(nsColor: .windowBackgroundColor),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 18))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

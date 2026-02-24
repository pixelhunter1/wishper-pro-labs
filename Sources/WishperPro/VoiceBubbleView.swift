import SwiftUI

struct VoiceBubbleView: View {
    let title: String
    let subtitle: String
    let isRecording: Bool
    let isTranscribing: Bool
    let audioLevel: Double

    private var tintColor: Color {
        if isTranscribing { return .orange }
        if isRecording { return .red }
        return .secondary
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tintColor.opacity(0.18))
                .frame(width: 38 + (audioLevel * 96))
                .animation(.easeOut(duration: 0.12), value: audioLevel)

            HStack(spacing: 9) {
                Circle()
                    .fill(tintColor)
                    .frame(width: 10, height: 10)
                    .opacity((isRecording || isTranscribing) ? 1 : 0.5)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(width: 150, height: 50)
    }
}

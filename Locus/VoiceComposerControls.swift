import SwiftUI

struct VoiceComposerButtons: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

    @EnvironmentObject private var model: AppModel
    @ObservedObject var voice: VoiceControlModel

    var body: some View {
        HStack(spacing: 4) {
            Button {
                voice.toggleDictation()
            } label: {
                Image(systemName: voice.isDictating ? "mic.fill" : "mic")
                    .font(.locus(size: 11, weight: .semibold))
                    .foregroundStyle(voice.isDictating ? model.accentActionColor : viewColors.muted)
                    .frame(width: 30, height: 30)
                    .background(voice.isDictating ? model.accentActionColor.opacity(0.1) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.locus())
            .disabled(voice.isVoiceModeActive)
            .help("Dictate an editable draft")
            .accessibilityLabel(voice.isDictating ? "Stop dictation" : "Start dictation")
            .accessibilityIdentifier("composer.voice.dictation")

            Button {
                voice.toggleVoiceMode()
            } label: {
                Image(systemName: voice.isVoiceModeActive ? "waveform.circle.fill" : "waveform.circle")
                    .font(.locus(size: 12, weight: .semibold))
                    .foregroundStyle(
                        voice.isVoiceModeActive ? model.accentActionColor : viewColors.muted
                    )
                    .frame(width: 30, height: 30)
                    .background(voice.isVoiceModeActive ? model.accentActionColor.opacity(0.1) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.locus())
            .help(voice.isVoiceModeActive ? "Exit voice mode" : "Enter voice mode")
            .accessibilityLabel(voice.isVoiceModeActive ? "Exit voice mode" : "Enter voice mode")
            .accessibilityIdentifier("composer.voice.mode")
        }
    }
}

struct VoiceComposerStrip: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

    @EnvironmentObject private var model: AppModel
    @ObservedObject var voice: VoiceControlModel

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: statusSymbol)
                .font(.locus(size: 10, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(voice.state.title)
                    .font(.locus(size: 9, weight: .semibold))
                    .foregroundStyle(viewColors.ink)
                Text(detail)
                    .font(.locus(size: 8))
                    .foregroundStyle(viewColors.muted)
                    .lineLimit(2)
                    .accessibilityIdentifier("composer.voice.transcript")
            }

            Spacer(minLength: 6)

            if voice.isVoiceModeActive {
                VoicePushToTalkButton(voice: voice)

                if voice.isSpeaking {
                    Button {
                        voice.stopSpeaking()
                    } label: {
                        Image(systemName: "speaker.slash.fill")
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.locus())
                    .help("Stop speaking")
                    .accessibilityLabel("Stop speaking")
                    .accessibilityIdentifier("composer.voice.stopSpeaking")
                }

                Button {
                    voice.exitVoiceMode()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.locus())
                .help("Exit voice mode")
                .accessibilityLabel("Exit voice mode")
                .accessibilityIdentifier("composer.voice.exit")
            } else if voice.isDictating {
                Button("Done") { voice.toggleDictation() }
                    .font(.locus(size: 9, weight: .semibold))
                    .accessibilityIdentifier("composer.voice.dictationDone")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(viewColors.paperDeep.opacity(0.62))
        .overlay(alignment: .top) {
            Rectangle().fill(viewColors.line).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.voice.strip")
    }

    private var detail: String {
        if !voice.partialTranscript.isEmpty { return voice.partialTranscript }
        switch voice.state {
        case .idle:
            return "Hold to talk, or click to keep listening"
        case .listening:
            return voice.isDictating ? "Release or choose Done to finish" : "Release to send"
        case .transcribing:
            return "Finishing your transcript"
        case .waiting:
            return "Your typed draft is still here"
        case .speaking:
            return "Only the completed answer is read aloud"
        case .attention(let kind):
            return kind.announcement
        case .error(let message):
            return message
        }
    }

    private var statusSymbol: String {
        switch voice.state {
        case .listening: "waveform"
        case .transcribing: "text.bubble"
        case .waiting: "ellipsis.bubble"
        case .speaking: "speaker.wave.2.fill"
        case .attention: "exclamationmark.circle.fill"
        case .error: "mic.slash.fill"
        case .idle: "waveform.circle"
        }
    }

    private var statusColor: Color {
        switch voice.state {
        case .attention, .error: viewColors.warning
        case .listening, .speaking: model.accentActionColor
        default: viewColors.muted
        }
    }
}

private struct VoicePushToTalkButton: View {
    @Environment(\.locusOceanTheme) private var usesWorldTheme
    @Environment(\.locusCaptainDeckTheme) private var usesDeckTheme
    @Environment(\.locusViewColors) private var viewColors

    @ObservedObject var voice: VoiceControlModel
    @State private var pointerStartedAt: Date?
    @State private var wasListeningAtPointerDown = false

    var body: some View {
        Image(systemName: voice.isListening ? "stop.fill" : "mic.fill")
            .font(.locus(size: 11, weight: .bold))
            .foregroundStyle(voice.isListening ? viewColors.coral : viewColors.surfaceCanvas)
            .frame(width: 32, height: 28)
            .background(voice.isListening ? viewColors.coral.opacity(0.12) : viewColors.ink)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
            .gesture(pointerGesture)
            .focusable()
            .onKeyPress(.space, phases: [.down, .up]) { press in
                if press.phase == .down { voice.beginPushToTalk() }
                else { voice.endPushToTalk() }
                return .handled
            }
            .help("Hold to talk · click to toggle")
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(voice.isListening ? "Stop voice recording" : "Push to talk")
            .accessibilityValue(voice.isListening ? "Listening" : "Not listening")
            .accessibilityAction { voice.toggleVoiceRecording() }
            .accessibilityIdentifier("composer.voice.pushToTalk")
    }

    private var pointerGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard pointerStartedAt == nil else { return }
                pointerStartedAt = Date()
                wasListeningAtPointerDown = voice.isListening
                if !wasListeningAtPointerDown { voice.beginPushToTalk() }
            }
            .onEnded { _ in
                let duration = Date().timeIntervalSince(pointerStartedAt ?? Date())
                pointerStartedAt = nil
                if wasListeningAtPointerDown {
                    voice.endPushToTalk()
                } else if duration >= 0.22 {
                    voice.endPushToTalk()
                }
                wasListeningAtPointerDown = false
            }
    }
}

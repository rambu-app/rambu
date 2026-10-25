import SwiftUI

/// Simulasi layar telepon bawaan iPhone atau WhatsApp. Layar ini bukan milik Rambu,
/// jadi Rambu hanya hadir lewat push dari atas dan Live Activity, seperti di HP asli.
struct CallScreen: View {
    @Environment(AppState.self) private var model
    @Environment(CallViewModel.self) private var call
    @State private var showDemo = false

    var body: some View {
        if let session = model.session {
            ZStack(alignment: .top) {
                CallBackdrop(channel: session.metadata.channel)

                VStack(spacing: 0) {
                    HStack {
                        Label("Simulasi", systemImage: "play.rectangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .glassEffect(.regular, in: .capsule)
                        Spacer()
                        Button { showDemo = true } label: {
                            Label("Demo", systemImage: "person.2.fill").font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Mode demo, ganti peran")
                    }
                    .padding(.horizontal, 16)

                    CallerHeader(session: session)
                        .padding(.top, 72)

                    Spacer(minLength: 16)

                    CallControls(speakerOn: session.speakerOn,
                                 onSpeaker: { call.turnOnSpeaker() },
                                 onEnd: { call.end() })
                        .padding(.bottom, 20)
                }

                ToastOverlay()
                    .padding(.top, 2)
            }
            .sheet(isPresented: $showDemo) {
                DemoSheet().presentationDetents([.medium, .large])
            }
        } else {
            Color.black.ignoresSafeArea()
        }
    }
}

private struct CallBackdrop: View {
    let channel: CallChannel

    var body: some View {
        LinearGradient(
            colors: channel == .whatsapp
                ? [Color(hex: 0x1C2B27), Color(hex: 0x0B1412)]
                : [Color(hex: 0x3A4442), Color(hex: 0x151A19)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

private struct CallerHeader: View {
    let session: CallSession
    @Environment(AppState.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.fill")
                .font(.system(size: 38))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 84, height: 84)
                .background(.white.opacity(0.14), in: .circle)
                .accessibilityHidden(true)
            Text(session.metadata.fixtureID == nil
                ? L10n.text(session.metadata.callerName, language: model.language)
                : session.metadata.callerName)
                .font(.system(.title, design: .default, weight: .semibold))
                .foregroundStyle(.white)
            Text(session.metadata.fixtureID == nil
                ? L10n.text(session.metadata.callerDetail, language: model.language)
                : session.metadata.callerDetail)
                .font(.subheadline).foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 6) {
                if session.metadata.channel == .whatsapp {
                    Image(systemName: "lock.fill").font(.caption)
                    Text("WhatsApp")
                    Text("·")
                }
                Text(session.startedAt, style: .timer).monospacedDigit()
            }
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.7))
        }
        .accessibilityElement(children: .combine)
    }
}

/// Tombol ala layar telepon iOS. Speaker bisa dinyalakan (puck hanya mendengar dari speaker),
/// Akhiri menutup telepon; tombol lain hanya tampilan.
private struct CallControls: View {
    let speakerOn: Bool
    let onSpeaker: () -> Void
    let onEnd: () -> Void
    @Environment(AppState.self) private var model

    private let others: [(String, String)] = [
        ("FaceTime", "video.fill"),
        ("Bisukan", "mic.slash.fill"),
        ("Tambah", "person.badge.plus"),
        ("Papan tombol", "circle.grid.3x3.fill"),
        ("Lainnya", "ellipsis"),
    ]

    var body: some View {
        VStack(spacing: 22) {
            GlassEffectContainer(spacing: 20) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 3), spacing: 18) {
                    Button(action: onSpeaker) {
                        control("Speaker", "speaker.wave.3.fill", on: speakerOn)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text(
                        speakerOn ? "Speaker, menyala" : "Speaker, mati. Ketuk untuk menyalakan",
                        language: model.language
                    ))
                    ForEach(others, id: \.0) { item in
                        control(item.0, item.1, on: false)
                            .accessibilityLabel(L10n.format(
                                "simulation.control_disabled",
                                fallback: "%@, tidak aktif di simulasi",
                                language: model.language,
                                item.0
                            ))
                    }
                }
                .padding(.horizontal, 36)
            }

            Button(action: onEnd) {
                Image(systemName: "phone.down.fill")
                    .font(.title)
                    .foregroundStyle(.white)
                    .frame(width: 78, height: 78)
                    .background(Color(hex: 0xEB4D3D), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Akhiri panggilan", language: model.language))
        }
        .sensoryFeedback(.selection, trigger: speakerOn)
    }

    private func control(_ title: String, _ symbol: String, on: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(on ? Color.black : .white)
                .frame(width: 72, height: 72)
                .background(on ? AnyShapeStyle(.white) : AnyShapeStyle(.clear), in: .circle)
                .glassEffect(on ? .identity : .regular, in: .circle)
            Text(L10n.text(title, language: model.language))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.9))
        }
        .accessibilityElement(children: .combine)
    }
}

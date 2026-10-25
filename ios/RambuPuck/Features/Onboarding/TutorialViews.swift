import SwiftUI

/// Tutorial tiga kartu: gambar bergerak, judul pendek, dan narasi suara.
/// Dipakai di onboarding orang tua dan dari Profil ("Ulangi tutorial").
struct TutorialCarousel: View {
    let isParent: Bool
    let onFinish: () -> Void

    @Environment(AppState.self) private var model
    @Environment(ProfileViewModel.self) private var profile
    @State private var page = 0

    private var cards: [TutorialCard] { isParent ? TutorialCard.parent : TutorialCard.guardian }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Lewati") { finish() }
                    .font(.body.weight(.semibold))
                Spacer()
                Button {
                    profile.setNarration(!model.narrationEnabled)
                    if model.narrationEnabled { speak() }
                } label: {
                    Image(systemName: model.narrationEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .accessibilityLabel(L10n.text(
                    model.narrationEnabled ? "Matikan suara" : "Nyalakan suara",
                    language: model.language
                ))
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            TabView(selection: $page) {
                ForEach(cards.indices, id: \.self) { index in
                    TutorialPage(card: cards[index], isActive: page == index)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: 8) {
                ForEach(cards.indices, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? Brand.teal : Brand.hairline)
                        .frame(width: index == page ? 26 : 8, height: 8)
                }
            }
            .animation(.smooth, value: page)
            .padding(.bottom, 18)
            .accessibilityHidden(true)

            Button {
                if page < cards.count - 1 { withAnimation(.smooth) { page += 1 } } else { finish() }
            } label: {
                WideLabel(title: page < cards.count - 1 ? "Lanjut" : "Mulai")
            }
            .primaryAction()
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
        .background(Brand.canvas.ignoresSafeArea())
        .onAppear { speak() }
        .onChange(of: page) { speak() }
        .onDisappear { profile.stopNarration() }
    }

    private func speak() {
        let card = cards[page]
        profile.narrate("\(card.title). \(card.line)")
    }

    private func finish() {
        onFinish()
    }
}

struct TutorialCard: Identifiable {
    enum Visual { case attachPuck, speaker, push, alertIn, readQuote, decide }

    let id: Int
    let visual: Visual
    let title: String
    let line: String

    static let parent = [
        TutorialCard(id: 0, visual: .attachPuck, title: "Tempel puck di HP", line: "Di punggung HP, seperti pegangan."),
        TutorialCard(id: 1, visual: .speaker, title: "Nyalakan loudspeaker", line: "Supaya Rambu ikut mendengar."),
        TutorialCard(id: 2, visual: .push, title: "Ada bahaya? Rambu kabari", line: "Anda dan anak langsung diberi tahu."),
    ]

    static let guardian = [
        TutorialCard(id: 0, visual: .alertIn, title: "Peringatan masuk", line: "Saat orang tua ditelepon penipu."),
        TutorialCard(id: 1, visual: .readQuote, title: "Baca kalimatnya", line: "Hanya kalimat yang mencurigakan."),
        TutorialCard(id: 2, visual: .decide, title: "Pilih satu jawaban", line: "Cukup satu pengawas yang menjawab."),
    ]
}

private struct TutorialPage: View {
    let card: TutorialCard
    let isActive: Bool

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            TutorialVisual(visual: card.visual, isActive: isActive)
                .frame(height: 330)
            VStack(spacing: 8) {
                Text(LocalizedStringKey(card.title))
                    .font(Brand.display(.title))
                    .foregroundStyle(Brand.ink)
                    .multilineTextAlignment(.center)
                Text(LocalizedStringKey(card.line))
                    .font(.title3)
                    .foregroundStyle(Brand.ink2)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Gambar bergerak untuk tiap kartu. Diputar ulang setiap kali kartunya tampil.
private struct TutorialVisual: View {
    let visual: TutorialCard.Visual
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var played = false

    var body: some View {
        Group {
            switch visual {
            case .attachPuck:
                PhotoSlot(name: "PhotoPuckOnPhone") { attachPuck }
                    .padding(.horizontal, 28)
            case .speaker:
                PhotoSlot(name: "PhotoSpeakerCall") { speaker }
                    .padding(.horizontal, 28)
            case .push, .alertIn: pushDrop
            case .readQuote: readQuote
            case .decide: decide
            }
        }
        .onChange(of: isActive, initial: true) { _, active in
            played = false
            guard active else { return }
            withAnimation(reduceMotion ? nil : .spring(duration: 0.9, bounce: 0.3).delay(0.35)) { played = true }
        }
        .accessibilityHidden(true)
    }

    /// Puck meluncur lalu menempel di punggung HP.
    private var attachPuck: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x2B3634), Color(hex: 0x161C1B)], startPoint: .top, endPoint: .bottom))
                .frame(width: 170, height: 310)
                .overlay(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(hex: 0x3D4947))
                        .frame(width: 62, height: 62)
                        .padding(14)
                }
            Circle()
                .fill(Brand.puckCream)
                .overlay { Circle().strokeBorder(Brand.teal, lineWidth: 10) }
                .overlay { Circle().fill(Brand.tealBright).frame(width: 9).offset(x: 20, y: 10) }
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
                .offset(x: played ? 0 : 190, y: played ? 40 : 20)
                .rotationEffect(.degrees(played ? 0 : 40))
        }
    }

    /// Ikon speaker bergelombang, maskot ikut mendengarkan.
    private var speaker: some View {
        HStack(spacing: 18) {
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 58, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative, isActive: isActive && !reduceMotion)
                .frame(width: 140, height: 140)
                .background(Brand.hero, in: .circle)
                .scaleEffect(played ? 1 : 0.7)
            MascotView(pose: .calm, sign: .safe)
                .frame(width: 120)
                .offset(x: played ? 0 : 40)
                .opacity(played ? 1 : 0)
        }
    }

    /// Push Rambu turun dari atas HP.
    private var pushDrop: some View {
        MiniPhone {
            EmptyView()
        } overlay: {
            PushBanner(toast: Toast(
                id: "tutorial", title: visual == .alertIn ? "Bahaya: Ibu mungkin ditipu" : "Bahaya: terindikasi penipuan",
                body: visual == .alertIn ? "Ketuk untuk melihat dan memutuskan." : "Jangan transfer atau sebut kode.",
                level: .danger, alertID: nil))
                .frame(width: 370)
                .scaleEffect(0.68, anchor: .top)
                .frame(width: 252, alignment: .top)
                .padding(.top, 42)
                .offset(y: played ? 0 : -200)
                .opacity(played ? 1 : 0)
        }
        .scaleEffect(0.82)
    }

    private var readQuote: some View {
        VStack(spacing: 14) {
            EvidenceCard(line: TranscriptLine(id: 0, offset: 20, speaker: .caller,
                                              text: "Tolong bacakan kode OTP-nya ke saya, Bu.",
                                              flagged: ["bacakan kode OTP-nya"], signals: [.secretCode]),
                         level: .danger)
                .offset(y: played ? 0 : 30)
                .opacity(played ? 1 : 0)
            MascotView(pose: .check, sign: .review).frame(height: 130)
        }
        .padding(.horizontal, 28)
    }

    private var decide: some View {
        VStack(spacing: 18) {
            MascotView(pose: .stop, sign: .danger).frame(height: 150)
            HStack(spacing: 10) {
                Label("Aman", systemImage: "checkmark")
                    .font(.headline).foregroundStyle(Brand.ink)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(.white, in: .capsule)
                Label("Penipuan", systemImage: "hand.raised.fill")
                    .font(.headline).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Brand.danger, in: .capsule)
                    .scaleEffect(played ? 1.06 : 1)
            }
            .padding(.horizontal, 36)
        }
    }
}

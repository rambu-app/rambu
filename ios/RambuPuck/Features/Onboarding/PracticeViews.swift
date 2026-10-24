import AVFoundation
import SwiftUI

// Latihan singkat di akhir onboarding: orang tua mengetuk push, pengawas memutuskan contoh peringatan.

// MARK: - Orang tua

/// Latihan singkat: ada telepon pura-pura, push Rambu turun, orang tua mengetuknya.
struct PracticeCallStep: View {
    @Environment(AppState.self) private var model
    @Environment(OnboardingViewModel.self) private var onboarding
    @Environment(ProfileViewModel.self) private var profile
    @State private var phase: Phase = .ringing

    enum Phase { case ringing, pushed, done }

    private var message: String {
        switch phase {
        case .ringing: "Ini telepon pura-pura. Tunggu sebentar."
        case .pushed: "Ketuk notifikasinya."
        case .done: "Begitu cara Rambu memberi tahu Anda."
        }
    }

    private let sample = Toast(id: "latihan", title: "Bahaya: terindikasi penipuan",
                               body: "Hati-hati. Jangan transfer atau sebut kode.", level: .danger, alertID: nil)

    var body: some View {
        StepScaffold(
            progress: (5, 5),
            title: phase == .done ? "Bagus!" : "Coba dulu",
            message: message
        ) {
            MiniPhone {
                VStack(spacing: 6) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 58, height: 58)
                        .background(.white.opacity(0.14), in: .circle)
                    Text("Nomor tidak dikenal").font(.headline).foregroundStyle(.white)
                    Text("Telepon").font(.caption).foregroundStyle(.white.opacity(0.7))
                }
                .padding(.top, 110)
            } overlay: {
                if phase == .pushed {
                    Button { finish() } label: { PushBanner(toast: sample).frame(width: 370) }
                        .buttonStyle(.plain)
                        .scaleEffect(0.68, anchor: .top)
                        .frame(width: 252, alignment: .top)
                        .padding(.top, 42)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .overlay(alignment: .bottomTrailing) { TapHint().offset(x: -70, y: 6) }
                }
                if phase == .done {
                    MascotView(pose: .happy, sign: .safe)
                        .frame(height: 170)
                        .padding(.top, 60)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        } actions: {
            if phase == .done {
                Button { onboarding.complete(as: .ratna) } label: { WideLabel(title: "Selesai") }
                    .primaryAction()
            } else {
                Button { onboarding.complete(as: .ratna) } label: { WideLabel(title: "Lewati") }
                    .secondaryAction()
            }
        }
        .animation(.spring(duration: 0.5, bounce: 0.25), value: phase)
        .sensoryFeedback(.warning, trigger: phase) { _, new in new == .pushed }
        .sensoryFeedback(.success, trigger: phase) { _, new in new == .done }
        .task {
            profile.narrate("Ini telepon pura-pura. Tunggu sebentar.")
            try? await Task.sleep(for: .seconds(2))
            phase = .pushed
            profile.narrate("Ada notifikasi dari Rambu. Ketuk notifikasinya.")
        }
    }

    private func finish() {
        phase = .done
        profile.narrate("Bagus. Begitu cara Rambu memberi tahu Anda.")
    }
}

// MARK: - Latihan telepon penipuan

/// Telepon latihan dari "penipu" dengan suara iPhone. Peringatan diatur waktunya,
/// bukan analisis sungguhan, supaya latihan selalu berjalan sama.
struct PracticeCallView: View {
    @Environment(ProfileViewModel.self) private var profile
    @Environment(\.dismiss) private var dismiss
    @AppStorage("practiceCallDone") private var practiced = false
    @State private var phase: Phase = .ringing
    @State private var caption = ""
    @State private var voice = PracticeVoice()

    enum Phase { case ringing, speaker, talking, warning, advice, done }

    private let script = [
        "Halo, selamat siang Bu. Saya Rina dari bagian keamanan bank.",
        "Rekening Ibu ada transaksi mencurigakan, jadi sementara kami blokir.",
        "Supaya bisa dibuka lagi, Ibu akan menerima SMS berisi kode. Tolong sebutkan kode OTP-nya ke saya sekarang ya, Bu.",
    ]

    private let warning = Toast(id: "latihan-telepon", title: "Bahaya: terindikasi penipuan",
                                body: "Jangan berikan kode atau transfer. Tutup telepon sekarang.", level: .danger, alertID: nil)

    var body: some View {
        ZStack {
            callScreen
            if phase == .warning {
                Button { show(.advice) } label: { PushBanner(toast: warning) }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 8)
                    .overlay(alignment: .top) { TapHint().padding(.top, 96) }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if phase == .advice { advice.transition(.move(edge: .bottom)) }
            if phase == .done { finished.transition(.opacity) }
        }
        .animation(.spring(duration: 0.5, bounce: 0.2), value: phase)
        .sensoryFeedback(.warning, trigger: phase) { _, new in new == .warning }
        .sensoryFeedback(.success, trigger: phase) { _, new in new == .done }
        .task { profile.narrate(coach) }
        .onDisappear { voice.stop() }
    }

    private var coach: String {
        switch phase {
        case .ringing: "Ada telepon dari nomor tidak dikenal. Ketuk Jawab."
        case .speaker: "Tekan Speaker supaya Rambu bisa ikut mendengar."
        case .talking: "Dengarkan penelepon."
        case .warning: "Rambu memberi peringatan. Ketuk peringatannya."
        case .advice, .done: ""
        }
    }

    private var callScreen: some View {
        VStack(spacing: 0) {
            HStack {
                Text("LATIHAN")
                    .font(.subheadline.weight(.heavy))
                    .tracking(1)
                    .foregroundStyle(Brand.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Brand.signal, in: .capsule)
                Spacer()
                Button("Akhiri latihan") { dismiss() }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, 20)

            VStack(spacing: 10) {
                Image(systemName: "person.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 96, height: 96)
                    .background(.white.opacity(0.14), in: .circle)
                Text("Nomor tidak dikenal").font(.title.weight(.semibold)).foregroundStyle(.white)
                Text(phase == .ringing ? "Memanggil…" : "00:12")
                    .font(.title3).foregroundStyle(.white.opacity(0.7))
            }
            .padding(.top, 48)

            if !caption.isEmpty && phase != .ringing {
                Text("“\(caption)”")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(20)
                    .frame(maxWidth: .infinity)
                    .background(.white.opacity(0.12), in: .rect(cornerRadius: 22, style: .continuous))
                    .padding(.horizontal, 20)
                    .padding(.top, 28)
                    .contentTransition(.opacity)
            }

            Spacer(minLength: 16)

            if phase == .ringing || phase == .speaker || phase == .talking {
                Text(coach)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Brand.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(18)
                    .frame(maxWidth: .infinity)
                    .background(.white, in: .rect(cornerRadius: 22, style: .continuous))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
            }

            if phase == .ringing {
                HStack {
                    callButton("Tolak", symbol: "phone.down.fill", tint: Brand.danger) { dismiss() }
                    Spacer()
                    callButton("Jawab", symbol: "phone.fill", tint: Brand.safe) { show(.speaker) }
                        .overlay(alignment: .bottomTrailing) { TapHint().offset(x: 18, y: -6) }
                }
                .padding(.horizontal, 48)
            } else {
                HStack {
                    callButton("Bisukan", symbol: "mic.slash.fill", tint: .white.opacity(0.18)) {}
                        .disabled(true)
                    Spacer()
                    callButton("Speaker", symbol: "speaker.wave.3.fill",
                               tint: phase == .speaker ? .white.opacity(0.18) : .white, glyph: phase == .speaker ? .white : Brand.ink) {
                        guard phase == .speaker else { return }
                        show(.talking)
                        Task { await talk() }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if phase == .speaker { TapHint().offset(x: 18, y: -6) }
                    }
                    Spacer()
                    callButton("Tutup", symbol: "phone.down.fill", tint: Brand.danger) { dismiss() }
                }
                .padding(.horizontal, 36)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [Color(hex: 0x2B3A3D), Color(hex: 0x111819)], startPoint: .top, endPoint: .bottom))
    }

    private var advice: some View {
        VStack(alignment: .leading, spacing: 20) {
            VerdictCard(
                presentation: .danger,
                headline: "Kemungkinan penipuan",
                summary: [SignalKind.impersonation, .secretCode].callerSummary ?? "",
                details: ["Contoh latihan"]
            )
            AdviceSection(items: [
                ("Jangan berikan kode OTP, PIN, atau kata sandi.", "nosign"),
                ("Tutup telepon. Bank tidak pernah meminta kode lewat telepon.", "phone.down.fill"),
                ("Hubungi keluarga jika ragu.", "person.2.fill"),
            ])
            Spacer(minLength: 0)
            Button { show(.done) } label: { WideLabel(title: "Tutup telepon", systemImage: "phone.down.fill") }
                .primaryAction(Brand.danger)
        }
        .padding(20)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.canvas)
    }

    private var finished: some View {
        VStack(spacing: 20) {
            Spacer()
            MascotView(pose: .happy, sign: .safe).frame(height: 180)
            Text("Bagus!")
                .font(Brand.display(.largeTitle))
                .foregroundStyle(Brand.ink)
            Text("Begitu cara Rambu memperingatkan Anda saat ada penipu.")
                .font(.title3)
                .foregroundStyle(Brand.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                practiced = true
                dismiss()
            } label: { WideLabel(title: "Selesai") }
                .primaryAction()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.canvas)
    }

    private func callButton(_ title: String, symbol: String, tint: Color, glyph: Color = .white,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(glyph)
                    .frame(width: 80, height: 80)
                    .background(tint, in: .circle)
                Text(title).font(.headline).foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }

    private func show(_ next: Phase) {
        phase = next
        profile.narrate(next == .done ? "Bagus. Begitu cara Rambu memperingatkan Anda." : coach)
    }

    private func talk() async {
        for line in script {
            caption = line
            await voice.say(line)
            guard phase == .talking, !voice.stopped else { return }
        }
        show(.warning)
    }
}

/// Suara penelepon latihan memakai suara bahasa Indonesia bawaan iPhone.
@MainActor
final class PracticeVoice: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var finished: CheckedContinuation<Void, Never>?
    private(set) var stopped = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func say(_ text: String) async {
        guard !stopped else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "id-ID")
        utterance.rate = 0.47
        await withCheckedContinuation { continuation in
            finished = continuation
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        stopped = true
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func resume() {
        finished?.resume()
        finished = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resume() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.resume() }
    }
}

/// Jari yang mengetuk berulang, penanda "ketuk di sini".
struct TapHint: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "hand.point.up.left.fill")
            .font(.system(size: 34))
            .foregroundStyle(.white, Brand.ink)
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            .phaseAnimator(reduceMotion ? [false] : [false, true]) { view, pressed in
                view.scaleEffect(pressed ? 0.85 : 1).offset(y: pressed ? -6 : 0)
            } animation: { _ in .easeInOut(duration: 0.6) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Pengawas

/// Contoh peringatan untuk dicoba. Pengawas belajar membaca kalimat lalu memilih.
struct PracticeAlertStep: View {
    @Environment(AppState.self) private var model
    @State private var answer: Verdict?

    private let line = TranscriptLine(id: 0, offset: 20, speaker: .caller,
                                      text: "Tolong bacakan kode OTP-nya ke saya ya, Bu. Biar transaksinya saya batalkan.",
                                      flagged: ["bacakan kode OTP-nya ke saya"], signals: [.secretCode])

    var body: some View {
        StepScaffold(progress: (3, 3), title: "Coba putuskan", message: "Contoh peringatan. Menurut Anda?") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: RiskLevel.danger.symbol)
                    Text("Bahaya")
                    Spacer()
                    Text("Contoh").font(.subheadline.weight(.semibold))
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(Brand.danger)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        Text("\(model.parent.name) mungkin sedang ditipu")
                            .font(Brand.display(.title3)).foregroundStyle(Brand.ink)
                        Spacer(minLength: 0)
                        MascotView(pose: .stop, sign: .danger).frame(width: 54)
                    }
                    EvidenceCard(line: line, level: .danger)
                }
                .padding(16)
            }
            .background(Brand.dangerSoft)
            .clipShape(.rect(cornerRadius: 24, style: .continuous))

            if let answer {
                feedback(for: answer).transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        } actions: {
            if answer == .scam {
                Button { model.onboardingStep = .waiting } label: { WideLabel(title: "Lanjut") }
                    .primaryAction()
            } else {
                HStack(spacing: 10) {
                    Button { withAnimation(.smooth) { answer = .safe } } label: { WideLabel(title: "Aman", systemImage: "checkmark") }
                        .secondaryAction()
                    Button { withAnimation(.smooth) { answer = .scam } } label: { WideLabel(title: "Penipuan", systemImage: "hand.raised.fill") }
                        .primaryAction(Brand.danger)
                }
            }
        }
        .sensoryFeedback(trigger: answer) { _, new in new == .scam ? .success : .warning }
    }

    private func feedback(for answer: Verdict) -> some View {
        let right = answer == .scam
        return HStack(spacing: 14) {
            MascotView(pose: right ? .happy : .check, sign: right ? .safe : .review).frame(width: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(right ? "Tepat" : "Coba lagi").font(.headline).foregroundStyle(Brand.ink)
                Text(right ? "Orang tua langsung diminta menutup telepon." : "Meminta kode OTP selalu tanda penipuan.")
                    .font(.subheadline).foregroundStyle(Brand.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(right ? Brand.safeSoft : Brand.signalSoft, in: .rect(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Bingkai HP

/// Bingkai HP kecil untuk latihan dan tutorial.
struct MiniPhone<Content: View, Overlay: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var overlay: Overlay

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(hex: 0x3A4442), Color(hex: 0x151A19)], startPoint: .top, endPoint: .bottom)
            content
            overlay
            Capsule().fill(.black).frame(width: 84, height: 24).padding(.top, 10)
        }
        .frame(width: 270, height: 420)
        .clipShape(.rect(cornerRadius: 44, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 44, style: .continuous).strokeBorder(Brand.ink, lineWidth: 6) }
        .frame(maxWidth: .infinity)
    }
}

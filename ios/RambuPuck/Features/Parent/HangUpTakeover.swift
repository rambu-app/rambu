import AVFoundation
import AudioToolbox
import SwiftUI

/// Setelah pendamping menekan "Penipuan", HP orang tua sengaja dibuat sulit diabaikan:
/// layar merah penuh, alarm berulang, dan getar, sampai orang tua menekan tombol atau panggilan selesai.
struct HangUpAlarm: Identifiable, Equatable, Sendable {
    let id: UUID
    let deciderName: String
}

/// Satu-satunya tempat takeover dipasang per layar. RootView menampilkannya saat simulasi telepon
/// tidak terbuka, CallScreen menampilkannya saat terbuka, jadi alarm tidak pernah berbunyi dua kali.
struct HangUpTakeoverHost: ViewModifier {
    @Environment(AppState.self) private var model
    var isActive: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if isActive, model.persona.isParent, let alarm = model.hangUpAlarm {
                HangUpTakeoverView(alarm: alarm)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: model.hangUpAlarm)
    }
}

extension View {
    func hangUpTakeover(isActive: Bool = true) -> some View {
        modifier(HangUpTakeoverHost(isActive: isActive))
    }
}

struct HangUpTakeoverView: View {
    @Environment(AppState.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    let alarm: HangUpAlarm
    @State private var siren = HangUpSiren()
    @State private var pulse = false

    private var callEnded: Bool {
        model.alerts.first { $0.id == alarm.id }?.callEnded ?? false
    }

    var body: some View {
        ZStack {
            // Denyut pelan (sekitar 1 kali per detik), jauh di bawah batas 3 kedipan per detik.
            Brand.danger.ignoresSafeArea()
            Brand.dangerInk.ignoresSafeArea()
                .opacity(pulse ? 0.55 : 0)

            // Pesan di tengah; kalau teks sangat besar dan tidak muat, pesan bisa digulir.
            // Tombol selalu menempel di bawah layar.
            ViewThatFits(in: .vertical) {
                VStack(spacing: 0) {
                    Spacer(minLength: 12)
                    message
                    Spacer(minLength: 12)
                }
                ScrollView { message.padding(.vertical, 12) }
                    .scrollIndicators(.visible)
            }
            .padding(.horizontal, 24)
            .safeAreaInset(edge: .bottom, spacing: 12) {
                Button {
                    stop()
                } label: {
                    Label("Sudah saya matikan", systemImage: "phone.down.fill")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Brand.dangerInk)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .padding(.vertical, 4)
                        .background(.white, in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Menghentikan alarm")
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 12)
                .background {
                    // Ikut berdenyut bersama latar, supaya tidak ada garis batas di atas tombol.
                    ZStack {
                        Brand.danger
                        Brand.dangerInk.opacity(pulse ? 0.55 : 0)
                    }
                    .ignoresSafeArea(edges: .bottom)
                }
            }
        }
        // Teks tetap membesar mengikuti setelan HP, tapi dibatasi supaya tombol tidak pecah bentuk.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear {
            siren.start(spoken: L10n.text("Matikan teleponnya sekarang", language: model.language),
                        language: model.language)
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { pulse = true }
        }
        .onDisappear { siren.stop() }
        .onChange(of: callEnded) { _, ended in
            if ended { stop() }
        }
    }

    private var message: some View {
        VStack(spacing: 28) {
            StopOctagon(large: !typeSize.isAccessibilitySize)
                .frame(width: typeSize.isAccessibilitySize ? 96 : 148, height: typeSize.isAccessibilitySize ? 96 : 148)
                .scaleEffect(pulse && !reduceMotion ? 1.04 : 1)
                .accessibilityHidden(true)

            VStack(spacing: 14) {
                Text("Matikan teleponnya sekarang")
                    .font(Brand.display(.largeTitle, .heavy))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(L10n.format("%@ yakin ini penipu.", language: model.language, alarm.deciderName))
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                rule("Jangan sebut kode apa pun", symbol: "number.square.fill")
                rule("Jangan transfer uang", symbol: "banknote.fill")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.18), in: .rect(cornerRadius: 22, style: .continuous))
        }
        .frame(maxWidth: .infinity)
    }

    private func rule(_ text: LocalizedStringKey, symbol: String) -> some View {
        Label {
            Text(text).font(.headline).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).font(.title3)
        }
        .foregroundStyle(.white)
    }

    private func stop() {
        siren.stop()
        model.hangUpAlarm = nil
    }
}

/// Rambu oktagon: bentuk "berhenti" dari sistem wayfinding Rambu, tetap terbaca tanpa warna.
struct StopOctagon: View {
    var large = true

    var body: some View {
        ZStack {
            Octagon().fill(.white)
            Octagon().inset(by: large ? 9 : 6).fill(Brand.danger)
            Image(systemName: "phone.down.fill")
                .font(.system(size: large ? 56 : 36, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

struct Octagon: InsettableShape {
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let side = min(r.width, r.height)
        let cut = side * (1 - 1 / (1 + sqrt(2))) / 2
        let x = r.midX - side / 2, y = r.midY - side / 2
        var path = Path()
        path.move(to: CGPoint(x: x + cut, y: y))
        path.addLine(to: CGPoint(x: x + side - cut, y: y))
        path.addLine(to: CGPoint(x: x + side, y: y + cut))
        path.addLine(to: CGPoint(x: x + side, y: y + side - cut))
        path.addLine(to: CGPoint(x: x + side - cut, y: y + side))
        path.addLine(to: CGPoint(x: x + cut, y: y + side))
        path.addLine(to: CGPoint(x: x, y: y + side - cut))
        path.addLine(to: CGPoint(x: x, y: y + cut))
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> Octagon {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

/// Alarm berulang yang tetap berbunyi walau HP dalam mode senyap, getar tiap detik,
/// dan suara "Matikan teleponnya sekarang" tiap beberapa detik di sela alarm.
@MainActor
final class HangUpSiren {
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private let speech = AVSpeechSynthesizer()
    private var tick = 0

    func start(spoken: String, language: AppLanguage) {
        guard timer == nil else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.duckOthers])
        try? session.setActive(true)

        if let url = Bundle.main.url(forResource: "rambu-urgent", withExtension: "caf"),
           let player = try? AVAudioPlayer(contentsOf: url) {
            player.numberOfLoops = -1
            player.volume = 1
            player.play()
            self.player = player
        }

        tick = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tick += 1
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                if self.tick % 6 == 2 {
                    let utterance = AVSpeechUtterance(string: spoken)
                    utterance.voice = AVSpeechSynthesisVoice(language: language == .english ? "en-US" : "id-ID")
                    utterance.rate = 0.45
                    self.speech.speak(utterance)
                }
            }
        }
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        speech.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

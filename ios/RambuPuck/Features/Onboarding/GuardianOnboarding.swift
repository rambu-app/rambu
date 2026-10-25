import SwiftUI

// Jalur pengawas: kode, nama dan hubungan, lalu menunggu izin orang tua.

struct EnterCodeStep: View {
    @Environment(AppState.self) private var model
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        StepScaffold(
            progress: (1, 3),
            title: "Masukkan kode",
            message: "6 angka dari aplikasi Rambu orang tua Anda."
        ) {
            ZStack {
                TextField("", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focused)
                    .opacity(0.01)
                    .accessibilityLabel("Kode 6 angka")
                    .onChange(of: code) { _, value in
                        code = String(value.filter(\.isNumber).prefix(6))
                    }
                DigitBoxes(digits: code, showsCursor: focused)
                    .contentShape(.rect)
                    .onTapGesture { focused = true }
            }
            if model.pendingInviteCode != nil {
                Label("Kode diisi dari tautan undangan", systemImage: "link")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Brand.safeInk)
            } else {
                Button("Isi kode demo 482 913", systemImage: "wand.and.stars") { code = "482913" }
                    .font(.subheadline.weight(.semibold))
                    .tint(Brand.teal)
            }
        } actions: {
            Button { model.onboardingStep = .guardianProfile } label: { WideLabel(title: "Lanjut") }
                .primaryAction()
                .disabled(code.count < 6)
        }
        .onAppear {
            if let pending = model.pendingInviteCode { code = pending } else { focused = true }
        }
    }
}

struct GuardianProfileStep: View {
    @Environment(AppState.self) private var model
    @Environment(ProfileViewModel.self) private var profile
    @State private var name = ""
    @State private var relation = "Anak"

    private let relations = ["Anak", "Cucu", "Saudara"]

    var body: some View {
        StepScaffold(
            progress: (1, 2),
            title: "Siapa Anda?"
        ) {
            NameField(title: "Nama Anda", text: $name, prompt: "Contoh: Sinta")

            VStack(alignment: .leading, spacing: 8) {
                Text("Hubungan").font(.subheadline.weight(.semibold)).foregroundStyle(Brand.ink2)
                HStack(spacing: 8) {
                    ForEach(relations, id: \.self) { option in
                        Button { relation = option } label: {
                            Text(LocalizedStringKey(option))
                                .font(.headline)
                                .foregroundStyle(relation == option ? .white : Brand.ink)
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .background(relation == option ? Brand.teal : .white, in: .capsule)
                                .overlay { Capsule().strokeBorder(relation == option ? .clear : Brand.hairline) }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(relation == option ? .isSelected : [])
                    }
                }
            }
            if model.allowsDemoControls { DemoPrefillNote() }
        } actions: {
            Button {
                profile.renameGuardian(.sinta, name: name, relation: relation)
                model.onboardingStep = model.allowsDemoControls ? .practiceAlert : .enterCode
            } label: { WideLabel(title: "Lanjut") }
                .primaryAction()
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onAppear {
            if name.isEmpty {
                let me = model.person(for: .sinta)
                name = me.name
                relation = me.relation
            }
        }
    }
}

struct GuardianWaitingStep: View {
    @Environment(AppState.self) private var model
    @Environment(OnboardingViewModel.self) private var onboarding
    @State private var connected = false

    var body: some View {
        let partner = model.person(for: .richard)
        StepScaffold(
            title: connected ? "Terhubung" : "Menunggu izin",
            message: connected
                ? L10n.format(
                    "guardian.protecting_together",
                    fallback: "Anda menjaga %@ bersama %@. Cukup satu yang menjawab.",
                    language: model.language,
                    model.parent.name,
                    partner.name
                )
                : L10n.format(
                    "guardian.needs_approval",
                    fallback: "%@ perlu mengizinkan di HP-nya.",
                    language: model.language,
                    model.parent.name
                )
        ) {
            // Foto asli: Tia Rahayu, Pexels.
            Image("PhotoGuardian")
                .resizable()
                .scaledToFill()
                .frame(height: 400)
                .frame(maxWidth: .infinity)
                .clipShape(.rect(cornerRadius: 32, style: .continuous))
                .overlay(alignment: .bottom) {
                    Group {
                        if connected {
                            PushBanner(toast: Toast(id: "contoh", title: L10n.format(
                                                    "family.alert_title_with_level",
                                                    fallback: "%@: %@ mungkin sedang ditipu",
                                                    language: model.language,
                                                    L10n.text("Bahaya", language: model.language),
                                                    model.parent.name
                                                ),
                                                    body: "Ketuk untuk melihat dan memutuskan.", level: .danger, alertID: nil))
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        } else {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(L10n.format(
                                    "guardian.waiting",
                                    fallback: "Menunggu %@…",
                                    language: model.language,
                                    model.parent.name
                                )).font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(Brand.ink)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .background(.white.opacity(0.92), in: .capsule)
                        }
                    }
                    .padding(12)
                }
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: -8) {
                        Avatar(person: model.person(for: .sinta), size: 40)
                        Avatar(person: model.parent, size: 40)
                    }
                    .padding(6)
                    .background(.white.opacity(0.9), in: .capsule)
                    .padding(14)
                }
                .accessibilityLabel("Seorang perempuan melihat HP")
        } actions: {
            Button { onboarding.complete(as: .sinta) } label: { WideLabel(title: "Mulai menjaga") }
                .primaryAction()
                .disabled(!connected)
        }
        .animation(.spring(duration: 0.5, bounce: 0.25), value: connected)
        .task {
            try? await Task.sleep(for: .seconds(2))
            connected = true
        }
    }
}

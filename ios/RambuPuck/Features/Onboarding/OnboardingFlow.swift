import SwiftUI

// MARK: - Alur

struct OnboardingFlow: View {
    @Environment(AppState.self) private var model
    @Environment(OnboardingViewModel.self) private var onboarding
    @Environment(ProfileViewModel.self) private var profile

    var body: some View {
        NavigationStack {
            Group {
                switch model.onboardingStep {
                case .welcome: WelcomeStep()
                case .tutorial: TutorialCarousel(isParent: true) { model.onboardingStep = .parentProfile }
                case .parentProfile: ParentProfileStep()
                case .guardianProfile: GuardianProfileStep()
                case .pairPuck: PairPuckStep()
                case .consent: ConsentStep()
                case .invite:
                    if model.allowsDemoControls { InviteGuardiansStep() }
                    else {
                        StepScaffold(progress: (3, 3), title: "Undang keluarga") {
                            FamilySetupContent { onboarding.complete(as: .ratna) }
                        } actions: { EmptyView() }
                    }
                case .enterCode:
                    if model.allowsDemoControls { EnterCodeStep() }
                    else {
                        StepScaffold(progress: (2, 2), title: "Hubungkan dengan orang tua") {
                            FamilySetupContent {
                                Task {
                                    await profile.requestNotifications()
                                    onboarding.complete(as: .sinta)
                                }
                            }
                        } actions: { EmptyView() }
                    }
                case .practiceCall: PracticeCallStep()
                case .practiceAlert: PracticeAlertStep()
                case .waiting: GuardianWaitingStep()
                }
            }
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            .background(Brand.canvas.ignoresSafeArea())
            .toolbar {
                if model.onboardingStep != .welcome && model.onboardingStep != .tutorial {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Kembali", systemImage: "chevron.left") { goBack() }
                    }
                }
            }
        }
        .animation(.smooth(duration: 0.35), value: model.onboardingStep)
    }

    private func goBack() {
        switch model.onboardingStep {
        case .tutorial: model.onboardingStep = .welcome
        case .enterCode: model.onboardingStep = model.allowsDemoControls ? .welcome : .guardianProfile
        case .parentProfile: model.onboardingStep = model.allowsDemoControls ? .tutorial : .welcome
        case .pairPuck: model.onboardingStep = .parentProfile
        case .consent: model.onboardingStep = model.allowsDemoControls ? .pairPuck : .parentProfile
        case .invite: model.onboardingStep = .consent
        case .practiceCall: model.onboardingStep = .invite
        case .guardianProfile: model.onboardingStep = model.allowsDemoControls ? .enterCode : .welcome
        case .practiceAlert: model.onboardingStep = .guardianProfile
        case .waiting: model.onboardingStep = .practiceAlert
        case .welcome: break
        }
    }
}

// MARK: - Bagian bersama

/// Kerangka langkah: progres, judul, satu kalimat pendek, isi, lalu tombol di bawah.
struct StepScaffold<Content: View, Actions: View>: View {
    var progress: (Int, Int)?
    let title: String
    var message: String?
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    if let progress {
                        StepProgress(current: progress.0, total: progress.1)
                            .padding(.bottom, 4)
                    }
                    Text(title).font(Brand.display(.largeTitle)).foregroundStyle(Brand.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if let message {
                        Text(message).font(.body).foregroundStyle(Brand.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                content
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 10) { actions }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
        }
    }
}

/// Kolom nama besar dan jelas. Sudah terisi data contoh, tetap bisa diubah.
struct NameField: View {
    let title: String?
    @Binding var text: String
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Brand.ink2)
            }
            TextField(prompt, text: $text)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Brand.ink)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .textContentType(.name)
                .submitLabel(.done)
                .padding(.horizontal, 16)
                .frame(minHeight: 58)
                .background(.white, in: .rect(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Brand.hairline)
                }
        }
    }
}

struct DemoPrefillNote: View {
    var body: some View {
        Label("Contoh untuk demo, boleh diganti", systemImage: "pencil")
            .font(.footnote)
            .foregroundStyle(Brand.ink3)
    }
}

struct WelcomeStep: View {
    @Environment(AppState.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showPush = false

    private let sample = Toast(id: "sambutan", title: "Bahaya: terindikasi penipuan",
                               body: "Sudah dikirim ke Sinta dan Richard.", level: .danger, alertID: nil)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Foto asli: ibu menelepon dengan cemas di rumah (RDNE Stock project, Pexels).
                Color.clear
                    .frame(height: 470)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .top) {
                        Image("PhotoWelcome").resizable().scaledToFill()
                    }
                    .clipped()
                    .overlay(alignment: .top) {
                        LinearGradient(colors: [Brand.canvas.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 110)
                    }
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [.clear, Brand.canvas], startPoint: .top, endPoint: .bottom)
                            .frame(height: 170)
                    }
                    .overlay(alignment: .topLeading) {
                        Image("Wordmark")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 26)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(.white.opacity(0.9), in: .capsule)
                            .padding(.leading, 20)
                            .padding(.top, 62)
                            .accessibilityLabel("Rambu")
                    }
                    .overlay(alignment: .bottom) {
                        if showPush {
                            PushBanner(toast: sample)
                                .padding(.horizontal, 14)
                                .padding(.bottom, 44)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .accessibilityLabel("Seorang ibu menelepon dengan raut cemas di rumah")

                VStack(alignment: .leading, spacing: 10) {
                    Text("Bantu keluarga mengenali penipuan telepon.")
                        .font(Brand.display(.largeTitle))
                        .foregroundStyle(Brand.ink)
                    Text("Rambu menganalisis percakapan dan memberi peringatan saat ada tanda penipuan.")
                        .font(.body)
                        .foregroundStyle(Brand.ink2)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
                .padding(.top, -18)
                .padding(.bottom, 24)
            }
        }
        .ignoresSafeArea(edges: .top)
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 10) {
                Button {
                    model.persona = .ratna
                    model.onboardingStep = model.allowsDemoControls ? .tutorial : .parentProfile
                } label: {
                    WideLabel(title: "Saya orang tua", systemImage: "shield.lefthalf.filled")
                }
                .primaryAction()
                Button {
                    model.persona = .sinta
                    model.onboardingStep = model.allowsDemoControls ? .enterCode : .guardianProfile
                } label: {
                    WideLabel(title: "Saya pendamping", systemImage: "person.2.fill")
                }
                .secondaryAction()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
        .task {
            guard model.allowsDemoControls else { return }
            try? await Task.sleep(for: .seconds(0.9))
            withAnimation(reduceMotion ? nil : .spring(duration: 0.6, bounce: 0.3)) { showPush = true }
        }
        .sensoryFeedback(.warning, trigger: showPush) { _, new in new }
    }
}

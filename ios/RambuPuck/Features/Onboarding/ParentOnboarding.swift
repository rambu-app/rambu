import SwiftUI

// Jalur orang tua: nama, pasang puck, persetujuan, undang pengawas.

struct ParentProfileStep: View {
    @Environment(AppState.self) private var model
    @Environment(ProfileViewModel.self) private var profile
    @State private var name = ""

    var body: some View {
        StepScaffold(
            progress: (1, 3),
            title: "Siapa nama Anda?",
            message: "Nama ini muncul di HP keluarga."
        ) {
            NameField(title: nil, text: $name, prompt: "Contoh: Ibu Ratna")
            if model.allowsDemoControls { DemoPrefillNote() }
        } actions: {
            Button {
                profile.renameParent(name)
                model.onboardingStep = model.allowsDemoControls ? .pairPuck : .consent
            } label: { WideLabel(title: "Lanjut") }
                .primaryAction()
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onAppear { if name.isEmpty { name = model.parent.name } }
    }
}

struct PairPuckStep: View {
    @Environment(AppState.self) private var model
    @State private var phase: Phase = .idle
    @State private var found: PuckState?

    enum Phase { case idle, searching, found }

    var body: some View {
        StepScaffold(
            progress: (2, 5),
            title: "Pasang puck",
            message: "Tempel di punggung HP, lalu tekan tombolnya sampai lampu berkedip."
        ) {
            VStack(spacing: 16) {
                ZStack {
                    if phase == .searching { SearchRings() }
                    PhotoSlot(name: "PhotoPuckProduct") {
                        PuckIllustration(ledColor: phase == .idle ? nil : Brand.tealBright)
                            .frame(maxWidth: 240)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 200)

                if let found, phase == .found {
                    HStack(spacing: 14) {
                        Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Brand.safe)
                        Text("\(found.name) ditemukan").font(.headline).foregroundStyle(Brand.ink)
                        Spacer(minLength: 0)
                        Label("\(found.battery)%", systemImage: found.batterySymbol)
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Brand.ink2)
                    }
                    .card()
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
                }
            }
        } actions: {
            switch phase {
            case .idle:
                Button { search() } label: { WideLabel(title: "Cari puck", systemImage: "dot.radiowaves.left.and.right") }
                    .primaryAction()
            case .searching:
                Button {} label: {
                    HStack(spacing: 10) { ProgressView(); Text("Mencari…") }
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 32)
                }
                .secondaryAction()
                .disabled(true)
            case .found:
                Button { model.onboardingStep = .consent } label: { WideLabel(title: "Hubungkan") }
                    .primaryAction()
            }
        }
        .animation(.smooth, value: phase)
    }

    private func search() {
        phase = .searching
        Task {
            let state = await SimulatedPuckLink().discover()
            found = state
            phase = .found
        }
    }
}

struct SearchRings: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expand = false

    var body: some View {
        ZStack {
            ForEach(0..<3) { i in
                Circle()
                    .stroke(Brand.teal.opacity(0.25), lineWidth: 2)
                    .scaleEffect(expand ? 1.35 : 0.6)
                    .opacity(expand ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: 2).repeatForever(autoreverses: false).delay(Double(i) * 0.6), value: expand)
            }
        }
        .frame(width: 220, height: 220)
        .onAppear { expand = true }
        .accessibilityHidden(true)
    }
}

struct ConsentStep: View {
    @Environment(AppState.self) private var model
    @Environment(ProfileViewModel.self) private var profile
    @State private var asking = false

    private let points: [(symbol: String, title: String, detail: String)] = [
        ("speaker.wave.3.fill", "Gunakan speaker saat menelepon", "Percakapan perlu terdengar jelas agar dapat dianalisis."),
        ("text.quote", "Keluarga melihat cuplikan", "Cuplikan percakapan membantu pendamping menilai peringatan."),
        ("bell.badge.fill", "Peringatan lewat notifikasi", "Muncul di atas layar saat menelepon."),
        ("hand.raised.fill", "Anda yang memutuskan", "Rambu tidak menutup telepon Anda."),
    ]

    var body: some View {
        StepScaffold(progress: (2, 3), title: "Sebelum mulai") {
            VStack(spacing: 12) {
                ForEach(points, id: \.title) { point in
                    HStack(spacing: 16) {
                        Image(systemName: point.symbol)
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(Brand.hero, in: .rect(cornerRadius: 18, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(point.title).font(.headline).foregroundStyle(Brand.ink)
                            Text(point.detail).font(.subheadline).foregroundStyle(Brand.ink2)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .card(padding: 14)
                    .accessibilityElement(children: .combine)
                }
            }
        } actions: {
            Button {
                // Peringatan datang lewat push, jadi izin notifikasi diminta di sini.
                asking = true
                Task {
                    await profile.requestNotifications()
                    asking = false
                    model.onboardingStep = .invite
                }
            } label: { WideLabel(title: "Lanjut", systemImage: "checkmark") }
                .primaryAction()
                .disabled(asking)
        }
    }
}

struct InviteGuardiansStep: View {
    @Environment(AppState.self) private var model
    @State private var requests: [Person] = []
    @State private var approved: Set<String> = []

    var body: some View {
        StepScaffold(
            progress: (4, 5),
            title: "Undang pengawas",
            message: "Kirim tautan ke anak Anda."
        ) {
            InviteActions(code: "482913")

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Permintaan masuk")
                if requests.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Menunggu…").font(.subheadline).foregroundStyle(Brand.ink2)
                    }
                    .card()
                } else {
                    VStack(spacing: 0) {
                        ForEach(requests) { person in
                            requestRow(person)
                            if person != requests.last { Divider().padding(.leading, 58) }
                        }
                    }
                    .card(padding: 14)
                }
            }
        } actions: {
            Button { model.onboardingStep = .practiceCall } label: { WideLabel(title: "Lanjut") }
                .primaryAction()
                .disabled(approved.isEmpty)
        }
        .task { await simulateRequests() }
    }

    private func requestRow(_ person: Person) -> some View {
        let isApproved = approved.contains(person.id)
        return HStack(spacing: 12) {
            Avatar(person: person, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(.headline).foregroundStyle(Brand.ink)
                Text(isApproved ? "Terhubung" : person.relation)
                    .font(.subheadline)
                    .foregroundStyle(isApproved ? Brand.safeInk : Brand.ink2)
            }
            Spacer()
            if isApproved {
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Brand.safe)
                    .accessibilityLabel("Terhubung")
            } else {
                Button("Izinkan") {
                    withAnimation(.smooth) { _ = approved.insert(person.id) }
                }
                .buttonStyle(.glassProminent)
                .tint(Brand.teal)
            }
        }
        .padding(.vertical, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func simulateRequests() async {
        for person in model.guardians where !requests.contains(person) {
            try? await Task.sleep(for: .milliseconds(1400))
            withAnimation(.smooth) { requests.append(person) }
        }
    }
}

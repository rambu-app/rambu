import SwiftUI

struct ParentRoot: View {
    @Environment(AppState.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.parentTab) {
            Tab(L10n.text("Beranda", language: model.language), systemImage: "house.fill", value: ParentTab.home) {
                ParentHome()
            }
            Tab(L10n.text("Riwayat", language: model.language), systemImage: "clock.fill", value: ParentTab.history) {
                NavigationStack { HistoryList(forGuardian: false) }
            }
            Tab("Puck", systemImage: "circle.circle.fill", value: ParentTab.puck) {
                PuckScreen()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .fullScreenCover(isPresented: $model.isCallScreenPresented) {
            CallScreen()
                .sheet(isPresented: $model.showCallStatus) {
                    CallStatusView()
                        .presentationDetents([.large])
                }
        }
    }
}

/// Status puck dulu, lalu cara pakai, lalu pengingat keamanan.
struct PuckScreen: View {
    @State private var pairing = BluetoothPuckPairing()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    PuckStatusCard(pairing: pairing)

                    if pairing.status == .paired {
                        PuckWifiCard(pairing: pairing)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Saat menerima panggilan")
                        VStack(alignment: .leading, spacing: 16) {
                            PuckStep(number: 1, title: "Letakkan puck dekat HP", detail: "Jarak sekitar satu jengkal.")
                            Divider()
                            PuckStep(number: 2, title: "Nyalakan speaker", detail: "Supaya puck bisa mendengar penelepon.")
                            Divider()
                            PuckStep(number: 3, title: "Bicara seperti biasa", detail: "Rambu memberi tahu jika ada tanda penipuan.")
                        }
                        .card(padding: 18)
                    }

                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "hand.raised.fill")
                            .font(.title3)
                            .foregroundStyle(Brand.signalInk)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Jika ada peringatan").font(.headline).foregroundStyle(Brand.signalInk)
                            Text("Jangan berikan OTP, PIN, atau kata sandi. Hubungi keluarga jika ragu.")
                                .font(.subheadline)
                                .foregroundStyle(Brand.signalInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.signalSoft, in: .rect(cornerRadius: 24, style: .continuous))
                    .accessibilityElement(children: .combine)
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .background(Brand.canvas)
            .navigationTitle("Rambu Puck")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { ProfileButton() }
            }
        }
    }
}

private struct PuckStatusCard: View {
    let pairing: BluetoothPuckPairing

    var body: some View {
        let content = content
        VStack(spacing: 16) {
            PhotoSlot(name: "PhotoPuckProduct") {
                PuckIllustration(ledColor: pairing.status == .paired ? Brand.tealBright : nil)
                    .frame(maxWidth: 200)
            }
            .frame(height: 150)

            VStack(spacing: 6) {
                Label(LocalizedStringKey(content.title), systemImage: content.symbol)
                    .font(Brand.display(.title3))
                    .foregroundStyle(content.tint)
                Text(LocalizedStringKey(content.detail))
                    .font(.subheadline)
                    .foregroundStyle(Brand.ink2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            switch pairing.status {
            case .idle, .failed:
                Button { pairing.pair() } label: {
                    WideLabel(title: "Pasangkan puck", systemImage: "dot.radiowaves.left.and.right")
                }
                .primaryAction()
            case .searching, .pairing:
                ProgressView().frame(minHeight: 44)
            case .paired:
                Button("Pasangkan ulang", systemImage: "arrow.clockwise") { pairing.pair() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.teal)
                    .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity)
        .card(padding: 20)
    }

    private var content: (symbol: String, title: String, detail: String, tint: Color) {
        switch pairing.status {
        case .idle:
            ("circle.dashed", "Belum dipasangkan", "Pasangkan sekali, lalu puck mendengarkan sendiri saat ada panggilan masuk.", Brand.ink)
        case .searching:
            ("dot.radiowaves.left.and.right", "Mencari puck…", "Pastikan puck menyala dan dekat HP.", Brand.ink)
        case .pairing:
            ("lock.shield", "Pilih Pasangkan", "Ketuk Pasangkan pada pesan yang muncul di iPhone.", Brand.ink)
        case .paired:
            ("checkmark.circle.fill", "Puck siap", "Puck mulai mendengarkan sendiri saat ada panggilan masuk.", Brand.safeInk)
        case .failed(let message):
            ("exclamationmark.triangle.fill", "Belum tersambung", message, Brand.dangerInk)
        }
    }
}

private struct PuckWifiCard: View {
    let pairing: BluetoothPuckPairing
    @Environment(AppState.self) private var model
    @Environment(AppViewModel.self) private var app
    @AppStorage("puckWifiName") private var savedName = ""
    @State private var preparing = false
    @State private var tokenError: String?
    @State private var editing = false
    @State private var name = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Wi-Fi puck")
            Group {
                if savedName.isEmpty || editing {
                    form
                } else {
                    HStack(spacing: 14) {
                        Image(systemName: "wifi")
                            .font(.title3)
                            .foregroundStyle(Brand.teal)
                            .frame(width: 44, height: 44)
                            .background(Brand.tealSoft, in: .rect(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(savedName).font(.headline).foregroundStyle(Brand.ink)
                            Text("Puck memakai Wi-Fi ini").font(.subheadline).foregroundStyle(Brand.ink2)
                        }
                        Spacer(minLength: 0)
                        Button("Ganti") {
                            name = savedName
                            editing = true
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.teal)
                    }
                }
            }
            .card(padding: 18)
        }
        .onChange(of: pairing.wifiStatus) { _, status in
            guard status == .connected else { return }
            savedName = name
            password = ""
            editing = false
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Nama Wi-Fi", text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(14)
                .background(Brand.canvas, in: .rect(cornerRadius: 14, style: .continuous))
            SecureField("Kata sandi Wi-Fi", text: $password)
                .padding(14)
                .background(Brand.canvas, in: .rect(cornerRadius: 14, style: .continuous))

            if let tokenError {
                Label(L10n.text(tokenError, language: model.language), systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Brand.dangerInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch pairing.wifiStatus {
            case .sending:
                Label("Puck sedang masuk Wi-Fi…", systemImage: "wifi")
                    .font(.subheadline).foregroundStyle(Brand.ink2)
            case .failed(let message):
                Label(L10n.text(message, language: model.language), systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Brand.dangerInk)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle, .connected:
                EmptyView()
            }

            Button { Task { await connect() } } label: {
                WideLabel(title: "Sambungkan puck ke Wi-Fi", systemImage: "wifi")
            }
            .secondaryAction()
            .disabled(name.isEmpty || preparing || pairing.wifiStatus == .sending)

            if editing {
                Button("Batal") { editing = false }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.teal)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
    }

    private func connect() async {
        preparing = true
        tokenError = nil
        defer { preparing = false }
        guard let token = await app.pilot.puckToken() else {
            tokenError = "Hubungkan keluarga dulu di Beranda, lalu coba lagi."
            return
        }
        pairing.sendWifi(name: name, password: password, serverURL: model.pilotServerURL, puckToken: token)
    }
}

private struct PuckStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(Brand.display(.headline))
                .foregroundStyle(Brand.teal)
                .frame(width: 36, height: 36)
                .background(Brand.tealSoft, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title)).font(.headline).foregroundStyle(Brand.ink)
                Text(LocalizedStringKey(detail)).font(.subheadline).foregroundStyle(Brand.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ParentHome: View {
    @Environment(AppState.self) private var model
    @AppStorage("practiceCallDone") private var practiced = false
    @State private var practicing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    IssueList()
                    ProtectionStatusCard()

                    if let last = model.history.first {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(title: "Panggilan terakhir")
                            NavigationLink(value: last.id) {
                                HistoryRow(record: last, forGuardian: false)
                                    .clipShape(.rect(cornerRadius: 24, style: .continuous))
                                    .card(padding: 0)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .background(Brand.canvas)
            .navigationTitle(model.parent.name.isEmpty ? "Rambu" : "Halo, \(model.parent.name)")
            .navigationDestination(for: UUID.self) { CallDetail(recordID: $0) }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { ProfileButton() } }
            .animation(.smooth, value: model.issues)
            .fullScreenCover(isPresented: $practicing) { PracticeCallView() }
            .task {
                guard !practiced, !model.allowsDemoControls else { return }
                practiced = true
                try? await Task.sleep(for: .milliseconds(600))
                practicing = true
            }
        }
    }
}

private struct ProtectionStatusCard: View {
    @Environment(AppState.self) private var model
    @State private var showFamily = false

    var body: some View {
        if model.protectionPresentation == .setupRequired {
            Button { showFamily = true } label: { card }
                .buttonStyle(.plain)
                .sheet(isPresented: $showFamily) { PilotSetupView() }
        } else {
            card
        }
    }

    private var card: some View {
        let content = content(for: model.protectionPresentation)
        return HStack(spacing: 14) {
            Image(systemName: content.symbol)
                .font(.title3)
                .foregroundStyle(Brand.teal)
                .frame(width: 48, height: 48)
                .background(Brand.tealSoft, in: .rect(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(content.title)).font(.headline).foregroundStyle(Brand.ink)
                if !content.detail.isEmpty {
                    Text(LocalizedStringKey(content.detail))
                        .font(.subheadline)
                        .foregroundStyle(Brand.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .card(padding: 14)
        .accessibilityElement(children: .combine)
    }

    private func content(
        for status: ProtectionPresentation
    ) -> (symbol: String, title: String, detail: String) {
        switch status {
        case .setupRequired:
            ("link.badge.plus", "Hubungkan keluarga", "Ketuk untuk mengundang anak atau keluarga.")
        case .monitoring:
            ("phone.badge.waveform.fill", "Belum ada sesi analisis aktif", "")
        case .waitingForPuck:
            ("waveform.badge.magnifyingglass", "Menunggu analisis", "")
        case .listening:
            ("waveform", "Analisis sedang berjalan", "")
        case .finishing:
            ("hourglass", "Menyelesaikan analisis", "Menunggu hasil akhir panggilan.")
        case .failed:
            ("exclamationmark.triangle.fill", "Analisis belum berhasil", "Hasil panggilan ini belum tersedia. Periksa koneksi lalu coba lagi.")
        case .completed(let level):
            ("checkmark.circle.fill", "Analisis selesai", level == .safe ? "Tidak ada tanda penipuan yang terdeteksi." : "Peringatan dan bukti sudah dikirim ke pengawas.")
        case .noSpeech:
            ("waveform.slash", "Percakapan tidak terdengar", "")
        }
    }
}

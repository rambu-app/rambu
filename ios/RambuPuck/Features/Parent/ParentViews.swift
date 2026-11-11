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
                NavigationStack(path: $model.historyPath) { HistoryList(forGuardian: false) }
            }
            Tab("Puck", systemImage: "dot.radiowaves.left.and.right", value: ParentTab.puck) {
                PuckScreen()
            }
        }
        .fullScreenCover(isPresented: $model.isCallScreenPresented) {
            CallScreen()
                .hangUpTakeover()
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
                        PuckHotspotBackupCard(pairing: pairing)
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
                            Text("Langsung matikan telepon. Jangan sebut OTP, PIN, atau kata sandi. Ragu? Telepon keluarga.")
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

private struct PuckHotspotBackupCard: View {
    let pairing: BluetoothPuckPairing
    @AppStorage("puckBackupWifiName") private var savedName = ""
    @State private var showingSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Cadangan data seluler")

            VStack(alignment: .leading, spacing: 16) {
                if savedName.isEmpty {
                    HStack(alignment: .top, spacing: 14) {
                        hotspotIcon
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Gunakan hotspot iPhone saat Wi-Fi rumah tidak tersedia.")
                                .font(.headline)
                                .foregroundStyle(Brand.ink)
                            Text("Puck akan berpindah sendiri saat Wi-Fi utama terputus.")
                                .font(.subheadline)
                                .foregroundStyle(Brand.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Button { showingSetup = true } label: {
                        WideLabel(title: "Atur hotspot cadangan", systemImage: "personalhotspot")
                    }
                    .secondaryAction()
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        hotspotIcon
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Hotspot cadangan tersimpan")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Brand.safeInk)
                            Text(savedName)
                                .font(.headline)
                                .foregroundStyle(Brand.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Puck memakai hotspot ini jika Wi-Fi utama tidak tersedia.")
                                .font(.subheadline)
                                .foregroundStyle(Brand.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }

                    if pairing.backupWifiStatus == .connected {
                        Label("Sedang dipakai", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Brand.safeInk)
                            .accessibilityLabel("Hotspot cadangan sedang dipakai")
                    }

                    Button("Ganti", systemImage: "arrow.clockwise") { showingSetup = true }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.teal)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
            }
            .card(padding: 18)
        }
        .sheet(isPresented: $showingSetup) {
            PuckHotspotSetupSheet(pairing: pairing, savedName: $savedName)
                .presentationDetents([.large])
        }
    }

    private var hotspotIcon: some View {
        Image(systemName: "personalhotspot")
            .font(.title3.weight(.semibold))
            .foregroundStyle(Brand.teal)
            .frame(width: 48, height: 48)
            .background(Brand.tealSoft, in: .rect(cornerRadius: 14, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct PuckHotspotSetupSheet: View {
    let pairing: BluetoothPuckPairing
    @Binding var savedName: String
    @Environment(AppState.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var hotspotIsOn = false
    @State private var selectedName = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if didSave {
                        savedConfirmation
                    } else if !hotspotIsOn {
                        turnOnStep
                    } else {
                        chooseNetworkStep
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .background(Brand.canvas)
            .navigationTitle("Hotspot iPhone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(didSave ? "Tutup" : "Batal") { dismiss() }
                }
            }
        }
        .onAppear { selectedName = savedName }
        .onChange(of: pairing.backupWifiStatus) { _, status in
            guard status == .saved || status == .connected else { return }
            savedName = selectedName
            password = ""
        }
    }

    private var turnOnStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            PuckStep(number: 1, title: "Nyalakan hotspot", detail: "Buka Pengaturan > Hotspot Pribadi, lalu nyalakan Izinkan Akses.")

            Label("Jika ada, nyalakan juga Maksimalkan Kompatibilitas.", systemImage: "wifi")
                .font(.body.weight(.semibold))
                .foregroundStyle(Brand.ink)
                .fixedSize(horizontal: false, vertical: true)

            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(Brand.teal)
                .frame(maxWidth: .infinity, minHeight: 128)
                .background(Brand.tealSoft, in: .rect(cornerRadius: 24, style: .continuous))
                .accessibilityHidden(true)

            Button {
                hotspotIsOn = true
                pairing.scanNetworks()
            } label: {
                WideLabel(title: "Hotspot sudah menyala", systemImage: "checkmark")
            }
            .primaryAction()
        }
    }

    private var chooseNetworkStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            PuckStep(number: 2, title: "Pilih hotspot Anda", detail: "Pilih nama iPhone dari daftar di bawah.")

            if pairing.networkScan.isScanning {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Puck sedang mencari jaringan…")
                        .font(.headline)
                        .foregroundStyle(Brand.ink)
                }
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                .accessibilityElement(children: .combine)
            }

            VStack(spacing: 10) {
                ForEach(pairing.networkScan.networks, id: \.self) { network in
                    PuckNetworkChoice(name: network, isSelected: selectedName == network) {
                        if selectedName != network { password = "" }
                        selectedName = network
                    }
                }
            }

            if !pairing.networkScan.isScanning && pairing.networkScan.networks.isEmpty {
                Text("Belum ada jaringan ditemukan.")
                    .font(.body)
                    .foregroundStyle(Brand.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Cari lagi", systemImage: "arrow.clockwise") { pairing.scanNetworks() }
                .font(.headline)
                .foregroundStyle(Brand.teal)
                .frame(maxWidth: .infinity, minHeight: 52)
                .disabled(pairing.networkScan.isScanning)

            if !selectedName.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    SecureField("Kata sandi hotspot", text: $password)
                        .textContentType(.password)
                        .padding(16)
                        .frame(minHeight: 56)
                        .background(.white, in: .rect(cornerRadius: 16, style: .continuous))

                    backupStatus

                    Button {
                        pairing.sendBackupWifi(name: selectedName, password: password)
                    } label: {
                        WideLabel(
                            title: pairing.backupWifiStatus == .sending ? "Menyimpan…" : "Simpan hotspot",
                            systemImage: "personalhotspot"
                        )
                    }
                    .primaryAction()
                    .disabled(password.count < 8 || pairing.backupWifiStatus == .sending)
                }
            }
        }
    }

    @ViewBuilder
    private var backupStatus: some View {
        switch pairing.backupWifiStatus {
        case .failed(let message):
            Label(L10n.text(message, language: model.language), systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.dangerInk)
                .fixedSize(horizontal: false, vertical: true)
        case .idle, .sending, .saved, .connected:
            EmptyView()
        }
    }

    private var savedConfirmation: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Brand.safeInk)
                .accessibilityHidden(true)
            Text("Hotspot cadangan tersimpan")
                .font(Brand.display(.title2))
                .foregroundStyle(Brand.ink)
                .multilineTextAlignment(.center)
            Text("Hotspot tersimpan. Puck akan menggunakannya saat Wi-Fi utama tidak tersedia.")
                .font(.body)
                .foregroundStyle(Brand.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Tutup") { dismiss() }
                .primaryAction()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 44)
        .accessibilityElement(children: .contain)
    }

    private var didSave: Bool {
        pairing.backupWifiStatus == .saved || pairing.backupWifiStatus == .connected
    }
}

private struct PuckNetworkChoice: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "wifi")
                    .font(.title3)
                Text(name)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
            }
            .foregroundStyle(isSelected ? Brand.teal : Brand.ink)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(
                isSelected ? Brand.tealSoft : .white,
                in: .rect(cornerRadius: 16, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityValue(isSelected ? "Dipilih" : "")
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

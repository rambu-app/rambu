import SwiftUI

struct ParentRoot: View {
    @Environment(AppState.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.parentTab) {
            Tab("Beranda", systemImage: "house.fill", value: ParentTab.home) {
                ParentHome()
            }
            Tab("Riwayat", systemImage: "clock.fill", value: ParentTab.history) {
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

/// Device guide only: no hardware readings or simulated device actions.
struct PuckScreen: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    PhotoSlot(name: "PhotoPuckProduct") {
                        PuckIllustration().frame(maxWidth: 240)
                    }
                    .frame(height: 200)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section("Saat menerima panggilan") {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Letakkan puck dekat HP").font(.headline)
                            Text("Pastikan suara dari HP tidak terhalang.")
                                .foregroundStyle(Brand.ink2)
                        }
                    } icon: {
                        Image(systemName: "iphone.gen3")
                            .foregroundStyle(Brand.teal)
                    }

                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Nyalakan speaker").font(.headline)
                            Text("Suara percakapan perlu terdengar oleh puck.")
                                .foregroundStyle(Brand.ink2)
                        }
                    } icon: {
                        Image(systemName: "speaker.wave.2.fill")
                            .foregroundStyle(Brand.teal)
                    }
                }

                Section("Jika ada peringatan") {
                    Text("Jangan berikan OTP, PIN, atau kata sandi. Periksa peringatan di Rambu dan hubungi keluarga jika ragu.")
                        .foregroundStyle(Brand.ink)
                }
            }
            .foregroundStyle(Brand.ink)
            .scrollContentBackground(.hidden)
            .background(Brand.canvas)
            .navigationTitle("Rambu Puck")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { ProfileButton() }
            }
        }
    }
}

struct ParentHome: View {
    @Environment(AppState.self) private var model

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
                                HistoryRow(record: last, forGuardian: false).card(padding: 16)
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
        }
    }
}


private struct ProtectionStatusCard: View {
    @Environment(AppState.self) private var model

    var body: some View {
        let content = content(for: model.protectionPresentation)
        HStack(spacing: 14) {
            Image(systemName: content.symbol)
                .font(.title3)
                .foregroundStyle(Brand.teal)
                .frame(width: 48, height: 48)
                .background(Brand.tealSoft, in: .rect(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title).font(.headline).foregroundStyle(Brand.ink)
                if !content.detail.isEmpty {
                    Text(content.detail)
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
            ("link.badge.plus", "Hubungkan keluarga", "Buka Profil → Keluarga untuk membuat kode undangan.")
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

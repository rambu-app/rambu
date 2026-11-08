import SwiftUI

// Layar izin & privasi untuk orang tua dan pendamping. Tiga pertanyaan yang biasanya ditanyakan
// keluarga dijawab berurutan: apa yang didengar, berapa lama disimpan, siapa yang bisa melihat.
// Kotak centang ada di ujung daftar, jadi pengguna menggulir sampai bawah sebelum bisa lanjut.

struct PrivacyConsentStep: View {
    @Environment(AppState.self) private var model
    @Environment(ProfileViewModel.self) private var profile
    @Environment(OnboardingViewModel.self) private var onboarding
    @State private var agreed = false
    @State private var busy = false

    private var isParent: Bool { model.persona.isParent }

    private var progress: (Int, Int) {
        switch (isParent, model.allowsDemoControls) {
        case (true, false): (2, 2)
        case (true, true): (3, 5)
        case (false, _): (2, 3)
        }
    }

    var body: some View {
        StepScaffold(
            progress: progress,
            title: isParent ? "Privasi Anda" : "Privasi keluarga",
            message: "Baca sampai bawah, lalu centang."
        ) {
            VStack(alignment: .leading, spacing: 30) {
                if isParent { parentSections } else { guardianSections }
                AgreeRow(
                    agreed: $agreed,
                    title: isParent ? "Saya paham dan setuju" : "Saya paham dan akan menjaga kerahasiaannya"
                )
            }
        } actions: {
            Button { proceed() } label: {
                WideLabel(title: busy ? "Menyimpan…" : "Setuju dan lanjut", systemImage: agreed ? "checkmark" : nil)
            }
            .primaryAction()
            .disabled(!agreed || busy)
        }
        .sensoryFeedback(.selection, trigger: agreed)
        .onAppear {
            // Keyboard dari kolom nama ikut terbawa ke layar ini; tutup supaya isi terbaca utuh.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    // MARK: Orang tua

    @ViewBuilder private var parentSections: some View {
        PrivacySection(number: 1, title: "Yang didengar") {
            PrivacyRow(symbol: "speaker.wave.2.fill", title: "Suara telepon dari speaker",
                       detail: "Hanya saat ada telepon. Berhenti saat telepon selesai.")
            NeverOpened(items: ["Chat", "Foto", "Kontak", "Lokasi"])
        }
        PrivacySection(number: 2, title: "Berapa lama disimpan") {
            retentionRows
        }
        PrivacySection(number: 3, title: "Siapa yang bisa melihat") {
            PrivacyRow(symbol: "person.2.fill", title: "Anda dan keluarga yang Anda undang",
                       detail: "Riwayat telepon dan kalimat penelepon yang memicu peringatan.")
            aiRow
        }
    }

    // MARK: Pendamping

    @ViewBuilder private var guardianSections: some View {
        PrivacySection(number: 1, title: "Yang Anda lihat") {
            PrivacyRow(symbol: "text.quote", title: "Kalimat penelepon yang mencurigakan",
                       detail: "Cukup untuk memutuskan, bukan isi telepon lengkap.")
            PrivacyRow(symbol: "clock.fill", title: "Riwayat telepon orang tua",
                       detail: "Aman atau bahaya, kapan, dan siapa yang menjawab.")
            NeverOpened(title: "Tidak pernah Anda dengar", items: ["Rekaman suara", "Isi chat"])
        }
        PrivacySection(number: 2, title: "Berapa lama disimpan") {
            retentionRows
        }
        PrivacySection(number: 3, title: "Janji Anda") {
            PrivacyRow(symbol: "hand.raised.fill", title: "Hanya untuk membantu orang tua",
                       detail: "Jangan tangkap layar atau sebarkan cuplikan ke orang lain.")
            aiRow
        }
    }

    // MARK: Bersama

    @ViewBuilder private var retentionRows: some View {
        PrivacyRow(symbol: "waveform", title: "Rekaman suara",
                   detail: "Dihapus begitu selesai diubah jadi teks.", badge: "Detik itu juga")
        PrivacyRow(symbol: "text.alignleft", title: "Teks percakapan",
                   detail: "Nomor HP, rekening, dan kode disensor dulu. Disimpan selama masa uji coba.")
    }

    private var aiRow: some View {
        PrivacyRow(symbol: "cpu", title: "AI penilai",
                   detail: "Membaca teks yang sudah disensor untuk mencari tanda penipuan.")
    }

    private func proceed() {
        busy = true
        Task {
            // Peringatan datang lewat notifikasi, jadi izinnya diminta tepat setelah persetujuan.
            await profile.requestNotifications()
            busy = false
            if isParent {
                if model.allowsDemoControls { model.onboardingStep = .invite } else { onboarding.complete(as: .ratna) }
            } else {
                model.onboardingStep = model.allowsDemoControls ? .practiceAlert : .enterCode
            }
        }
    }
}

// MARK: - Komponen

/// Bagian bernomor: nomor di lingkaran, judul, garis rambut, lalu isi. Bukan kartu seragam.
private struct PrivacySection<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text("\(number)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Brand.teal, in: .circle)
                    .accessibilityHidden(true)
                Text(LocalizedStringKey(title))
                    .font(Brand.display(.title3))
                    .foregroundStyle(Brand.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            Rectangle().fill(Brand.hairline).frame(height: 1)
            VStack(alignment: .leading, spacing: 18) { content }
        }
    }
}

private struct PrivacyRow: View {
    let symbol: String
    let title: String
    let detail: String
    var badge: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(Brand.teal)
                .frame(width: 40, height: 40)
                .background(Brand.tealSoft, in: .rect(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(LocalizedStringKey(title)).font(.headline).foregroundStyle(Brand.ink)
                    if let badge {
                        Text(LocalizedStringKey(badge))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Brand.safeInk)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Brand.safeSoft, in: .capsule)
                    }
                }
                Text(LocalizedStringKey(detail)).font(.subheadline).foregroundStyle(Brand.ink2)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Hal yang tidak pernah disentuh Rambu, ditandai dengan garis coret supaya terbaca sekilas.
private struct NeverOpened: View {
    var title = "Tidak pernah dibuka"
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(LocalizedStringKey(title), systemImage: "nosign")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.ink2)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { ForEach(items, id: \.self, content: chip) }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { ForEach(Array(items.prefix(2)), id: \.self, content: chip) }
                    HStack(spacing: 8) { ForEach(Array(items.dropFirst(2)), id: \.self, content: chip) }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: .rect(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Brand.hairline) }
        .accessibilityElement(children: .combine)
    }

    private func chip(_ item: String) -> some View {
        Text(LocalizedStringKey(item))
            .font(.subheadline.weight(.semibold))
            .strikethrough(true, color: Brand.ink3)
            .foregroundStyle(Brand.ink3)
            .lineLimit(1)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Brand.canvas, in: .capsule)
    }
}

/// Kotak centang besar. Seluruh baris bisa diketuk.
private struct AgreeRow: View {
    @Binding var agreed: Bool
    let title: String

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { agreed.toggle() }
        } label: {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(agreed ? Brand.teal : .white)
                    .strokeBorder(agreed ? Brand.teal : Brand.ink3, lineWidth: 2)
                    .frame(width: 30, height: 30)
                    .overlay {
                        if agreed {
                            Image(systemName: "checkmark").font(.headline.weight(.heavy)).foregroundStyle(.white)
                        }
                    }
                Text(LocalizedStringKey(title))
                    .font(.headline)
                    .foregroundStyle(Brand.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(minHeight: 64)
            .background(agreed ? Brand.tealSoft : .white, in: .rect(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(agreed ? Brand.teal : Brand.hairline, lineWidth: agreed ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(agreed ? [.isSelected] : [])
    }
}

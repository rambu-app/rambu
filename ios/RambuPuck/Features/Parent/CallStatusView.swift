import SwiftUI

/// Layar yang terbuka saat orang tua mengetuk push Rambu di tengah telepon.
/// Satu instruksi besar, jawaban pengawas, dan tombol menelepon anak.
struct CallStatusView: View {
    @Environment(AppState.self) private var model
    @Environment(ProfileViewModel.self) private var profile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let session = model.session {
                        let status = Status(session: session, alert: model.activeAlert,
                                            unanswered: model.unanswered.contains(session.id),
                                            language: model.language)
                        hero(status)
                        guardiansLine(status)
                    } else {
                        ContentUnavailableView("Telepon sudah selesai", systemImage: "phone.down.fill")
                    }
                }
                .padding(20)
            }
            .background(Brand.canvas)
            .navigationTitle("Status telepon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kembali ke telepon", systemImage: "phone.fill") { dismiss() }
                }
            }
            .onAppear {
                if let session = model.session {
                    let status = Status(session: session, alert: model.activeAlert,
                                        unanswered: model.unanswered.contains(session.id),
                                        language: model.language)
                    profile.narrate("\(status.title). \(status.detail)")
                }
            }
        }
    }

    private func hero(_ status: Status) -> some View {
        VStack(spacing: 14) {
            Label(LocalizedStringKey(status.presentation.title), systemImage: status.presentation.symbol)
                .font(.headline)
                .foregroundStyle(status.presentation.glyph)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(status.presentation.tint, in: .capsule)
            Text(status.title)
                .font(Brand.display(.largeTitle))
                .foregroundStyle(Brand.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if !status.detail.isEmpty {
                Text(status.detail)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Brand.ink2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .background(status.presentation.soft, in: .rect(cornerRadius: 16, style: .continuous))
    }

    private func guardiansLine(_ status: Status) -> some View {
        HStack(spacing: 12) {
            AvatarStack(people: model.guardians, size: 34)
            Text(status.guardianNote)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .card(padding: 14)
    }

    /// Apa yang harus dilakukan orang tua sekarang, dari keadaan telepon dan jawaban pengawas.
    private struct Status {
        let level: RiskLevel
        let title: String
        let detail: String
        let guardianNote: String
        let presentation: HistoryPresentation

        @MainActor
        init(
            session: CallSession,
            alert: FamilyAlert?,
            unanswered: Bool,
            language: AppLanguage
        ) {
            func text(_ key: String) -> String { L10n.text(key, language: language) }
            if let decision = alert?.decision {
                presentation = decision.verdict == .scam ? .danger : .safe
            } else if session.analysisFailure != nil || session.protectionStatus == .noSpeech {
                presentation = .unassessed
            } else if session.level == .danger {
                presentation = .danger
            } else if session.level == .review {
                presentation = .review
            } else {
                presentation = session.protectionStatus == .completed ? .safe : .unassessed
            }
            if let decision = alert?.decision {
                let scam = decision.verdict == .scam
                level = scam ? .danger : .safe
                title = scam
                    ? text("Tutup telepon sekarang")
                    : L10n.format("Aman, kata %@", language: language, decision.by.name)
                detail = scam
                    ? L10n.format("%@ yakin ini penipuan.", language: language, decision.by.name)
                    : text("Tetap jangan beri kode atau transfer.")
                guardianNote = L10n.format("%@ sudah menjawab.", language: language, decision.by.name)
            } else if session.analysisFailure != nil {
                level = .review
                title = text("Analisis belum berhasil")
                detail = text("Hasil panggilan ini belum tersedia. Periksa koneksi lalu coba lagi.")
                guardianNote = text("Analisis berhenti dan tidak menghasilkan penilaian aman.")
            } else if unanswered {
                level = session.level
                title = text("Belum ada jawaban")
                detail = text("Jangan lakukan tindakan apa pun dulu.")
                guardianNote = text("Pengawas sudah diberi tahu, menunggu jawaban.")
            } else if session.level > .safe {
                level = session.level
                title = text("Terindikasi penipuan")
                detail = text(session.level.parentAdvice)
                guardianNote = text("Pengawas sudah diberi tahu, menunggu jawaban.")
            } else {
                level = .safe
                switch session.protectionStatus {
                case .waitingForPuck:
                    title = text("Menunggu analisis")
                    detail = ""
                case .listening where !session.speakerOn:
                    title = text("Nyalakan loudspeaker")
                    detail = text("Percakapan belum terdengar jelas.")
                case .listening:
                    title = text("Rambu sedang mendengarkan")
                    detail = ""
                case .completed:
                    title = text("Analisis selesai")
                    detail = text("Tidak ada tanda penipuan yang terdeteksi.")
                case .noSpeech:
                    title = text("Tidak ada audio yang dianalisis")
                    detail = ""
                }
                guardianNote = text("Pengawas dikabari kalau ada tanda penipuan.")
            }
        }
    }
}

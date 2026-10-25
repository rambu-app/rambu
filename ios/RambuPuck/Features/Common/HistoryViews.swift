import SwiftUI

// MARK: - Daftar riwayat

struct HistoryList: View {
    let forGuardian: Bool
    @Environment(AppState.self) private var model

    private var records: [CallRecord] {
        Self.visibleRecords(model.history, forGuardian: forGuardian)
    }

    static func visibleRecords(_ records: [CallRecord], forGuardian: Bool) -> [CallRecord] { records }

    static func handledAlerts(_ alerts: [FamilyAlert], records: [CallRecord]) -> [FamilyAlert] {
        let recordedIDs = Set(records.map(\.id))
        return alerts.filter { $0.decision != nil && !recordedIDs.contains($0.id) }
            .sorted { $0.raisedAt > $1.raisedAt }
    }

    private var handled: [FamilyAlert] {
        forGuardian ? Self.handledAlerts(model.alerts, records: records) : []
    }

    var body: some View {
        List {
            if records.isEmpty && handled.isEmpty {
                VStack(spacing: 10) {
                    MascotView(pose: .calm, sign: .safe).frame(height: 130)
                    Text("Belum ada riwayat").font(Brand.display(.title3)).foregroundStyle(Brand.ink)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
            } else {
                if !handled.isEmpty {
                    Section("Peringatan ditangani") {
                        ForEach(handled) { alert in
                            NavigationLink(value: alert.id) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(alert.title(language: model.language))
                                        .font(.headline).foregroundStyle(Brand.ink)
                                    if let decision = alert.decision {
                                        Label(L10n.format(
                                              "decision.by_verdict",
                                              fallback: "%@: %@",
                                              language: model.language,
                                              decision.by.name,
                                              L10n.text(decision.verdict.pastTitle, language: model.language)),
                                              systemImage: decision.verdict == .scam ? "hand.raised.fill" : "checkmark.circle.fill")
                                            .font(.subheadline)
                                            .foregroundStyle(decision.verdict == .scam ? Brand.dangerInk : Brand.safeInk)
                                    }
                                    Text(LocalizedStringKey(
                                        alert.callEnded ? "Panggilan selesai" : "Menunggu panggilan selesai"
                                    ))
                                        .font(.caption).foregroundStyle(Brand.ink2)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
                Section {
                    ForEach(records) { record in
                        NavigationLink(value: record.id) { HistoryRow(record: record, forGuardian: forGuardian) }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Brand.canvas)
        .navigationTitle(L10n.text("Riwayat", language: model.language))
        .navigationDestination(for: UUID.self) { id in
            if records.contains(where: { $0.id == id }) {
                CallDetail(recordID: id)
            } else {
                AlertDetail(alertID: id)
            }
        }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ProfileButton() } }
    }
}

struct HistoryRow: View {
    let record: CallRecord
    let forGuardian: Bool
    @Environment(AppState.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text(record.title, language: model.language))
                .font(.headline)
                .foregroundStyle(Brand.ink)
                .fixedSize(horizontal: false, vertical: true)

            HistoryBadge(
                presentation: record.historyPresentation,
                language: model.language
            )

            Label(Fmt.day(record.startedAt, language: model.language), systemImage: record.channel.symbol)
                .font(.subheadline)
                .foregroundStyle(Brand.ink2)
                .labelStyle(CompactLabelStyle())

            if let decision = record.decision {
                Label(L10n.format(
                      "decision.by_verdict",
                      fallback: "%@: %@",
                      language: model.language,
                      decision.by.name,
                      L10n.text(decision.verdict.pastTitle, language: model.language)),
                      systemImage: decision.verdict == .scam ? "hand.raised.fill" : "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(decision.verdict == .scam ? Brand.dangerInk : Brand.safeInk)
                    .labelStyle(CompactLabelStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// Ikon kecil rapat dengan teks, untuk baris metadata.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.footnote)
            configuration.title
        }
    }
}

// MARK: - Detail telepon

struct CallDetail: View {
    let recordID: UUID
    @Environment(AppState.self) private var model

    var body: some View {
        if let record = model.history.first(where: { $0.id == recordID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VerdictCard(
                        presentation: record.historyPresentation,
                        headline: record.verdictHeadline(language: model.language),
                        summary: record.signals.callerSummary(language: model.language)
                            ?? record.incidentSummary(language: model.language),
                        details: [
                            L10n.text(record.channel.label, language: model.language),
                            Fmt.day(record.startedAt, language: model.language),
                            Fmt.duration(record.duration, language: model.language),
                        ]
                    )

                    if record.displayReason == nil && !record.signals.isEmpty {
                        AdviceSection(items: record.signals.map {
                            (L10n.text($0.advice, language: model.language), "nosign")
                        } + [(
                            L10n.text("Hubungi keluarga jika ragu.", language: model.language),
                            "person.2.fill"
                        )])
                    }

                    if let decision = record.decision {
                        HStack(spacing: 12) {
                            Avatar(person: decision.by, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.format(
                                    "decision.by_verdict",
                                    fallback: "%@: %@",
                                    language: model.language,
                                    decision.by.name,
                                    L10n.text(decision.verdict.pastTitle, language: model.language)
                                ))
                                    .font(.headline).foregroundStyle(Brand.ink)
                                Text(Fmt.day(decision.at, language: model.language))
                                    .font(.subheadline).foregroundStyle(Brand.ink2)
                            }
                        }
                        .card()
                    }

                    if record.displayReason == nil && !record.signals.isEmpty {
                        SignalEvidenceSection(signals: record.signals, evidence: record.evidence)
                    }

                    if !record.evidence.isEmpty {
                        TranscriptLink(evidence: record.evidence)
                    }
                }
                .padding(20)
            }
            .background(Brand.canvas)
            .navigationTitle("Detail")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Riwayat tidak ditemukan", systemImage: "clock.badge.xmark")
        }
    }
}

private struct HistoryBadge: View {
    let presentation: HistoryPresentation
    let language: AppLanguage

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: presentation.symbol)
            Text(L10n.text(presentation.title, language: language))
        }
        .font(.subheadline.weight(.bold))
        .foregroundStyle(presentation.glyph)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(presentation.tint, in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

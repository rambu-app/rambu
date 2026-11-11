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
                        NavigationLink(value: record.id) {
                            HistoryRow(record: record, forGuardian: forGuardian)
                        }
                        .navigationLinkIndicatorVisibility(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
            }
        }
        .listStyle(.plain)
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

struct HistoryRowContent: Equatable {
    let status: String
    let callTitle: String
    let channel: String
    let date: String
    let decision: String?

    init(record: CallRecord, language: AppLanguage) {
        status = L10n.text(record.historyPresentation.title, language: language)
        callTitle = L10n.text(record.title, language: language)
        channel = L10n.text(record.channel.label, language: language)
        date = Fmt.day(record.startedAt, language: language)
        decision = record.decision.map {
            L10n.format(
                "history.decision.by_verdict",
                fallback: "%@ menandai panggilan ini sebagai %@",
                language: language,
                $0.by.name,
                L10n.text($0.verdict.pastTitle, language: language)
            )
        }
    }
}
struct HistoryRow: View {
    let record: CallRecord
    let forGuardian: Bool
    @Environment(AppState.self) private var model

    var body: some View {
        let presentation = record.historyPresentation
        let content = HistoryRowContent(record: record, language: model.language)

        HStack(alignment: .top, spacing: 14) {
            Image(systemName: presentation.symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(presentation.ink)
                .frame(width: 44, height: 44)
                .background(presentation.soft, in: .circle)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(content.status)
                        .font(.headline)
                        .foregroundStyle(presentation.ink)

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Brand.ink3)
                        .accessibilityHidden(true)
                }

                Text(content.callTitle)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Brand.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Label("\(content.channel) · \(content.date)", systemImage: record.channel.symbol)
                    .font(.subheadline)
                    .foregroundStyle(Brand.ink2)
                    .labelStyle(CompactLabelStyle())
                    .fixedSize(horizontal: false, vertical: true)

                if let decision = content.decision {
                    Divider()
                        .overlay(Brand.hairline)
                        .padding(.top, 2)

                    Label(
                        decision,
                        systemImage: record.decision?.verdict == .scam
                            ? "hand.raised.fill" : "checkmark.circle.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(
                        record.decision?.verdict == .scam ? Brand.dangerInk : Brand.safeInk
                    )
                    .labelStyle(CompactLabelStyle())
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Brand.hairline)
        }
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

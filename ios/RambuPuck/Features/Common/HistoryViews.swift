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
                                    Text(alert.title).font(.headline).foregroundStyle(Brand.ink)
                                    if let decision = alert.decision {
                                        Label("\(decision.by.name): \(decision.verdict.pastTitle)",
                                              systemImage: decision.verdict == .scam ? "hand.raised.fill" : "checkmark.circle.fill")
                                            .font(.subheadline)
                                            .foregroundStyle(decision.verdict == .scam ? Brand.dangerInk : Brand.safeInk)
                                    }
                                    Text(alert.callEnded ? "Panggilan selesai" : "Menunggu panggilan selesai")
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
        .navigationTitle("Riwayat")
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
        HStack(alignment: .top, spacing: 12) {
            HistoryTile(presentation: record.historyPresentation)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .font(.headline).foregroundStyle(Brand.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    HistoryBadge(presentation: record.historyPresentation)
                    Label(Fmt.day(record.startedAt), systemImage: record.channel.symbol)
                        .font(.subheadline).foregroundStyle(Brand.ink2)
                        .labelStyle(CompactLabelStyle())
                }
                if let decision = record.decision {
                    Label("\(decision.by.name): \(decision.verdict.pastTitle)",
                          systemImage: decision.verdict == .scam ? "hand.raised.fill" : "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(decision.verdict == .scam ? Brand.dangerInk : Brand.safeInk)
                        .labelStyle(CompactLabelStyle())
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
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
                    VStack(alignment: .leading, spacing: 10) {
                        HistoryBadge(presentation: record.historyPresentation, large: true)
                        Text(record.title)
                            .font(Brand.display(.title))
                            .foregroundStyle(Brand.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 14) {
                            Label(Fmt.day(record.startedAt), systemImage: "calendar")
                            Label(Fmt.duration(record.duration), systemImage: "timer")
                        }
                        .font(.subheadline).foregroundStyle(Brand.ink2)
                        .labelStyle(CompactLabelStyle())
                        Label(record.callerDetail, systemImage: record.channel.symbol)
                            .font(.subheadline).foregroundStyle(Brand.ink3)
                            .labelStyle(CompactLabelStyle())
                    }

                    SummaryCard(record: record)

                    if let decision = record.decision {
                        HStack(spacing: 12) {
                            Avatar(person: decision.by, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(decision.by.name): \(decision.verdict.pastTitle)")
                                    .font(.headline).foregroundStyle(Brand.ink)
                                Text(Fmt.day(decision.at)).font(.subheadline).foregroundStyle(Brand.ink2)
                            }
                        }
                        .card()
                    }

                    if record.decision?.verdict == .safe {
                        Label("Pendamping menandai panggilan ini aman.", systemImage: "checkmark.circle")
                            .font(.footnote).foregroundStyle(Brand.ink3)
                    }

                    if let reason = record.displayReason {
                        HStack(spacing: 12) {
                            Image(systemName: record.historyPresentation.symbol)
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(record.historyPresentation.ink)
                            Text(reason)
                                .font(.body).foregroundStyle(Brand.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .card()
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Tidak dapat dinilai. \(reason)")
                    } else if record.signals.isEmpty {
                        HStack(spacing: 12) {
                            MascotView(pose: .calm, animated: false).frame(width: 56)
                            Text("Tidak terdeteksi tanda penipuan.")
                                .font(.body).foregroundStyle(Brand.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .card()
                    } else {
                        FlowLayout(spacing: 6) {
                            ForEach(record.signals, id: \.self) { SignalChip(kind: $0, level: record.level) }
                        }
                    }
                    if !record.evidence.isEmpty || (record.displayReason == nil && !record.signals.isEmpty) {
                        CallEvidenceSection(evidence: record.evidence, level: record.level)
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
    var large = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: presentation.symbol)
            Text(presentation.title)
        }
        .font(large ? .headline : .subheadline.weight(.bold))
        .foregroundStyle(presentation.glyph)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, large ? 14 : 10)
        .padding(.vertical, large ? 8 : 5)
        .background(presentation.tint, in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

private struct HistoryTile: View {
    let presentation: HistoryPresentation
    @ScaledMetric private var size: CGFloat = 44

    var body: some View {
        Image(systemName: presentation.symbol)
            .font(.system(size: size * 0.46, weight: .bold))
            .foregroundStyle(presentation.glyph)
            .frame(width: size, height: size)
            .background(presentation.tint, in: .rect(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityLabel(presentation.title)
    }
}

/// Brief interpretation of the detected signals, separate from automatic-transcription excerpts.
private struct SummaryCard: View {
    let record: CallRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Ringkasan Rambu", systemImage: "text.alignleft")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.teal)
            Text(record.incidentSummary)
                .font(.body)
                .foregroundStyle(Brand.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
        .accessibilityElement(children: .combine)
    }
}

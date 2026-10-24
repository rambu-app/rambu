import SwiftUI

// Detail peringatan untuk pengawas: kalimat penelepon, penerima, dan dua tombol keputusan.

// MARK: - Detail

struct AlertDetail: View {
    let alertID: UUID
    @Environment(AppState.self) private var model

    var body: some View {
        if let alert = model.alerts.first(where: { $0.id == alertID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VerdictCard(
                        presentation: alert.level.historyPresentation,
                        headline: alert.title,
                        summary: alert.signals.callerSummary ?? "Rambu mendeteksi tanda penipuan pada panggilan ini.",
                        details: [
                            alert.channel.label,
                            "Terdeteksi \(Fmt.clock(alert.raisedAt))",
                            alert.callEnded ? "Panggilan selesai" : "Panggilan masih berlangsung",
                        ]
                    )

                    if alert.decision == nil && !alert.signals.isEmpty {
                        AdviceSection(items: alert.signals.map(\.adviceForGuardian).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                            .map { ($0, "exclamationmark.bubble.fill") }
                            + [("Pilih Aman atau Penipuan di bawah agar \(alert.parent.name) tahu.", "hand.tap.fill")])
                    }

                    if !alert.signals.isEmpty {
                        SignalEvidenceSection(signals: alert.signals, evidence: alert.evidence)
                    }

                    if !alert.evidence.isEmpty {
                        TranscriptLink(evidence: alert.evidence)
                    }

                    if alert.decision == nil {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: "Penerima")
                            RecipientsCard(alert: alert)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Brand.canvas)
            .safeAreaBar(edge: .bottom) { DecisionBar(alert: alert) }
            .toolbar(.hidden, for: .tabBar)
            .navigationTitle("Peringatan")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Peringatan tidak ditemukan", systemImage: "bell.slash")
        }
    }
}

private struct RecipientsCard: View {
    let alert: FamilyAlert
    @Environment(AppState.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ForEach(alert.recipients) { person in
                HStack(spacing: 12) {
                    Avatar(person: person, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person == model.currentPerson ? "\(person.name) (Anda)" : person.name)
                            .font(.headline).foregroundStyle(Brand.ink)
                        Text(status(for: person)).font(.subheadline).foregroundStyle(Brand.ink2)
                    }
                    Spacer()
                    if alert.decision?.by == person {
                        Image(systemName: alert.decision?.verdict == .scam ? "hand.raised.fill" : "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(alert.decision?.verdict == .scam ? Brand.danger : Brand.safe)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                if person != alert.recipients.last { Divider().padding(.leading, 52) }
            }
        }
        .card(padding: 14)
    }

    private func status(for person: Person) -> String {
        if let decision = alert.decision {
            return decision.by == person
                ? "Menandai \(decision.verdict.pastTitle), \(Fmt.clock(decision.at))"
                : "Tidak perlu menjawab"
        }
        return "Menerima, \(Fmt.clock(alert.raisedAt))"
    }
}

// MARK: - Keputusan

/// Dua keputusan saja. "Aman" diberi konfirmasi karena menurunkan kewaspadaan orang tua;
/// "Penipuan" langsung terkirim karena setiap detik berarti.
private struct DecisionBar: View {
    let alert: FamilyAlert
    @Environment(AppState.self) private var model
    @Environment(AppViewModel.self) private var app
    @State private var confirmSafe = false

    var body: some View {
        VStack(spacing: 10) {
            if let decision = alert.decision {
                decidedContent(decision)
            } else {
                HStack(spacing: 10) {
                    Button { confirmSafe = true } label: { WideLabel(title: "Aman", systemImage: "checkmark") }
                        .secondaryAction()
                    Button { app.decide(.scam, on: alert.id) } label: { WideLabel(title: "Penipuan", systemImage: "hand.raised.fill") }
                        .primaryAction(Brand.danger)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .sensoryFeedback(.success, trigger: alert.decision)
        .confirmationDialog("Tandai aman?", isPresented: $confirmSafe, titleVisibility: .visible) {
            Button("Ya, aman") { app.decide(.safe, on: alert.id) }
        } message: {
            Text("\(alert.parent.name) akan diberi tahu.")
        }
    }

    @ViewBuilder
    private func decidedContent(_ decision: GuardianDecision) -> some View {
        let mine = decision.by == model.currentPerson
        HStack(spacing: 12) {
            Group {
                if mine {
                    Image(systemName: "paperplane.fill").foregroundStyle(Brand.teal)
                } else {
                    Avatar(person: decision.by, size: 36)
                }
            }
            .font(.title3)
            .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(mine ? "Anda" : decision.by.name) menandai \(decision.verdict.pastTitle)")
                    .font(.headline).foregroundStyle(Brand.ink)
                Text("Terkirim ke \(alert.parent.name) · \(Fmt.clock(decision.at))")
                    .font(.subheadline).foregroundStyle(Brand.ink2)
            }
            Spacer(minLength: 0)
            if !mine {
                Image(systemName: "lock.fill").foregroundStyle(Brand.ink3).accessibilityLabel("Tombol terkunci")
            }
        }
        .padding(12)
        .background(.white, in: .rect(cornerRadius: 20, style: .continuous))
        .shadow(color: Brand.ink.opacity(0.08), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Pita tingkat risiko

/// Risk and time since the warning was first detected, not call duration.
struct LevelBand: View {
    let level: RiskLevel
    let callEnded: Bool
    let detectedAt: Date
    var handled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: level.symbol)
                Text(level.title)
                Spacer()
                if callEnded {
                    Label("Panggilan selesai", systemImage: "phone.down.fill")
                        .font(.subheadline.weight(.semibold))
                } else if handled {
                    Label("Ditangani", systemImage: "checkmark")
                        .font(.subheadline.weight(.semibold))
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Terdeteksi \(Fmt.duration(max(0, context.date.timeIntervalSince(detectedAt)))) lalu")
                    .font(.subheadline).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.headline)
        .foregroundStyle(level.glyph)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(level.tint)
    }
}

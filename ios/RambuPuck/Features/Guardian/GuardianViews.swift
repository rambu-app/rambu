import SwiftUI

// MARK: - Tab dan beranda

struct GuardianRoot: View {
    @Environment(AppState.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.guardianTab) {
            Tab(L10n.text("Beranda", language: model.language), systemImage: "house.fill", value: GuardianTab.home) {
                GuardianHome()
            }
            Tab(L10n.text("Riwayat", language: model.language), systemImage: "clock.fill", value: GuardianTab.history) {
                NavigationStack { HistoryList(forGuardian: true) }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

struct GuardianHome: View {
    @Environment(AppState.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.guardianPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    IssueList()
                    if let alert = model.featuredAlert {
                        NavigationLink(value: alert.id) { AlertHeroCard(alert: alert) }
                            .buttonStyle(.plain)
                    } else {
                        QuietState()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Yang Anda jaga")
                        ProtectedParentCard()
                        ForEach(model.extraParents) { OtherParentRow(person: $0) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .background(Brand.canvas)
            .navigationTitle("Halo, \(model.currentPerson.name)")
            .navigationDestination(for: UUID.self) { AlertDetail(alertID: $0) }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { ProfileButton() } }
        }
    }
}

// MARK: - Kartu beranda

private struct AlertHeroCard: View {
    let alert: FamilyAlert
    @Environment(AppState.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LevelBand(level: alert.level, callEnded: alert.callEnded, detectedAt: alert.raisedAt)

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(alert.title(language: model.language))
                            .font(Brand.display(.title2))
                            .foregroundStyle(Brand.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Label(alert.callerDetail, systemImage: alert.channel.symbol)
                            .font(.subheadline).foregroundStyle(Brand.ink2)
                    }
                    Spacer(minLength: 0)
                }

                FlowLayout(spacing: 6) {
                    ForEach(alert.signals, id: \.self) { SignalChip(kind: $0, level: alert.level, onTint: true) }
                }

                HStack {
                    if let decision = alert.decision {
                        Label(L10n.format(
                              "decision.by_verdict",
                              fallback: "%@: %@",
                              language: model.language,
                              decision.by == model.currentPerson
                                ? L10n.text("Anda", language: model.language)
                                : decision.by.name,
                              L10n.text(decision.verdict.pastTitle, language: model.language)),
                              systemImage: decision.verdict == .scam ? "hand.raised.fill" : "checkmark.circle.fill")
                    } else {
                        Text("Lihat dan putuskan")
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Brand.ink3)
                }
                .font(.headline)
                .foregroundStyle(Brand.ink)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alert.level.soft)
        .clipShape(.rect(cornerRadius: 28, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Buka peringatan")
    }
}

private struct ProtectedParentCard: View {
    @Environment(AppState.self) private var model

    var body: some View {
        let others = model.otherGuardians(than: model.currentPerson)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Avatar(person: model.parent, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.parent.name).font(.headline).foregroundStyle(Brand.ink)
                    if [.waitingForPuck, .listening, .finishing].contains(model.guardianSessionStatus) {
                        Label(
                            LocalizedStringKey(model.guardianSessionStatus.message),
                            systemImage: "waveform"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.teal)
                    } else {
                        Text(LocalizedStringKey(model.guardianSessionStatus.message))
                            .font(.subheadline).foregroundStyle(Brand.ink2)
                    }
                }
                Spacer(minLength: 0)
            }

            if !others.isEmpty {
            Divider()
            HStack(spacing: 10) {
                AvatarStack(people: [model.currentPerson] + others, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.format(
                        "guardian.together",
                        fallback: "Bersama %@",
                        language: model.language,
                        others.map(\.name).formatted(.list(type: .and).locale(model.language.locale))
                    ))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Brand.ink)
                    Text("Cukup satu yang menjawab")
                        .font(.footnote).foregroundStyle(Brand.ink2)
                }
                Spacer(minLength: 0)
            }
            }
        }
        .card()
        .accessibilityElement(children: .combine)
    }
}

/// Orang tua yang dijaga plus rekan pengawas, dalam satu kartu.
/// Orang tua lain yang dijaga. Di demo tidak ada telepon dari HP mereka.
private struct OtherParentRow: View {
    let person: Person
    @Environment(AppState.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Avatar(person: person, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(.headline).foregroundStyle(Brand.ink)
                Text(L10n.text(person.relation, language: model.language))
                    .font(.subheadline).foregroundStyle(Brand.ink2)
            }
            Spacer(minLength: 0)
            Image(systemName: "checkmark.shield.fill").foregroundStyle(Brand.safe)
                .accessibilityLabel("Dijaga")
        }
        .card(padding: 14)
        .accessibilityElement(children: .combine)
    }
}

private struct QuietState: View {
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "bell")
                .font(.title2).foregroundStyle(Brand.teal)
            Text("Tidak ada peringatan baru")
                .font(Brand.display(.title3)).foregroundStyle(Brand.ink)
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.safeSoft, in: .rect(cornerRadius: 28, style: .continuous))
    }
}

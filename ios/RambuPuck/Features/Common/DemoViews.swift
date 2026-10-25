import SwiftUI

// Semua yang hanya ada untuk demo: pilihan skenario telepon dan Mode demo.

// MARK: - Pilih skenario

struct ScenarioPicker: View {
    @Environment(AppState.self) private var model
    @Environment(CallViewModel.self) private var call
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Scenario.all(language: model.language)) { scenario in
                        Button {
                            dismiss()
                            call.start(scenario)
                        } label: {
                            ScenarioRow(scenario: scenario)
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Semua percakapan fiktif.")
                }
            }
            .navigationTitle("Contoh telepon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Tutup", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}

struct ScenarioRow: View {
    let scenario: Scenario

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: scenario.channel.symbol)
                .font(.headline)
                .foregroundStyle(Brand.teal)
                .frame(width: 40, height: 40)
                .background(Brand.tealSoft, in: .rect(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(scenario.title).font(.headline).foregroundStyle(Brand.ink)
                Text(scenario.summary).font(.subheadline).foregroundStyle(Brand.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                LevelPill(level: scenario.expectedLevel)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Mode demo

struct DemoSheet: View {
    @Environment(AppState.self) private var model
    @Environment(AppViewModel.self) private var app
    @Environment(CallViewModel.self) private var call
    @Environment(FamilyViewModel.self) private var family
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Persona.allCases) { persona in
                        Button {
                            app.switchPersona(persona)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Avatar(person: model.person(for: persona), size: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.person(for: persona).name).font(.headline).foregroundStyle(Brand.ink)
                                    Text(LocalizedStringKey(persona.roleLabel))
                                        .font(.subheadline).foregroundStyle(Brand.ink2)
                                }
                                Spacer()
                                if model.persona == persona {
                                    Image(systemName: "checkmark").font(.headline).foregroundStyle(Brand.teal)
                                }
                            }
                        }
                        .accessibilityAddTraits(model.persona == persona ? .isSelected : [])
                    }
                } header: {
                    Text("Lihat sebagai")
                } footer: {
                    Text("Aslinya tiap orang memakai HP sendiri.")
                }

                if model.persona.isParent, model.onboardingComplete {
                    Section("Simulasi telepon") {
                        ForEach(Scenario.all(language: model.language)) { scenario in
                            Button {
                                dismiss()
                                call.start(scenario)
                            } label: { ScenarioRow(scenario: scenario) }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    Toggle("Loudspeaker mati di telepon berikutnya", isOn: Bindable(model).speakerOffNextCall)
                    Toggle("Internet putus", isOn: Bindable(model).simulateOffline)
                    Toggle("Bluetooth menyala", isOn: Bindable(model).bluetoothOn)
                    Toggle("Puck tersambung", isOn: Binding(get: { model.puck.isConnected }, set: { model.puck.isConnected = $0 }))
                    Toggle("Baterai puck lemah", isOn: Binding(get: { model.puck.battery <= 20 },
                                                               set: { model.puck.battery = $0 ? 14 : 82 }))
                } header: {
                    Text("Simulasi gangguan")
                } footer: {
                    Text("Untuk melihat banner di beranda dan pengingat loudspeaker.")
                }
                .tint(Brand.teal)

                if !model.persona.isParent, let alert = model.alerts.first(where: { $0.decision == nil }) {
                    let other = model.otherGuardians(than: model.currentPerson).first ?? .richard
                    Section {
                        Button(L10n.format(
                            "guardian.other_answered",
                            fallback: "%@ menjawab lebih dulu",
                            language: model.language,
                            other.name
                        )) {
                            family.simulateDecision(by: other, .scam, on: alert.id)
                            dismiss()
                        }
                    } header: {
                        Text("Pengawas lain")
                    } footer: {
                        Text("Lihat tombol yang terkunci.")
                    }
                }

                Section {
                    Button("Ulangi dari awal", role: .destructive) { confirmReset = true }
                } footer: {
                    Text("Semua data di sini fiktif.")
                }
            }
            .navigationTitle("Mode demo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Selesai", systemImage: "checkmark") { dismiss() }
                }
            }
            .confirmationDialog("Ulangi demo dari awal?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Ulangi", role: .destructive) {
                    app.resetDemo()
                    dismiss()
                }
            }
        }
    }
}

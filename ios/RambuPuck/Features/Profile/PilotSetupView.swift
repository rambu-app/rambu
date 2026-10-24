import SwiftUI

struct ServerConnectionLabel: View {
    @Environment(AppState.self) private var model

    var body: some View {
        Label(model.pilotServerStatus.message,
              systemImage: model.pilotServerStatus == .reachable ? "network" : "network.slash")
            .font(.subheadline).foregroundStyle(Brand.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct PilotSetupView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView { FamilySetupContent().padding(24) }
                .background(Brand.canvas)
                .navigationTitle("Keluarga")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Selesai") { dismiss() }
                    }
                }
        }
    }
}

/// The real invitation flow is shared by onboarding and family settings.
struct FamilySetupContent: View {
    @Environment(AppState.self) private var model
    @Environment(PilotViewModel.self) private var pilot
    @State private var code = ""
    @State private var busy = false
    @State private var showInvitation = false
    @State private var confirmLeave = false
    var onContinue: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let error = model.pilotError {
                VStack(alignment: .leading, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.subheadline).foregroundStyle(Brand.signalInk)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.pilotConnected {
                        Button("Perbarui keluarga") { perform { await pilot.refresh() } }
                            .frame(minHeight: 44).disabled(busy)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.signalSoft, in: .rect(cornerRadius: 18, style: .continuous))
                .accessibilityElement(children: .contain)
            }
            if model.pilotConnected {
                connectedContent
            } else if model.persona.isParent {
                Button {
                    perform { _ = await pilot.createFamily() }
                } label: {
                    WideLabel(title: busy ? "Membuat kode…" : "Buat kode undangan", systemImage: "person.badge.plus")
                }
                .primaryAction()
                .disabled(busy)
            } else {
                TextField("Kode 6 angka", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.title2.monospacedDigit())
                    .padding(16)
                    .background(.white, in: .rect(cornerRadius: 12))
                    .accessibilityLabel("Kode undangan enam angka")
                    .onChange(of: code) { _, value in
                        code = String(value.filter(\.isNumber).prefix(6))
                    }
                Button {
                    perform {
                        if await pilot.joinFamily(code: code), let onContinue { onContinue() }
                    }
                } label: {
                    WideLabel(title: busy ? "Menghubungkan…" : "Hubungkan", systemImage: "link")
                }
                .primaryAction()
                .disabled(busy || code.count != 6)
            }
        }
        .onAppear {
            code = model.pendingInviteCode ?? ""
            showInvitation = model.pilotRole == "parent" && model.guardians.isEmpty
        }
        .onChange(of: model.pilotConnected) { _, connected in
            showInvitation = connected && model.pilotRole == "parent" && model.guardians.isEmpty
        }
        .confirmationDialog("Keluar dari keluarga di HP ini?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Keluar dari keluarga", role: .destructive) { pilot.disconnect() }
            Button("Batal", role: .cancel) { }
        } message: {
            Text("HP ini berhenti menyinkronkan peringatan keluarga. Data keluarga di server tidak dihapus.")
        }
    }

    private var connectedContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            if model.pilotRole == "parent" {
                if model.guardians.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Undang pendamping Anda")
                            .font(Brand.display(.title3)).foregroundStyle(Brand.ink)
                        Text("Bagikan kode ke anak atau anggota keluarga. Mereka memasukkannya di Rambu pada HP mereka.")
                            .font(.subheadline).foregroundStyle(Brand.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: "Pendamping Anda", trailing: "\(model.guardians.count) orang")
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(model.guardians.enumerated()), id: \.element.id) { index, person in
                                if index > 0 { Divider() }
                                personRow(person, detail: person.relation)
                            }
                        }
                        .card(padding: 16)
                        Text("Peringatan panggilan Anda dibagikan kepada pendamping ini.")
                            .font(.footnote).foregroundStyle(Brand.ink2)
                            .padding(.horizontal, 4)
                    }
                }

                if model.guardians.isEmpty || showInvitation {
                    Group {
                        if let code = model.pilotInviteCode, !code.isEmpty {
                            InviteActions(code: code, renewing: busy) { perform { await pilot.renewInvite() } }
                        } else {
                            Button { perform { await pilot.renewInvite() } } label: {
                                WideLabel(title: busy ? "Membuat kode…" : "Buat kode undangan", systemImage: "person.badge.plus")
                            }
                            .primaryAction()
                            .disabled(busy)
                        }
                    }
                    .card(padding: 18)
                } else {
                    Button {
                        showInvitation = true
                    } label: {
                        WideLabel(title: "Undang pendamping lain", systemImage: "person.badge.plus")
                    }
                    .secondaryAction().disabled(busy)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Yang Anda dampingi")
                    personRow(model.parent, detail: "Orang tua").card(padding: 16)
                    Text("Anda menerima peringatan saat Rambu mendeteksi tanda penipuan dalam panggilannya.")
                        .font(.footnote).foregroundStyle(Brand.ink2)
                        .padding(.horizontal, 4)
                }
            }

            if let onContinue {
                Button { onContinue() } label: { WideLabel(title: "Selesai") }.primaryAction()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "Kelola")
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 12) {
                            Image(systemName: "person.2.fill").foregroundStyle(Brand.teal)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Keluarga terhubung").foregroundStyle(Brand.ink)
                                ServerConnectionLabel()
                            }
                        }
                        .padding(.vertical, 8)
                        .accessibilityElement(children: .combine)
                        Divider()
                        Button("Perbarui keluarga", systemImage: "arrow.triangle.2.circlepath") {
                            perform { await pilot.refresh() }
                        }
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .disabled(busy)
                        Divider()
                        Button("Keluar dari keluarga", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            confirmLeave = true
                        }
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .disabled(busy)
                    }
                    .font(.body.weight(.medium))
                    .card(padding: 8)
                }
            }
        }
    }

    private func personRow(_ person: Person, detail: String) -> some View {
        HStack(spacing: 12) {
            Avatar(person: person, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(.headline).foregroundStyle(Brand.ink)
                Text(detail).font(.subheadline).foregroundStyle(Brand.ink2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func perform(_ operation: @escaping @MainActor () async -> Void) {
        busy = true
        Task { await operation(); busy = false }
    }
}

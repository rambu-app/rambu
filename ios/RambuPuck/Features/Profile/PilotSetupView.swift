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
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.subheadline).foregroundStyle(Brand.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.pilotConnected {
                        Button("Perbarui keluarga") { perform { await pilot.refresh() } }
                            .frame(minHeight: 44).disabled(busy)
                    }
                }
                .padding(16)
                .background(Brand.hairline.opacity(0.5), in: .rect(cornerRadius: 12))
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
            DisclosureGroup("Pengaturan lanjutan") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Alamat server", text: Bindable(model).pilotServerURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL).padding(12)
                        .background(.white, in: .rect(cornerRadius: 12))
                        .disabled(model.pilotConnected || busy)
                    Text("Kedua HP harus menggunakan alamat server yang sama.")
                        .font(.footnote).foregroundStyle(Brand.ink2)
                }
                .padding(.top, 12)
            }
            .font(.subheadline).disabled(busy)
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
        VStack(alignment: .leading, spacing: 20) {
            Label("Keluarga terhubung", systemImage: "person.2.fill")
                .font(.headline).foregroundStyle(Brand.teal)
            ServerConnectionLabel()
            if model.pilotRole == "parent" {
                if model.guardians.isEmpty {
                    Text("Undang pendamping Anda")
                        .font(Brand.display(.title2)).foregroundStyle(Brand.ink)
                    Text("Bagikan kode ke anak atau anggota keluarga. Mereka memasukkannya di Rambu pada HP mereka.")
                        .foregroundStyle(Brand.ink2)
                } else {
                    Text("Pendamping Anda")
                        .font(Brand.display(.title2)).foregroundStyle(Brand.ink)
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(model.guardians) { person in
                            HStack(spacing: 12) {
                                Avatar(person: person, size: 44)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(person.name).font(.headline).foregroundStyle(Brand.ink)
                                    Text(person.relation).font(.subheadline).foregroundStyle(Brand.ink2)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    Text("Peringatan panggilan Anda dibagikan kepada pendamping ini.")
                        .font(.subheadline).foregroundStyle(Brand.ink2)
                    Button {
                        showInvitation.toggle()
                    } label: {
                        WideLabel(title: showInvitation ? "Tutup undangan" : "Undang pendamping lain", systemImage: "person.badge.plus")
                    }
                    .primaryAction().disabled(busy)
                }
                if showInvitation {
                    VStack(alignment: .leading, spacing: 12) {
                        if !model.guardians.isEmpty {
                            Text("Pendamping baru memasukkan kode ini di HP-nya.")
                                .font(.subheadline).foregroundStyle(Brand.ink2)
                        }
                        if let code = model.pilotInviteCode, !code.isEmpty { InviteActions(code: code).disabled(busy) }
                        Button(busy ? "Membuat kode…" : "Buat kode baru", systemImage: "arrow.clockwise") {
                            perform { await pilot.renewInvite() }
                        }
                        .frame(minHeight: 44).disabled(busy)
                    }
                }
            } else {
                Text("Yang Anda dampingi")
                    .font(Brand.display(.title2)).foregroundStyle(Brand.ink)
                HStack(spacing: 12) {
                    Avatar(person: model.parent, size: 44)
                    Text(model.parent.name).font(.headline).foregroundStyle(Brand.ink)
                }
                .accessibilityElement(children: .combine)
                Text("Anda menerima peringatan saat Rambu mendeteksi tanda penipuan dalam panggilannya.")
                    .font(.subheadline).foregroundStyle(Brand.ink2)
            }
            if let onContinue {
                Button("Selesai") { onContinue() }.primaryAction()
            } else {
                DisclosureGroup("Kelola keluarga") {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Perbarui keluarga", systemImage: "arrow.triangle.2.circlepath") {
                            perform { await pilot.refresh() }
                        }.frame(minHeight: 44).disabled(busy)
                        Button("Keluar dari keluarga", role: .destructive) { confirmLeave = true }
                            .frame(minHeight: 44).disabled(busy)
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline)
            }
        }
    }

    private func perform(_ operation: @escaping @MainActor () async -> Void) {
        busy = true
        Task { await operation(); busy = false }
    }
}

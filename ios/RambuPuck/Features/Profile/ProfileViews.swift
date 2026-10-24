import SwiftUI

/// Profil: cukup nama dan hubungan. Rambu bukan media sosial, jadi tidak ada foto.
struct ProfileView: View {
    @Environment(AppState.self) private var model
    @Environment(AppViewModel.self) private var app
    @Environment(ProfileViewModel.self) private var profile
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var name = ""
    @State private var relation = "Anak"
    @State private var phoneNumber = ""
    @State private var savingPhone = false
    @State private var phoneError: String?
    @State private var showInvite = false
    @State private var showJoin = false
    @State private var showTutorial = false
    @State private var showPilot = false
    @State private var confirmClear = false
    @State private var confirmReset = false

    private let relations = ["Anak", "Cucu", "Saudara"]

    var body: some View {
        let me = model.currentPerson
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        Avatar(person: me, size: 72)
                        Text(me.name).font(Brand.display(.title2)).foregroundStyle(Brand.ink)
                        Text(model.persona.isParent ? "Orang tua" : "Pendamping")
                            .font(.subheadline).foregroundStyle(Brand.ink2)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Section("Nama") {
                    if model.pilotConnected {
                        Text(me.name)
                    } else {
                    TextField("Nama panggilan", text: $name)
                        .font(.body.weight(.semibold))
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .onSubmit(saveName)
                    if !model.persona.isParent {
                        Picker("Hubungan", selection: $relation) {
                            ForEach(relations, id: \.self) { Text($0) }
                        }
                        .onChange(of: relation) { saveName() }
                    }
                    }
                }

                if model.pilotConnected {
                    Section {
                        TextField("Contoh: 081234567890", text: $phoneNumber)
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                            .autocorrectionDisabled()
                            .accessibilityLabel("Nomor telepon Anda")
                        Button(savingPhone ? "Menyimpan…" : "Simpan nomor") {
                            Task {
                                savingPhone = true
                                phoneError = nil
                                if await app.pilot.savePhoneNumber(phoneNumber) {
                                    phoneNumber = model.currentPerson.phoneNumber ?? ""
                                } else {
                                    phoneError = model.pilotError
                                }
                                savingPhone = false
                            }
                        }
                        .disabled(savingPhone || phoneNumber == (me.phoneNumber ?? ""))
                        if let phoneError {
                            Text(phoneError).font(.subheadline).foregroundStyle(Brand.dangerInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } header: {
                        Text("Nomor telepon (opsional)")
                    } footer: {
                        Text("Dibagikan kepada keluarga yang terhubung agar mereka bisa menelepon Anda. Kosongkan dan simpan untuk menghapus nomor.")
                    }
                }

                if model.allowsDemoControls && model.persona.isParent {
                    guardiansSection
                } else if model.allowsDemoControls {
                    parentsSection
                }

                Section("Peringatan") {
                    HStack {
                        Label("Notifikasi", systemImage: "bell.badge.fill")
                        Spacer()
                        if model.notificationsAuthorized {
                            Text("Aktif").foregroundStyle(Brand.safeInk)
                        } else {
                            Button("Nyalakan") { enableNotifications() }
                                .buttonStyle(.glassProminent).tint(Brand.teal)
                        }
                    }
                    Toggle(isOn: Binding(get: { model.narrationEnabled }, set: { profile.setNarration($0) })) {
                        Label("Bacakan peringatan", systemImage: "speaker.wave.2.fill")
                    }
                    .tint(Brand.teal)
                }

                Section {
                    Button { showPilot = true } label: {
                        HStack {
                            Label("Keluarga", systemImage: "person.2")
                            Spacer()
                            Text(model.pilotConnected ? "Tergabung" : "Belum")
                                .foregroundStyle(model.pilotConnected ? Brand.safeInk : Brand.ink3)
                        }
                    }
                    if model.pilotConnected { ServerConnectionLabel() }
                } header: {
                    Text("Hubungkan keluarga")
                } footer: {
                    Text("Orang tua membuat kode undangan. Pendamping memasukkan kode itu di HP-nya.")
                }

                if model.allowsDemoControls {
                    Section("Bantuan") {
                    Button { showTutorial = true } label: {
                        Label("Ulangi tutorial", systemImage: "play.circle.fill")
                    }
                    if model.persona.isParent {
                        Button(role: .destructive) { confirmClear = true } label: {
                            Label("Hapus riwayat", systemImage: "trash")
                        }
                    }
                    }
                }

                Section {
                    if model.allowsDemoControls {
                        Button { openDemo() } label: {
                            Label("Mode demo", systemImage: "person.2.badge.gearshape.fill")
                        }
                    }
                    Button("Keluar dan mulai ulang", role: .destructive) { confirmReset = true }
                } footer: {
                    Text("Profil disimpan di HP ini. Keluarga, peringatan, dan hasil analisis disinkronkan saat terhubung.")
                }
            }
            .navigationTitle("Profil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Selesai", systemImage: "checkmark") {
                        saveName()
                        dismiss()
                    }
                    .disabled(savingPhone)
                }
            }
            .onAppear {
                name = me.name
                relation = me.relation
                phoneNumber = me.phoneNumber ?? ""
            }
            .sheet(isPresented: $showInvite) { InviteSheet() }
            .sheet(isPresented: $showJoin) { JoinParentSheet() }
            .sheet(isPresented: $showPilot) { PilotSetupView() }
            .fullScreenCover(isPresented: $showTutorial) {
                TutorialCarousel(isParent: model.persona.isParent) { showTutorial = false }
            }
            .confirmationDialog("Hapus semua riwayat?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Hapus", role: .destructive) { profile.clearHistory() }
            }
            .confirmationDialog("Keluar dan mulai ulang?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Keluar", role: .destructive) { app.resetDemo() }
            } message: {
                Text("Profil dan riwayat lokal di HP ini dihapus. Data keluarga di server tetap tersimpan.")
            }
        }
    }

    private var guardiansSection: some View {
        Section {
            ForEach(model.guardians) { person in
                PersonRow(person: person)
                    .swipeActions {
                        if model.guardians.count > 1 {
                            Button("Hapus", role: .destructive) { profile.removeGuardian(person) }
                        }
                    }
            }
            Button { showInvite = true } label: {
                Label("Undang pengawas", systemImage: "person.badge.plus")
            }
        } header: {
            Text("Pengawas")
        } footer: {
            Text("Geser ke kiri untuk menghapus. Minimal satu pengawas.")
        }
    }

    private var parentsSection: some View {
        Section("Yang Anda jaga") {
            ForEach(model.protectedParents) { person in
                PersonRow(person: person)
                    .swipeActions {
                        if model.extraParents.contains(person) {
                            Button("Berhenti", role: .destructive) { profile.removeProtectedParent(person) }
                        }
                    }
            }
            Button { showJoin = true } label: {
                Label("Jaga orang tua lain", systemImage: "plus.circle.fill")
            }
        }
    }

    private func saveName() {
        guard !model.pilotConnected else { return }
        if model.persona.isParent {
            profile.renameParent(name)
        } else {
            profile.renameGuardian(model.persona, name: name, relation: relation)
        }
    }

    private func enableNotifications() {
        Task {
            await profile.requestNotifications()
            if !model.notificationsAuthorized, let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                openURL(url)
            }
        }
    }

    /// Hanya dipakai fixture screenshot. Profil ditutup sebelum sheet fixture dibuka.
    private func openDemo() {
        saveName()
        model.showProfile = false
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            model.showDemoSheet = true
        }
    }
}

private struct PersonRow: View {
    let person: Person

    var body: some View {
        HStack(spacing: 12) {
            Avatar(person: person, size: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text(person.name).font(.headline).foregroundStyle(Brand.ink)
                Text(person.relation).font(.subheadline).foregroundStyle(Brand.ink2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Undangan

/// Kode undangan plus cara mengirimnya. Tautan https bisa diketuk langsung di WhatsApp.
struct InviteActions: View {
    let code: String
    var renewing = false
    var onRenew: (() -> Void)?
    @Environment(AppState.self) private var model
    @State private var copied = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let validity = InviteValidity(expiresAt: model.pilotInviteExpiresAt, now: context.date)
            let message = InviteLink.message(code: code, parentName: model.parent.name, expiresAt: model.pilotInviteExpiresAt)
            VStack(alignment: .leading, spacing: 14) {
                DigitBoxes(digits: code).opacity(validity.canShare ? 1 : 0.4)
                Label(validity.message, systemImage: validity.canShare ? "clock" : "exclamationmark.circle.fill")
                    .font(.subheadline.weight(validity.canShare ? .regular : .semibold))
                    .foregroundStyle(validity.canShare ? Brand.ink2 : Brand.dangerInk)
                if validity.canShare {
                    ShareLink(item: message) {
                        WideLabel(title: "Bagikan kode", systemImage: "square.and.arrow.up")
                    }
                    .primaryAction()
                    HStack {
                        Button {
                            UIPasteboard.general.string = code
                            withAnimation(.smooth) { copied = true }
                        } label: {
                            Label(copied ? "Kode tersalin" : "Salin kode", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        Spacer()
                        if let onRenew {
                            Button(renewing ? "Membuat kode…" : "Buat kode baru", systemImage: "arrow.clockwise", action: onRenew)
                                .disabled(renewing)
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.teal)
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                } else if let onRenew {
                    Button(action: onRenew) {
                        WideLabel(title: renewing ? "Membuat kode…" : "Buat kode baru", systemImage: "arrow.clockwise")
                    }
                    .primaryAction()
                    .disabled(renewing)
                }
            }
        }
        .onChange(of: code) { _, _ in copied = false }
    }
}

private struct InviteSheet: View {
    @Environment(AppState.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Kirim tautan ini ke anak Anda. Mereka tinggal mengetuknya.")
                        .font(.body).foregroundStyle(Brand.ink2)
                    InviteActions(code: model.pilotInviteCode ?? "482913")
                }
                .padding(24)
            }
            .background(Brand.canvas)
            .navigationTitle("Undang pengawas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Tutup", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Pengawas menambah orang tua lain lewat kode 6 angka.
private struct JoinParentSheet: View {
    @Environment(AppState.self) private var model
    @Environment(ProfileViewModel.self) private var profile
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var added: Person?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                if let added {
                    VStack(spacing: 12) {
                        MascotView(pose: .happy, sign: .safe).frame(height: 130)
                        Text("Sekarang Anda menjaga \(added.name)")
                            .font(Brand.display(.title3)).foregroundStyle(Brand.ink)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    Button { dismiss() } label: { WideLabel(title: "Selesai") }.primaryAction()
                } else {
                    Text("Masukkan kode dari aplikasi Rambu orang tua.")
                        .font(.body).foregroundStyle(Brand.ink2)
                    ZStack {
                        TextField("", text: $code)
                            .keyboardType(.numberPad)
                            .focused($focused)
                            .opacity(0.01)
                            .onChange(of: code) { _, value in code = String(value.filter(\.isNumber).prefix(6)) }
                        DigitBoxes(digits: code, showsCursor: focused)
                            .contentShape(.rect)
                            .onTapGesture { focused = true }
                    }
                    Button("Isi kode demo 715 204", systemImage: "wand.and.stars") { code = "715204" }
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button {
                        withAnimation(.smooth) { added = profile.addProtectedParent(code: code) }
                    } label: { WideLabel(title: "Gabung") }
                        .primaryAction()
                        .disabled(code.count < 6)
                }
            }
            .padding(24)
            .background(Brand.canvas)
            .navigationTitle("Jaga orang tua lain")
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

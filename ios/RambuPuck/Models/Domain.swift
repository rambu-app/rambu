import SwiftUI

// MARK: - Orang dan peran

/// Peran yang sedang dilihat. Di produk nyata satu HP adalah satu orang;
/// mode demo menggabungkan ketiganya di satu HP.
enum Persona: String, CaseIterable, Identifiable, Codable, Sendable {
    case ratna, sinta, richard

    var id: String { rawValue }

    var isParent: Bool { self == .ratna }
    var roleLabel: String { isParent ? "Orang tua" : "Pengawas" }
}

struct Person: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let initial: String
    let relation: String
    let colorHex: UInt32
    var phoneNumber: String? = nil

    var color: Color { Color(hex: colorHex) }

    var telephoneURL: URL? {
        guard let phoneNumber, let normalized = PhoneNumber.normalized(phoneNumber) else { return nil }
        return URL(string: "tel:\(normalized)")
    }
}

enum PhoneNumber {
    static func normalized(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 40,
              value.range(of: "^[+0-9 ()\\-.]+$", options: .regularExpression) != nil else { return nil }
        var compact = value.filter { !" ()-.".contains($0) }
        if compact.hasPrefix("0") { compact = "+62" + compact.dropFirst() }
        else if compact.hasPrefix("62") { compact = "+" + compact }
        guard compact.range(of: "^\\+[1-9][0-9]{7,14}$", options: .regularExpression) != nil else { return nil }
        return compact
    }
}

extension Person {
    static let ratna = Person(id: "ratna", name: "Ibu Ratna", initial: "R", relation: "Ibu", colorHex: 0x006F63)
    static let sinta = Person(id: "sinta", name: "Sinta", initial: "S", relation: "Anak", colorHex: 0x1E6E9E)
    static let richard = Person(id: "richard", name: "Richard", initial: "R", relation: "Anak", colorHex: 0x6347A8)
    static let guardians: [Person] = [.sinta, .richard]

    /// Nama baru dengan warna dan id yang sama. Inisial diambil dari kata terakhir,
    /// jadi "Ibu Ratna" menjadi R, bukan I.
    func renamed(_ newName: String, relation newRelation: String? = nil) -> Person {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? self.name : trimmed
        let initial = name.split(separator: " ").last?.first.map { String($0).uppercased() } ?? self.initial
        return Person(id: id, name: name, initial: initial, relation: newRelation ?? relation, colorHex: colorHex, phoneNumber: phoneNumber)
    }
}

// MARK: - Tanda penipuan

/// Kategori tanda social engineering yang dicari di percakapan.
enum SignalKind: String, Codable, CaseIterable, Hashable, Sendable {
    case impersonation, urgency, secretCode, transfer, remoteApp

    /// Nama kategori untuk pengawas.
    var title: String {
        switch self {
        case .impersonation: "Mengaku dari lembaga"
        case .urgency: "Desakan waktu"
        case .secretCode: "Meminta kode OTP atau PIN"
        case .transfer: "Meminta transfer uang"
        case .remoteApp: "Menyuruh pasang aplikasi"
        }
    }

    /// Kalimat pendek untuk orang tua saat telepon masih berjalan.
    var parentHeadline: String {
        switch self {
        case .impersonation: "Penelepon mengaku dari lembaga"
        case .urgency: "Penelepon mendesak Anda"
        case .secretCode: "Penelepon meminta kode rahasia"
        case .transfer: "Penelepon meminta transfer"
        case .remoteApp: "Penelepon menyuruh pasang aplikasi"
        }
    }

    var symbol: String {
        switch self {
        case .impersonation: "building.columns.fill"
        case .urgency: "timer"
        case .secretCode: "key.fill"
        case .transfer: "banknote.fill"
        case .remoteApp: "arrow.down.app.fill"
        }
    }

    /// Tingkat minimum yang ditandai sinyal ini jika muncul sendirian.
    var floor: RiskLevel {
        switch self {
        case .impersonation, .urgency: .danger
        case .secretCode, .transfer, .remoteApp: .danger
        }
    }
}

/// Aturan penilaian tiruan untuk prototipe. Backend menggantinya dengan analisis Langflow.
enum RiskRules {
    static func level(for signals: Set<SignalKind>) -> RiskLevel {
        if signals.isEmpty { return .safe }
        if signals.count >= 2 { return .danger }
        return signals.map(\.floor).max() ?? .safe
    }
}

// MARK: - Panggilan

enum CallChannel: String, Codable, Hashable, Sendable {
    case cellular, whatsapp

    var label: String { self == .cellular ? "Telepon seluler" : "Panggilan WhatsApp" }
    var short: String { self == .cellular ? "Telepon" : "WhatsApp" }
    var symbol: String { self == .cellular ? "phone.fill" : "bubble.left.fill" }
}

enum Speaker: String, Codable, Hashable, Sendable {
    case caller, parent, unknown

    var label: String {
        switch self {
        case .caller: "Penelepon"
        case .parent: "Orang tua"
        case .unknown: "Pembicara"
        }
    }
}

/// Satu potongan transkrip ±5 detik.
struct TranscriptLine: Identifiable, Hashable, Codable, Sendable {
    let id: Int
    let offset: TimeInterval?
    let speaker: Speaker
    let text: String
    let flagged: [String]
    let signals: [SignalKind]

    var isFlagged: Bool { !signals.isEmpty }

    static func groupedForDisplay(_ lines: [TranscriptLine]) -> [TranscriptLine] {
        // Group only exact or clearly contained excerpts. Keep every original in storage.
        // Short phrases and differing negations are deliberately not treated as overlap.
        let negations: Set<String> = ["jangan", "tidak", "bukan", "tak", "belum", "tanpa", "enggak", "nggak", "gak", "ga", "ngga", "ndak"]
        func words(_ line: TranscriptLine) -> [String] {
            line.text.lowercased().components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty }
        }
        var result: [TranscriptLine] = []
        for line in lines {
            let current = words(line)
            guard !current.isEmpty else { continue }
            if let index = result.firstIndex(where: { existing in
                guard existing.speaker == line.speaker, Set(existing.signals) == Set(line.signals) else { return false }
                let previous = words(existing)
                if previous == current { return true }
                guard min(previous.count, current.count) >= 4,
                      Set(previous).intersection(negations) == Set(current).intersection(negations) else { return false }
                let a = " " + previous.joined(separator: " ") + " "
                let b = " " + current.joined(separator: " ") + " "
                return a.contains(b) || b.contains(a)
            }) {
                if current.count > words(result[index]).count { result[index] = line }
            } else {
                result.append(line)
            }
        }
        return result
    }
}

struct InviteValidity {
    let expiresAt: Date?
    let now: Date

    var canShare: Bool { expiresAt.map { $0 > now } ?? false }

    var message: String {
        guard let expiresAt else { return "Buat kode baru untuk membagikan undangan." }
        let remaining = expiresAt.timeIntervalSince(now)
        guard remaining > 0 else { return "Kode kedaluwarsa" }
        if remaining < 60 { return "Berlaku kurang dari 1 menit lagi" }
        return "Berlaku \(Int(ceil(remaining / 60))) menit lagi"
    }
}

struct Scenario: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let summary: String
    let callerName: String
    let callerDetail: String
    let channel: CallChannel
    let lines: [TranscriptLine]

    var expectedLevel: RiskLevel { RiskRules.level(for: Set(lines.flatMap(\.signals))) }

    var callMetadata: CallMetadata {
        CallMetadata(
            title: title,
            callerName: callerName,
            callerDetail: callerDetail,
            channel: channel,
            fixtureID: id
        )
    }
}

struct CallMetadata: Hashable, Sendable {
    let title: String
    let callerName: String
    let callerDetail: String
    let channel: CallChannel
    let fixtureID: String?

    static let production = CallMetadata(
        title: "Panggilan terdeteksi",
        callerName: "Panggilan aktif",
        callerDetail: "Nomor tidak tersedia",
        channel: .cellular,
        fixtureID: nil
    )
}

enum ProtectionStatus: String, Equatable, Sendable {
    case waitingForPuck
    case listening
    case completed
    case noSpeech
}

struct AnalysisFailure: Equatable, Sendable {
    let code: String
    let title: String
    let detail: String
    let at: Date
}

/// Panggilan yang sedang berlangsung di HP orang tua.
struct CallSession: Identifiable, Sendable {
    let id: UUID
    let metadata: CallMetadata
    let startedAt: Date
    var heard: [TranscriptLine] = []
    var signals: [SignalKind] = []
    var level: RiskLevel = .safe
    var isListening = true
    var analysisFailure: AnalysisFailure?
    var protectionStatus: ProtectionStatus
    /// Puck hanya mendengar dari loudspeaker. Kalau mati, Rambu belum bisa menilai apa pun.
    var speakerOn = true

    var headline: String { signals.last?.parentHeadline ?? "Rambu mendengarkan" }

    init(
        id: UUID,
        metadata: CallMetadata,
        startedAt: Date,
        protectionStatus: ProtectionStatus = .waitingForPuck
    ) {
        self.id = id
        self.metadata = metadata
        self.startedAt = startedAt
        self.protectionStatus = protectionStatus
    }

    init(id: UUID, scenario: Scenario, startedAt: Date) {
        self.init(
            id: id,
            metadata: scenario.callMetadata,
            startedAt: startedAt,
            protectionStatus: .listening
        )
    }
}

// MARK: - Keputusan keluarga

enum Verdict: String, Codable, Hashable, Sendable {
    case scam, safe

    var pastTitle: String { self == .scam ? "penipuan" : "aman" }
}

struct GuardianDecision: Hashable, Codable, Sendable {
    let by: Person
    let verdict: Verdict
    let at: Date
}

enum DecisionOutcome: Equatable, Sendable {
    case accepted(GuardianDecision)
    case alreadyDecided(GuardianDecision)
    case unknownAlert
}

/// Peringatan yang dikirim ke semua pengawas. Hanya kalimat penelepon yang memicu
/// peringatan yang ikut terkirim; percakapan lengkap tetap di HP orang tua.
struct FamilyAlert: Identifiable, Hashable, Sendable {
    let id: UUID
    let parent: Person
    let callerDetail: String
    let channel: CallChannel
    let startedAt: Date
    var raisedAt: Date
    var level: RiskLevel
    var signals: [SignalKind]
    var evidence: [TranscriptLine]
    var recipients: [Person]
    var decision: GuardianDecision?
    var callEnded = false

    var title: String {
        "\(parent.name) mungkin sedang ditipu"
    }
}

struct CallRecord: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let title: String
    let callerDetail: String
    let channel: CallChannel
    let startedAt: Date
    let duration: TimeInterval
    var level: RiskLevel
    var signals: [SignalKind]
    var evidence: [TranscriptLine]
    var decision: GuardianDecision?
    var unassessedReason: String? = nil

    var displayReason: String? {
        guard let unassessedReason else { return nil }
        return unassessedReason == "Tidak ada suara yang dapat dianalisis."
            ? unassessedReason : "Analisis belum berhasil. Hasil panggilan ini belum tersedia."
    }

    var historyPresentation: HistoryPresentation {
        if unassessedReason != nil { return .unassessed }
        switch level {
        case .safe: return .safe
        case .review: return .review
        case .danger: return .danger
        }
    }
}

enum HistoryPresentation: String, Codable, Hashable, Sendable {
    case safe, review, danger, unassessed

    var title: String {
        switch self {
        case .safe: "Aman"
        case .review: "Bahaya"
        case .danger: "Bahaya"
        case .unassessed: "Tidak dapat dinilai"
        }
    }

    var symbol: String {
        switch self {
        case .safe: "checkmark.circle.fill"
        case .review: "exclamationmark.triangle.fill"
        case .danger: "exclamationmark.octagon.fill"
        case .unassessed: "questionmark.circle.fill"
        }
    }

    var colorRole: HistoryColorRole {
        switch self {
        case .safe: .safe
        case .review: .danger
        case .danger: .danger
        case .unassessed: .neutral
        }
    }

    var tint: Color {
        switch colorRole {
        case .safe: Brand.safe
        case .warning: Brand.signal
        case .danger: Brand.danger
        case .neutral: Brand.ink3
        }
    }

    var soft: Color {
        switch colorRole {
        case .safe: Brand.safeSoft
        case .warning: Brand.signalSoft
        case .danger: Brand.dangerSoft
        case .neutral: Brand.hairline
        }
    }

    var ink: Color {
        switch colorRole {
        case .safe: Brand.safeInk
        case .warning: Brand.signalInk
        case .danger: Brand.dangerInk
        case .neutral: Brand.ink2
        }
    }

    var glyph: Color { .white }
}

enum HistoryColorRole: String, Codable, Hashable, Sendable {
    case safe, warning, danger, neutral
}

// MARK: - Puck

struct PuckState: Hashable, Codable, Sendable {
    var isPaired: Bool
    var isConnected: Bool
    var battery: Int
    var isCharging: Bool
    var name: String
    var serial: String
    var firmware: String

    var batterySymbol: String {
        if isCharging { return "battery.100percent.bolt" }
        switch battery {
        case 76...: return "battery.100percent"
        case 51...75: return "battery.75percent"
        case 26...50: return "battery.50percent"
        default: return "battery.25percent"
        }
    }

    static let demo = PuckState(isPaired: true, isConnected: true, battery: 82, isCharging: false,
                                name: "Rambu Puck", serial: "RP-2F8A", firmware: "0.3.1")
    static let unpaired = PuckState(isPaired: false, isConnected: false, battery: 0, isCharging: false,
                                    name: "Rambu Puck", serial: "", firmware: "")
}

// MARK: - Navigasi

enum ParentTab: Hashable { case home, history, puck }
enum GuardianTab: Hashable { case home, history }

enum OnboardingStep: String, Hashable, Sendable {
    // Jalur orang tua
    case welcome, tutorial, parentProfile, pairPuck, consent, invite, practiceCall
    // Jalur pengawas
    case enterCode, guardianProfile, practiceAlert, waiting
}

// MARK: - Gangguan

/// Hal yang membuat Rambu tidak bisa bekerja penuh. Tampil sebagai banner di beranda.
enum SystemIssue: String, Identifiable, CaseIterable, Sendable {
    case notificationsOff, offline, bluetoothOff, puckDisconnected, puckLowBattery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notificationsOff: "Notifikasi mati"
        case .offline: "Tidak ada internet"
        case .bluetoothOff: "Bluetooth mati"
        case .puckDisconnected: "Puck terputus"
        case .puckLowBattery: "Baterai puck lemah"
        }
    }

    var detail: String {
        switch self {
        case .notificationsOff: "Peringatan tidak akan muncul."
        case .offline: "Pengawas belum bisa dikabari."
        case .bluetoothOff: "Rambu tidak bisa mendengar."
        case .puckDisconnected: "Dekatkan puck ke HP."
        case .puckLowBattery: "Isi daya sebelum habis."
        }
    }

    var symbol: String {
        switch self {
        case .notificationsOff: "bell.slash.fill"
        case .offline: "wifi.slash"
        case .bluetoothOff: "antenna.radiowaves.left.and.right.slash"
        case .puckDisconnected: "circle.slash"
        case .puckLowBattery: "battery.25percent"
        }
    }

    /// Label tombol, kalau masalahnya bisa dibereskan dari sini.
    var action: String? {
        switch self {
        case .notificationsOff: "Nyalakan"
        case .bluetoothOff: "Pengaturan"
        case .puckDisconnected: "Sambungkan"
        case .offline, .puckLowBattery: nil
        }
    }
}

/// Isi push Rambu. Dikirim sebagai notifikasi sistem, atau tampil sebagai tiruan banner
/// di dalam app kalau izin notifikasi belum ada.
struct Toast: Identifiable, Equatable {
    let id: String
    let title: String
    let body: String
    /// Menentukan warna dan papan yang dipegang maskot.
    let level: RiskLevel
    let alertID: UUID?
}

// MARK: - Format tanggal berbahasa Indonesia

enum Fmt {
    static let locale = Locale(identifier: "id_ID")

    static func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }

    static func day(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar(identifier: .gregorian)
        if calendar.isDate(date, inSameDayAs: now) { return "Hari ini, \(clock(date))" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Kemarin, \(clock(date))"
        }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(locale))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let rest = total % 60
        if minutes == 0 { return "\(rest) dtk" }
        return rest == 0 ? "\(minutes) mnt" : "\(minutes) mnt \(rest) dtk"
    }

    static func offset(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Ringkasan kejadian

extension CallRecord {
    /// Interpretation of detected categories. Metadata and caregiver decisions are shown separately.
    var incidentSummary: String {
        if let displayReason {
            return displayReason
        }
        guard !signals.isEmpty else { return "Tidak terdeteksi tanda penipuan pada percakapan yang dianalisis." }
        let listed = signals.map(\.summaryLabel).formatted(.list(type: .and).locale(Fmt.locale))
        return "Rambu mendeteksi indikasi \(listed)."
    }
}

extension SignalKind {
    var summaryLabel: String {
        switch self {
        case .impersonation: "penyamaran sebagai lembaga"
        case .urgency: "desakan untuk segera bertindak"
        case .secretCode: "permintaan kode OTP atau PIN"
        case .transfer: "permintaan transfer uang"
        case .remoteApp: "permintaan memasang aplikasi"
        }
    }

    var callerPhrase: String {
        switch self {
        case .impersonation: "mengaku dari lembaga"
        case .urgency: "mendesak Anda"
        case .secretCode: "meminta kode OTP atau PIN"
        case .transfer: "meminta transfer uang"
        case .remoteApp: "menyuruh memasang aplikasi"
        }
    }

    var adviceForGuardian: String {
        switch self {
        case .impersonation, .urgency: "Minta orang tua menutup telepon dan menelepon balik lewat nomor resmi."
        case .secretCode: "Ingatkan untuk tidak memberikan kode OTP atau PIN."
        case .transfer: "Ingatkan untuk tidak mentransfer uang."
        case .remoteApp: "Ingatkan untuk tidak memasang aplikasi apa pun."
        }
    }

    var advice: String {
        switch self {
        case .impersonation: "Hubungi lembaganya lewat nomor resmi."
        case .urgency: "Jangan terburu-buru. Tutup telepon dulu."
        case .secretCode: "Jangan berikan kode OTP, PIN, atau kata sandi."
        case .transfer: "Jangan transfer uang."
        case .remoteApp: "Jangan pasang aplikasi yang diminta penelepon."
        }
    }
}

extension [SignalKind] {
    var callerSummary: String? {
        guard !isEmpty else { return nil }
        return "Penelepon \(map(\.callerPhrase).formatted(.list(type: .and).locale(Fmt.locale)))."
    }
}

extension CallRecord {
    var verdictHeadline: String {
        switch historyPresentation {
        case .danger, .review: "Kemungkinan penipuan"
        case .safe: "Tidak ada tanda penipuan"
        case .unassessed: "Belum bisa dinilai"
        }
    }
}

extension RiskLevel {
    var historyPresentation: HistoryPresentation {
        switch self {
        case .safe: .safe
        case .review: .review
        case .danger: .danger
        }
    }
}

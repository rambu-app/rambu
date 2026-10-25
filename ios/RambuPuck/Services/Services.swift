@preconcurrency import ActivityKit
import CoreBluetooth
import Foundation

// MARK: - Batas serah terima ke backend
//
// Tiga protokol di bawah adalah satu-satunya titik yang perlu diganti tim backend.
// UI hanya bergantung pada protokol ini, bukan pada implementasi simulasinya.
// Lihat ios/README.md untuk kontrak lengkapnya.

/// Identitas panggilan yang sedang diperiksa.
struct CallContext: Sendable {
    let id: UUID
    let metadata: CallMetadata
    let startedAt: Date
    let language: AppLanguage

    init(
        id: UUID,
        metadata: CallMetadata,
        startedAt: Date,
        language: AppLanguage = .indonesian
    ) {
        self.id = id
        self.metadata = metadata
        self.startedAt = startedAt
        self.language = language
    }
}

/// Hasil pemeriksaan satu potongan audio ±5 detik dari puck.
struct ChunkAssessment: Sendable {
    let line: TranscriptLine
    /// Tingkat keseluruhan panggilan setelah potongan ini. Tidak pernah turun.
    let level: RiskLevel
    /// Tanda yang terdeteksi di potongan ini saja.
    let signals: [SignalKind]
}

/// Sumber penilaian risiko selama panggilan.
/// Nyata: audio puck → POST /transcribe (backend/) → analisis Langflow → ChunkAssessment.
protocol CallAnalysisSession: Sendable {
    var assessments: AsyncThrowingStream<ChunkAssessment, Error> { get }
    var statusUpdates: AsyncStream<ProtectionStatus> { get }
    func finish() async throws
    func cancel() async throws
}

protocol CallAnalysisSource: Sendable {
    var usesAuthoritativeRemoteAlerts: Bool { get }
    func assessments(for call: CallContext) -> AsyncThrowingStream<ChunkAssessment, Error>
    func start(for call: CallContext) async throws -> any CallAnalysisSession
}

extension CallAnalysisSource {
    var usesAuthoritativeRemoteAlerts: Bool { false }

    func start(for call: CallContext) async throws -> any CallAnalysisSession {
        LegacyCallAnalysisSession(assessments: assessments(for: call))
    }
}

private struct LegacyCallAnalysisSession: CallAnalysisSession {
    let assessments: AsyncThrowingStream<ChunkAssessment, Error>
    let statusUpdates = AsyncStream<ProtectionStatus> { $0.finish() }

    func finish() async throws {}
    func cancel() async throws {}
}

/// Saluran keluarga: menyebarkan peringatan ke semua pengawas dan menerima keputusan.
/// Server nyata wajib menegakkan aturan "keputusan pertama yang berlaku".
@MainActor
protocol FamilyRelay: AnyObject {
    var onEvent: ((RelayEvent) -> Void)? { get set }
    func publish(_ alert: FamilyAlert)
    func submit(_ decision: GuardianDecision, for alertID: UUID) -> DecisionOutcome
}

enum RelayEvent: Sendable {
    case alert(FamilyAlert)
    case decided(alertID: UUID, GuardianDecision)
}

/// Koneksi Bluetooth ke Rambu Puck.
/// Nyata: CoreBluetooth, menunggu spesifikasi GATT dari tim hardware.
@MainActor
protocol PuckLink: AnyObject {
    func discover() async -> PuckState
}

/// Relay di memori. Menjalankan aturan yang sama dengan server nyata:
/// keputusan pertama yang masuk berlaku, keputusan berikutnya ditolak.
@MainActor
final class LocalFamilyRelay: FamilyRelay {
    var onEvent: ((RelayEvent) -> Void)?
    private var alerts: [UUID: FamilyAlert] = [:]

    func publish(_ alert: FamilyAlert) {
        var stored = alert
        // Pembaruan tingkat risiko tidak boleh menghapus keputusan yang sudah masuk.
        stored.decision = alerts[alert.id]?.decision
        alerts[alert.id] = stored
        onEvent?(.alert(stored))
    }

    func submit(_ decision: GuardianDecision, for alertID: UUID) -> DecisionOutcome {
        guard var alert = alerts[alertID] else { return .unknownAlert }
        if let existing = alert.decision { return .alreadyDecided(existing) }
        alert.decision = decision
        alerts[alertID] = alert
        onEvent?(.decided(alertID: alertID, decision))
        return .accepted(decision)
    }
}

@MainActor
final class SimulatedPuckLink: PuckLink {
    func discover() async -> PuckState {
        try? await Task.sleep(for: .seconds(2))
        return .demo
    }
}

/// Memasangkan iPhone dengan puck lewat Bluetooth. Setelah dipasangkan, iOS sendiri
/// yang memberi tahu puck saat ada panggilan masuk (ANCS), tanpa perlu Rambu terbuka.
/// Lewat sambungan yang sama, app mengirim Wi-Fi dan alamat server ke puck.
@MainActor
@Observable
final class BluetoothPuckPairing: NSObject {
    enum Status: Equatable {
        case idle
        case searching
        case pairing
        case paired
        case failed(String)
    }

    enum WifiStatus: Equatable {
        case idle
        case sending
        case connected
        case failed(String)
    }

    private enum PendingTask: Equatable {
        case pair
        case wifi(Data)
    }

    private static let service = CBUUID(string: "5B4F74AF-95E4-4449-8129-C97AD2293807")
    private static let pairing = CBUUID(string: "29308BE3-4FCA-47FB-AF2D-3539D416BAA1")
    private static let wifi = CBUUID(string: "8E1F2A6C-3B7D-4C59-9A0E-5D2F7B4C1E93")
    private static let pairedKey = "puckPaired"

    private(set) var status: Status
    private(set) var wifiStatus = WifiStatus.idle
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var pending: PendingTask?
    @ObservationIgnored private var timeout: Task<Void, Never>?

    override init() {
        status = UserDefaults.standard.bool(forKey: Self.pairedKey) ? .paired : .idle
    }

    func pair() {
        status = .searching
        start(.pair)
    }

    func sendWifi(name: String, password: String, serverURL: String, puckToken: String) {
        let server = URL(string: serverURL)
        let https = server?.scheme == "https"
        let port = server?.port ?? (https ? 443 : 80)
        let config = [name, password, server?.host() ?? "", String(port), https ? "1" : "0", puckToken].joined(separator: "\n")
        wifiStatus = .sending
        start(.wifi(Data(config.utf8)))
    }

    private func start(_ task: PendingTask) {
        pending = task
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, !Task.isCancelled, self.pending != nil else { return }
            self.central?.stopScan()
            self.fail("Puck tidak ditemukan. Pastikan puck menyala dan dekat HP.")
        }
        guard let central, central.state == .poweredOn else {
            if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
            return
        }
        connect(central)
    }

    private func connect(_ central: CBCentralManager) {
        if let known = central.retrieveConnectedPeripherals(withServices: [Self.service]).first {
            use(known, on: central)
        } else {
            central.scanForPeripherals(withServices: [Self.service])
        }
    }

    private func use(_ peripheral: CBPeripheral, on central: CBCentralManager) {
        self.peripheral = peripheral
        peripheral.delegate = self
        if peripheral.state == .connected {
            peripheral.discoverServices([Self.service])
        } else {
            central.connect(peripheral)
        }
    }

    private func finish() {
        pending = nil
        timeout?.cancel()
    }

    private func fail(_ message: String) {
        switch pending {
        case .pair: status = .failed(message)
        case .wifi: wifiStatus = .failed(message)
        case nil: break
        }
        finish()
    }
}

extension BluetoothPuckPairing: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn where pending != nil:
            connect(central)
        case .poweredOff:
            fail("Bluetooth mati. Nyalakan Bluetooth lalu coba lagi.")
        case .unauthorized:
            fail("Izinkan Bluetooth untuk Rambu di Pengaturan.")
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        central.stopScan()
        if case .pair = pending { status = .pairing }
        use(peripheral, on: central)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fail("Gagal terhubung ke puck. Coba lagi.")
    }
}

extension BluetoothPuckPairing: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            fail("Perangkat ini bukan Rambu Puck.")
            return
        }
        peripheral.discoverCharacteristics([Self.pairing, Self.wifi], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let characteristics = service.characteristics ?? []
        switch pending {
        case .pair:
            guard let pairing = characteristics.first(where: { $0.uuid == Self.pairing }) else {
                fail("Perangkat ini bukan Rambu Puck.")
                return
            }
            // Karakteristik ini terenkripsi, jadi membacanya memunculkan permintaan pairing iOS.
            peripheral.readValue(for: pairing)
        case .wifi(let config):
            guard let wifi = characteristics.first(where: { $0.uuid == Self.wifi }) else {
                fail("Perbarui firmware puck terlebih dahulu.")
                return
            }
            peripheral.setNotifyValue(true, for: wifi)
            peripheral.writeValue(config, for: wifi, type: .withResponse)
        case nil:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if error != nil { fail("Wi-Fi belum terkirim. Coba lagi.") }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == Self.pairing {
            guard case .pair = pending else { return }
            guard error == nil else {
                fail("Pairing dibatalkan. Coba lagi dan pilih Pasangkan.")
                return
            }
            UserDefaults.standard.set(true, forKey: Self.pairedKey)
            status = .paired
            finish()
        } else if characteristic.uuid == Self.wifi, case .wifi = pending {
            switch characteristic.value.map({ String(decoding: $0, as: UTF8.self) }) {
            case "connected":
                wifiStatus = .connected
                finish()
            case "failed":
                fail("Puck tidak bisa masuk Wi-Fi. Periksa nama dan kata sandi.")
            default:
                break
            }
        }
    }
}

// MARK: - Live Activity

/// Mengatur Live Activity panggilan. Bersifat pelengkap: kalau Live Activity
/// dimatikan pengguna, layar di dalam app tetap berjalan normal.
@MainActor
final class CallLiveActivity {
    private var activity: Activity<RambuCallAttributes>?
    private let enabled: Bool

    init(enabled: Bool) {
        self.enabled = enabled
        guard enabled else { return }
        // Live Activity dari proses sebelumnya (misal app ditutup paksa saat menelepon)
        // tidak ikut berakhir. Daftarnya diambil sekarang supaya yang dibuat sesudah ini aman.
        let stale = Activity<RambuCallAttributes>.activities
        if !stale.isEmpty {
            Task {
                for activity in stale {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
    }

    var isActive: Bool { activity != nil }

    func start(attributes: RambuCallAttributes, state: RambuCallAttributes.ContentState) {
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end(state: state, dismissImmediately: true)
        activity = try? Activity.request(
            attributes: attributes,
            content: ActivityContent(state: state, staleDate: nil),
            pushType: nil
        )
    }

    func update(_ state: RambuCallAttributes.ContentState) {
        guard let activity else { return }
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    func end(state: RambuCallAttributes.ContentState, dismissImmediately: Bool = false) {
        guard let activity else { return }
        self.activity = nil
        let policy: ActivityUIDismissalPolicy = dismissImmediately ? .immediate : .after(.now.addingTimeInterval(10))
        Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: policy) }
    }
}

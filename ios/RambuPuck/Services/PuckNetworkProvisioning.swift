import Foundation

enum PuckNetworkProvisioningError: Error, Equatable {
    case invalidSSID
    case invalidPassword
    case packetTooLarge
}

enum PuckNetworkPacket: Equatable, Sendable {
    case scanStarted
    case network(String)
    case scanFinished
    case backupSaved
    case failure(String)

    static let scanRequest = Data([0x01])

    static func saveBackup(
        name: String,
        password: String,
        maximumWriteLength: Int
    ) throws -> Data {
        let ssid = Data(name.utf8)
        let secret = Data(password.utf8)
        guard !ssid.isEmpty, ssid.count <= 32 else {
            throw PuckNetworkProvisioningError.invalidSSID
        }
        guard (8...63).contains(secret.count) else {
            throw PuckNetworkProvisioningError.invalidPassword
        }

        let packet = Data([0x04, UInt8(ssid.count)]) + ssid + secret
        guard packet.count <= maximumWriteLength else {
            throw PuckNetworkProvisioningError.packetTooLarge
        }
        return packet
    }

    init?(data: Data) {
        guard let type = data.first else { return nil }
        let payload = data.dropFirst()
        switch type {
        case 0x01 where payload.isEmpty:
            self = .scanStarted
        case 0x02:
            guard let ssid = String(data: payload, encoding: .utf8) else { return nil }
            self = .network(ssid)
        case 0x03 where payload.isEmpty:
            self = .scanFinished
        case 0x04 where payload.isEmpty:
            self = .backupSaved
        case 0x05:
            guard let message = String(data: payload, encoding: .utf8) else { return nil }
            self = .failure(message)
        default:
            return nil
        }
    }
}

struct PuckNetworkScanState: Equatable, Sendable {
    private(set) var networks: [String] = []
    private(set) var isScanning = false
    private(set) var backupSaved = false
    private(set) var errorMessage: String?

    mutating func receive(_ packet: PuckNetworkPacket) {
        switch packet {
        case .scanStarted:
            networks = []
            isScanning = true
            errorMessage = nil
        case .network(let ssid):
            if !ssid.isEmpty, !networks.contains(ssid) {
                networks.append(ssid)
            }
        case .scanFinished:
            isScanning = false
        case .backupSaved:
            backupSaved = true
            errorMessage = nil
        case .failure(let message):
            isScanning = false
            errorMessage = message
        }
    }
}

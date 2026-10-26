import Foundation
import Testing
@testable import RambuPuck

struct PuckNetworkProvisioningTests {
    @Test("Scan request uses the firmware protocol byte")
    func encodesScanRequest() {
        #expect(PuckNetworkPacket.scanRequest == Data([0x01]))
    }

    @Test("Backup credentials use a byte length before UTF-8 SSID data")
    func encodesUnicodeBackupCredentials() throws {
        let packet = try PuckNetworkPacket.saveBackup(
            name: "Zahra’s iPhone 📱",
            password: "safe-pass",
            maximumWriteLength: 185
        )

        let ssid = Data("Zahra’s iPhone 📱".utf8)
        #expect(packet == Data([0x04, UInt8(ssid.count)]) + ssid + Data("safe-pass".utf8))
    }

    @Test("Credentials that cannot fit in one encrypted write are rejected")
    func rejectsOversizedCredentials() {
        #expect(throws: PuckNetworkProvisioningError.packetTooLarge) {
            try PuckNetworkPacket.saveBackup(
                name: "Zahra's iPhone",
                password: String(repeating: "p", count: 63),
                maximumWriteLength: 20
            )
        }
        #expect(throws: PuckNetworkProvisioningError.invalidSSID) {
            try PuckNetworkPacket.saveBackup(
                name: String(repeating: "a", count: 33),
                password: "safe-pass",
                maximumWriteLength: 185
            )
        }
        #expect(throws: PuckNetworkProvisioningError.invalidPassword) {
            try PuckNetworkPacket.saveBackup(
                name: "Zahra's iPhone",
                password: "short",
                maximumWriteLength: 185
            )
        }
    }

    @Test("Scan state deduplicates exact SSIDs and ignores empty names")
    func deduplicatesScanResults() {
        var state = PuckNetworkScanState()

        state.receive(.scanStarted)
        state.receive(.network("Zahra's iPhone"))
        state.receive(.network(""))
        state.receive(.network("Zahra's iPhone"))
        state.receive(.network("Kopinako BSD"))
        state.receive(.scanFinished)

        #expect(state.networks == ["Zahra's iPhone", "Kopinako BSD"])
        #expect(!state.isScanning)
        #expect(state.errorMessage == nil)
    }

    @Test("Incoming packets reject unknown types and invalid UTF-8")
    func rejectsMalformedPackets() {
        #expect(PuckNetworkPacket(data: Data()) == nil)
        #expect(PuckNetworkPacket(data: Data([0xff])) == nil)
        #expect(PuckNetworkPacket(data: Data([0x02, 0xff])) == nil)
        #expect(PuckNetworkPacket(data: Data([0x01, 0x00])) == nil)
        #expect(PuckNetworkPacket(data: Data([0x04, 0x00])) == nil)
    }

    @Test("Firmware status and error packets update observable setup state")
    func handlesStatusPackets() {
        var state = PuckNetworkScanState()
        state.receive(.scanStarted)
        state.receive(.failure("Scan failed"))
        #expect(!state.isScanning)
        #expect(state.errorMessage == "Scan failed")

        #expect(PuckNetworkPacket(data: Data([0x03])) == .scanFinished)
        #expect(PuckNetworkPacket(data: Data([0x04])) == .backupSaved)
        #expect(PuckNetworkPacket(data: Data([0x05]) + Data("Invalid".utf8)) == .failure("Invalid"))
    }
}

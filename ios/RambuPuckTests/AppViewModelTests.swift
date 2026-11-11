import Foundation
import Testing
@testable import RambuPuck

@MainActor
struct AppViewModelTests {
    private func makeApp(persona: Persona = .ratna) -> AppViewModel {
        AppViewModel(
            persona: persona,
            onboardingComplete: true,
            analysis: ScenarioAnalysis(interval: .zero, initialDelay: .zero),
            liveActivities: false,
            notifications: false,
            speech: false,
            pilot: nil
        )
    }

    private func makeAlert(id: UUID, callEnded: Bool = false) -> FamilyAlert {
        FamilyAlert(
            id: id,
            parent: .ratna,
            callerDetail: "0812 0000 0000",
            channel: .cellular,
            startedAt: .now,
            raisedAt: .now,
            level: .danger,
            signals: [.secretCode],
            evidence: [],
            recipients: Person.guardians,
            callEnded: callEnded
        )
    }

    private func makeRecord(id: UUID) -> CallRecord {
        CallRecord(
            id: id,
            title: "Panggilan terdeteksi",
            callerDetail: "0812 0000 0000",
            channel: .cellular,
            startedAt: .now,
            duration: 30,
            level: .danger,
            signals: [.secretCode],
            evidence: [],
            decision: nil
        )
    }

    @Test("Semua feature ViewModel memakai satu AppState")
    func composesOneSharedState() {
        let app = AppViewModel(
            onboardingComplete: true,
            analysis: ScenarioAnalysis(interval: .zero, initialDelay: .zero),
            liveActivities: false,
            notifications: false,
            speech: false,
            pilot: nil
        )

        #expect(app.onboarding.state === app.state)
        #expect(app.call.state === app.state)
        #expect(app.family.state === app.state)
        #expect(app.profile.state === app.state)
        #expect(app.pilot.state === app.state)
    }

    @Test("Komposisi normal memakai sesi proteksi produksi")
    func normalLaunchUsesProtectionAnalysis() {
        let source = DemoLaunch.productionAnalysis {
            ProtectionConnection(serverURL: "http://192.168.1.8:8000", accessToken: "parent-token")
        }

        #expect(source is ProtectionCallAnalysisSource)
    }

    @Test("Komposisi screenshot tetap memakai sumber fixture deterministik")
    func screenshotLaunchUsesFixtureAnalysis() throws {
        let source = try #require(DemoLaunch.analysisSource(serverURL: "http://192.168.1.8:8000") as? BackendCallAnalysisSource)

        #expect(source.serverURL == "http://192.168.1.8:8000")
    }

    @Test("Notifikasi sesi aktif orang tua membuka status panggilan")
    func parentSessionNotificationResolvesToCallStatus() {
        let app = makeApp()
        let id = UUID()
        app.state.session = CallSession(
            id: id,
            metadata: .production,
            startedAt: .now,
            protectionStatus: .listening
        )

        #expect(app.notificationDestination(for: id) == .parentCallStatus)
    }

    @Test("Notifikasi peringatan langsung pengawas membuka detail peringatan")
    func guardianLiveAlertNotificationResolvesToAlertDetail() {
        let app = makeApp(persona: .sinta)
        let id = UUID()
        app.state.alerts = [makeAlert(id: id)]

        #expect(app.notificationDestination(for: id) == .guardianAlert(id))
    }

    @Test("Riwayat selesai menang atas peringatan lama dengan ID yang sama")
    func completedRecordNotificationResolvesToHistory() {
        let app = makeApp(persona: .sinta)
        let id = UUID()
        app.state.alerts = [makeAlert(id: id, callEnded: true)]
        app.state.history = [makeRecord(id: id)]

        #expect(app.notificationDestination(for: id) == .history(id))
    }

    @Test("Notifikasi yang tidak dikenal tidak membuka layar kosong")
    func unknownNotificationResolvesToUnresolved() {
        let app = makeApp(persona: .sinta)

        #expect(app.notificationDestination(for: UUID()) == .unresolved)
    }

    @Test("Rute status panggilan menampilkan sheet orang tua")
    func routesParentCallStatus() {
        let app = makeApp()

        app.routeNotification(.parentCallStatus)

        #expect(app.state.showCallStatus)
    }

    @Test("Rute peringatan pengawas membuka ID tepat di beranda")
    func routesGuardianAlertToExactDetail() {
        let app = makeApp(persona: .sinta)
        let id = UUID()

        app.routeNotification(.guardianAlert(id))

        #expect(app.state.guardianTab == .home)
        #expect(app.state.guardianPath == [id])
        #expect(app.state.historyPath.isEmpty)
    }

    @Test("Rute riwayat orang tua membuka ID tepat")
    func routesParentHistoryToExactDetail() {
        let app = makeApp()
        let id = UUID()

        app.routeNotification(.history(id))

        #expect(app.state.parentTab == .history)
        #expect(app.state.historyPath == [id])
        #expect(app.state.guardianPath.isEmpty)
    }

    @Test("Rute riwayat pengawas membuka ID tepat")
    func routesGuardianHistoryToExactDetail() {
        let app = makeApp(persona: .sinta)
        let id = UUID()

        app.routeNotification(.history(id))

        #expect(app.state.guardianTab == .history)
        #expect(app.state.historyPath == [id])
        #expect(app.state.guardianPath.isEmpty)
    }

    @Test("Mengetuk notifikasi yang sama lagi tetap membuka detail")
    func repeatedRouteToSameAlertRemainsValid() {
        let app = makeApp(persona: .sinta)
        let id = UUID()

        app.routeNotification(.guardianAlert(id))
        app.state.guardianPath = []
        app.routeNotification(.guardianAlert(id))

        #expect(app.state.guardianPath == [id])
    }

    @Test("Rute tak dikenal tetap di akar dan menjelaskan datanya belum tersedia")
    func unresolvedRouteAvoidsEmptyDestination() throws {
        let app = makeApp(persona: .sinta)
        app.state.guardianPath = [UUID()]
        app.state.historyPath = [UUID()]

        app.routeNotification(.unresolved)

        let toast = try #require(app.state.toast)
        #expect(app.state.guardianTab == .home)
        #expect(app.state.guardianPath.isEmpty)
        #expect(app.state.historyPath.isEmpty)
        #expect(toast.level == .safe)
        #expect(toast.alertID == nil)
    }
}

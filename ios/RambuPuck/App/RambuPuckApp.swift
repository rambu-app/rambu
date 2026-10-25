import SwiftUI

@main
struct RambuPuckApp: App {
    @UIApplicationDelegateAdaptor(RambuAppDelegate.self) private var appDelegate
    @State private var app = DemoLaunch.makeModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(app.state)
                .environment(app.onboarding)
                .environment(app.call)
                .environment(app.family)
                .environment(app.profile)
                .environment(app.pilot)
                .environment(\.locale, app.state.language.locale)
                .tint(Brand.teal)
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var model
    @Environment(AppViewModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .top) {
            content
                .id(model.onboardingComplete ? model.persona.rawValue : "onboarding")
            ToastOverlay()
        }
        .animation(.smooth(duration: 0.35), value: model.persona)
        .animation(.smooth(duration: 0.35), value: model.onboardingComplete)
        .sheet(isPresented: $model.showDemoSheet) {
            DemoSheet()
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $model.showProfile) {
            ProfileView()
        }
        .task { app.startCallMonitoring() }
        .onOpenURL { app.handleIncoming($0) }
        .onChange(of: scenePhase) { _, phase in
            // Izin notifikasi bisa berubah dari Pengaturan iOS.
            if phase == .active {
                app.refreshCallMonitoring()
                Task {
                    await app.profile.refreshNotificationStatus()
                    await app.pilot.refresh()
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.onboardingComplete {
            OnboardingFlow()
        } else if model.persona.isParent {
            ParentRoot()
        } else {
            GuardianRoot()
        }
    }
}

/// Variabel lingkungan untuk demo dan screenshot. Kirim lewat simctl dengan awalan SIMCTL_CHILD_.
///
///     RAMBU_PERSONA=ratna|sinta|richard     peran awal
///     RAMBU_SKIP_ONBOARDING=1               langsung ke beranda
///     RAMBU_FAST=1                          potongan audio tiap 0,7 detik, eskalasi 8 detik
///     RAMBU_SCENE=<adegan>[:<skenario>]     buka adegan tertentu (lihat apply)
///
/// Tanpa RAMBU_SCENE, app memakai data yang tersimpan di HP.
@MainActor
enum DemoLaunch {
    static func makeModel() -> AppViewModel {
        let env = ProcessInfo.processInfo.environment
        let isTesting = env["XCTestConfigurationFilePath"] != nil
        let fast = env["RAMBU_FAST"] == "1"
        let scene = env["RAMBU_SCENE"]
        let usesStore = !isTesting && scene == nil && env["RAMBU_SKIP_ONBOARDING"] == nil
        let credentialStore = PilotCredentialStore()
        let pilotSync = isTesting || scene != nil ? nil : PilotSync(credentialStore: credentialStore)
        let serverURL = pilotSync?.serverURL ?? "http://127.0.0.1:8000"
        let connection: @Sendable () -> ProtectionConnection? = {
            guard let credentials = credentialStore.load(),
                  credentials.member.role == "parent",
                  !credentials.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let url = URL(string: credentials.serverURL),
                  ["http", "https"].contains(url.scheme?.lowercased()),
                  url.host != nil else { return nil }
            return ProtectionConnection(
                serverURL: credentials.serverURL,
                accessToken: credentials.accessToken
            )
        }
        let monitor: (any CallActivityMonitoring)? = scene == nil && !isTesting
            ? CallKitActivityMonitor()
            : nil

        let app = AppViewModel(
            persona: Persona(rawValue: env["RAMBU_PERSONA"] ?? "") ?? .ratna,
            onboardingComplete: env["RAMBU_SKIP_ONBOARDING"] == "1" || (scene != nil && !(scene!.hasPrefix("onboarding")) && !(scene!.hasPrefix("setup-"))),
            allowsDemoControls: scene != nil && !(scene!.hasPrefix("setup-")),
            analysis: scene == nil
                ? productionAnalysis(connection: connection)
                : analysisSource(serverURL: serverURL),
            liveActivities: !isTesting,
            notifications: !isTesting,
            speech: !isTesting && scene == nil,
            callActivity: monitor,
            isProtectionConfigured: { connection() != nil },
            store: usesStore ? .standard : nil,
            pilot: pilotSync,
            escalationDelay: fast ? .seconds(8) : .seconds(45),
            speakerCheckDelay: fast ? .seconds(1.5) : .seconds(3)
        )
        if scene != nil { app.state.hidesNotificationIssue = true }
        if let scene, !isTesting { apply(scene, to: app) }
        return app
    }

    static func analysisSource(serverURL: String) -> any CallAnalysisSource {
        BackendCallAnalysisSource(serverURL: serverURL)
    }

    static func productionAnalysis(
        connection: @escaping @Sendable () -> ProtectionConnection?
    ) -> any CallAnalysisSource {
        ProtectionCallAnalysisSource(connection: connection)
    }

    private static func apply(_ scene: String, to app: AppViewModel) {
        let model = app.state
        let parts = scene.split(separator: ":").map(String.init)
        let key = parts.first ?? ""
        let scenario = Scenario.all.first { $0.id == parts.dropFirst().first } ?? .bankOTP

        switch key {
        case "setup-parent":
            model.onboardingStep = .parentProfile
        case "setup-child":
            model.persona = .sinta
            model.onboardingStep = .guardianProfile
        case "setup-code":
            model.persona = .sinta
            model.onboardingStep = .enterCode
        case "setup-invite":
            model.onboardingStep = .invite
        case "onboarding":
            model.onboardingStep = OnboardingStep(rawValue: parts.dropFirst().first ?? "") ?? .welcome
        case "history":
            model.parentTab = .history
        case "puck":
            model.parentTab = .puck
        case "profile":
            model.showProfile = true
        case "guardian-profile":
            app.switchPersona(.sinta)
            model.showProfile = true
        case "issues":
            model.simulateOffline = true
            model.puck.isConnected = false
            model.hidesNotificationIssue = false
        case "guardian-home":
            app.switchPersona(.sinta)
        case "call":
            app.call.start(scenario)
        case "speaker-off":
            model.speakerOffNextCall = true
            app.call.start(scenario)
        case "call-status":
            let task = app.call.start(scenario)
            Task {
                await task.value
                model.showCallStatus = true
            }
        case "call-decided":
            let task = app.call.start(scenario)
            Task {
                await task.value
                if let id = model.alerts.first?.id { app.family.simulateDecision(by: .sinta, .scam, on: id) }
            }
        case "alert", "alert-locked", "alert-mine", "guardian-alert-home":
            let task = app.call.start(scenario)
            Task {
                await task.value
                app.switchPersona(.sinta)
                guard let id = model.alerts.first?.id else { return }
                if key == "alert-locked" { app.family.simulateDecision(by: .richard, .scam, on: id) }
                if key == "alert-mine" { app.decide(.scam, on: id) }
                if key != "guardian-alert-home" { app.family.openAlert(id) }
                model.toast = nil
            }
        default:
            break
        }
    }
}

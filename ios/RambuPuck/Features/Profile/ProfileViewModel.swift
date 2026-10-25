import Foundation
import Observation

/// Mengelola profil, pengaturan lokal, izin notifikasi, dan state puck.
@MainActor
@Observable
final class ProfileViewModel {
    @ObservationIgnored let state: AppState
    @ObservationIgnored private let notifier: RambuNotifier
    @ObservationIgnored private let narrator: Narrator
    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private let store: LocalStore?
    @ObservationIgnored private let urgencyFeedback: any UrgencyFeedbackProviding

    init(
        state: AppState,
        notifier: RambuNotifier,
        narrator: Narrator,
        network: NetworkMonitor,
        store: LocalStore?,
        urgencyFeedback: any UrgencyFeedbackProviding = UrgencyFeedback()
    ) {
        self.state = state
        self.notifier = notifier
        self.narrator = narrator
        self.network = network
        self.store = store
        self.urgencyFeedback = urgencyFeedback
    }

    func startNetworkMonitoring() {
        network.onChange = { [weak state] online in state?.isOnline = online }
        network.start()
    }

    func renameParent(_ name: String) {
        state.parent = state.parent.renamed(name)
        persist()
    }

    func renameGuardian(_ persona: Persona, name: String, relation: String) {
        let index = persona == .richard ? 1 : 0
        guard state.guardians.indices.contains(index) else {
            state.guardianDraft = state.guardianDraft.renamed(name, relation: relation)
            return
        }
        state.guardians[index] = state.guardians[index].renamed(name, relation: relation)
        persist()
    }

    func removeGuardian(_ person: Person) {
        guard state.guardians.count > 1 else { return }
        state.guardians.removeAll { $0 == person }
        persist()
    }

    @discardableResult
    func addProtectedParent(code: String) -> Person? {
        guard state.allowsDemoControls, code.count == 6 else { return nil }
        let samples = [
            Person(id: "hadi", name: "Pak Hadi", initial: "H", relation: "Ayah", colorHex: 0x8A5A12),
            Person(id: "lies", name: "Oma Lies", initial: "L", relation: "Nenek", colorHex: 0xA23B72),
        ]
        guard let next = samples.first(where: { !state.extraParents.contains($0) }) else { return nil }
        state.extraParents.append(next)
        persist()
        return next
    }

    func removeProtectedParent(_ person: Person) {
        state.extraParents.removeAll { $0 == person }
        persist()
    }

    func clearHistory() {
        state.history = []
        persist()
    }

    func setNarration(_ enabled: Bool) {
        state.narrationEnabled = enabled
        if !enabled { narrator.stop() }
        persist()
    }

    func narrate(_ text: String) {
        guard state.narrationEnabled else { return }
        narrator.speak(text)
    }

    func stopNarration() {
        narrator.stop()
    }

    func refreshNotificationStatus() async {
        await notifier.refresh()
        state.notificationsAuthorized = notifier.isAuthorized
    }

    func requestNotifications() async {
        await notifier.requestAuthorization()
        state.notificationsAuthorized = notifier.isAuthorized
    }

    func reconnectPuck() async {
        guard state.allowsDemoControls else { return }
        try? await Task.sleep(for: .seconds(1.2))
        state.bluetoothOn = true
        state.puck.isConnected = true
    }

    func present(_ push: Toast) {
        if notifier.isAuthorized {
            notifier.post(push)
        } else {
            if push.isUrgent { urgencyFeedback.presentUrgentFeedback() }
            state.toast = push
        }
        if state.persona.isParent { narrate("\(push.title). \(push.body)") }
    }

    func onNotificationOpen(_ action: @escaping (UUID?) -> Void) {
        notifier.onOpen = action
    }

    func persist() {
        store?.save(state.savedState)
    }

    func clearStoredState() {
        store?.clear()
    }
}

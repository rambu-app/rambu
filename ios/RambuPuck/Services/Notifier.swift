import SwiftUI
import UserNotifications

/// Menampilkan status dan peringatan yang dibuat di perangkat ini sebagai notifikasi lokal.
/// Peringatan lintas perangkat tetap dikirim server melalui APNs. Kalau izin notifikasi belum
/// diberikan, ProfileViewModel menampilkan pesan yang sama di dalam app.
@MainActor
final class RambuNotifier: NSObject, UNUserNotificationCenterDelegate {
    private(set) var isAuthorized = false
    var onOpen: ((UUID?) -> Void)?

    private let enabled: Bool
    private var center: UNUserNotificationCenter? { enabled ? .current() : nil }

    init(enabled: Bool) {
        self.enabled = enabled
        super.init()
        guard let center else { return }
        center.delegate = self
        Task {
            await refresh()
            if isAuthorized { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    func refresh() async {
        guard let center else { return }
        let status = await center.notificationSettings().authorizationStatus
        isAuthorized = status == .authorized || status == .provisional
    }

    func requestAuthorization() async {
        guard let center else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        await refresh()
        if isAuthorized { UIApplication.shared.registerForRemoteNotifications() }
    }

    func post(_ toast: Toast) {
        guard let center else { return }
        let content = notificationContent(for: toast)
        center.add(UNNotificationRequest(identifier: toast.id, content: content, trigger: nil))
    }

    func notificationContent(for toast: Toast) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = toast.title
        content.body = toast.body
        content.sound = toast.notificationSoundName.map {
            UNNotificationSound(named: UNNotificationSoundName($0))
        } ?? .default
        content.threadIdentifier = toast.alertID?.uuidString ?? "rambu"
        if let id = toast.alertID { content.userInfo = ["alertID": id.uuidString] }
        if let attachment = mascotAttachment(for: toast.level) { content.attachments = [attachment] }
        return content
    }

    /// Thumbnail maskot yang memegang rambu sesuai tingkat risiko, tampil di sisi kanan push.
    private func mascotAttachment(for level: RiskLevel) -> UNNotificationAttachment? {
        let view = MascotView(pose: level.mascotPose, animated: false, sign: level)
            .frame(width: 150, height: 150)
            .padding(18)
            .background(level.soft)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        guard let data = renderer.uiImage?.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rambu-\(UUID().uuidString).png")
        do {
            try data.write(to: url)
            return try UNNotificationAttachment(identifier: "maskot", url: url)
        } catch {
            return nil
        }
    }

    // Tetap tampilkan banner walau app Rambu sedang terbuka (misal saat simulasi telepon).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let raw = response.notification.request.content.userInfo["alertID"] as? String
        await open(raw.flatMap(UUID.init(uuidString:)))
    }

    private func open(_ id: UUID?) {
        onOpen?(id)
    }
}

extension RiskLevel {
    /// Ekspresi maskot untuk tiap tingkat: senyum, memeriksa, menahan.
    var mascotPose: MascotPose {
        switch self {
        case .safe: .wave
        case .review: .check
        case .danger: .stop
        }
    }
}

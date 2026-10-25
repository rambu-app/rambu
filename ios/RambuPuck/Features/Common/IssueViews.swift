import SwiftUI

/// Satu baris peringatan kondisi perangkat, dengan tombol perbaikan kalau ada.
struct IssueBanner: View {
    let issue: SystemIssue
    @Environment(AppState.self) private var model
    @Environment(ProfileViewModel.self) private var profile
    @Environment(\.openURL) private var openURL
    @State private var working = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: issue.symbol)
                .font(.headline)
                .foregroundStyle(Brand.signalInk)
                .frame(width: 40, height: 40)
                .background(Brand.signal, in: .rect(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(issue.title)).font(.headline).foregroundStyle(Brand.ink)
                Text(LocalizedStringKey(issue.detail)).font(.subheadline).foregroundStyle(Brand.ink2)
            }
            Spacer(minLength: 0)
            if let action = issue.action {
                Button {
                    fix()
                } label: {
                    if working {
                        ProgressView()
                    } else {
                        Text(LocalizedStringKey(action)).font(.subheadline.weight(.semibold))
                    }
                }
                .buttonStyle(.glassProminent)
                .tint(Brand.teal)
                .disabled(working)
            }
        }
        .padding(12)
        .background(Brand.signalSoft, in: .rect(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Brand.signal.opacity(0.5)) }
        .accessibilityElement(children: .combine)
    }

    private func fix() {
        switch issue {
        case .notificationsOff:
            Task {
                await profile.requestNotifications()
                if !model.notificationsAuthorized, let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    openURL(url)
                }
            }
        case .bluetoothOff, .puckDisconnected:
            working = true
            Task {
                await profile.reconnectPuck()
                working = false
            }
        case .offline, .puckLowBattery:
            break
        }
    }
}

/// Semua gangguan yang sedang terjadi, ditumpuk di atas beranda.
struct IssueList: View {
    @Environment(AppState.self) private var model

    var body: some View {
        if !model.issues.isEmpty {
            VStack(spacing: 8) {
                ForEach(model.issues) { IssueBanner(issue: $0) }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

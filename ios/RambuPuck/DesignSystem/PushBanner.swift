import SwiftUI

/// Tampilan push notifikasi Rambu, mengikuti banner notifikasi iOS:
/// ikon app, nama app, waktu, judul, isi, dan thumbnail maskot yang memegang rambu.
struct PushBanner: View {
    let toast: Toast
    @Environment(AppState.self) private var model

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image("RambuIcon")
                .resizable()
                .frame(width: 38, height: 38)
                .clipShape(.rect(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text("RAMBU").font(.caption.weight(.semibold)).foregroundStyle(Brand.ink3)
                    Spacer()
                    Text("sekarang").font(.caption).foregroundStyle(Brand.ink3)
                }
                Text(LocalizedStringKey(toast.title))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Brand.ink)
                Text(LocalizedStringKey(toast.body))
                    .font(.subheadline).foregroundStyle(Brand.ink)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            MascotView(pose: toast.level.mascotPose, animated: false, sign: toast.level)
                .padding(.top, 2)
                .frame(width: 54, height: 54)
                .background(toast.level.soft, in: .rect(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.white.opacity(0.9), in: .rect(cornerRadius: 26, style: .continuous))
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.format(
            "accessibility.notification",
            fallback: "Notifikasi Rambu. %@. %@",
            language: model.language,
            toast.title,
            toast.body
        ))
    }
}

import SwiftUI

// Aturan pakai kaca (Liquid Glass) mengikuti HIG: kaca untuk kontrol dan navigasi
// yang melayang di atas konten; isi informasi memakai kartu padat supaya mudah dibaca.

// MARK: - Kartu dan tombol

extension View {
    func card(padding: CGFloat = 18) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: .rect(cornerRadius: 24, style: .continuous))
            .shadow(color: Brand.ink.opacity(0.06), radius: 14, y: 6)
    }

    /// Tombol utama: kaca menonjol, cukup besar untuk pengguna 40+ (min. 56 pt).
    func primaryAction(_ tint: Color = Brand.teal) -> some View {
        self.buttonStyle(.glassProminent).controlSize(.extraLarge).tint(tint)
    }

    func secondaryAction() -> some View {
        self.buttonStyle(.glass).controlSize(.extraLarge)
    }
}

/// Isi tombol lebar penuh dengan tinggi minimum yang aman untuk jari.
struct WideLabel: View {
    let title: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage { Image(systemName: systemImage) }
            Text(LocalizedStringKey(title))
        }
        .font(.headline)
        .frame(maxWidth: .infinity, minHeight: 32)
    }
}

// MARK: - Orang

struct Avatar: View {
    let person: Person
    var size: CGFloat = 44

    var body: some View {
        Text(person.initial)
            .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(person.color.gradient))
            .accessibilityHidden(true)
    }
}

struct AvatarStack: View {
    let people: [Person]
    var size: CGFloat = 28

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(people) { person in
                Avatar(person: person, size: size)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Avatar di kanan atas membuka Profil.
struct ProfileButton: View {
    @Environment(AppState.self) private var model

    var body: some View {
        Button {
            model.showProfile = true
        } label: {
            Avatar(person: model.currentPerson, size: 30)
        }
        .accessibilityLabel(L10n.format(
            "accessibility.profile",
            fallback: "Profil %@",
            language: model.language,
            model.currentPerson.name
        ))
    }
}

// MARK: - Teks dan tata letak

struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(LocalizedStringKey(title)).font(Brand.display(.headline)).foregroundStyle(Brand.ink)
            Spacer()
            if let trailing {
                Text(LocalizedStringKey(trailing)).font(.subheadline).foregroundStyle(Brand.ink3)
            }
        }
        .padding(.horizontal, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Deretan kapsul yang turun baris saat tidak muat.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            let gap: CGFloat = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += gap + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

/// Garis progres pengganti teks "Langkah 1 dari 4".
struct StepProgress: View {
    let current: Int
    let total: Int
    @Environment(AppState.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...total, id: \.self) { index in
                Capsule()
                    .fill(index <= current ? Brand.teal : Brand.hairline)
                    .frame(height: 5)
            }
        }
        .frame(maxWidth: 48 * CGFloat(total))
        .animation(.smooth, value: current)
        .accessibilityElement()
        .accessibilityLabel(L10n.format(
            "accessibility.step",
            fallback: "Langkah %d dari %d",
            language: model.language,
            current,
            total
        ))
    }
}

struct GlassChip: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(LocalizedStringKey(text), systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular.tint(.white.opacity(0.10)), in: .capsule)
    }
}

// MARK: - Kode 6 digit

struct DigitBoxes: View {
    let digits: String
    var count = 6
    var showsCursor = false
    @Environment(AppState.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                box(at: index)
                if index == count / 2 - 1 { Spacer().frame(width: 4) }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(
            digits.isEmpty
                ? L10n.text("Kode belum diisi", language: model.language)
                : L10n.format(
                    "accessibility.code",
                    fallback: "Kode %@",
                    language: model.language,
                    digits.map(String.init).joined(separator: " ")
                )
        )
    }

    private func box(at index: Int) -> some View {
        let characters = Array(digits)
        let value = index < characters.count ? String(characters[index]) : ""
        let active = showsCursor && index == min(characters.count, count - 1)
        return Text(value)
            .font(.system(.title, design: .rounded, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(Brand.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            .background(.white, in: .rect(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(active ? Brand.teal : Brand.hairline, lineWidth: active ? 2 : 1)
            }
    }
}

// MARK: - Tempat foto

/// Foto dari katalog aset, dengan ilustrasi cadangan kalau asetnya tidak ada.
/// Slot yang dipakai: PhotoPuckProduct, PhotoPuckOnPhone, PhotoSpeakerCall (lihat ios/README.md).
struct PhotoSlot<Fallback: View>: View {
    let name: String
    var cornerRadius: CGFloat = 28
    @ViewBuilder var fallback: Fallback

    var body: some View {
        if let image = UIImage(named: name) {
            Color.clear
                .overlay { Image(uiImage: image).resizable().scaledToFill() }
                .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
                .accessibilityHidden(true)
        } else {
            fallback
        }
    }
}

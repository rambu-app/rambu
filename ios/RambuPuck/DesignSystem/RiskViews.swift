import SwiftUI

// Tampilan tingkat risiko. Bentuk ikon ikut membedakan tingkat (lingkaran, segitiga, oktagon),
// jadi status tetap terbaca tanpa warna.

// MARK: - Ikon dan label

struct LevelIcon: View {
    let level: RiskLevel
    @ScaledMetric private var size: CGFloat

    init(level: RiskLevel, size: CGFloat = 22) {
        self.level = level
        _size = ScaledMetric(wrappedValue: size, relativeTo: .title3)
    }

    var body: some View {
        Image(systemName: level.symbol)
            .font(.system(size: size, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(level.glyph, level.tint)
            .accessibilityLabel(level.title)
    }
}

struct LevelPill: View {
    let level: RiskLevel

    var body: some View {
        HStack(spacing: 6) {
            LevelIcon(level: level, size: 15)
            Text(level.title).font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(level.ink)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(level.soft, in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

/// Label status berwarna penuh: kuning untuk Waspada, merah untuk Bahaya.
struct RiskBadge: View {
    let level: RiskLevel
    var large = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: level.symbol)
            Text(level.title)
        }
            .font(large ? .headline : .subheadline.weight(.bold))
            .foregroundStyle(level.glyph)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, large ? 14 : 10)
            .padding(.vertical, large ? 8 : 5)
            .background(level.tint, in: .capsule)
            .accessibilityElement(children: .combine)
    }
}

/// Ubin ikon berwarna penuh untuk baris daftar.
struct LevelTile: View {
    let level: RiskLevel
    @ScaledMetric private var size: CGFloat = 44

    var body: some View {
        Image(systemName: level.symbol)
            .font(.system(size: size * 0.46, weight: .bold))
            .foregroundStyle(level.glyph)
            .frame(width: size, height: size)
            .background(level.tint, in: .rect(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityLabel(level.title)
    }
}

// MARK: - Tanda dan kalimat penelepon

/// Satu tanda penipuan sebagai kapsul berikon. Menggantikan paragraf penjelasan.
struct SignalChip: View {
    let kind: SignalKind
    var level: RiskLevel = .danger
    /// Di atas latar berwarna risiko, kapsul memakai putih supaya tetap terlihat.
    var onTint = false

    var body: some View {
        Label(kind.title, systemImage: kind.symbol)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(level.ink)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(onTint ? .white : level.soft, in: .capsule)
    }
}

/// Menyorot frasa pemicu di dalam kalimat, supaya pengawas bisa menilai sendiri.
struct HighlightedText: View {
    let text: String
    let phrases: [String]
    var tint: Color = Brand.danger
    var ink: Color = Brand.dangerInk

    var body: some View {
        Text(attributed).foregroundStyle(Brand.ink)
    }

    private var attributed: AttributedString {
        var result = AttributedString(text)
        for phrase in phrases where !phrase.isEmpty {
            var start = result.startIndex
            while start < result.endIndex, let range = result[start...].range(of: phrase, options: .caseInsensitive) {
                result[range].backgroundColor = tint.opacity(0.14)
                result[range].foregroundColor = ink
                result[range].inlinePresentationIntent = .stronglyEmphasized
                start = range.upperBound
            }
        }
        return result
    }
}

/// Selected automatic-transcription excerpt, not a verified quote or a speaker-timed recording.
struct EvidenceCard: View {
    let line: TranscriptLine
    var level: RiskLevel = .danger

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(line.text.split(whereSeparator: \.isWhitespace).joined(separator: " "))
                .font(.body).foregroundStyle(Brand.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !line.signals.isEmpty {
                Text("Ditandai Rambu: " + line.signals.map(\.title).joined(separator: ", "))
                    .font(.caption).foregroundStyle(Brand.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Detail panggilan

/// The verdict leads: what kind of call this was, in one sentence, with call facts as small print.
struct VerdictCard: View {
    let presentation: HistoryPresentation
    let headline: String
    let summary: String
    let details: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: presentation.symbol)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(presentation.glyph)
                    .frame(width: 44, height: 44)
                    .background(presentation.tint, in: .rect(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.title.uppercased())
                        .font(.footnote.weight(.bold))
                        .tracking(0.5)
                        .foregroundStyle(presentation.ink)
                    Text(headline)
                        .font(Brand.display(.title2, .heavy))
                        .foregroundStyle(Brand.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
            }
            Text(summary)
                .font(.body)
                .foregroundStyle(Brand.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(details.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(presentation.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(presentation.soft, in: .rect(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct AdviceSection: View {
    let items: [(text: String, symbol: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Yang sebaiknya dilakukan")
            VStack(alignment: .leading, spacing: 14) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: items[index].symbol)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Brand.teal)
                            .frame(width: 32, height: 32)
                            .background(Brand.tealSoft, in: .rect(cornerRadius: 10, style: .continuous))
                        Text(items[index].text)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Brand.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(minHeight: 32, alignment: .leading)
                    }
                }
            }
            .card()
        }
    }
}

/// Each signal once, with the automatic-transcription excerpt that triggered it.
struct SignalEvidenceSection: View {
    let signals: [SignalKind]
    let evidence: [TranscriptLine]

    var body: some View {
        let lines = TranscriptLine.groupedForDisplay(evidence)
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Tanda yang ditemukan")
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(signals.enumerated()), id: \.element) { index, signal in
                    if index > 0 { Divider() }
                    VStack(alignment: .leading, spacing: 10) {
                        Label(signal.title, systemImage: signal.symbol)
                            .font(.headline)
                            .foregroundStyle(Brand.dangerInk)
                        ForEach(lines.filter { $0.signals.contains(signal) }) { line in
                            Text("“\(line.text.split(whereSeparator: \.isWhitespace).joined(separator: " "))”")
                                .font(.body)
                                .foregroundStyle(Brand.ink)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Brand.canvas, in: .rect(cornerRadius: 14, style: .continuous))
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .card()
        }
    }
}

struct TranscriptLink: View {
    let evidence: [TranscriptLine]

    var body: some View {
        NavigationLink {
            TranscriptExcerpts(evidence: evidence)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "text.alignleft").foregroundStyle(Brand.teal)
                Text("Lihat transkripsi otomatis")
                    .font(.body.weight(.semibold)).foregroundStyle(Brand.ink)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Brand.ink3)
            }
            .frame(minHeight: 24)
            .card(padding: 16)
        }
        .buttonStyle(.plain)
    }
}

private struct TranscriptExcerpts: View {
    let evidence: [TranscriptLine]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Semua cuplikan yang tersimpan dari transkripsi otomatis, bukan rekaman lengkap. Kata-kata bisa salah terbaca.")
                    .font(.footnote).foregroundStyle(Brand.ink2)
                ForEach(Array(evidence.enumerated()), id: \.offset) { index, line in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Cuplikan \(index + 1)")
                            .font(.caption.weight(.semibold)).foregroundStyle(Brand.ink2)
                        Text(line.text).font(.body).foregroundStyle(Brand.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .card(padding: 16)
                }
            }
            .padding(20)
        }
        .background(Brand.canvas)
        .navigationTitle("Transkripsi otomatis")
        .navigationBarTitleDisplayMode(.inline)
    }
}

import Foundation

// Percakapan sintetis berbahasa Indonesia untuk simulasi.
// Semua nama lembaga, nomor, dan orang fiktif. Nomor penelepon sengaja disamarkan.

extension Scenario {
    static let bankOTP = Scenario(
        id: "bank-otp",
        title: "Mengaku petugas Bank Sentosa",
        summary: "Minta kode OTP untuk membatalkan transaksi.",
        callerName: "Nomor tidak dikenal",
        callerDetail: "+62 812-••••-4417",
        channel: .cellular,
        lines: [
            .init(id: 0, offset: 0, speaker: .caller,
                  text: "Selamat siang, dengan Ibu Ratna? Saya Andi dari bagian keamanan Bank Sentosa.",
                  flagged: ["dari bagian keamanan Bank Sentosa"], signals: [.impersonation]),
            .init(id: 1, offset: 5, speaker: .parent,
                  text: "Iya, betul. Ada apa, Pak?", flagged: [], signals: []),
            .init(id: 2, offset: 10, speaker: .caller,
                  text: "Ada transaksi mencurigakan di rekening Ibu. Kalau tidak dibatalkan dalam sepuluh menit, saldo Ibu bisa terkuras.",
                  flagged: ["dalam sepuluh menit", "saldo Ibu bisa terkuras"], signals: [.urgency]),
            .init(id: 3, offset: 15, speaker: .parent,
                  text: "Aduh, terus saya harus bagaimana?", flagged: [], signals: []),
            .init(id: 4, offset: 20, speaker: .caller,
                  text: "Sebentar lagi masuk SMS berisi kode enam angka. Tolong bacakan kodenya ke saya supaya transaksinya bisa saya batalkan.",
                  flagged: ["bacakan kodenya ke saya"], signals: [.secretCode]),
            .init(id: 5, offset: 25, speaker: .caller,
                  text: "Kodenya jangan diberikan ke siapa pun selain saya, ya, Bu.",
                  flagged: ["jangan diberikan ke siapa pun selain saya"], signals: [.secretCode]),
        ]
    )

    static let accidentTransfer = Scenario(
        id: "kecelakaan-transfer",
        title: "Kabar anak kecelakaan",
        summary: "Kabar kecelakaan, lalu minta biaya operasi.",
        callerName: "Nomor tidak dikenal",
        callerDetail: "+62 857-••••-2290",
        channel: .whatsapp,
        lines: [
            .init(id: 0, offset: 0, speaker: .caller,
                  text: "Halo, Bu. Saya perawat dari RS Medika Utama. Anak Ibu baru saja kecelakaan motor.",
                  flagged: ["perawat dari RS Medika Utama", "Anak Ibu baru saja kecelakaan"], signals: [.impersonation]),
            .init(id: 1, offset: 5, speaker: .parent,
                  text: "Astaga, anak saya yang mana? Bagaimana keadaannya?", flagged: [], signals: []),
            .init(id: 2, offset: 10, speaker: .caller,
                  text: "Harus dioperasi sekarang juga, Bu. Kalau terlambat bisa fatal.",
                  flagged: ["dioperasi sekarang juga", "Kalau terlambat bisa fatal"], signals: [.urgency]),
            .init(id: 3, offset: 15, speaker: .caller,
                  text: "Uang mukanya delapan juta. Tolong transfer sekarang ke rekening dokter yang saya kirim.",
                  flagged: ["transfer sekarang ke rekening dokter"], signals: [.transfer]),
            .init(id: 4, offset: 20, speaker: .parent,
                  text: "Sebentar, saya telepon anak saya dulu.", flagged: [], signals: []),
            .init(id: 5, offset: 25, speaker: .caller,
                  text: "Jangan ditutup, Bu. Waktunya tidak cukup.",
                  flagged: ["Jangan ditutup", "Waktunya tidak cukup"], signals: [.urgency]),
        ]
    )

    static let courierApp = Scenario(
        id: "kurir-aplikasi",
        title: "Kurir menyuruh buka file",
        summary: "Menyuruh buka file dan pasang aplikasi.",
        callerName: "Nomor tidak dikenal",
        callerDetail: "+62 896-••••-1043",
        channel: .whatsapp,
        lines: [
            .init(id: 0, offset: 0, speaker: .caller,
                  text: "Permisi, Bu. Saya kurir. Ada paket atas nama Ibu Ratna yang tertahan di gudang.",
                  flagged: ["paket atas nama Ibu Ratna yang tertahan"], signals: [.impersonation]),
            .init(id: 1, offset: 5, speaker: .parent,
                  text: "Paket apa, ya? Saya tidak pesan apa-apa.", flagged: [], signals: []),
            .init(id: 2, offset: 10, speaker: .caller,
                  text: "Untuk cek resinya, Ibu buka file yang barusan saya kirim di WhatsApp, lalu pasang aplikasinya.",
                  flagged: ["buka file yang barusan saya kirim", "pasang aplikasinya"], signals: [.remoteApp]),
            .init(id: 3, offset: 15, speaker: .caller,
                  text: "Kalau tidak dikonfirmasi hari ini, paketnya dikembalikan dan Ibu kena denda.",
                  flagged: ["tidak dikonfirmasi hari ini", "Ibu kena denda"], signals: [.urgency]),
        ]
    )

    static let neighbourSafe = Scenario(
        id: "tetangga-aman",
        title: "Telepon dari Bu Wati",
        summary: "Tetangga mengabarkan jadwal arisan.",
        callerName: "Bu Wati",
        callerDetail: "Kontak tersimpan",
        channel: .cellular,
        lines: [
            .init(id: 0, offset: 0, speaker: .caller,
                  text: "Assalamualaikum, Bu Ratna. Ini Wati, tetangga sebelah.", flagged: [], signals: []),
            .init(id: 1, offset: 5, speaker: .parent,
                  text: "Waalaikumsalam, Bu Wati. Ada apa?", flagged: [], signals: []),
            .init(id: 2, offset: 10, speaker: .caller,
                  text: "Arisan minggu depan jadi di rumah saya, ya. Jam empat sore.", flagged: [], signals: []),
            .init(id: 3, offset: 15, speaker: .parent,
                  text: "Oh iya, nanti saya bawa kue.", flagged: [], signals: []),
        ]
    )

    static func all(language: AppLanguage = .indonesian) -> [Scenario] {
        language == .english
            ? [.bankOTPEnglish, .accidentTransferEnglish, .courierAppEnglish, .neighbourSafeEnglish]
            : [.bankOTP, .accidentTransfer, .courierApp, .neighbourSafe]
    }

    private static let bankOTPEnglish = Scenario(
        id: "bank-otp",
        title: "Caller claiming to be from Sentosa Bank",
        summary: "Asks for an OTP to cancel a transaction.",
        callerName: "Unknown number",
        callerDetail: "+1 (415) •••-4417",
        channel: .cellular,
        lines: [
            .init(id: 0, offset: 0, speaker: .caller,
                  text: "Good afternoon, is this Mrs Ratna? I'm Andrew from Sentosa Bank's security team.",
                  flagged: ["from Sentosa Bank's security team"], signals: [.impersonation]),
            .init(id: 1, offset: 5, speaker: .parent,
                  text: "Yes, speaking. What happened?", flagged: [], signals: []),
            .init(id: 2, offset: 10, speaker: .caller,
                  text: "There is a suspicious transaction on your account. If it is not cancelled within ten minutes, your balance could be drained.",
                  flagged: ["within ten minutes", "your balance could be drained"], signals: [.urgency]),
            .init(id: 3, offset: 15, speaker: .parent,
                  text: "Oh no. What should I do?", flagged: [], signals: []),
            .init(id: 4, offset: 20, speaker: .caller,
                  text: "You will receive a six-digit code by text. Please read the code to me so I can cancel the transaction.",
                  flagged: ["read the code to me"], signals: [.secretCode]),
            .init(id: 5, offset: 25, speaker: .caller,
                  text: "Do not share the code with anyone except me.",
                  flagged: ["Do not share the code with anyone except me"], signals: [.secretCode]),
        ]
    )

    private static let accidentTransferEnglish = Scenario(
        id: "kecelakaan-transfer",
        title: "Claim that a family member had an accident",
        summary: "Claims an accident occurred, then demands surgery payment.",
        callerName: "Unknown number",
        callerDetail: "+1 (202) •••-2290",
        channel: .whatsapp,
        lines: [
            .init(id: 0, offset: 0, speaker: .caller,
                  text: "Hello. I'm a nurse at Medika Medical Center. Your child was just in a motorcycle accident.",
                  flagged: ["a nurse at Medika Medical Center", "Your child was just in a motorcycle accident"], signals: [.impersonation]),
            .init(id: 1, offset: 5, speaker: .parent,
                  text: "Which child? How are they?", flagged: [], signals: []),
            .init(id: 2, offset: 10, speaker: .caller,
                  text: "They need surgery immediately. Any delay could be fatal.",
                  flagged: ["surgery immediately", "delay could be fatal"], signals: [.urgency]),
            .init(id: 3, offset: 15, speaker: .caller,
                  text: "The deposit is eight thousand dollars. Transfer it now to the doctor's account.",
                  flagged: ["Transfer it now to the doctor's account"], signals: [.transfer]),
            .init(id: 4, offset: 20, speaker: .parent,
                  text: "Wait, I will call my child first.", flagged: [], signals: []),
            .init(id: 5, offset: 25, speaker: .caller,
                  text: "Do not hang up. There is no time.",
                  flagged: ["Do not hang up", "There is no time"], signals: [.urgency]),
        ]
    )

    private static let courierAppEnglish = Scenario(
        id: "kurir-aplikasi",
        title: "Courier asks you to open a file",
        summary: "Asks you to open a file and install an app.",
        callerName: "Unknown number",
        callerDetail: "+1 (646) •••-1043",
        channel: .whatsapp,
        lines: [
            .init(id: 0, offset: 0, speaker: .caller,
                  text: "Hello. I'm a courier. A package for Mrs Ratna is being held at our warehouse.",
                  flagged: ["package for Mrs Ratna is being held"], signals: [.impersonation]),
            .init(id: 1, offset: 5, speaker: .parent,
                  text: "What package? I did not order anything.", flagged: [], signals: []),
            .init(id: 2, offset: 10, speaker: .caller,
                  text: "Open the file I just sent on WhatsApp and install the app to check the tracking number.",
                  flagged: ["Open the file I just sent", "install the app"], signals: [.remoteApp]),
            .init(id: 3, offset: 15, speaker: .caller,
                  text: "If you do not confirm today, the package will be returned and you will be fined.",
                  flagged: ["confirm today", "you will be fined"], signals: [.urgency]),
        ]
    )

    private static let neighbourSafeEnglish = Scenario(
        id: "tetangga-aman",
        title: "Call from your neighbor Wati",
        summary: "A neighbor shares the community gathering schedule.",
        callerName: "Wati",
        callerDetail: "Saved contact",
        channel: .cellular,
        lines: [
            .init(id: 0, offset: 0, speaker: .caller,
                  text: "Hello, Mrs Ratna. It's Wati from next door.", flagged: [], signals: []),
            .init(id: 1, offset: 5, speaker: .parent,
                  text: "Hi, Wati. What is it?", flagged: [], signals: []),
            .init(id: 2, offset: 10, speaker: .caller,
                  text: "Next week's neighborhood gathering will be at my house at four in the afternoon.", flagged: [], signals: []),
            .init(id: 3, offset: 15, speaker: .parent,
                  text: "All right, I will bring cake.", flagged: [], signals: []),
        ]
    )

    /// Mengganti nama contoh di transkrip dengan nama orang tua yang diisi saat onboarding.
    func personalized(parentName: String, language: AppLanguage = .indonesian) -> Scenario {
        let sample = language == .english ? "Mrs Ratna" : Person.ratna.name
        guard parentName != sample else { return self }
        let swap = { (s: String) in
            s.replacingOccurrences(of: sample, with: parentName)
             .replacingOccurrences(of: "Bu Ratna", with: parentName)
        }
        let lines = lines.map {
            TranscriptLine(id: $0.id, offset: $0.offset, speaker: $0.speaker,
                           text: swap($0.text), flagged: $0.flagged.map(swap), signals: $0.signals)
        }
        return Scenario(id: id, title: title, summary: summary, callerName: callerName,
                        callerDetail: callerDetail, channel: channel, lines: lines)
    }
}

extension CallRecord {
    /// Match the complete bundled fixture, so real calls with a similar title stay intact.
    var isSampleRecord: Bool {
        guard let sample = Self.seed().first else { return false }
        return title == sample.title && callerDetail == sample.callerDetail
            && channel == sample.channel && duration == sample.duration
            && signals == sample.signals && evidence == sample.evidence
    }

    /// Riwayat awal supaya layar riwayat tidak kosong saat demo pertama. Hanya telepon berisiko yang disimpan.
    static func seed(now: Date = .now, decider: Person = .richard) -> [CallRecord] {
        [
            CallRecord(
                id: UUID(),
                title: "Hadiah undian dari nomor asing",
                callerDetail: "+62 813-••••-0921",
                channel: .whatsapp,
                startedAt: now.addingTimeInterval(-3 * 86400 - 5400),
                duration: 96,
                level: .danger,
                signals: [.impersonation, .transfer],
                evidence: [
                    TranscriptLine(id: 0, offset: 4, speaker: .caller,
                                   text: "Selamat, Ibu terpilih sebagai pemenang undian dari toko online kami.",
                                   flagged: ["terpilih sebagai pemenang undian"], signals: [.impersonation]),
                    TranscriptLine(id: 1, offset: 31, speaker: .caller,
                                   text: "Hadiahnya bisa dicairkan setelah Ibu transfer biaya pajak lima ratus ribu.",
                                   flagged: ["transfer biaya pajak"], signals: [.transfer]),
                ],
                decision: GuardianDecision(by: decider, verdict: .scam, at: now.addingTimeInterval(-3 * 86400 - 5340))
            ),
        ]
    }
}

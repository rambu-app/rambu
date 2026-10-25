# Rambu Puck · iOS

Aplikasi iPhone untuk Rambu Puck, perangkat eksternal bermikrofon yang mendengarkan telepon loudspeaker orang tua lalu meneruskan tanda penipuan ke keluarga. Runtime normal memakai CallKit dan sesi proteksi backend nyata. Sampai hardware tersedia, executable macOS di `tools/rambu-puck-agent` menjadi puck sementara dan menangkap audio melalui mikrofon Mac.

Kebutuhan produk ada di [`docs/prd/rambu-puck.prd.md`](../docs/prd/rambu-puck.prd.md).

## Menjalankan

Butuh Xcode 26 dengan SDK iOS 26. Proyek Xcode sudah ikut di-commit, jadi XcodeGen hanya perlu kalau `project.yml` diubah.

```bash
open ios/RambuPuck.xcodeproj
```

Pilih simulator iPhone 17 Pro (punya Dynamic Island), lalu Run. Dari terminal:

```bash
cd ios && xcodebuild -scheme RambuPuck -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Setelah mengubah `project.yml`:

```bash
brew install xcodegen && cd ios && xcodegen generate
```

## Alur runtime normal

1. Jalankan Langflow dan backend seperti di README root.
2. Pasang app pada iPhone fisik, selesaikan onboarding orang tua, lalu buka **Profil → Pilot keluarga**.
3. Isi `http://ALAMAT_IP_MAC:8000` dan buat keluarga. Gunakan kode undangan enam angka yang aktif untuk memasangkan agent Mac.
4. Jalankan agent dalam mode `listen` dan dekatkan Mac ke loudspeaker iPhone.
5. Biarkan Rambu berjalan, lalu tempatkan atau terima panggilan nyata. Dashboard bergerak dari memantau panggilan, menunggu Puck, mendengarkan, sampai hasil akhir atau kegagalan eksplisit.

CallKit hanya memberi status panggilan. Ia tidak memberi akses ke audio panggilan dan tidak menjamin app yang sudah dihentikan akan diluncurkan ketika panggilan masuk. Audio hanya dianalisis jika Mac/puck benar-benar mendengarnya secara akustik dari loudspeaker.

Skenario sintetis dan Mode demo tetap dikompilasi khusus untuk test/screenshot dengan `RAMBU_SCENE`; kontrol tersebut tidak ditampilkan pada runtime normal.

Data demo tersimpan lokal di `Application Support/Rambu/state.json`. Mode pilot memakai identitas perangkat acak di Keychain dan menyimpan keluarga, peringatan, serta keputusan di SQLite backend.

## Bahasa dan lokalisasi

App mendukung Bahasa Indonesia (`id`) dan English (`en`). Instalasi baru mengikuti bahasa pilihan iPhone jika cocok, lalu pengguna dapat menggantinya saat onboarding atau melalui **Profil → Bahasa**. Pilihan disimpan bersama state app tanpa menghapus keluarga, onboarding, atau riwayat.

- Semua terjemahan UI dikelola di `RambuPuck/Resources/Localizable.xcstrings`; deskripsi izin sistem ada di `RambuPuck/Resources/InfoPlist.xcstrings`.
- Teks statis SwiftUI memakai String Catalog secara otomatis. Teks dinamis dan terpersonalisasi memakai semantic key melalui `L10n.text` atau `L10n.format`, dengan salinan Bahasa Indonesia sebagai fallback.
- Nama pengguna dan transkrip penelepon adalah data, bukan copy UI, sehingga tidak diterjemahkan.
- `AppLanguage.backendCode` mengirim `id` atau `en` ke sesi proteksi. Backend memakai bahasa itu untuk transkripsi dan prompt analisis, tetapi pemeriksaan permintaan rahasia tetap dwibahasa.
- Registrasi token APNs menyertakan bahasa perangkat. Backend mengelompokkan penerima menurut bahasa agar satu keluarga dapat menerima push dalam bahasa yang berbeda.

Saat menambah copy baru, gunakan semantic key untuk kalimat yang memiliki interpolasi atau dipakai lintas fitur, tambahkan nilai `id` dan `en` ke catalog, lalu validasi catalog:

```bash
xcrun xcstringstool compile ios/RambuPuck/Resources/Localizable.xcstrings --output-directory /tmp/rambu-localizable-check
xcrun xcstringstool compile ios/RambuPuck/Resources/InfoPlist.xcstrings --output-directory /tmp/rambu-infoplist-check
```

## Puck Mac dan dua iPhone opsional

1. Jalankan backend agar terlihat dari Wi-Fi:

   ```bash
   cd backend
   uv sync
   uv run uvicorn rambu_api.app:app --host 0.0.0.0 --port 8000 --env-file .env
   ```

2. Pasang app di iPhone orang tua. iPhone pengawas bersifat opsional dan hanya diperlukan untuk alur peringatan keluarga.
3. Di setiap iPhone buka **Profil → Pilot keluarga** dan isi `http://ALAMAT_IP_MAC:8000`.
4. Orang tua membuat kode. Kode yang sama dapat dipakai pengawas untuk bergabung dan agent Mac untuk `pair`.
5. Ekspor `RAMBU_SERVER_URL` dan token hasil pairing sebagai `RAMBU_PUCK_TOKEN`, lalu jalankan `swift run --package-path tools/rambu-puck-agent rambu-puck-agent listen` dari root repo.
6. Saat panggilan nyata tersambung, HP orang tua membuat sesi; agent menemukannya, merekam mikrofon, dan mengirim WAV berurutan. Peringatan risiko muncul di HP pengawas dan keputusan kembali ke orang tua.

Sinkronisasi foreground memakai polling ringan 1,5 detik. Saat kredensial APNs tersedia, server juga mengirim notifikasi saat app berada di latar belakang. Petunjuk lengkap ada di [`docs/PILOT.md`](../docs/PILOT.md).

## Batas serah terima ke backend

Semua ada di `RambuPuck/Services/Services.swift`. UI hanya mengenal protokol ini.

| Protokol | Tugas | Simulasi sekarang | Implementasi nyata |
|---|---|---|---|
| `CallAnalysisSource` | Memiliki siklus start/finish/cancel dan mengalirkan status serta assessment | `ScenarioAnalysis` hanya untuk test/screenshot | `ProtectionCallAnalysisSource` → `/api/protection/sessions/*` |
| `FamilyRelay` | Menyebar `FamilyAlert` ke semua pengawas dan menerima `GuardianDecision` | `LocalFamilyRelay` untuk demo; `PilotSync` untuk dua HP | Backend SQLite + APNs; keputusan pertama dikunci atomik. |
| `PuckLink` | Menemukan dan menghubungkan puck | `SimulatedPuckLink` | CoreBluetooth, menunggu spesifikasi GATT dari tim hardware |

Kontrak data yang diharapkan UI:

- `ChunkAssessment.level` adalah tingkat **keseluruhan** panggilan dan tidak boleh turun. Nilainya `safe`, `review`, atau `danger`.
- `ChunkAssessment.signals` hanya berisi tanda di potongan itu: `impersonation`, `urgency`, `secretCode`, `transfer`, `remoteApp`.
- `TranscriptLine.flagged` berisi frasa persis dari `text` yang akan disorot untuk pengawas.
- `TranscriptLine.speaker` membedakan penelepon dari orang tua. Pengawas hanya menerima kalimat penelepon yang memicu peringatan (lihat `CallViewModel.makeAlert`). Ini butuh pemisahan suara dari satu mikrofon puck.
- Tingkat Aman tidak pernah dikirim ke pengawas.

### Aturan jawaban pertama di server

Dua pengawas bisa menekan hampir bersamaan, jadi keputusan harus dikunci di server dengan update atomik:

```sql
UPDATE alerts
SET decision = :verdict, decided_by = :member_id, decided_at = now()
WHERE id = :alert_id AND decision IS NULL;
```

Kalau tidak ada baris yang berubah, balas `409` dengan keputusan yang sudah ada. App memetakan ini ke `DecisionOutcome.alreadyDecided`, mengunci tombol, dan memberi tahu "Richard sudah menjawab lebih dulu". Pemenang memicu push ke orang tua dan pengawas lain.

### Lainnya untuk backend

- **Ringkasan kejadian** (`CallRecord.incidentSummary`) sekarang disusun lokal dari tanda dan keputusan. Di produk nyata teks ini dibuat watsonx Orchestrate setelah panggilan selesai dan dikirim bersama riwayat.
- **Umpan balik deteksi**: jawaban "Aman" masih dicatat lokal sebagai false positive. Endpoint agregasi model belum dibuat.
- **Eskalasi tanpa jawaban** berjalan di app untuk prototipe. Di produk nyata sebaiknya timer di server supaya tetap jalan walau HP orang tua sibuk.
- **Tautan undangan**: `InviteLink` membuat tautan `https://rambu-saku.vercel.app/gabung?kode=482913` (bisa diketuk di WhatsApp). Halaman itu perlu meneruskan ke `rambu://gabung?kode=…` atau dijadikan Universal Link dengan file `apple-app-site-association`. Skema `rambu://` sudah terdaftar di app. Uji dengan `xcrun simctl openurl booted "rambu://gabung?kode=482913"`.
- **Pengingat loudspeaker** saat ini hanya bagian dari simulasi. `CXCallObserver`, pengukuran volume puck, dan mode background Bluetooth baru dapat diimplementasikan setelah protokol hardware disepakati.

`RiskRules` di `Models/Domain.swift` adalah aturan tiruan (dua tanda berbeda langsung dianggap Bahaya). Backend boleh menggantinya sepenuhnya.

## Yang disimulasikan dan yang belum ada

- **Layar telepon** hanya fixture screenshot. Di iPhone asli layar telepon milik iOS; runtime normal tidak membukanya.
- **Memutus telepon orang tua tidak mungkin di iOS.** Aplikasi pihak ketiga tidak bisa mengakhiri panggilan seluler maupun WhatsApp. Gantinya, setelah keputusan "Ini penipuan", pengawas bisa menekan **Telepon Ibu Ratna sekarang**. Kalau operator mengaktifkan panggilan tunggu, panggilan itu muncul di atas telepon penipu dan orang tua bisa langsung beralih. Perlu diuji di HP asli.
- **Live Activity** masih diperbarui lokal. APNs standar sudah tersedia untuk peringatan dan keputusan; token/push Live Activity belum dihubungkan.
- Sudah ada `CXCallObserver`, sesi proteksi produksi, dan agent puck macOS. Belum ada BLE/hardware puck nyata, jaminan peluncuran app saat terminated, panggilan penyelamat VoIP, Universal Link produksi, atau akun pengguna penuh. Pilot memakai kredensial perangkat acak, bukan kata sandi.

## Struktur

```
ios/
  project.yml                        konfigurasi XcodeGen (jalankan `xcodegen` setelah menambah file)
  RambuPuck/
    App/RambuPuckApp.swift           titik masuk, RootView, peluncur demo (RAMBU_SCENE)
    App/AppViewModel.swift           composition root dan routing lintas fitur
    Models/AppLanguage.swift         pilihan bahasa, locale, dan helper L10n
    Models/AppState.swift            state observable bersama dan penyimpanan
    Models/Domain.swift              tipe domain, aturan risiko tiruan, ringkasan kejadian
    Models/Scenarios.swift           percakapan sintetis dan riwayat awal
    Services/Services.swift          protokol serah terima ke backend + simulasi + Live Activity
    Services/PilotAPI.swift          API, Keychain, polling, dan sinkronisasi dua HP
    Services/Notifier.swift          push lokal (pengganti APNs di prototipe)
    Services/Support.swift           penyimpanan lokal, narasi suara, internet, tautan undangan, umpan balik
    Resources/*.xcstrings            catalog Bahasa Indonesia dan English
    DesignSystem/
      Components.swift               kartu, tombol, avatar, header, kode 6 digit, PhotoSlot
      RiskViews.swift                ikon, label, dan chip tingkat risiko; gelembung kalimat penelepon
      PushBanner.swift               tampilan push Rambu
      Illustrations.swift            ilustrasi puck, maskot interaktif
    Features/
      Onboarding/                    alur, tampilan, dan OnboardingViewModel
      Parent/                        tampilan orang tua dan CallViewModel
      Guardian/                      tampilan pengawas dan FamilyViewModel
      Profile/                       profil, pilot, dan ViewModel masing-masing
      Common/                        riwayat, Mode demo, banner gangguan, telepon cepat, tiruan push
  Shared/                            dipakai app dan widget: token merek, maskot, atribut Live Activity
  RambuPuckWidgets/                  Live Activity: Lock Screen + Dynamic Island
  RambuPuckTests/                    Swift Testing
  Screenshots/                       hasil scripts/screenshots.sh
```

Setiap file berisi satu layar atau satu kelompok komponen. Tipe `private` dipakai untuk bagian yang hanya dipakai di file itu.

## Desain

- Liquid Glass bawaan iOS 26 (`glassEffect`, `.glass`, `.glassProminent`) untuk kontrol dan navigasi. Isi informasi memakai kartu padat supaya mudah dibaca.
- Judul SF Pro Rounded, isi SF Pro, semuanya Dynamic Type.
- Tingkat risiko dibedakan bentuk dan teks, bukan warna saja: lingkaran untuk Aman, segitiga untuk Perlu dicek, oktagon untuk Bahaya.
- Merah dan kuning hanya dipakai untuk tingkat risiko.
- Maskot digambar ulang sebagai vektor (`Shared/Mascot.swift`) dengan enam pose. Titik kuning di dadanya selalu amber merek, bukan penanda status.
- Mode terang saja.

## Foto dan slot gambar

Foto asli dari Pexels (lisensi Pexels, bebas dipakai termasuk komersial):

- `PhotoWelcome`: ibu usia sekitar 40 menelepon dengan cemas di rumah. Foto oleh RDNE Stock project.
- `PhotoGuardian`: perempuan melihat HP. Foto oleh Tia Rahayu.

Gambar produk dan gaya hidup dibuat dengan image generation (puck belum punya foto fisik). Kalau asetnya dihapus, `PhotoSlot` menampilkan ilustrasi cadangan:

| Slot | Dipakai di | Ukuran |
|---|---|---|
| `PhotoPuckProduct` | Langkah pasang puck, tab Puck | 1600 × 1000 |
| `PhotoPuckOnPhone` | Tutorial kartu 1 | 1400 × 1400 |
| `PhotoSpeakerCall` | Tutorial kartu 2 | 1400 × 1400 |

## Screenshot

```bash
ios/scripts/screenshots.sh
```

Skrip ini membangun app, lalu membuka setiap adegan lewat variabel `RAMBU_SCENE` (daftarnya ada di `DemoLaunch` pada `App/RambuPuckApp.swift`). `RAMBU_FAST=1` mempercepat potongan audio menjadi 0,7 detik.

Semua nama, nomor, dan percakapan di aplikasi ini fiktif.

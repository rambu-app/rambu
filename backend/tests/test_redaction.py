from rambu_api.redaction import mask_sensitive_text


def test_masks_phone_account_and_otp_numbers() -> None:
    text = (
        "Hubungi 0812-3456-7890, transfer ke rekening 8800000001, "
        "lalu sebutkan OTP 482913."
    )

    masked = mask_sensitive_text(text)

    assert "0812" not in masked
    assert "8800000001" not in masked
    assert "482913" not in masked
    assert "[NOMOR_TELEPON]" in masked
    assert "[NOMOR_REKENING]" in masked
    assert "OTP [KODE]" in masked


def test_masks_punctuated_otp_and_spoken_account_number() -> None:
    text = (
        "Sebutkan kode OTP 482.913 sekarang. Transfer ke rekening "
        "delapan miliar delapan ratus juta satu untuk pengamanan."
    )

    masked = mask_sensitive_text(text)

    assert "482.913" not in masked
    assert "delapan miliar" not in masked
    assert "OTP [KODE]" in masked
    assert "rekening [NOMOR_REKENING]" in masked

    joined = mask_sensitive_text("Transfer kerekening delapan miliar delapan ratus juta satu.")
    assert "delapan miliar" not in joined
    assert "[NOMOR_REKENING]" in joined


def test_masks_read_out_codes_that_whisper_bends() -> None:
    cases = {
        "Silakan dibacakan angkanya. 2.6.6108 Baik.": "6108",
        "Betul kode OTP yang masuk tolong dibacakan. Kodanya 1163.": "1163",
        "Kodenya 2 6 6 1 0 8 ya Pak.": "2 6 6 1 0 8",
        "PIN saya 4821, benar?": "4821",
        "kodenya dua enam enam satu nol delapan": "dua enam enam",
    }

    for text, secret in cases.items():
        masked = mask_sensitive_text(text)
        assert secret not in masked, masked
        assert "[KODE]" in masked, masked


def test_keeps_amounts_and_short_numbers_visible() -> None:
    kept = [
        "Nanti ada kode 6 angka yang masuk lewat SMS.",
        "Bapak bisa menitipkan uang jaminan sebesar 5 juta rupiah.",
        "Ibu tinggal melunasi biaya balik nama sebesar Rp1.500.000.",
        "Kode promo berlaku sampai 2 jam lagi, biayanya 1500 ribu.",
        "Iuran arisan masih 50 ribu, kumpul pukul 4 sore.",
    ]

    for text in kept:
        assert mask_sensitive_text(text) == text

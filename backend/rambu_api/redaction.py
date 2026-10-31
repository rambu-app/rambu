import re


PHONE_PATTERN = re.compile(r"(?<!\d)(?:\+62|0)[\d -]{8,15}\d")
ACCOUNT_PATTERN = re.compile(r"(?<!\d)\d{9,18}(?!\d)")
_DIGIT_WORD = r"(?:nol|kosong|satu|dua|tiga|empat|lima|enam|tujuh|delapan|sembilan)"
# A code read out after a cue word: "OTP 482913", "Kodanya 1163.", "angkanya. 2.6.6108",
# "kodenya dua enam enam satu nol delapan". Whisper often bends the cue word ("koda") and
# splits the digits, so allow a short gap and separators. Money amounts stay visible.
OTP_PATTERN = re.compile(
    r"(?i)(\b(?:otp|kode|koda|pin|sandi|password|angka)(?:nya)?\b[^\d\[]{0,30}?)"
    r"(?<!rp)(?<!rp )"
    r"(?:\d(?:[ .-]?\d){3,7}|" + _DIGIT_WORD + r"(?:[\s,.-]+" + _DIGIT_WORD + r"){3,7}\b)"
    r"(?!\d|[.,]\d|\s*(?:ribu|rb|juta|jt|miliar|rupiah)\b)"
)
SPOKEN_ACCOUNT_PATTERN = re.compile(
    r"(?i)(\b(?:ke\s*)?rekening\s+)(?:(?:nol|satu|dua|tiga|empat|lima|enam|tujuh|delapan|"
    r"sembilan|sepuluh|sebelas|belas|puluh|ratus|ribu|juta|miliar)\s*){2,}"
)


def mask_sensitive_text(text: str) -> str:
    masked = PHONE_PATTERN.sub("[NOMOR_TELEPON]", text)
    masked = ACCOUNT_PATTERN.sub("[NOMOR_REKENING]", masked)
    masked = SPOKEN_ACCOUNT_PATTERN.sub(r"\1[NOMOR_REKENING] ", masked)
    return OTP_PATTERN.sub(r"\1[KODE]", masked)

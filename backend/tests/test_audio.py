import io
import wave

import struct

from rambu_api.audio import adpcm_to_wav, split_wav, validate_wav_bytes

from .conftest import wav_bytes, write_test_wav


def test_split_wav_returns_valid_five_second_chunks(tmp_path) -> None:
    source = write_test_wav(tmp_path / "call.wav", seconds=11)

    chunks = list(split_wav(source, chunk_seconds=5))

    assert len(chunks) == 3
    durations = []
    for chunk in chunks:
        with wave.open(io.BytesIO(chunk), "rb") as audio:
            assert audio.getnchannels() == 1
            assert audio.getsampwidth() == 2
            assert audio.getframerate() == 16_000
            durations.append(audio.getnframes() / audio.getframerate())
    assert durations == [5.0, 5.0, 1.0]


def test_live_chunk_validation_rejects_wrong_format_and_long_audio() -> None:
    assert validate_wav_bytes(wav_bytes(seconds=5)) == 5

    try:
        validate_wav_bytes(wav_bytes(seconds=7))
    except ValueError as error:
        assert "terlalu panjang" in str(error)
    else:
        raise AssertionError("long chunk was accepted")

    try:
        validate_wav_bytes(wav_bytes(sample_rate=8_000))
    except ValueError as error:
        assert "16 kHz" in str(error)
    else:
        raise AssertionError("wrong sample rate was accepted")


def adpcm_block(codes: list[int]) -> bytes:
    packed = bytearray((len(codes) + 1) // 2)
    for index, code in enumerate(codes):
        packed[index // 2] |= code << (4 * (index & 1))
    return struct.pack("<H", len(codes)) + bytes(packed)


def pcm_samples(value: bytes) -> list[int]:
    with wave.open(io.BytesIO(value), "rb") as audio:
        assert audio.getnchannels() == 1
        assert audio.getsampwidth() == 2
        assert audio.getframerate() == 16_000
        frames = audio.readframes(audio.getnframes())
    return list(struct.unpack(f"<{len(frames) // 2}h", frames))


def test_adpcm_chunk_decodes_like_puck_firmware() -> None:
    first_slot = adpcm_block([7, 7, 0, 8])
    second_slot = adpcm_block([15])
    third_slot = adpcm_block([0])

    samples = pcm_samples(adpcm_to_wav(first_slot + second_slot + third_slot))

    # Decoder state resets per slot; interpolation carries across slots and truncates toward zero.
    assert samples == [5, 11, 26, 41, 43, 45, 43, 42, 15, -11, -5, 0]


def test_adpcm_chunk_rejects_truncated_block() -> None:
    try:
        adpcm_to_wav(adpcm_block([1, 2, 3])[:-1])
    except ValueError as error:
        assert "ADPCM" in str(error)
    else:
        raise AssertionError("truncated ADPCM was accepted")

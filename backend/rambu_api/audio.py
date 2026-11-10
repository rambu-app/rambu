import io
import struct
import wave
from collections.abc import Iterator
from pathlib import Path


def split_wav(path: Path, chunk_seconds: int = 5) -> Iterator[bytes]:
    try:
        source = wave.open(str(path), "rb")
    except (EOFError, wave.Error) as error:
        raise ValueError("Audio WAV tidak valid.") from error

    with source:
        channels = source.getnchannels()
        sample_width = source.getsampwidth()
        sample_rate = source.getframerate()
        if channels != 1 or sample_width != 2 or sample_rate != 16_000:
            raise ValueError("Gunakan WAV mono PCM 16-bit dengan sample rate 16 kHz.")

        frames_per_chunk = sample_rate * chunk_seconds
        while frames := source.readframes(frames_per_chunk):
            buffer = io.BytesIO()
            with wave.open(buffer, "wb") as output:
                output.setnchannels(channels)
                output.setsampwidth(sample_width)
                output.setframerate(sample_rate)
                output.writeframes(frames)
            yield buffer.getvalue()


def validate_wav_bytes(value: bytes, maximum_seconds: float = 6.5) -> float:
    try:
        source = wave.open(io.BytesIO(value), "rb")
    except (EOFError, wave.Error) as error:
        raise ValueError("Audio WAV tidak valid.") from error

    with source:
        if source.getnchannels() != 1 or source.getsampwidth() != 2 or source.getframerate() != 16_000:
            raise ValueError("Gunakan WAV mono PCM 16-bit dengan sample rate 16 kHz.")
        duration = source.getnframes() / source.getframerate()
        if duration > maximum_seconds:
            raise ValueError("Potongan audio terlalu panjang; kirim paling lama 6,5 detik.")
        return duration


ADPCM_STEPS = (
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60,
    66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371,
    408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878,
    2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845,
    8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086,
    29794, 32767,
)
ADPCM_INDEX_SHIFT = (-1, -1, -1, -1, 2, 4, 6, 8)


def adpcm_to_wav(value: bytes) -> bytes:
    output = []
    previous = 0
    offset = 0
    while offset < len(value):
        if offset + 2 > len(value):
            raise ValueError("Audio ADPCM tidak valid.")
        count = int.from_bytes(value[offset : offset + 2], "little")
        packed = value[offset + 2 : offset + 2 + (count + 1) // 2]
        if len(packed) != (count + 1) // 2:
            raise ValueError("Audio ADPCM tidak valid.")
        offset += 2 + len(packed)
        predicted = 0
        index = 0
        for position in range(count):
            code = packed[position // 2] >> (4 * (position & 1)) & 0x0F
            step = ADPCM_STEPS[index]
            delta = step >> 3
            if code & 4:
                delta += step
            if code & 2:
                delta += step >> 1
            if code & 1:
                delta += step >> 2
            predicted = max(-32768, min(32767, predicted - delta if code & 8 else predicted + delta))
            index = max(0, min(88, index + ADPCM_INDEX_SHIFT[code & 7]))
            output.append(int((previous + predicted) / 2))
            output.append(predicted)
            previous = predicted

    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16_000)
        wav.writeframes(struct.pack(f"<{len(output)}h", *output))
    return buffer.getvalue()

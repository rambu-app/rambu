import io
import wave
from pathlib import Path


def write_test_wav(path: Path, seconds: float = 11.0, sample_rate: int = 16_000) -> Path:
    frame_count = int(seconds * sample_rate)
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(b"\x01\x00" * frame_count)
    return path


def wav_bytes(seconds: float = 1.0, sample_rate: int = 16_000) -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(b"\x01\x00" * int(seconds * sample_rate))
    return buffer.getvalue()


class ImmediateExecutor:
    def submit(self, function, *args):
        function(*args)

from rambu_api.transcription import FasterWhisperTranscriber

from .conftest import write_test_wav


class Segment:
    def __init__(self, text: str) -> None:
        self.text = text


class StubWhisperModel:
    def __init__(self) -> None:
        self.languages: list[str] = []

    def transcribe(self, path: str, **kwargs):
        assert path.endswith("sample.mp3")
        self.languages.append(kwargs["language"])
        return [Segment(" Halo "), Segment("Ibu.")], object()


def test_ignores_tiny_trailing_audio_chunk(tmp_path) -> None:
    path = write_test_wav(tmp_path / "tail.wav", seconds=0.2)

    assert FasterWhisperTranscriber("small").transcribe(path) == ""


def test_passes_mp3_dataset_audio_to_whisper(tmp_path) -> None:
    path = tmp_path / "sample.mp3"
    path.write_bytes(b"synthetic fixture")
    transcriber = FasterWhisperTranscriber("small")
    model = StubWhisperModel()
    transcriber._model = model

    assert transcriber.transcribe(path) == "Halo Ibu."
    assert model.languages == ["id"]


def test_passes_selected_english_language_to_whisper(tmp_path) -> None:
    path = tmp_path / "sample.mp3"
    path.write_bytes(b"synthetic fixture")
    model = StubWhisperModel()
    transcriber = FasterWhisperTranscriber("small")
    transcriber._model = model

    assert transcriber.transcribe(path, language="en") == "Halo Ibu."
    assert model.languages == ["en"]

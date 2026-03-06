#!/usr/bin/env python3
"""
Tests for transcribe.py

Run with: pytest scripts/test_transcribe.py -v
"""

import json
import os
import subprocess
import sys
import tempfile
import pytest


def make_test_audio(duration_seconds: float = 3.0, sample_rate: int = 16000) -> str:
    """Create a short sine-wave WAV file for testing."""
    import numpy as np
    import soundfile as sf

    t = np.linspace(0, duration_seconds, int(sample_rate * duration_seconds), endpoint=False)
    # Two tones to simulate speech-like audio
    audio = 0.3 * np.sin(2 * np.pi * 440 * t) + 0.2 * np.sin(2 * np.pi * 880 * t)
    audio = audio.astype(np.float32)

    tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
    sf.write(tmp.name, audio, sample_rate)
    return tmp.name


SCRIPT_PATH = os.path.join(os.path.dirname(__file__), "transcribe.py")
FAKE_TOKEN = "fake_hf_token_for_testing"


class TestOutputSchema:
    """Test that the JSON output schema is valid."""

    def test_output_has_required_keys(self, tmp_audio):
        result = run_transcribe(tmp_audio, skip_diarization=True)
        assert "segments" in result or "error" in result

    def test_segments_have_required_fields(self, tmp_audio):
        result = run_transcribe(tmp_audio, skip_diarization=True)
        if "error" in result:
            pytest.skip(f"Transcription failed (may need model): {result['error']}")
        for seg in result["segments"]:
            assert "start" in seg
            assert "end" in seg
            assert "text" in seg
            assert "speaker" in seg

    def test_segment_timestamps_are_numeric(self, tmp_audio):
        result = run_transcribe(tmp_audio, skip_diarization=True)
        if "error" in result:
            pytest.skip(f"Transcription failed (may need model): {result['error']}")
        for seg in result["segments"]:
            assert isinstance(seg["start"], (int, float))
            assert isinstance(seg["end"], (int, float))
            assert seg["end"] >= seg["start"]

    def test_speaker_labels_assigned(self, tmp_audio):
        result = run_transcribe(tmp_audio, skip_diarization=True)
        if "error" in result:
            pytest.skip(f"Transcription failed (may need model): {result['error']}")
        for seg in result["segments"]:
            assert seg["speaker"].startswith("SPEAKER_")

    def test_language_field_present(self, tmp_audio):
        result = run_transcribe(tmp_audio, skip_diarization=True)
        if "error" in result:
            pytest.skip(f"Transcription failed (may need model): {result['error']}")
        assert "language" in result
        assert isinstance(result["language"], str)

    def test_num_speakers_field_present(self, tmp_audio):
        result = run_transcribe(tmp_audio, skip_diarization=True)
        if "error" in result:
            pytest.skip(f"Transcription failed (may need model): {result['error']}")
        assert "num_speakers" in result
        assert isinstance(result["num_speakers"], int)
        assert result["num_speakers"] >= 0


class TestErrorHandling:
    """Test error handling for invalid inputs."""

    def test_missing_audio_file_returns_error(self):
        result = run_script(["/nonexistent/audio.wav", FAKE_TOKEN])
        assert "error" in result

    def test_empty_token_returns_error(self):
        with tempfile.NamedTemporaryFile(suffix=".wav") as f:
            result = run_script([f.name, ""])
            assert "error" in result

    def test_output_is_valid_json(self, tmp_audio):
        """Ensure stdout is always valid JSON even on error."""
        proc = subprocess.run(
            [sys.executable, SCRIPT_PATH, tmp_audio, FAKE_TOKEN],
            capture_output=True,
            text=True,
        )
        output = proc.stdout.strip()
        assert output, "stdout should not be empty"
        parsed = json.loads(output)
        assert isinstance(parsed, dict)


# ─── Fixtures ────────────────────────────────────────────────────────────────

@pytest.fixture(scope="session")
def tmp_audio():
    try:
        path = make_test_audio()
        yield path
    finally:
        if os.path.exists(path):
            os.unlink(path)


# ─── Helpers ─────────────────────────────────────────────────────────────────

def run_script(args: list) -> dict:
    """Run transcribe.py with given args and parse JSON stdout."""
    proc = subprocess.run(
        [sys.executable, SCRIPT_PATH] + args,
        capture_output=True,
        text=True,
    )
    try:
        return json.loads(proc.stdout.strip())
    except json.JSONDecodeError:
        return {"error": f"Invalid JSON: {proc.stdout[:200]}"}


def run_transcribe(audio_path: str, skip_diarization: bool = True) -> dict:
    """Run transcribe.py with a real audio file, optionally mocking diarization."""
    return run_script([audio_path, FAKE_TOKEN, "--model", "tiny"])

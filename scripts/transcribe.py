#!/usr/bin/env python3
"""
Audio transcription script using whisperX with speaker diarization.

Usage:
    transcribe.py <audio_file_path> <hf_token> [--model large-v3] [--language auto]

Output:
    JSON to stdout with segments, language, and speaker count.
"""

import sys
import json
import argparse
import os
import logging
import warnings


def setup_logging():
    """Redirect all logging and warnings to stderr so only JSON goes to stdout."""
    # Force all loggers to write to stderr
    logging.basicConfig(stream=sys.stderr, level=logging.WARNING)
    for name in logging.root.manager.loggerDict:
        logger = logging.getLogger(name)
        logger.handlers = []
        handler = logging.StreamHandler(sys.stderr)
        logger.addHandler(handler)

    # Redirect Python warnings to stderr
    warnings.showwarning = lambda msg, cat, fn, lineno, file=None, line=None: \
        print(f"{cat.__name__}: {msg}", file=sys.stderr)


def parse_args():
    parser = argparse.ArgumentParser(description="Transcribe audio with speaker diarization")
    parser.add_argument("audio_file", help="Path to audio file")
    parser.add_argument("hf_token", help="HuggingFace API token for pyannote.audio")
    parser.add_argument("--model", default="large-v3", help="Whisper model to use")
    parser.add_argument("--language", default="auto", help="Language code or 'auto' for detection")
    return parser.parse_args()


def emit_progress(step: int, total: int, message: str):
    """Emit a progress update to stderr in a parseable format."""
    percent = int(step / total * 100)
    sys.stderr.write(f"PROGRESS:{percent}:{message}\n")
    sys.stderr.flush()


def transcribe(audio_file: str, hf_token: str, model_name: str = "large-v3", language: str = "auto") -> dict:
    setup_logging()

    import time
    start_time = time.time()

    emit_progress(0, 5, "Loading model...")
    import whisperx

    device = "cpu"
    compute_type = "int8"

    # Determine language parameter for whisperX
    lang = None if language == "auto" else language

    # Step 1: Load model and transcribe
    emit_progress(1, 5, f"Loading {model_name} model...")
    model = whisperx.load_model(model_name, device, compute_type=compute_type, language=lang)
    audio = whisperx.load_audio(audio_file)

    emit_progress(2, 5, "Transcribing audio...")
    result = model.transcribe(audio, batch_size=16)

    detected_language = result.get("language", "en")

    # Step 2: Align word-level timestamps
    emit_progress(3, 5, "Aligning timestamps...")
    try:
        model_a, metadata = whisperx.load_align_model(
            language_code=detected_language,
            device=device
        )
        result = whisperx.align(
            result["segments"],
            model_a,
            metadata,
            audio,
            device,
            return_char_alignments=False
        )
    except Exception as e:
        # If alignment fails, proceed without it
        sys.stderr.write(f"Warning: alignment failed: {e}\n")

    # Step 3: Speaker diarization
    emit_progress(4, 5, "Identifying speakers...")
    try:
        from whisperx.diarize import DiarizationPipeline
        diarize_model = DiarizationPipeline(token=hf_token, device=device)
        diarize_segments = diarize_model(audio)
        result = whisperx.assign_word_speakers(diarize_segments, result)
    except Exception as e:
        sys.stderr.write(f"Warning: diarization failed: {e}\n")
        # Add placeholder speaker if diarization fails
        for seg in result.get("segments", []):
            if "speaker" not in seg:
                seg["speaker"] = "SPEAKER_00"

    # Step 4: Build output
    emit_progress(5, 5, "Finalizing...")
    segments = []
    speakers = set()

    for seg in result.get("segments", []):
        speaker = seg.get("speaker", "SPEAKER_00")
        speakers.add(speaker)
        segments.append({
            "start": round(seg.get("start", 0.0), 3),
            "end": round(seg.get("end", 0.0), 3),
            "text": seg.get("text", "").strip(),
            "speaker": speaker,
        })

    elapsed = time.time() - start_time
    sys.stderr.write(f"PROGRESS:100:Done in {elapsed:.1f}s\n")
    sys.stderr.flush()

    return {
        "segments": segments,
        "language": detected_language,
        "num_speakers": len(speakers),
    }


def main():
    args = parse_args()

    if not os.path.exists(args.audio_file):
        error = {"error": f"Audio file not found: {args.audio_file}"}
        print(json.dumps(error))
        sys.exit(1)

    if not args.hf_token or args.hf_token.strip() == "":
        error = {"error": "HuggingFace token is required for speaker diarization"}
        print(json.dumps(error))
        sys.exit(1)

    try:
        result = transcribe(
            audio_file=args.audio_file,
            hf_token=args.hf_token,
            model_name=args.model,
            language=args.language,
        )
        print(json.dumps(result, ensure_ascii=False))
    except Exception as e:
        error = {"error": str(e)}
        print(json.dumps(error))
        sys.exit(1)


if __name__ == "__main__":
    main()

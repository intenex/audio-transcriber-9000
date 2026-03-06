#!/usr/bin/env bash
set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log()  { echo -e "${GREEN}[setup]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC}  $*"; }
err()  { echo -e "${RED}[error]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ─── 1. XcodeGen ──────────────────────────────────────────────────────────────
log "Checking for xcodegen…"
if ! command -v xcodegen &>/dev/null; then
    log "Installing xcodegen via Homebrew…"
    brew install xcodegen
else
    log "xcodegen already installed: $(xcodegen --version)"
fi

# ─── 2. Conda environment ─────────────────────────────────────────────────────
log "Checking for conda…"
# Source conda init for non-interactive shell
CONDA_BASE=$(conda info --base 2>/dev/null || echo "")
if [[ -z "$CONDA_BASE" ]]; then
    err "conda not found. Install Miniconda first: https://docs.conda.io/en/latest/miniconda.html"
    exit 1
fi

# shellcheck source=/dev/null
source "$CONDA_BASE/etc/profile.d/conda.sh"

ENV_NAME="transcriber"
if conda env list | grep -q "^${ENV_NAME} "; then
    log "Conda env '${ENV_NAME}' already exists. Updating…"
    conda env update -n "$ENV_NAME" -f scripts/environment.yml --prune
else
    log "Creating conda env '${ENV_NAME}' with Python 3.11…"
    conda env create -f scripts/environment.yml
fi

# ─── 3. Install pip packages ──────────────────────────────────────────────────
log "Installing Python dependencies in '${ENV_NAME}'…"
conda run -n "$ENV_NAME" pip install -r scripts/requirements.txt

# ─── 4. Pre-download Whisper model ────────────────────────────────────────────
log "Pre-downloading Whisper large-v3 model weights (this may take a few minutes)…"
conda run -n "$ENV_NAME" python - <<'PYEOF'
import sys
try:
    from faster_whisper import WhisperModel
    print("Downloading large-v3 model…")
    model = WhisperModel("large-v3", device="cpu", compute_type="int8")
    print("Model downloaded successfully.")
except ImportError:
    print("faster-whisper not yet installed; skipping model pre-download.", file=sys.stderr)
except Exception as e:
    print(f"Warning: model download failed: {e}", file=sys.stderr)
PYEOF

# ─── 5. Pre-download mlx-lm model ─────────────────────────────────────────────
log "Pre-downloading mlx-lm model (Mistral 7B 4-bit, ~4GB — this will take a while)…"
conda run -n "$ENV_NAME" python - <<'PYEOF'
import sys
DEFAULT_MODEL = "mlx-community/Mistral-7B-Instruct-v0.3-4bit"
try:
    from mlx_lm import load
    print(f"Downloading {DEFAULT_MODEL}…")
    load(DEFAULT_MODEL)
    print("mlx-lm model downloaded successfully.")
except ImportError:
    print("mlx-lm not installed; skipping model pre-download.", file=sys.stderr)
except Exception as e:
    print(f"Warning: mlx-lm model download failed: {e}", file=sys.stderr)
PYEOF

# ─── 6. Generate Xcode project ────────────────────────────────────────────────
log "Generating Xcode project with xcodegen…"
xcodegen generate --spec project.yml

# ─── 7. Done ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Setup complete!${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}Before first use, you need a HuggingFace token:${NC}"
echo "  1. Visit https://huggingface.co/settings/tokens and create a token"
echo "  2. Accept terms at https://huggingface.co/pyannote/speaker-diarization-community-1"
echo "  3. Accept terms at https://huggingface.co/pyannote/segmentation-3.0"
echo "  4. Open the app → Settings (gear icon) → paste your token"
echo ""
echo -e "${GREEN}To open the project in Xcode:${NC}"
echo "  open AudioTranscriber.xcodeproj"
echo ""
echo -e "${GREEN}To run Python tests:${NC}"
echo "  conda run -n transcriber pytest scripts/test_transcribe.py -v"
echo ""

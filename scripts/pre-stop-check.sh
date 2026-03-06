#!/bin/bash
# Pre-stop verification hook for Audio Transcriber 9000
# This runs before Claude Code ends a session.
# Exit 0 = allow stop, Exit non-zero = block stop with message.

set -e

PROJECT_DIR="/Users/intenex/Dropbox/code/audio-transcriber"
PLAN_FILE="/Users/intenex/.claude/plans/steady-strolling-goose.md"

cd "$PROJECT_DIR"

# 1. Check if the project builds
echo "🔨 Verifying build..."
BUILD_OUTPUT=$(xcodebuild -project AudioTranscriber9000.xcodeproj -scheme AudioTranscriber9000 -configuration Debug build 2>&1 | tail -5)

if ! echo "$BUILD_OUTPUT" | grep -q "BUILD SUCCEEDED"; then
    echo "❌ BUILD FAILED — fix build errors before ending session."
    echo "$BUILD_OUTPUT"
    exit 2
fi

echo "✅ Build succeeded."

# 2. Check if plan file exists and has unchecked items
if [ -f "$PLAN_FILE" ]; then
    UNCHECKED=$(grep -c '^\- \[ \]' "$PLAN_FILE" 2>/dev/null || true)
    CHECKED=$(grep -c '^\- \[x\]' "$PLAN_FILE" 2>/dev/null || true)

    if [ "$UNCHECKED" -gt 0 ]; then
        echo ""
        echo "⚠️  Plan has $UNCHECKED unchecked items (and $CHECKED completed)."
        echo "   Review the plan and ensure all feasible items are done."
        echo "   Plan: $PLAN_FILE"
        # Don't block — just warn. Claude should have followed CLAUDE.md instructions.
    else
        echo "✅ Plan: all items checked off."
    fi
fi

# 3. Verify the app binary exists
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/AudioTranscriber9000-*/Build/Products/Debug -name "Audio Transcriber 9000.app" -maxdepth 1 2>/dev/null | head -1)
if [ -z "$APP_PATH" ]; then
    echo "❌ Built app not found in DerivedData."
    exit 2
fi

echo "✅ App binary found: $APP_PATH"
echo ""
echo "Pre-stop checks passed. Session can end."
exit 0

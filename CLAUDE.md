# Audio Transcriber 9000 — Claude Code Instructions

## Before Ending Any Session

**MANDATORY**: Before claiming work is complete or ending a session, you MUST:

1. **Check the plan file** (`/Users/intenex/.claude/plans/steady-strolling-goose.md`) — verify every item is implemented. If items remain that can be done, continue working on them.

2. **Build verification** — Run `xcodebuild -project AudioTranscriber9000.xcodeproj -scheme AudioTranscriber9000 -configuration Debug build` and confirm `BUILD SUCCEEDED`.

3. **Launch and test the app** — Use `osascript` and `open` to verify the app:
   - Launch: `open -a "/path/to/DerivedData/.../Audio Transcriber 9000.app"`
   - Wait 2 seconds, then verify it launched: `osascript -e 'tell application "System Events" to get name of every process whose name contains "Audio Transcriber"'`
   - Verify UI elements via accessibility: `osascript -e 'tell application "System Events" to tell process "Audio Transcriber 9000" to get entire contents of window 1'`
   - Check for expected elements: "New Recording" button, "Import Audio" button, settings gear, sidebar
   - Test each feature modified in the session (e.g. click buttons via `osascript`, verify state changes)
   - Quit when done: `osascript -e 'tell application "Audio Transcriber 9000" to quit'`

4. **Run unit tests** if they exist — `xcodebuild test -project AudioTranscriber9000.xcodeproj -scheme AudioTranscriberTests -configuration Debug`

5. **Report status** — Clearly state what was completed, what was tested, and any remaining items that couldn't be done (with reasons).

Do NOT skip these steps. Do NOT claim "everything works" without actually running the verification. If the build fails, fix it before ending. If tests fail, fix them before ending.

## Project Notes

- Bundle ID: `com.audiortranscriber.AudioTranscriber`
- Build product: `~/Library/Developer/Xcode/DerivedData/AudioTranscriber9000-*/Build/Products/Debug/Audio Transcriber 9000.app`
- XcodeGen: run `xcodegen generate` after modifying `project.yml`
- TCC/Microphone: requires manual permission grant in System Settings for recording to work

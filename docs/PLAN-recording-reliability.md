# Recording reliability and TestFlight — 2026-09-14

User scope: capture microphone plus Mac output through headphone/speaker changes; warn after 15 minutes of silence and pause after 30; keep two-hour check-ins non-blocking with stop-and-review trimming; fix elapsed-time display; keep eight-hour recording/playback/transcript work bounded and recover audio after crashes; push and deliver internal/external TestFlight where account access permits.

- [x] Read project docs and earlier Claude Code project sessions.
- [ ] Separate system audio capture from microphone route changes; verify both sources and route recovery.
- [x] Durable, bounded recording writer and recovery; verify forced termination and eight-hour synthetic capture.
- [x] Silence warning/pause/resume and non-blocking duration check-ins; accurate elapsed time and animation.
- [x] Stop-and-review screen with playback and explicit verified truncation.
- [x] Long transcript rendering/search/highlighting and streamed playback performance.
- [x] Update architecture/development/testing docs and run Mac build, full tests, appropriate gated tests, iOS build/tests, and actual app probes.
- [x] Review changes, commit, push, and verify GitHub state.
- [x] Signed direct Mac release preserving all features (user decision); iOS TestFlight archive/upload, processing and internal/external group availability or specific review blockers.

No hosted automation is being added. Builds and tests run locally. Real library audio remains read-only during verification.

Verification checkpoint: 327 Mac tests (24 gated skips), 319 iOS tests (13 gated skips), and three iOS UI tests pass. Real local/preview/resume/long-file tests and scratch Mac recording, review, recovery, long-transcript scrolling and seven-hour seeking pass. ScreenCaptureKit virtual-route switching measures no gaps. AirPods physical switching is pending because the headphones disconnected.

Release checkpoint: source revision `16f2e91` is pushed to `codex/recording-reliability`. Mac 1.1 (2) is Developer ID signed and Apple-notarized (submission `e34ae63f-82ee-4874-960a-71a7943b30ec`, Accepted), stapled and accepted by Gatekeeper. The exported app launched with a scratch library and played a saved recording with an advancing clock. The local ZIP and checksum are under ignored `dist/AudioTranscriber-1.1-2/`. iOS upload initially rejected the icon alpha channel; revision `f858880` supplies an iOS-only RGB copy preserving all color pixels. The corrected 1.1 (2) upload is VALID, build `2e14ca8c-6192-44b5-a62c-f8936537f4a6`. Both Internal and External groups are attached. Internal state is `IN_BETA_TESTING` with the account owner invited; external state is `WAITING_FOR_BETA_REVIEW` (submitted 2026-09-14). What to Test and review information are populated. External tester addresses have not been provided, so that group has no testers yet. No public App Store release was made.

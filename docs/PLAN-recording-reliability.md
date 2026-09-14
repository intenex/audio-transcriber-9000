# Recording reliability and TestFlight — 2026-09-14

User scope: capture microphone plus Mac output through headphone/speaker changes; warn after 15 minutes of silence and pause after 30; keep two-hour check-ins non-blocking with stop-and-review trimming; fix elapsed-time display; keep eight-hour recording/playback/transcript work bounded and recover audio after crashes; push and deliver internal/external TestFlight where account access permits.

- [x] Read project docs and earlier Claude Code project sessions.
- [ ] Separate system audio capture from microphone route changes; verify both sources and route recovery.
- [x] Durable, bounded recording writer and recovery; verify forced termination and eight-hour synthetic capture.
- [x] Silence warning/pause/resume and non-blocking duration check-ins; accurate elapsed time and animation.
- [x] Stop-and-review screen with playback and explicit verified truncation.
- [x] Long transcript rendering/search/highlighting and streamed playback performance.
- [x] Update architecture/development/testing docs and run Mac build, full tests, appropriate gated tests, iOS build/tests, and actual app probes.
- [ ] Review changes, commit, push, and verify GitHub state.
- [ ] Signed direct Mac release preserving all features (user decision); iOS TestFlight archive/upload, processing and internal/external group availability or specific review blockers.

No hosted automation is being added. Builds and tests run locally. Real library audio remains read-only during verification.

Verification checkpoint: 327 Mac tests (24 gated skips), 319 iOS tests (13 gated skips), and three iOS UI tests pass. Real local/preview/resume/long-file tests and scratch Mac recording, review, recovery, long-transcript scrolling and seven-hour seeking pass. ScreenCaptureKit virtual-route switching measures no gaps. AirPods physical switching is pending because the headphones disconnected.

# Icon refresh — September 28, 2026

Ivory audio waveform bars flowing into lavender text lines.

Artwork was created with the built-in image-generation tool. iOS uses full-bleed opaque RGB assets; Mac variants use transparent edges around a rounded tile. Catalog image dimensions and alpha requirements were verified. Only artwork, build metadata, and release documentation changed.

## Release state

| Platform | Version | Build ID | Processing | Internal TestFlight |
|---|---|---|---|---|
| IOS | 1.1 (3) | `76f514cf-613b-4599-932f-7bf32e1ac7b6` | VALID | IN_BETA_TESTING |

New builds are attached to eligible existing distribution drafts to supply the App Store Connect listing icons. No App Store review/release or external beta review was submitted; tester membership and existing external builds were preserved.

## Verification

Mac Debug build and 327 tests passed (24 hardware/model-gated tests skipped). The app launched with a five-recording isolated fixture; About showed the new icon and 1.1 (3). Signed iOS payload. The separate arm64 direct Mac build preserves the unsandboxed feature set, external Python/MLX, and arbitrary folders.

All release work was initiated manually on the local Mac. No CI, hosted schedule, paid plan, or overage was enabled. Artifacts, signatures, checksums, and API state are preserved in the icon-refresh task workspace under `work/releases/audio/`.

Direct Mac notarization: **Accepted**, submission `46a30e2f-75e3-4649-b371-daeb59609116`. Stapling and Gatekeeper verification passed. The Mac App Store Connect icon intentionally remains unresolved, preserving the user's direct-distribution decision.

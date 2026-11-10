# Working on Final Fusion

Read [README.md](README.md), [DEVELOPMENT.md](DEVELOPMENT.md) and [LICENSE](LICENSE).

- Prefer a setting or a reproducible fix that meets the user's request. Preserve Korean and English UI text and the setup flow unless the user asks to change it.
- Keep the host and viewer bundle IDs, settings layout, wire protocol, and the update disk's Studio Receiver.app name compatible.
- Build into a temporary folder. Validate with fabricated pairing settings. Do not replace an active remote app, deploy a relay, send a viewer package or publish changes without the user's authorization.
- Keep private viewer packages, keys, relay configuration and raw diagnostic output out of source control. Share only redacted diagnostics.
- Report build, simulated checks and physical-device results separately. Personal local modifications are permitted under LICENSE.

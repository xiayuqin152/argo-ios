# Argo iOS sources

Argo's UI and input code are adapted from [nwverse/Persona](https://github.com/nwverse/Persona/tree/3002eb387c65fe471a75b03586e89bd49e20f4a3), commit `3002eb387c65fe471a75b03586e89bd49e20f4a3`. The Persona MIT notice is retained in [ios/ThirdParty/Persona/LICENSE](ios/ThirdParty/Persona/LICENSE), with a copy in the app's license resources. Adapted source files retain their source comments.

[BeautifulUI](ios/ThirdParty/BeautifulUI/VENDORED.md) remains a local Swift package. Its `LICENSE`, `LICENSE-beautifului`, `NOTICE` and provenance file are retained unchanged.

`ios/Packages/ArgoMobileKit` supplies Argo pairing, pinned gateway transport, credentials and session APIs. Its 18 shared Swift files are ordinary package files in this standalone tree. No external monorepo directory or symlink is required.

This source export includes no Git history, platform SDKs, caches, user configuration, Persona Hub or private assistant data. Argo contributions are covered by the root MIT LICENSE, © 2026 Argo contributors.

The per-file origin commits, Git blob IDs and adaptations are retained in
[upstream-files.json](ios/Argo/Verification/upstream-files.json). This was the only
file retained from the original development Verification directory export.
[NotificationUnregisterCheck.swift](ios/Argo/Verification/NotificationUnregisterCheck.swift)
was added later as an Argo notification lifecycle regression check.

QR pairing, full-page composition and the native image PasteButton use Persona
revision `89927b54baab6b8207315f6c2a4d2e5831598d45`. Pairing keeps Argo's existing
single-use code parser, certificate pinning and owned Keychain credentials.
The full-page editor reads and writes the existing conversation draft and keeps
modal visibility ownership until its actual dismissal. Image providers use the
existing bounded private-file preparation and attachment delivery lifecycle.

The optional Return Key Sends behavior is adapted from Persona PR #8202,
head `75c30cc008554144a72fb917edd548f528ea45b0`, via the local source integration
`0af3cee3373f2315efa05f00c0ba73c1d211c642`. The integration commit is a local
integration record, not a publicly resolvable `nwverse/Persona` ref; the PR head
above is the public provenance ref. It uses Argo's existing send gate and
IME/input ownership. Other source-only Persona PRs are not claimed as installed
Argo capabilities. No Persona server protocol, health or private assistant is
included.

Argo artwork provenance and exact source assets are in
[brand sources](docs/branding/SOURCES.md). The four original Persona/BeautifulUI
licenses and notice remain in both the source tree and app resources.

Notification lifecycle sequencing follows Persona PushRegistrar concepts; the implementation uses the paired Argo host device registration contract. No Persona backend is required. Device and SDK behavior remain to be validated.

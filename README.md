# Argo iOS

<p align="center">
  <img src="docs/branding/argo-logo.png" alt="Argo" width="144" height="144">
</p>

Argo's companion for iPhone and iPad: follow your coding sessions, read progress and reply from your phone, with selected UI, input and pairing components adapted from Persona.

[简体中文](README.zh-CN.md) · [Build and host requirements](ios/README.md) · [Notifications](docs/phone-notifications.md)

## Sessions and input

- Browse paired hosts, workspaces, messages, tool activity and conversation history.
- Read and reply to connected **managed** sessions, including supported Agent questions. Historical, manual or unattached sessions are read only.
- See working, waiting, finished and error states. Sending shows the host's delivery or queue receipt; refresh to check an unknown result before sending again.
- Queue previews and full-message reads require an Argo host upgraded to the [bounded queue and full-item contract](research/queue-wire-v2/queue-wire-v2.md).
- Expand the message field for long text. Return inserts a line break by default; **Settings → Return Key Sends** enables Return to send, with Shift-Return for a line break.
- Attach photos or files and open managed previews. The system **Paste Image** button imports images when you tap it.

## Pair

On a compatible Argo host, run:

```sh
argo pair
```

In the app, scan its QR code, tap **Paste Pairing Code**, or enter the complete `argo1:` code. A code is single-use and expires after 10 minutes. Scanning needs camera permission and a supported device; paste and manual entry remain available. Allow local-network access when prompted, and make sure the phone can reach the host.

The host must provide the bounded 1 MiB chat contract. Phone alerts additionally require `PUT/DELETE /api/notify/device`. Verified Argo source master `56b03830908811c8cc1675675bbdd59127303b5f` includes combined backend revision `eba473a09100b11b2f6ea0cf77ab5817f50f6608`. The running service has not been deployed from this source. See the exact [host requirements](ios/README.md#host-compatibility). This repository contains the phone client.

## Phone alerts

The source candidate includes per-host notification registration and tap-to-open routing. After pairing, select a host and enable **Settings → Notifications → Agent Alerts on This iPhone**. Alerts contain status only. A suitably signed app, notification permission and the host's own APNs setup are required; see [configuration and permissions](docs/phone-notifications.md).

Signing, actual APNs delivery and background receipt on a device await validation. The app reads sessions while in the foreground and reconnects when reopened.

## Build and installation

The app targets iOS 26+, with the `Argo` scheme in [ios/Argo.xcodeproj](ios/Argo.xcodeproj). [GitHub Actions](https://github.com/xiayuqin152/argo-ios/actions/workflows/ios-unsigned.yml) runs the Core tests with the selected Xcode, then creates a Release iPhoneOS archive and unsigned IPA. Open a successful run for its commit, artifacts and logs.

The workflow's **unsigned IPA cannot be installed directly**. Device installation requires an Apple Developer account, a suitable certificate and provisioning profile. Signed IPA, TestFlight and App Store distribution are not configured. See [build instructions and current validation](ios/README.md).

## Credits and licenses

Argo contributions use the [MIT License](LICENSE), © 2026 Argo contributors.

Selected UI, input and pairing components come from [Persona](https://github.com/nwverse/persona), © 2026 nwverse, under its [MIT License](ios/ThirdParty/Persona/LICENSE). [BeautifulUI](ios/ThirdParty/BeautifulUI), © 2026 ChrisPan, retains its [MIT License](ios/ThirdParty/BeautifulUI/LICENSE). Its foundation, [Beautiful UI](https://www.beautifului.dev/), © 2026 Shane Levine, retains its [MIT license](ios/ThirdParty/BeautifulUI/LICENSE-beautifului) and [notice](ios/ThirdParty/BeautifulUI/NOTICE). File provenance is recorded in [UPSTREAM.md](UPSTREAM.md).

The logo and AppIcon reuse the owner's existing Argo brand; the original sources and rebuild instructions remain in [brand sources](docs/branding/SOURCES.md).

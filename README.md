# Argo iOS

<p align="center">
  <img src="docs/branding/argo-logo.png" alt="Argo" width="144" height="144">
</p>

Argo's iOS companion for iPhone and iPad: follow your coding sessions, read progress and reply from your phone, with selected UI, input and pairing components adapted from Persona. This repository contains the iOS client; the Argo host runs separately.

[简体中文](README.zh-CN.md) · [Build and host requirements](ios/README.md) · [Notifications](docs/phone-notifications.md) · [iOS source candidate](https://github.com/xiayuqin152/argo-ios/pull/3)

## Sessions and input

- Browse paired hosts, workspaces, messages, tool activity and conversation history.
- Read and reply to connected **managed** sessions, including supported Agent questions. Historical, manual or unattached sessions are read only.
- See phone-sent messages in the Agent's conversation when the host reads them back from its history. **Delivery Receipts** separately show sending, queued, delivered or unknown status.
- See working, waiting, finished and error states. Sending shows the host's delivery or queue receipt; refresh to check an unknown result before sending again.
- View queued messages and open or copy their full text. Earlier handoff records remain read only; hiding one does not retract input already sent to the Agent.
- Expand the message field for long text. Return inserts a line break by default; **Settings → Return Key Sends** enables Return to send, with Shift- or Option-Return for a line break.
- Attach photos or files and open managed previews. The system **Paste Image** button imports images when you tap it.

## Pair

On a compatible Argo host, run:

```sh
argo pair
```

In the app, scan its QR code, tap **Paste Pairing Code**, or enter the complete `argo1:` code. A code is single-use and expires after 10 minutes. Scanning needs camera permission and a supported device; paste and manual entry remain available. Allow local-network access when prompted, and make sure the phone can reach the host.

Use an Argo host that supports mobile conversation reads, message receipts and full queue-message reads. Phone alerts additionally require notification registration and the host's APNs setup. See the [host capability requirements](ios/README.md#host-compatibility); host source changes are tracked in [Loom PR#44](https://github.com/xiayuqin152/loom/pull/44). A minimum released host version has not been specified.

## Phone alerts

After pairing, select a host and enable **Settings → Notifications → Agent Alerts on This iPhone**. Alerts contain status only. Tapping one opens its paired host and session without sending a message; alerts from disabled or replaced registrations are ignored. A suitably signed app, notification permission and the host's own APNs setup are required; see [configuration and permissions](docs/phone-notifications.md).

Signing, actual APNs delivery and background receipt on a device await validation. The app reads sessions while in the foreground and reconnects when reopened.

## Build and installation

The app targets iOS 26+, with the `Argo` scheme in [ios/Argo.xcodeproj](ios/Argo.xcodeproj). [GitHub Actions](https://github.com/xiayuqin152/argo-ios/actions/workflows/ios-unsigned.yml) is configured to run Core tests with the selected Xcode, create a Release iPhoneOS archive and unsigned IPA, then run native UIKit input tests on an available iOS Simulator. It preserves the archive and UIKit test xcresult bundles. Builds run on GitHub-hosted Macs; you do not need your own Mac or a local Xcode installation. Results apply only to the source commit recorded by each run; see [build records and pending validation](ios/README.md#validation-status).

The workflow's **unsigned IPA cannot be installed directly**. Device installation requires an Apple Developer account, a suitable certificate and provisioning profile. Signed IPA, TestFlight and App Store distribution are not configured. See [build and installation instructions](ios/README.md).

## Credits and licenses

Argo contributions use the [MIT License](LICENSE), © 2026 Argo contributors.

Selected UI, input and pairing components come from [Persona](https://github.com/nwverse/persona), © 2026 nwverse, under its [MIT License](ios/ThirdParty/Persona/LICENSE). [BeautifulUI](ios/ThirdParty/BeautifulUI), © 2026 ChrisPan, retains its [MIT License](ios/ThirdParty/BeautifulUI/LICENSE). Its foundation, [Beautiful UI](https://www.beautifului.dev/), © 2026 Shane Levine, retains its [MIT license](ios/ThirdParty/BeautifulUI/LICENSE-beautifului) and [notice](ios/ThirdParty/BeautifulUI/NOTICE). File provenance is recorded in [UPSTREAM.md](UPSTREAM.md).

The logo and AppIcon reuse the owner's existing Argo brand; the original sources and rebuild instructions remain in [brand sources](docs/branding/SOURCES.md).

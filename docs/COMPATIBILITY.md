# Host compatibility

This repository contains the iOS client for iPhone and iPad. Connect it to an
Argo host with the mobile capabilities below; the host is installed and upgraded
separately.

A minimum released host version has not been specified. Host source changes
are tracked separately from this public iOS repository. iOS source changes are
tracked in [PR#3](https://github.com/xiayuqin152/argo-ios/pull/3).
Confirm the capabilities below on the host you deploy before pairing.

| Feature | Required host capability and phone behavior |
| --- | --- |
| Pairing | Argo pairing codes, device credential authentication and an address reachable from the phone. Raw IPv6-zone addresses and Unicode DNS names use the same normalization on both sides. |
| Conversations | Bounded native chat reads, history cursors and attachment references. The phone displays the Agent conversation returned by the host. |
| Replies | Connected managed sessions accept messages and supported Agent answers with delivery receipts. Historical, manual and unattached sessions remain read only. |
| Queued messages | Bounded queue previews and receipts, plus full-message reads by the original item ID. Open or copy full text when a preview is shortened. |
| Earlier handoffs | Read-only records from the original session, kept separate from the current send queue. Source-read errors show a warning without discarding readable messages or receipts. |
| Phone alerts | Paired-device notification registration and the host's own APNs configuration. Tapping an alert opens its host and session without sending a message. |

## Messages sent from the phone

Phone-sent text remains visible in **Delivery Receipts** with its sending,
queued, delivered or unknown status. When the host reads the message back from
the Agent's native conversation history, it appears in that conversation.
A queue acknowledgement or native handoff receipt does not mean the Agent has
finished its turn.

An unknown result keeps its warning, including when matching text appears in
the conversation. Refresh the host state before deciding what to do next.
The app does not automatically resend an unknown message or repeat a send when
it returns to the foreground.

A queue send conflict (HTTP 409) is also shown as unknown: input may already
have been pasted even when Enter was blocked. The host's explanation is kept;
check the host or terminal state before another send.

## Queues and earlier records

Native accepted or unknown handoffs and ordinary terminal sends with unknown
delivery are read only. They can be viewed, copied or explicitly hidden/removed;
removal does not retract possible input or turn an unknown result into success.
The app does not rebuild these records as messages to send again.

Earlier records retain their original host, session and message ownership. They
are opened from the original source rather than the resumed session's send
queue. If some earlier records cannot be read, the app shows a warning while
keeping current messages and readable receipts available. Counts can be
incomplete in that state.

## Notifications and installation

Enable alerts separately for each paired host. The app checks the current
pairing and notification registration before opening an alert's host/session;
alerts from disabled or replaced registrations are ignored. Alerts contain
status only. See [notification setup](phone-notifications.md) for permissions,
signing and APNs environments. APNs delivery and device background behavior
still require device validation.

An unsigned IPA cannot be installed directly. Device installation needs an
Apple Developer account, a suitable certificate and provisioning profile.
Cloud builds and artifacts apply only to the source commit recorded by each
run. See [build records and pending validation](../ios/README.md#validation-status)
for the earlier successful build and remaining device checks. For later source
changes, use the SDK, UIKit and package results from that commit's own run.

## Host integration reference

The client uses gateway `proto=1` and HTTP `api=1`. Conversation reads require
`bounded:true`, `byteLimit:1048576`, native identity checks, history cursors and
raw-source `fileRefs`. Queue previews and send/hide receipts use the
[queue-wire v2 contract](../research/queue-wire-v2/queue-wire-v2.md), including
bounded responses and full-item reads. Notification registration uses
`PUT/DELETE /api/notify/device` with the paired device's credentials.

Real pairing/replies, camera, IME/paste, Photos/Quick Look, accessibility,
signing and device notification behavior remain separate validation steps.

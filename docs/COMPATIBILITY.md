# Host compatibility

Argo MobileKit uses the authenticated Argo gateway (`proto=1`, HTTP `api=1`).
Conversation reading additionally requires opt-in bounded native chat responses:
`bounded:true`, `byteLimit:1048576`, native identity checks, block cursors and
raw-source `fileRefs`. These requirements are checked in the client; a legacy
whole-record chat response is not accepted as a bounded page. The host must also
carry the matching raw IPv6-zone and Unicode DNS pairing normalization.

The latest fetched Argo source master is
`56b03830908811c8cc1675675bbdd59127303b5f`. It includes independently reviewed
combined backend revision `eba473a09100b11b2f6ea0cf77ab5817f50f6608`;
their source trees are identical. This includes bounded chat/fileRefs, pairing
normalization and phone notification registration/APNs support. The running
service has not been deployed from this source; a released minimum host version
has not been specified. No server source or private server history is included
in this phone client repository.

Queue/reply, interrupt, exact displayed-question seen acknowledgement, attachment
upload/download and Claude model recovery use the existing authenticated APIs.
Unknown delivery/upload/model actions retain evidence and require explicit
readback; foregrounding does not automatically repeat a POST. Manual sessions
remain read-only. Local attachment previews and new remote reads have separate
ownership and authorization checks.

Phone Tailcat transport is not connected. Notification registration, credential-preserving removal and GET-only tap routing are implemented. The host provides PUT/DELETE /api/notify/device and requires its own APNs configuration. Debug uses provider sandbox and entitlement development; Release uses production for both. APNs/background delivery and actual signing remain unvalidated.
Current Linux checks cover Core and production model state. Final-revision iOS
SDK/SwiftUI/UIKit/resource checks run in GitHub's standard macOS cloud runner.
Real pairing/replies, camera, IME/paste, Photos/Quick Look, accessibility and
device notification behavior require their own validation.

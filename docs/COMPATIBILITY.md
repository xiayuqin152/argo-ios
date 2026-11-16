# Host compatibility

Argo MobileKit uses the authenticated Argo gateway (`proto=1`, HTTP `api=1`).
Conversation reading additionally requires opt-in bounded native chat responses:
`bounded:true`, `byteLimit:1048576`, native identity checks, block cursors and
raw-source `fileRefs`. These requirements are checked in the client; a legacy
whole-record chat response is not accepted as a bounded page. The host must also
carry the matching raw IPv6-zone and Unicode DNS pairing normalization.

The previously verified Argo source master is
`56b03830908811c8cc1675675bbdd59127303b5f`. It includes independently reviewed
combined backend revision `eba473a09100b11b2f6ea0cf77ab5817f50f6608`;
their source trees are identical. This includes bounded chat/fileRefs, pairing
normalization and phone notification registration/APNs support. The running
service has not been deployed from this source; a released minimum host version
has not been specified. No server source or private server history is included
in this phone client repository.

This client additionally requires [queue-wire v2](../research/queue-wire-v2/queue-wire-v2.md).
Upgrade the host code to provide bounded queue reads and send/hide receipts,
plus read-only full-item reads alongside the existing contracts. The source
verification above covers the older chat, pairing and notification combination;
running-host queue-wire v2 support still needs validation.

Queue previews may shorten display text; viewing or copying incomplete content
first reads the full item by its original ID. Native `accepted` acknowledges a
CLI handoff; turn completion is read from the native conversation. Native
`unknown` retains an uncertain result. Both states allow view/copy and explicit
hide only; hiding a record leaves the CLI input unchanged. Unknown sends retain
their evidence for readback and are never automatically resent.

| Capability | Client request | Required host contract |
| --- | --- | --- |
| Queue preview | `GET /api/agents/{run}/queue?bounded=1` | Root `bounded:true`, `byteLimit:8388608`; the entire encoded JSON body, including its final newline, is strictly smaller than 8,388,608 bytes (8 MiB). |
| Send receipt | `POST /api/agents/{run}/queue?bounded=1` | The same root markers and byte bound; the original `X-Loom-Attempt` retains its idempotency semantics. An old-style success receipt is treated as unknown delivery and requires readback. |
| Native hide receipt | `DELETE /api/agents/{run}/queue/{id}/native?bounded=1` | A bounded queue response under the same byte bound. iOS ignores this response body; the request hides the record only and is not automatically replayed. |
| Preview fields | Queue views and receipts above | Preserve all `items`/`later`, IDs, targets, native states and counts. Queue `ws` and current `identity` are inside `queue` in a receipt. Each object's optional `truncatedFields` marks shortened display strings; previews never supply text for sends or overwrites. |
| Complete item | `GET /api/agents/{run}/queue/{id}` | Read-only, no `bounded` mode: complete `item` with original `id` and optional original `target`, plus current `run`/`ws`/`identity`/`state`/`ended`/`later`; no truncation, body strictly smaller than 16,777,216 bytes (16 MiB). Missing or hidden items return 404. Reading never sends, retries, edits or cancels a message. |

Queue/reply, interrupt, exact displayed-question seen acknowledgement, attachment
upload/download and Claude model recovery use the existing authenticated APIs.
Unknown delivery/upload/model actions retain evidence and require explicit
readback; foregrounding does not automatically repeat a POST. Manual sessions
remain read-only. Local attachment previews and new remote reads have separate
ownership and authorization checks.

Phone Tailcat transport is not connected. Notification registration, credential-preserving removal and GET-only tap routing are implemented. The host provides PUT/DELETE /api/notify/device and requires its own APNs configuration. Debug uses provider sandbox and entitlement development; Release uses production for both. APNs/background delivery and actual signing remain unvalidated.
An unsigned IPA cannot be installed directly; device installation requires an
Apple Developer account, a suitable certificate and provisioning profile.
Current Linux checks cover Core and production model state. Final-revision iOS
SDK/SwiftUI/UIKit/resource checks run in GitHub's standard macOS cloud runner.
Real pairing/replies, camera, IME/paste, Photos/Quick Look, accessibility and
device notification behavior require their own validation.

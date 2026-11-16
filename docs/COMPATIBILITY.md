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

A resumed native session may also provide optional `nativeSources` entries of the
form `{sourceRun,target,nativeHistory}`. Each entry references older read-only
handoffs with the same workspace, engine, native home and native session, and
keeps the original terminal-agent identity. The reference carries no item body.
Queue and Agent-card `nativeHistory` counts include these sources; `items`,
`later` and `pending` still describe only the current run. A missing or null
`nativeSources` field means the host did not provide this capability, not that
no earlier records exist. Consuming clients must keep the sources separate from
the current send queue and use the original `sourceRun` queue, full-item and
native-hide APIs with the original item ID, target and revision/owner checks.
They must not automatically resend a source item. This requires a host containing
`dcd3d67d56fccebe273a82d3b72527356c1027dc` or the equivalent fix; running-host
support still needs separate validation.

When only some sources are readable, queue responses and Agent cards may include
an optional `nativeSourcesError` string. This is a partial source-read diagnostic,
not an error for the current queue or receipt. Current state, successful
item/attempt receipts, readable sources and their counts remain valid, and the
current `notice` is not replaced. Those counts can be incomplete, so
`nativeHistory` is not a complete-total guarantee. A source error never means
that no history exists, even when the count is zero. A missing error field means
no diagnostic was provided, not that history is complete. Current-queue
permission, version and read failures, and source full-item/hide failures, keep
their original error responses instead of becoming this diagnostic. Reporting
it requires `e078c23ee4d44fe5eddeea0d41ee04e6fc0aebc7` or the equivalent fix.
No ordinary-PTY source or recovery extension is defined by this contract.

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

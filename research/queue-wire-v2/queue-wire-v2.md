# Queue wire v2: bounded previews and full item reads

Incremental implementation contract, frozen on top of native handoff wire v1
(`a72e2704e9c1279ab809223364746543e54dda91`) and implementation
`748fc7207211a308f0aed41724b679aa03daeb34`. Native acceptance, unknown outcomes,
attempt identity, persistence and read-only restrictions keep their v1 meanings.

## Opt-in preview responses

Append exactly one `bounded=1` to GET `/api/agents/{run}/queue` and to any
existing queue write: POST/PUT/DELETE queue, PUT/DELETE queue/{id},
POST queue/{id}/send, POST queue/flush, DELETE queue/{id}/native.
Other values or repeated `bounded` parameters return 400 before a write starts.
No `bounded` parameter preserves the existing complete response protocol.

The response keeps its existing queue or receipt shape. Its root adds
`bounded:true` and `byteLimit:8388608`; the complete encoded JSON body, including
its final newline, is **strictly smaller than 8,388,608 bytes**. This covers
all items, later items, the receipt's duplicate item, hold/note/errors and
optional metadata together. A queue preview also includes `ws` (current
workspace ID) and `identity` (the current authoritative terminal-agent identity,
with the existing run/engine/pid/start/started/session shape). In a receipt these
two fields are inside `queue`. Identity can have an empty session when the
current native binding is unavailable; clients must not infer a replacement.

All entries, order, IDs, target identities, native states, counts, timestamps,
submit/parked flags and action references remain intact. Preview text can be a
UTF-8 prefix ending in `…`; clients must not depend on a fixed prefix length.
Only these display strings may be shortened:

| Object carrying `truncatedFields` | Allowed field paths |
| --- | --- |
| Each item (including receipt `item` and `later` entries) | `text`, `source`, `deliveryUnknown`, `native.note`, `origin.label`, `origin.why`, `pasted.placeholder` |
| Queue view | `hold`, `notice`, `laterError`, `pastedOut.text` |
| Receipt | `note` |
| Error body | `error`, `detail` |

Each object's optional `truncatedFields:string[]` lists exactly the fields
actually shortened in that object, using the paths above. Absent means empty.
Nested display paths are listed on their owning item/queue, not on `native`,
`origin` or `pastedOut`. Unknown future markers mean the associated value is
incomplete; never use a preview to send or overwrite stored text. Full stored
strings are unchanged. Credential masking before a shortened prefix uses the
existing chat truncation helper. Error status and machine code are preserved.

The byte budget is checked after ordinary Go JSON escaping. If identity/action
structure alone cannot fit (corrupt or out-of-contract historical data), return
a small 500 error with `code:"queue_response_too_large"`, never drop entries or
shorten identity. This is a representation error; do not retry a write with a
new attempt. `X-Loom-Attempt` keys ignore `bounded`: replaying the same attempt
with either representation never executes it again. A bounded cached outcome
must not become an incomplete legacy response on unbounded replay.

Example (only `text` shortened):

```json
{"delivered":false,"item":{"id":"q-example","text":"instruction…","submit":true,"created":"2026-11-16T00:00:00Z","native":{"state":"accepted","note":"Codex 已接收"},"truncatedFields":["text"]},"queue":{"run":"run-example","ws":"workspace-example","identity":{"run":"run-example","engine":"codex","pid":0,"start":"","started":"0001-01-01T00:00:00Z","session":"thread-example"},"state":"working","hold":"","items":[{"id":"q-example","text":"instruction…","submit":true,"created":"2026-11-16T00:00:00Z","native":{"state":"accepted","note":"Codex 已接收"},"truncatedFields":["text"]}],"later":[],"pending":0,"nativeHistory":1},"bounded":true,"byteLimit":8388608}
```

## Read one complete item

`GET /api/agents/{run}/queue/{id}` uses the same authentication, workspace and
private-run ownership rules as GET queue. It searches retained/pending `items`
and scheduled `later` by the original item ID. Moving a scheduled item into
`items` keeps that ID. This endpoint has no `bounded` mode: requesting it is a
full-text read, never a send, retry, cancellation, or queue edit.

```json
{"run":"run-example","ws":"workspace-example","identity":{"run":"run-example","engine":"codex","pid":0,"start":"","started":"0001-01-01T00:00:00Z","session":"thread-example"},"state":"working","ended":false,"later":false,"item":{"id":"q-example","text":"complete original instruction","submit":true,"created":"2026-11-16T00:00:00Z","native":{"state":"accepted","note":"Codex 已接收"}}}
```

`later:true` identifies a currently scheduled item. `identity` is the current
run binding; `item.target`, when present, stays the original item's binding.
Missing/removed/hidden items return 404 (also after delivery); they never return
an empty successful item or an actionable retry. A full response has no
`truncatedFields` and stays below 16,777,216 bytes for current admitted requests
(1 MiB request, 256 KiB text; native text 100 KiB, CLI diagnostics 4 KiB).
An out-of-contract item exceeding that response bound returns a small 500
`queue_item_too_large` error without truncating or changing the stored item.

## Client actions and late responses

Desktop queue calls opt into previews. Expand, copy and edit first read the
complete item by ID. A client binds this read to the captured host, workspace,
run, item ID, target and current identity, and discards late responses after
closing, switching host/workspace, refreshing/replacing the row, or changing
the item's revision, native/read-only status or scheduling class. Editing uses
only the fetched full text. Copy copies only fetched full text. Send, reorder,
withdraw and explicit hide continue to use IDs, never preview text.

Native rows offer view/copy and the existing explicit hide only; accepted,
unknown and unrecognized native states cannot be edited or sent. Preview/full
reads do not project chat. The original native transcript continues to supply
the real user message once through the existing transcript reader.

## Restored native sources (optional)

Queue views and their receipts may add `nativeSources` as an optional array of
`{sourceRun,target,nativeHistory}`. Each entry references an earlier run's
read-only handoffs with the same workspace, engine, native home and native
session. `sourceRun` is that original run; `target` retains its original
terminal-agent identity. No item body is copied into this reference or into the
resumed run.

Queue and Agent-card `nativeHistory` counts aggregate current-run and source
records. `items`, `later` and `pending` still belong only to the current run.
Missing or null `nativeSources` means the host did not provide this capability;
it does not prove that no earlier records exist.

A consumer reads the original queue and full items through the original
`sourceRun` endpoints. Explicit hide likewise uses the original run and item ID,
with the existing target, revision and owner checks. Sources never become
current send tasks and are not automatically resent. This extension requires a
host containing `dcd3d67d56fccebe273a82d3b72527356c1027dc` or the equivalent
fix, rather than merely an older queue-wire-v2 host.

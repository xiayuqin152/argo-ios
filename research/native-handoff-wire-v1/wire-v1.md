# Native handoff wire v1 (frozen for parallel iOS adaptation)

Base: 221c1a94c5b64eaee38594cd02ffb96c5a7ceaff. This document fixes the new public contract; existing PTY receipts retain their semantics.

- Original queue item keeps `id`, `text`, `submit`, `source`, `created`, `target` and adds optional `native: {state: "accepted" | "unknown", note: string}`. `target` is the original server-confirmed identity. Private NativeHome/terminal metadata stays on the server.
- POST `/api/agents/{run}/queue` native accepted/unknown returns HTTP 200, `delivered:false`, original `item` and current `queue`. `accepted` means “Codex 已接收”; `unknown` means “接收结果未知，请查看原会话”. Neither means native chat/model completion. Both are non-retryable, read-only handoff records; clients must branch on presence of `item.native` before ordinary queued/pasted handling. Unrecognized future native states are read-only unknown, never retryable.
- GET queue `items` includes ordinary pending items and native handoff records. New `pending` counts ordinary unsent items plus scheduled items; `nativeHistory` counts native records. Agent cards keep `queued` for pending only and add `nativeHistory` for the separate status entry. Native history does not count as “waiting to send”, but consumes the existing total capacity.
- POST replay uses existing `X-Loom-Attempt` semantics (same request/attempt); the original item ID is unchanged. No new idempotency protocol. Distinct explicit attempts with identical text remain distinct messages.
- Editing, single Send Now, and ordinary DELETE/clear of native rows return 409. Batch flush skips accepted records and stops at unknown; neither is handed over again. Reorder must leave native records at their current positions. No cross-thread migration. Accepted records do not block subsequent ordinary delivery; unknown retains conservative ordering until explicitly hidden.
- DELETE `/api/agents/{run}/queue/{id}/native` explicitly hides only that Argo handoff record. It does not cancel/retract Codex input. No resend or native cancellation button. Native records survive restart and original-identity changes without becoming sendable.
- Desktop queue/status entry shows the original body and native label; full body can be expanded. Native transcript stays on the existing response_item projection and appears once when Codex writes it. No event_msg duplication or guessed completion matching.

Accepted response (ordinary optional fields omitted):

```json
{"delivered":false,"item":{"id":"q-example","text":"mobile instruction","submit":true,"source":"ios","created":"2026-11-16T00:00:00Z","target":{"run":"run-example","engine":"codex","session":"thread-example"},"native":{"state":"accepted","note":"Codex 已接收；原生会话记录将在 Codex 开始处理后显示"}},"queue":{"run":"run-example","state":"working","hold":"","items":[{"id":"q-example","text":"mobile instruction","submit":true,"source":"ios","created":"2026-11-16T00:00:00Z","target":{"run":"run-example","engine":"codex","session":"thread-example"},"native":{"state":"accepted","note":"Codex 已接收；原生会话记录将在 Codex 开始处理后显示"}}],"later":[],"pending":0,"nativeHistory":1}}
```

Unknown uses the identical shape with `native.state:"unknown"`, an actionable `native.note`, `delivered:false`, and the original ID/body/target. Persistence errors return their existing error response; GET/restart conservatively retains the pre-written unknown record if the external call could have started. Do not offer retry on transport ambiguity.

Persistence: queue-session.json v2, not unversioned queue.json. v1 readers refuse v2. Before any native side effect persist unknown with the original identity; explicit success updates accepted. Save failure after the side effect retains unknown. A definitely unstarted/unsupported native call may restore the original pending item and use the existing PTY rules after that restoration is persisted.

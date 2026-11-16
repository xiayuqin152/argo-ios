#!/usr/bin/env python3
"""Record fixed Git source evidence only; this does not run a backend."""
import argparse
import hashlib
from pathlib import Path
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--repo", required=True)
a = p.parse_args()
product = "748fc7207211a308f0aed41724b679aa03daeb34"
wire = "a72e2704e9c1279ab809223364746543e54dda91"

def show(sha, path):
    return subprocess.check_output(["git", "-C", a.repo, "show", f"{sha}:{path}"])

frozen = show(wire, "research/native-handoff-visibility/wire-v1.md")
assert frozen == Path("research/native-handoff-wire-v1/wire-v1.md").read_bytes()
print(f"wire={wire} sha256={hashlib.sha256(frozen).hexdigest()} matches iOS frozen copy")
print(f"product={product}")
anchors = {
    "internal/server/queue.go": [
        'DeliveryUnknown string `json:"deliveryUnknown,omitempty"`',
        'Native *nativeHandoff `json:"native,omitempty"`',
        'Pending       int         `json:"pending"`',
        'NativeHistory int         `json:"nativeHistory"`',
        'Delivered bool       `json:"delivered"`',
        'Item      *queueItem `json:"item,omitempty"`',
        'Pending: pendingCount(items) + len(later), NativeHistory: nativeCount(items)',
        'return DeliverResult{Item: &item, Queue: h.view(run, q, t)}, nil',
        'mux.HandleFunc("DELETE /api/agents/{run}/queue/{id}/native", s.hideNativeQueueItem)',
    ],
    "internal/server/queue_native.go": [
        'State          string `json:"state"`', 'Note           string `json:"note"`',
        'nativeAccepted      = "accepted"', 'nativeUnknown       = "unknown"',
        'prepared.Target = &origin',
        'return DeliverResult{Item: &item, Queue: s.queue.view(run, q, t)}, true',
        'func (s *Server) hideNativeQueueItem',
        'q.doc.Items = slices.Delete(slices.Clone(q.doc.Items), i, i+1)',
        'return pendingCount(q.doc.Items) + len(q.later), nativeCount(q.doc.Items)',
    ],
    "internal/server/agent_view.go": [
        'NativeHistory int          `json:"nativeHistory,omitempty"`',
        'Queued        int          `json:"queued"`',
    ],
}
for path, needles in anchors.items():
    source = show(product, path).decode()
    print(f"blob={subprocess.check_output(['git', '-C', a.repo, 'rev-parse', f'{product}:{path}'], text=True).strip()} {path}")
    for needle in needles:
        matches = [(i, line.strip()) for i, line in enumerate(source.splitlines(), 1) if needle in line]
        assert matches, (path, needle)
        for line, value in matches:
            print(f"  {path}:{line}: {value}")
print("PASS static v1 source/endpoint check; no backend execution or end-to-end acceptance claimed")

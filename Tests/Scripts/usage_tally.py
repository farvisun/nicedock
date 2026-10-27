#!/usr/bin/env python3
"""Independent token tally over local Claude Code / Codex JSONL logs.

Cross-checks the app's byte-level scanner (ConnLogScanner) with a plain `json.loads` pass.
Usage: usage_tally.py <manifest.json>

The manifest is written by LocalLogsTests: {"source": "claude"|"codex", "start": <unix seconds>,
"files": {"<path>": <bytes the app consumed>}}. Only those first bytes of each file are read so
logs that keep growing (live sessions) still compare exactly. Prints one JSON object:
{"input", "output", "cacheWrite", "cacheRead", "calls", "lines"}.
"""
import json
import sys
from datetime import datetime


def epoch(ts):
    """'2026-10-27T00:25:33.123Z' -> int unix seconds (truncated, like the app)."""
    if not isinstance(ts, str) or not ts.endswith("Z"):
        return None
    try:
        return int(datetime.fromisoformat(ts[:-1] + "+00:00").timestamp())
    except ValueError:
        return None


def lines(path, limit):
    with open(path, "rb") as fh:
        data = fh.read(limit)
    for raw in data.split(b"\n"):
        if raw.strip():
            yield raw


def claude(files, start):
    """One entry per (message.id, requestId), keeping the line with the most output tokens."""
    keyed, loose, count = {}, [], 0
    for path, limit in files.items():
        for raw in lines(path, limit):
            if b'"usage"' not in raw:
                continue
            try:
                obj = json.loads(raw)
            except ValueError:
                continue
            msg = obj.get("message") if isinstance(obj, dict) else None
            usage = msg.get("usage") if isinstance(msg, dict) else None
            if not isinstance(usage, dict) or msg.get("model") == "<synthetic>":
                continue
            t = epoch(obj.get("timestamp"))
            if t is None or t < start:
                continue
            count += 1
            row = (
                usage.get("input_tokens") or 0,
                usage.get("output_tokens") or 0,
                usage.get("cache_creation_input_tokens") or 0,
                usage.get("cache_read_input_tokens") or 0,
            )
            key = (msg.get("id"), obj.get("requestId"))
            if key == (None, None):
                loose.append(row)
            elif key not in keyed or keyed[key][1] < row[1]:
                keyed[key] = row
    rows = list(keyed.values()) + loose
    return {
        "input": sum(r[0] for r in rows),
        "output": sum(r[1] for r in rows),
        "cacheWrite": sum(r[2] for r in rows),
        "cacheRead": sum(r[3] for r in rows),
        "calls": len(rows),
        "lines": count,
    }


def codex(files, start):
    """Sums `last_token_usage` of each token_count event whose running total moved."""
    out = {"input": 0, "output": 0, "cacheWrite": 0, "cacheRead": 0, "calls": 0, "lines": 0}
    for path, limit in files.items():
        previous = None
        for raw in lines(path, limit):
            if b'"token_count"' not in raw:
                continue
            try:
                obj = json.loads(raw)
            except ValueError:
                continue
            info = (obj.get("payload") or {}).get("info") or {}
            total = info.get("total_token_usage")
            last = info.get("last_token_usage") or {}
            if not isinstance(total, dict):
                continue
            running = (total.get("input_tokens", 0), total.get("cached_input_tokens", 0), total.get("output_tokens", 0))
            if running == previous:
                continue  # re-emitted event, nothing new was used
            previous = running
            inp, cached, output = last.get("input_tokens", 0), last.get("cached_input_tokens", 0), last.get("output_tokens", 0)
            t = epoch(obj.get("timestamp"))
            if inp + output <= 0 or t is None or t < start:
                continue
            out["lines"] += 1
            out["calls"] += 1
            out["input"] += max(inp - cached, 0)
            out["cacheRead"] += cached
            out["output"] += output
    return out


def main():
    manifest = json.load(open(sys.argv[1]))
    run = claude if manifest["source"] == "claude" else codex
    print(json.dumps(run(manifest["files"], int(manifest["start"]))))


if __name__ == "__main__":
    main()

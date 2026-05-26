from __future__ import annotations

import json
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from uuid import uuid4


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


class ThinkingStore:
    def __init__(self, path: str | Path):
        self.path = Path(path).expanduser()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()

    def append(
        self,
        *,
        turn_id: str,
        thinking: str,
        timestamp: str | None = None,
        session_id: str | None = None,
    ) -> dict[str, Any]:
        turn_id = str(turn_id or "").strip()
        if not turn_id:
            raise ValueError("turn_id required")
        if not isinstance(thinking, str) or not thinking.strip():
            raise ValueError("thinking required")

        record = {
            "id": uuid4().hex,
            "turn_id": turn_id,
            "thinking": thinking,
            "timestamp": str(timestamp or "").strip() or _utc_now_iso(),
            "session_id": str(session_id or "").strip(),
            "created_at": _utc_now_iso(),
        }
        line = json.dumps(record, ensure_ascii=False, separators=(",", ":"))
        with self._lock:
            with self.path.open("a", encoding="utf-8") as f:
                f.write(line + "\n")
        return record

    def read(self, *, turn_id: str | None = None, limit: int = 50) -> list[dict[str, Any]]:
        turn_id = str(turn_id or "").strip()
        limit = max(1, min(int(limit or 50), 500))
        if not self.path.exists():
            return []

        records: list[dict[str, Any]] = []
        with self._lock:
            for line in self.path.read_text(encoding="utf-8").splitlines():
                if not line.strip():
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if turn_id and record.get("turn_id") != turn_id:
                    continue
                records.append(record)
        return records[-limit:]

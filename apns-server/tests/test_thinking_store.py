from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from thinking_store import ThinkingStore


class ThinkingStoreTests(unittest.TestCase):
    def test_append_creates_jsonl(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            store = ThinkingStore(tmp_path / "state" / "thinking_log.jsonl")

            record = store.append(
                turn_id="turn-1",
                thinking="first raw thinking block",
                timestamp="2026-05-26T14:20:00Z",
                session_id="main",
            )

            self.assertEqual(record["turn_id"], "turn-1")
            self.assertEqual(record["thinking"], "first raw thinking block")
            lines = (tmp_path / "state" / "thinking_log.jsonl").read_text().splitlines()
            self.assertEqual(len(lines), 1)
            self.assertEqual(json.loads(lines[0])["session_id"], "main")

    def test_read_filters_by_turn_and_limit(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            store = ThinkingStore(tmp_path / "thinking_log.jsonl")
            store.append(turn_id="turn-1", thinking="old")
            store.append(turn_id="turn-2", thinking="other")
            store.append(turn_id="turn-1", thinking="new")

            records = store.read(turn_id="turn-1", limit=1)

            self.assertEqual(len(records), 1)
            self.assertEqual(records[0]["thinking"], "new")

    def test_append_rejects_missing_required_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            store = ThinkingStore(tmp_path / "thinking_log.jsonl")

            with self.assertRaisesRegex(ValueError, "turn_id"):
                store.append(turn_id="", thinking="raw")

            with self.assertRaisesRegex(ValueError, "thinking"):
                store.append(turn_id="turn-1", thinking=" ")


if __name__ == "__main__":
    unittest.main()

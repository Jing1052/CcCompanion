from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import claudep_bridge


class TextFromContentTests(unittest.TestCase):
    def test_string_passthrough(self):
        self.assertEqual(claudep_bridge.text_from_content("hi"), "hi")

    def test_multimodal_extracts_text_parts_only(self):
        content = [
            {"type": "text", "text": "看这张"},
            {"type": "image_url", "image_url": {"url": "data:..."}},
            {"type": "text", "text": "好看吗"},
        ]
        self.assertEqual(claudep_bridge.text_from_content(content), "看这张\n好看吗")

    def test_none_is_empty(self):
        self.assertEqual(claudep_bridge.text_from_content(None), "")


class RenderMessagesTests(unittest.TestCase):
    def test_single_user_is_prompt_verbatim(self):
        prompt, system_extra = claudep_bridge.render_messages(
            [{"role": "user", "content": "今天好累"}]
        )
        self.assertEqual(prompt, "今天好累")
        self.assertEqual(system_extra, "")

    def test_system_role_lifted_into_system_extra(self):
        prompt, system_extra = claudep_bridge.render_messages(
            [
                {"role": "system", "content": "你是Llaude"},
                {"role": "user", "content": "早"},
            ]
        )
        self.assertEqual(prompt, "早")
        self.assertEqual(system_extra, "你是Llaude")

    def test_multi_turn_history_becomes_context_block(self):
        prompt, _ = claudep_bridge.render_messages(
            [
                {"role": "user", "content": "早"},
                {"role": "assistant", "content": "早，小猫"},
                {"role": "user", "content": "想你了"},
            ]
        )
        self.assertIn("之前的对话", prompt)
        self.assertIn("Human: 早", prompt)
        self.assertIn("Assistant: 早，小猫", prompt)
        # 当前消息单独落地在末尾
        self.assertTrue(prompt.endswith("想你了"))

    def test_empty_messages(self):
        self.assertEqual(claudep_bridge.render_messages([]), ("", ""))


class ParseStreamLineTests(unittest.TestCase):
    def _ev(self, delta: dict) -> str:
        return json.dumps(
            {"type": "stream_event", "event": {"type": "content_block_delta", "delta": delta}}
        )

    def test_text_delta(self):
        line = self._ev({"type": "text_delta", "text": "小猫"})
        self.assertEqual(claudep_bridge.parse_stream_line(line), ("text", "小猫"))

    def test_thinking_delta(self):
        line = self._ev({"type": "thinking_delta", "thinking": "她又熬夜了"})
        self.assertEqual(
            claudep_bridge.parse_stream_line(line), ("thinking", "她又熬夜了")
        )

    def test_non_stream_event_ignored(self):
        self.assertIsNone(
            claudep_bridge.parse_stream_line(json.dumps({"type": "result", "result": "x"}))
        )

    def test_blank_and_garbage_ignored(self):
        self.assertIsNone(claudep_bridge.parse_stream_line(""))
        self.assertIsNone(claudep_bridge.parse_stream_line("not json"))

    def test_other_block_delta_type_ignored(self):
        line = self._ev({"type": "signature_delta", "signature": "x"})
        self.assertIsNone(claudep_bridge.parse_stream_line(line))


if __name__ == "__main__":
    unittest.main()

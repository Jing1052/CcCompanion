from __future__ import annotations

import sys
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import claudep_ext
import claudep_jobs


def _new_job():
    return {"t0": time.time(), "events": [], "done": False, "error": None}


def _py(script):
    return [sys.executable, "-u", "-c", script]


class ClaudepWatchdogTests(unittest.TestCase):
    """_run 的三条命路：卡死被杀、静默退出报错、正常流不受影响。
    2026-07-10 fable 卡死案：进程活着但零模型事件，旧代码只能陪它耗到网关 600s
    超时，App 十分钟死寂；stderr 进 DEVNULL 死因全吞。"""

    def setUp(self):
        self._cap = claudep_jobs._FIRST_EVENT_CAP
        self._cwd = claudep_ext._CWD
        claudep_ext._CWD = "/tmp"

    def tearDown(self):
        claudep_jobs._FIRST_EVENT_CAP = self._cap
        claudep_ext._CWD = self._cwd

    def test_stall_killed_by_watchdog(self):
        # init 行吐了（不算模型事件）然后闷死——watchdog 该在 cap 后杀掉并报错
        claudep_jobs._FIRST_EVENT_CAP = 2
        job = _new_job()
        t0 = time.time()
        claudep_jobs._run(job, _py(
            "import json,sys,time;"
            "print(json.dumps({'type':'system','subtype':'init','session_id':'s1'}));"
            "sys.stdout.flush();time.sleep(60)"), {}, "hi")
        self.assertTrue(job["done"])
        self.assertIn("没吐任何模型事件", job["error"] or "")
        self.assertLess(time.time() - t0, 30)  # 没陪它睡满 60s
        self.assertEqual(job["events"], [])

    def test_silent_exit_reports_error_with_stderr(self):
        # 一字未出直接退出（如 CLI 崩溃）——旧代码静默 done=空回复，现在如实报错带 stderr 尾
        job = _new_job()
        claudep_jobs._run(job, _py(
            "import sys;print('boom: model not available',file=sys.stderr);sys.exit(3)"),
            {}, "hi")
        self.assertTrue(job["done"])
        self.assertIn("一字未出", job["error"] or "")
        self.assertIn("boom: model not available", job["error"] or "")
        self.assertEqual(job["events"], [])

    def test_normal_stream_untouched(self):
        # 正常吐事件的路一根汗毛都不能少：content/reasoning 顺序、session、无 error
        claudep_jobs._FIRST_EVENT_CAP = 2  # 事件先到就绝不该误杀
        job = _new_job()
        claudep_jobs._run(job, _py(
            "import json,sys,time;"
            "w=lambda o:(print(json.dumps(o)),sys.stdout.flush());"
            "w({'type':'system','subtype':'init','session_id':'sid-x'});"
            "w({'type':'stream_event','event':{'type':'content_block_delta',"
            "'delta':{'type':'thinking_delta','thinking':'想'}}});"
            "time.sleep(3);"  # 事件到手后再拖过 cap，watchdog 不该动手
            "w({'type':'stream_event','event':{'type':'content_block_delta',"
            "'delta':{'type':'text_delta','text':'好'}}});"
            "w({'type':'result','result':'好','session_id':'sid-x'})"), {}, "hi")
        self.assertTrue(job["done"])
        self.assertIsNone(job["error"])
        self.assertEqual(job["session_id"], "sid-x")
        self.assertIn(["reasoning", "想"], job["events"])
        self.assertIn(["content", "好"], job["events"])

    def test_resume_silent_exit_still_falls_back(self):
        # resume 一字未出退出→仍要静默改跑全量（新 error 赋值不许挡住这条老路）
        job = _new_job()
        ok_cmd = _py(
            "import json,sys;"
            "print(json.dumps({'type':'stream_event','event':{'type':'content_block_delta',"
            "'delta':{'type':'text_delta','text':'全量好'}}}));sys.stdout.flush()")
        claudep_jobs._run(job, _py("import sys;sys.exit(0)"), {}, "hi",
                          fallback=(ok_cmd, "full-prompt"))
        self.assertTrue(job["done"])
        self.assertIsNone(job["error"])
        self.assertIn(["content", "全量好"], job["events"])


if __name__ == "__main__":
    unittest.main()

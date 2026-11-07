#!/usr/bin/env python3
"""阶段 3：规划会话、审阅页发布、go 关口与签名。python3 orc/tests/test_planning.py

规划会话（claude）、发布（codex）、签名校验（northstar）都换成可编排的假命令：
$ORC_FAKE/script 每行决定第几次规划运行做什么；$ORC_FAKE/publish 决定发布成功还是失败。
"""
import json
import os
import subprocess
import sys
import textwrap
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_orc import ORC, ORC_ROOT, OrcCase  # noqa: E402

FAKE_CLAUDE = r'''#!/usr/bin/env python3
import json, os, sys, time, pathlib
fake = pathlib.Path(os.environ["ORC_FAKE"])
args = sys.argv[1:]
if "-p" not in args:
    sys.exit(2)
prompt = sys.stdin.read()
n = len(list(fake.glob("call-*.json"))) + 1
session = args[args.index("--session-id") + 1] if "--session-id" in args else args[args.index("--resume") + 1]
(fake / f"call-{n}.json").write_text(json.dumps({"args": args, "cwd": os.getcwd(), "prompt": prompt,
    "role": os.environ.get("ORC_ROLE"), "mission": os.environ.get("ORC_MISSION")}))
script = [l for l in (fake / "script").read_text().splitlines() if l.strip()] if (fake / "script").exists() else []
action = script[n - 1] if n - 1 < len(script) else "ok"
work = pathlib.Path(os.getcwd())
if action.startswith("sleep:"):
    time.sleep(float(action.split(":")[1])); action = "ok"
def outputs(task_extra):
    (work / "design.md").write_text("# 设计\n\n## 关键决定\n- 用 CSV\n")
    (work / "plan.md").write_text("# 计划\n1. 导出\n")
    task = {"id": "export", "depends_on": [], "files": ["src/export.py"], "contracts": [],
            "verification": ["python -m pytest tests/test_export.py"], "state": "ready",
            "acceptance": ["导出 CSV"], "clauses": ["N1"], "component": "reports"}
    task.update(task_extra)
    (work / "task-dag.json").write_text(json.dumps({"version": 1, "mission": os.environ["ORC_MISSION"], "tasks": [task]}))
if action.startswith("question:"):
    (work / "QUESTION.md").write_text(action.split(":", 1)[1])
elif action == "ok":
    outputs({})
elif action == "ok+constraints":
    outputs({}); (work / "northstar-constraints.md").write_text("- N9: 导出只用标准库 csv\n")
elif action == "bad":
    outputs({"acceptance": []})
elif action == "crash":
    sys.exit(3)
print(json.dumps({"type": "result", "is_error": False, "session_id": session, "result": "done"}))
'''

FAKE_CODEX = r'''#!/usr/bin/env python3
import json, os, sys, pathlib
fake = pathlib.Path(os.environ["ORC_FAKE"])
calls = fake / "publish-calls"
calls.write_text(calls.read_text() + os.getcwd() + "\n" if calls.exists() else os.getcwd() + "\n")
mode = (fake / "publish").read_text().strip() if (fake / "publish").exists() else "ok"
if not pathlib.Path("dist/plan/index.html").is_file():
    print(json.dumps({"error": "no dist/plan/index.html"})); sys.exit(0)
print("working...")
if mode == "ok":
    print(json.dumps({"url": "https://plan.example.invalid/plan", "project_id": "proj-1"}))
else:
    print(json.dumps({"error": "Sites connector unavailable"}))
'''

FAKE_NORTHSTAR = r'''#!/bin/sh
# 假 northstar：verify-mission 在 $ORC_FAKE/sig-ok 存在且 control 里有签名文件时通过
[ "$1" = verify-mission ] && [ -f "$ORC_FAKE/sig-ok" ] && [ -f "$2/approved.sha256.sig" ]
'''


class PlanningCase(OrcCase):
    def setUp(self):
        super().setUp()
        self.fake = self.tmp / "fake"
        self.fake.mkdir()
        bin_ = self.tmp / "fakebin"
        bin_.mkdir()
        for name, body in (("claude", FAKE_CLAUDE), ("codex", FAKE_CODEX)):
            (bin_ / name).write_text(body.replace("#!/usr/bin/env python3", f"#!{sys.executable}", 1))
            (bin_ / name).chmod(0o755)
        ns = self.tmp / "ns"
        (ns / "bin").mkdir(parents=True)
        (ns / "bin" / "northstar").write_text(FAKE_NORTHSTAR)
        (ns / "bin" / "northstar").chmod(0o755)
        # 产品仓库带 NORTHSTAR：节点的 clauses 不能为空
        (self.repo / ".northstar").mkdir()
        (self.repo / ".northstar" / "NORTHSTAR.md").write_text("# NORTHSTAR\n- N1: 报表可以导出\n")
        self.env.update(ORC_FAKE=str(self.fake), ORC_NORTHSTAR_ROOT=str(ns),
                        ORC_WORKTREES=str(self.tmp / "wt"), PATH=f"{bin_}:/usr/bin:/bin")
        os.environ["ORC_WORKTREES"] = str(self.tmp / "wt")

    def tearDown(self):
        os.environ.pop("ORC_WORKTREES", None)
        super().tearDown()

    def script(self, *steps):
        (self.fake / "script").write_text("\n".join(steps) + "\n")

    def calls(self):
        return [json.loads(p.read_text()) for p in sorted(self.fake.glob("call-*.json"), key=lambda p: int(p.stem[5:]))]

    def step(self, name="m1"):
        return self.run_orc("step", "--mission", name)

    def wait(self, name="m1"):
        r = self.run_orc("wait", "--mission", name, "--timeout", "30")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def to_plan_review(self, *steps):
        self.script(*steps)
        r, mdir = self.new()
        self.assertEqual(self.next_line(r), "next: wait", r.stdout + r.stderr)
        self.wait()
        return mdir


class LaunchAndWait(PlanningCase):
    def test_planner_is_launched_sandboxed_with_plan_model(self):
        self.script("sleep:1")
        r, mdir = self.new()
        self.assertIn("启动规划会话", r.stdout)
        self.assertEqual(self.next_line(r), "next: wait")
        r2 = self.step()                       # 还在跑：不重复启动
        self.assertEqual(self.next_line(r2), "next: wait")
        self.wait()
        calls = self.calls()
        self.assertEqual(len(calls), 1)
        c = calls[0]
        models = json.loads((mdir / "models.json").read_text())["roles"]
        args = c["args"]
        self.assertEqual(args[args.index("--model") + 1], models["plan"]["model"])
        self.assertEqual(args[args.index("--effort") + 1], models["plan"]["effort"])
        self.assertIn("--session-id", args)
        work = self.tmp / "wt" / "m1" / "plan-work"
        self.assertEqual(os.path.realpath(c["cwd"]), os.path.realpath(work))   # 在 $ORC_HOME 之外
        settings = json.loads(next(a.split("=", 1)[1] for a in args if a.startswith("--settings=")))
        self.assertTrue(settings["sandbox"]["enabled"])
        self.assertTrue(settings["sandbox"]["failIfUnavailable"])
        self.assertFalse(settings["sandbox"]["allowUnsandboxedCommands"])
        allowed = next(a.split("=", 1)[1] for a in args if a.startswith("--allowedTools="))
        self.assertIn(f"Write(/{os.path.realpath(work)}/**)", allowed)
        self.assertNotIn(str(self.repo), allowed, "产品仓库不在可写范围")
        # 实测（2026-11-07）：--add-dir 会把目录加进沙箱的可写白名单，Bash 能写产品仓库。
        # 所以不用 --add-dir，并对产品仓库 denyWrite；读代码不受影响（Read / Grep / git log 实测可用）
        self.assertFalse([a for a in args if a.startswith("--add-dir")], "不能用 --add-dir")
        self.assertIn(os.path.realpath(self.repo), settings["sandbox"]["filesystem"]["denyWrite"])
        self.assertEqual(args[args.index("--permission-mode") + 1], "default")
        self.assertEqual((c["role"], c["mission"]), ("plan", "m1"))
        self.assertIn("Add CSV export", c["prompt"])
        self.assertIn("N1: 报表可以导出", c["prompt"])
        starts = [e for e in self.events(mdir) if e["kind"] == "planner-start"]
        self.assertEqual(len(starts), 1)

    def test_process_killed_without_rc_is_a_failure_not_running_forever(self):
        self.script("sleep:60", "ok")
        r, mdir = self.new()
        start = [e for e in self.events(mdir) if e["kind"] == "planner-start"][0]
        import time
        for _ in range(100):                    # 等假规划会话真正跑起来（写下调用记录）再杀
            if (self.fake / "call-1.json").exists():
                break
            time.sleep(0.05)
        os.killpg(start["pid"], 9)              # 进程被杀，没有留下退出码
        for _ in range(50):
            try:
                os.kill(start["pid"], 0)
                time.sleep(0.1)
            except ProcessLookupError:
                break
        r = self.step()
        self.assertEqual(self.next_line(r), "next: wait", r.stdout)     # 当作失败，发回同一个会话
        lost = [e for e in self.events(mdir) if e["kind"] == "planner-exit"][0]
        self.assertEqual((lost["rc"], lost["outcome"]), (None, "failed"))
        self.wait()
        r = self.step()
        self.assertTrue(self.next_line(r).startswith("next: go-gate "), r.stdout)

    def test_crash_with_nonzero_rc_is_retried_in_the_same_session(self):
        self.script("crash", "ok")
        r, mdir = self.new()
        self.wait()
        r = self.step()                        # 第 1 次失败：自动重跑（同一会话）
        self.assertEqual(self.next_line(r), "next: wait")
        self.wait()
        r = self.step()
        self.assertTrue(self.next_line(r).startswith("next: go-gate "), r.stdout)
        self.assertIn("--resume", self.calls()[1]["args"])


class Outputs(PlanningCase):
    def test_valid_outputs_go_to_plan_review_and_publish(self):
        mdir = self.to_plan_review("ok")
        r = self.step()
        self.assertEqual(self.next_line(r), "next: go-gate https://plan.example.invalid/plan", r.stdout + r.stderr)
        self.assertEqual((mdir / "state").read_text().strip(), "plan-review")
        for f in ("design.md", "plan.md", "task-dag.json"):
            self.assertTrue((mdir / "plan" / f).is_file(), f)
        kinds = [e["kind"] for e in self.events(mdir)]
        self.assertIn("plan-ready", kinds)
        self.assertIn("published", kinds)
        page = (self.tmp / "wt" / "m1" / "site" / "dist" / "plan" / "index.html").read_text()
        self.assertIn("用 CSV", page)
        self.assertIn("导出 CSV", page)               # DAG 的验收标准出现在审阅页
        r2 = self.step()                               # 页面没变：不重复发布
        self.assertEqual(self.next_line(r2), self.next_line(r))
        self.assertEqual(len((self.fake / "publish-calls").read_text().splitlines()), 1)

    def test_invalid_outputs_are_sent_back_then_mediated(self):
        mdir = self.to_plan_review("bad", "bad", "bad")
        for _ in range(2):                             # 自动修 2 次
            r = self.step()
            self.assertEqual(self.next_line(r), "next: wait")
            self.wait()
        r = self.step()
        self.assertTrue(self.next_line(r).startswith("next: mediate "), r.stdout)
        self.assertEqual((mdir / "state").read_text().strip(), "blocked")
        calls = self.calls()
        self.assertEqual(len(calls), 3)
        self.assertIn("acceptance", calls[1]["prompt"])     # 修复请求里写明了问题
        self.assertIn("--resume", calls[1]["args"])
        session = calls[0]["args"][calls[0]["args"].index("--session-id") + 1]
        self.assertEqual(calls[2]["args"][calls[2]["args"].index("--resume") + 1], session)

    def test_question_is_asked_and_answer_resumes_the_same_session(self):
        mdir = self.to_plan_review("question:导出要包含已删除的记录吗？", "ok")
        r = self.step()
        self.assertEqual(self.next_line(r), "next: ask-user 导出要包含已删除的记录吗？")
        self.assertEqual((mdir / "state").read_text().strip(), "blocked")
        self.assertEqual(self.run_orc("answer", "不包含").returncode, 0)
        r = self.step()
        self.assertEqual(self.next_line(r), "next: wait")
        self.wait()
        r = self.step()
        self.assertTrue(self.next_line(r).startswith("next: go-gate "), r.stdout)
        first, second = self.calls()
        session = first["args"][first["args"].index("--session-id") + 1]
        self.assertEqual(second["args"][second["args"].index("--resume") + 1], session)
        self.assertIn("不包含", second["prompt"])
        self.assertFalse((self.tmp / "wt" / "m1" / "plan-work" / "QUESTION.md").exists())


class Publish(PlanningCase):
    def test_publish_failure_never_offers_a_local_file(self):
        (self.fake / "publish").write_text("fail")
        mdir = self.to_plan_review("ok")
        r = self.step()
        self.assertTrue(self.next_line(r).startswith("next: error "), r.stdout)
        self.assertIn("Sites", self.next_line(r))
        self.assertNotIn("go-gate", r.stdout)
        self.assertEqual((mdir / "state").read_text().strip(), "plan-review")
        (self.fake / "publish").write_text("ok")
        r = self.step()
        self.assertTrue(self.next_line(r).startswith("next: go-gate https://"), r.stdout)


class ReviseAndGo(PlanningCase):
    def at_gate(self, *steps):
        mdir = self.to_plan_review(*steps)
        r = self.step()
        self.assertTrue(self.next_line(r).startswith("next: go-gate "), r.stdout + r.stderr)
        return mdir

    def test_revise_resumes_planner_with_feedback(self):
        mdir = self.at_gate("ok", "ok")
        r = self.run_orc("revise", "--mission", "m1", "再加一个按日期筛选")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((mdir / "state").read_text().strip(), "planning")
        r = self.step()
        self.assertEqual(self.next_line(r), "next: wait")
        self.wait()
        self.assertIn("再加一个按日期筛选", self.calls()[1]["prompt"])
        self.assertIn("--resume", self.calls()[1]["args"])
        r = self.step()
        self.assertTrue(self.next_line(r).startswith("next: go-gate "), r.stdout)

    def test_go_freezes_four_files_then_waits_for_signature(self):
        mdir = self.at_gate("ok")
        r = self.run_orc("go", "--mission", "m1")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        control = os.path.realpath(mdir / "control")
        self.assertIn(f"northstar approve-mission {control}", r.stdout)
        self.assertEqual(self.next_line(r), f"next: sign {control}")
        c = Path(control)
        self.assertEqual((c / "approved-design.md").read_bytes(), (mdir / "plan" / "design.md").read_bytes())
        self.assertEqual((c / "approved-plan.md").read_bytes(), (mdir / "plan" / "plan.md").read_bytes())
        self.assertTrue((c / "brief-exec.md").read_text().startswith("# 执行规则：mission m1"))
        names = sorted(l.split()[1] for l in (c / "approved.sha256").read_text().splitlines())
        self.assertEqual(names, ["approved-design.md", "approved-plan.md", "approved-task-dag.json", "brief-exec.md"])
        ok = subprocess.run([sys.executable, str(ORC_ROOT / "scripts" / "verify-approved-authority.py"),
                             "--control-dir", control], capture_output=True, text=True)
        self.assertEqual(ok.returncode, 0, ok.stderr)
        self.assertIn("frozen", [e["kind"] for e in self.events(mdir)])
        # 没签名：停在 plan-review，一直提示签名
        for _ in range(2):
            r = self.step()
            self.assertEqual(self.next_line(r), f"next: sign {control}")
        self.assertEqual((mdir / "state").read_text().strip(), "plan-review")
        # go 之后不能再改
        r = self.run_orc("revise", "--mission", "m1", "x")
        self.assertIn("已经冻结", r.stderr)
        r = self.run_orc("go", "--mission", "m1")
        self.assertIn("已经冻结", self.next_line(r) + r.stderr)

    def test_invalid_signature_stays_in_plan_review(self):
        mdir = self.at_gate("ok")
        self.run_orc("go", "--mission", "m1")
        (mdir / "control" / "approved.sha256.sig").write_text("forged\n")   # 签名文件在，但校验不过
        r = self.step()
        self.assertTrue(self.next_line(r).startswith("next: error "), r.stdout)
        self.assertIn("签名", self.next_line(r))
        self.assertEqual((mdir / "state").read_text().strip(), "plan-review")

    def test_valid_signature_enters_approved(self):
        mdir = self.at_gate("ok")
        self.run_orc("go", "--mission", "m1")
        (mdir / "control" / "approved.sha256.sig").write_text("sig\n")
        (self.fake / "sig-ok").write_text("")
        r = self.step()
        self.assertIn("plan-review → approved", r.stdout)
        self.assertIn("approved", [e.get("to") for e in self.events(mdir) if e["kind"] == "state"])

    def test_tampered_after_go_is_caught_before_approved(self):
        mdir = self.at_gate("ok")
        self.run_orc("go", "--mission", "m1")
        (mdir / "control" / "approved.sha256.sig").write_text("sig\n")
        (self.fake / "sig-ok").write_text("")
        path = mdir / "control" / "approved-plan.md"
        path.chmod(0o644)
        path.write_text("改过的计划\n")
        r = self.step()
        self.assertTrue(self.next_line(r).startswith("next: error "), r.stdout)
        self.assertEqual((mdir / "state").read_text().strip(), "plan-review")

    def test_go_refused_before_review_page_is_published(self):
        (self.fake / "publish").write_text("fail")
        mdir = self.to_plan_review("ok")
        self.step()
        r = self.run_orc("go", "--mission", "m1")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("审阅页还没有发布", self.next_line(r) + r.stderr)
        self.assertFalse((mdir / "control" / "approved.sha256").exists())

    def test_constraints_are_drafted_into_product_northstar(self):
        self.at_gate("ok+constraints")
        r = self.run_orc("go", "--mission", "m1")
        drafted = (self.repo / "drafts" / "NORTHSTAR.md").read_text()
        self.assertIn("N1: 报表可以导出", drafted)
        self.assertIn("N9: 导出只用标准库 csv", drafted)
        self.assertIn("northstar seal", r.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)

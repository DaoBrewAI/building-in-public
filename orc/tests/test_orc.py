#!/usr/bin/env python3
"""orc 骨架的测试：python3 orc/tests/test_orc.py（只用标准库；3.9 和 3.11+ 都要过）。

每个测试用独立的 ORC_HOME 和临时产品仓库，不碰 ~/.orc、/opt/northstar 或真实的 git 全局配置。
"""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ORC_ROOT = Path(__file__).resolve().parents[1]
ORC = ORC_ROOT / "bin" / "orc"


def load_orc():
    loader = importlib.machinery.SourceFileLoader("orc_cli", str(ORC))
    spec = importlib.util.spec_from_loader("orc_cli", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class OrcCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(os.path.realpath(tempfile.mkdtemp(prefix="orc-test-")))
        self.home = self.tmp / "orc-home"
        self.repo = self.tmp / "product"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        self.env = dict(os.environ, ORC_HOME=str(self.home),
                        GIT_CONFIG_GLOBAL=str(self.tmp / "gitconfig"), GIT_CONFIG_NOSYSTEM="1")
        (self.tmp / "gitconfig").write_text("")
        self._saved = {k: os.environ.get(k) for k in ("ORC_HOME",)}
        os.environ["ORC_HOME"] = str(self.home)
        self.orc = load_orc()

    def tearDown(self):
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_orc(self, *args, env=None):
        return subprocess.run([sys.executable, str(ORC), *args], capture_output=True, text=True,
                              env=env or self.env, cwd=str(self.repo))

    def new(self, name="m1", request="Add CSV export"):
        r = self.run_orc("step", "--new", request, "--name", name, "--repo", str(self.repo))
        return r, self.home / "missions" / name

    def events(self, mdir):
        return [json.loads(l) for l in (mdir / "events.jsonl").read_text().splitlines() if l.strip()]

    @staticmethod
    def next_line(r):
        lines = [l for l in r.stdout.splitlines() if l.startswith("next: ")]
        return lines[-1] if lines else ""


class StepNew(OrcCase):
    def test_new_mission_reaches_planning_with_correct_next(self):
        r, mdir = self.new()
        self.assertIn("new → planning", r.stdout)
        self.assertTrue(self.next_line(r).startswith("next: error 规划会话还没有实现（PLAN 阶段 3）"), r.stdout)
        self.assertIn("orc step --mission m1", self.next_line(r))
        self.assertEqual(r.stdout.strip().splitlines()[-1], self.next_line(r), "next: 必须是最后一行")
        self.assertEqual((mdir / "state").read_text().strip(), "planning")
        self.assertEqual((mdir / "request.md").read_text().strip(), "Add CSV export")
        self.assertEqual((mdir / "repo").read_text().strip(), str(self.repo))
        kinds = [(e["kind"], e.get("to")) for e in self.events(mdir)]
        self.assertEqual(kinds, [("created", None), ("state", "planning")])
        for sub in ("control", "control/tasks", "nodes", "questions", "answers", "plan"):
            self.assertTrue((mdir / sub).is_dir(), sub)

    def test_models_are_recorded_at_start_and_not_reread(self):
        _, mdir = self.new()
        models = json.loads((mdir / "models.json").read_text())
        self.assertEqual(models["roles"]["implement"]["cli"], "codex")
        self.assertEqual(models["roles"]["plan_review"]["cli"], "claude")
        self.assertTrue(models["roles"]["implement"]["model"])
        created = self.events(mdir)[0]
        self.assertEqual(len(created["models"]), 64)
        # 之后 models.toml 被改坏，运行中的 mission 不受影响
        bad = self.tmp / "bad.toml"
        bad.write_text("[implement]\n")
        env = dict(self.env, ORC_MODELS_TOML=str(bad))
        r = self.run_orc("step", "--mission", "m1", env=env)
        self.assertIn("规划会话还没有实现", r.stdout)
        self.assertEqual(json.loads((mdir / "models.json").read_text())["roles"], models["roles"])

    def test_generated_name_and_default_repo(self):
        r = self.run_orc("step", "--new", "Fix the login bug")
        self.assertEqual(r.returncode, 1)   # 停在 planning（规划未实现）时 next 是 error
        names = os.listdir(self.home / "missions")
        self.assertEqual(len(names), 1)
        self.assertRegex(names[0], r"^\d{8}-\d{6}-fix-the-login-bug$")
        repo = (self.home / "missions" / names[0] / "repo").read_text().strip()
        self.assertEqual(repo, str(self.repo))

    def test_refusals_say_what_is_wrong_and_what_to_do(self):
        self.new()
        cases = [
            (("step", "--new", "x", "--name", "m1", "--repo", str(self.repo)), "已经存在"),
            (("step", "--new", "x", "--name", "Bad_Name", "--repo", str(self.repo)), "不合法"),
            (("step", "--new", "x", "--repo", str(self.tmp)), "不是 git 仓库"),
            (("step", "--new", "   ", "--repo", str(self.repo)), "请求是空的"),
            (("step", "--mission", "nope"), "orc step --new"),
            (("step",), "--new"),
        ]
        for args, expect in cases:
            r = self.run_orc(*args)
            self.assertEqual(r.returncode, 1, args)
            self.assertTrue(self.next_line(r).startswith("next: error "), (args, r.stdout, r.stderr))
            self.assertIn(expect, self.next_line(r), args)

    def test_orc_writes_nothing_into_the_product_repo(self):
        self.new()
        status = subprocess.run(["git", "-C", str(self.repo), "status", "--porcelain", "--ignored"],
                                capture_output=True, text=True).stdout
        self.assertEqual(status, "")


class StepRepeatAndResume(OrcCase):
    def test_repeated_step_is_identical_and_adds_no_events(self):
        _, mdir = self.new()
        before = (mdir / "events.jsonl").read_text()
        r1 = self.run_orc("step", "--mission", "m1")
        r2 = self.run_orc("step", "--mission", "m1")
        self.assertEqual(r1.stdout, r2.stdout)
        self.assertEqual((r1.returncode, r2.returncode), (1, 1))
        self.assertEqual((mdir / "events.jsonl").read_text(), before)

    def test_interrupted_after_event_before_state_is_repaired_from_log(self):
        _, mdir = self.new()
        (mdir / "state").write_text("new\n")   # 中断在「写日志」和「写 state」之间
        r = self.run_orc("step", "--mission", "m1")
        self.assertEqual((mdir / "state").read_text().strip(), "planning")
        self.assertNotIn("new → planning", r.stdout, "日志里已经有这次转换，不应再做一次")
        self.assertEqual(sum(1 for e in self.events(mdir) if e["kind"] == "state"), 1)

    def test_interrupted_before_first_step_resumes(self):
        _, mdir = self.new()
        lines = (mdir / "events.jsonl").read_text().splitlines()
        (mdir / "events.jsonl").write_text(lines[0] + "\n")   # 只有 created：还没走第一步
        (mdir / "state").unlink()
        r = self.run_orc("step", "--mission", "m1")
        self.assertIn("new → planning", r.stdout)
        self.assertEqual((mdir / "state").read_text().strip(), "planning")

    def test_corrupt_event_log_is_reported_not_rewritten(self):
        _, mdir = self.new()
        with open(mdir / "events.jsonl", "a") as f:
            f.write("{not json\n")
        r = self.run_orc("step", "--mission", "m1")
        self.assertIn("不是合法 JSON", self.next_line(r))
        self.assertIn("{not json", (mdir / "events.jsonl").read_text())

    def test_step_waits_for_the_shared_lifecycle_lock(self):
        _, mdir = self.new()
        control = os.path.realpath(mdir / "control")
        holder = subprocess.Popen([sys.executable, "-c", (
            "import importlib.util,sys,time,pathlib\n"
            f"s=importlib.util.spec_from_file_location('l','{ORC_ROOT}/scripts/coordinator_lifecycle_lock.py')\n"
            "m=importlib.util.module_from_spec(s); s.loader.exec_module(m)\n"
            f"fd=m.acquire_lifecycle_lock(pathlib.Path('{control}'))\n"
            "print('held', flush=True); time.sleep(1.5); m.release_lifecycle_lock(fd)\n")],
            stdout=subprocess.PIPE, text=True)
        self.assertEqual(holder.stdout.readline().strip(), "held")
        start = time.monotonic()
        self.run_orc("step", "--mission", "m1")
        waited = time.monotonic() - start
        holder.wait()
        self.assertGreater(waited, 1.0, "broker / integrate 拿着锁时 orc step 必须等待")


class Transitions(OrcCase):
    def test_only_legal_transitions(self):
        self.new()
        m = self.orc.Mission("m1")
        with m:
            with self.assertRaises(self.orc.OrcError) as ctx:
                m.transition("executing", "test")
            self.assertIn("不允许从 planning 转到 executing", str(ctx.exception))
            m.transition("plan-review", "test")
            m.transition("planning", "test")      # 审阅时打回重新规划
            m.transition("failed", "test", reason="测试")
            with self.assertRaises(self.orc.OrcError):
                m.transition("planning", "test")  # failed 是终态

    def test_blocked_question_answer_and_resume(self):
        _, mdir = self.new()
        m = self.orc.Mission("m1")
        with m:
            m.transition("blocked", "test", reason="熔断")
            q = m.ask("节点 n1 连续 3 次偏离，要调整目标吗？", "ask-user", "test")
        r = self.run_orc("step", "--mission", "m1")
        self.assertEqual(self.next_line(r), "next: ask-user 节点 n1 连续 3 次偏离，要调整目标吗？")
        self.assertEqual(r.returncode, 0)
        r = self.run_orc("answer", "不调整，继续")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((mdir / "answers" / q.name).read_text().strip(), "不调整，继续")
        r = self.run_orc("step", "--mission", "m1")
        self.assertIn("blocked → planning", r.stdout)
        self.assertEqual((mdir / "state").read_text().strip(), "planning")
        kinds = [e["kind"] for e in self.events(mdir)]
        self.assertEqual(kinds, ["created", "state", "state", "ask", "answer", "state"])

    def test_answer_refusals(self):
        self.new("m1")
        r = self.run_orc("answer", "x")
        self.assertIn("没有等待回答的问题", r.stderr)
        self.new("m2")
        for name in ("m1", "m2"):
            with self.orc.Mission(name) as m:
                m.ask("问题", "mediate", "test")
        r = self.run_orc("answer", "x")
        self.assertIn("有多个 mission 在等回答", r.stderr)
        r = self.run_orc("answer", "--mission", "m1", "--file", str(self.tmp / "nope.md"), "x")
        self.assertIn("不是 mission m1 里等待回答的问题", r.stderr)
        r = self.run_orc("answer", "--mission", "m1", "  ")
        self.assertIn("回答是空的", r.stderr)


class NodeStates(OrcCase):
    def test_node_states_are_derived_from_protocol_files(self):
        _, mdir = self.new()
        tasks = [{"id": i, "depends_on": [], "files": [f"{i}.txt"], "contracts": [],
                  "verification": ["true"], "state": "ready"} for i in ("a", "b", "c", "d", "e", "f")]
        (mdir / "control" / "approved-task-dag.json").write_text(json.dumps({"version": 1, "mission": "m1", "tasks": tasks}))
        ctl, work = mdir / "control" / "tasks", mdir / "nodes"
        for node, state in (("b", "ready"), ("c", "ready"), ("d", "integrated"), ("e", "ready"), ("f", "ready")):
            (ctl / node).mkdir(parents=True)
            (ctl / node / "state").write_text(state + "\n")
        (work / "c").mkdir(parents=True)
        (work / "c" / "state").write_text("completed\n")
        (ctl / "e" / "unresolved-rework").write_text("")
        (ctl / "f" / "blocked").write_text("熔断\n")
        states = self.orc.Mission("m1").node_states()
        self.assertEqual(states, {"a": "pending", "b": "running", "c": "submitted",
                                  "d": "integrated", "e": "rework", "f": "blocked"})
        r = self.run_orc("status", "--mission", "m1")
        self.assertIn("a=pending，b=running，c=submitted，d=integrated，e=rework，f=blocked", r.stdout)


class Models(OrcCase):
    def test_minimal_parser_matches_tomllib_on_the_real_config(self):
        text = (ORC_ROOT / "config" / "models.toml").read_text()
        minimal = self.orc.parse_toml_minimal(text)
        self.assertEqual(set(minimal), {"implement", "plan_review"})
        try:
            import tomllib
        except ModuleNotFoundError:
            self.skipTest("这个 Python 没有 tomllib，只验证最小解析器")
        self.assertEqual(minimal, tomllib.loads(text))

    def test_config_errors_say_what_to_fix(self):
        cases = [
            ("[implement]\ncli = \"codex\"\nmodel = \"m\"\neffort = \"high\"\n", "缺少 [plan_review]"),
            ("[implement]\ncli = \"codex\"\nmodel = \"m\"\neffort = \"high\"\n[plan_review]\ncli = \"claude\"\n", "缺少 model, effort"),
            ("[implement]\ncli = \"claude\"\nmodel = \"m\"\neffort = \"h\"\n[plan_review]\ncli = \"claude\"\nmodel = \"m\"\neffort = \"h\"\n", "交叉评审"),
        ]
        for text, expect in cases:
            p = self.tmp / "m.toml"
            p.write_text(text)
            with self.assertRaises(self.orc.OrcError) as ctx:
                self.orc.resolve_models(p)
            self.assertIn(expect, str(ctx.exception))
        with self.assertRaises(self.orc.OrcError) as ctx:
            self.orc.resolve_models(self.tmp / "missing.toml")
        self.assertIn("找不到模型配置", str(ctx.exception))


class Doctor(OrcCase):
    def fake_install(self):
        ns = self.tmp / "opt-northstar"
        (ns / "bin").mkdir(parents=True)
        (ns / "hooks").mkdir()
        (ns / "git").mkdir()
        (ns / "bin" / "northstar").write_text("#!/bin/sh\n")
        (ns / "bin" / "northstar").chmod(0o755)
        for h in ("guard.sh", "align.sh", "inject.sh", "stop-gate.sh"):
            (ns / "hooks" / h).write_text("")
        managed = self.tmp / "managed-settings.json"
        managed.write_text('{"hooks": {"PreToolUse": [{"hooks": [{"command": "/opt/northstar/hooks/guard.sh"}]}]}}')
        codex = self.tmp / "codex-hooks.json"
        codex.write_text(managed.read_text())
        subprocess.run(["git", "config", "--global", "core.hooksPath", str(ns / "git")], env=self.env, check=True)
        fakebin = self.tmp / "fakebin"
        fakebin.mkdir()
        for c in ("codex", "claude", "jq"):
            (fakebin / c).write_text("#!/bin/sh\necho ok\n")
            (fakebin / c).chmod(0o755)
        return dict(self.env, ORC_NORTHSTAR_ROOT=str(ns), ORC_CLAUDE_MANAGED_SETTINGS=str(managed),
                    ORC_CODEX_HOOKS=str(codex), PATH=f"{fakebin}:{os.environ['PATH']}")

    def test_all_good(self):
        env = self.fake_install()
        r = self.run_orc("doctor", env=env)
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertNotIn("FAIL", r.stdout)
        self.assertIn("warn  Sites 发布", r.stdout)
        self.assertIn("orc doctor --live", r.stdout)

    def test_live_calls_each_model_once(self):
        env = self.fake_install()
        r = self.run_orc("doctor", "--live", env=env)
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("ok  模型可用：implement", r.stdout)
        self.assertIn("ok  模型可用：plan_review", r.stdout)

    def test_missing_trust_layer_fails_with_fix(self):
        env = self.fake_install()
        shutil.rmtree(Path(env["ORC_NORTHSTAR_ROOT"]) / "hooks")
        Path(env["ORC_CODEX_HOOKS"]).write_text("{}")
        r = self.run_orc("doctor", env=env)
        self.assertEqual(r.returncode, 1)
        self.assertIn("FAIL  信任层：四个 hook 脚本", r.stdout)
        self.assertIn("重新运行 install.sh", r.stdout)
        self.assertIn("FAIL  信任层：Codex 已注册 hook", r.stdout)
        self.assertIn("有 2 项未通过", r.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)

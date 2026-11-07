#!/usr/bin/env python3
"""orc 骨架的测试：python3 orc/tests/test_orc.py（只用标准库；3.9 和 3.11+ 都要过）。

每个测试用独立的 ORC_HOME 和临时产品仓库，不碰 ~/.orc、/opt/northstar 或真实的 git 全局配置。
"""
import importlib.machinery
import importlib.util
import hashlib
import json
import os
import shutil
import signal
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
        # 阶段 3 起，进入 planning 会在后台启动规划会话（claude）。这里放一个只会等待的假 claude，
        # 绝不调用真实模型；tearDown 时按 planner-start 事件里的 pid 结束它们
        basebin = self.tmp / "basebin"
        basebin.mkdir()
        (basebin / "claude").write_text("#!/bin/sh\nexec sleep 300\n")
        (basebin / "claude").chmod(0o755)
        self.env = dict(os.environ, ORC_HOME=str(self.home), ORC_WORKTREES=str(self.tmp / "worktrees"),
                        GIT_CONFIG_GLOBAL=str(self.tmp / "gitconfig"), GIT_CONFIG_NOSYSTEM="1",
                        PATH=f"{basebin}:{os.environ['PATH']}")
        (self.tmp / "gitconfig").write_text("")
        self._saved = {k: os.environ.get(k) for k in ("ORC_HOME",)}
        os.environ["ORC_HOME"] = str(self.home)
        self.orc = load_orc()

    def tearDown(self):
        for events in self.home.glob("missions/*/events.jsonl"):
            for line in events.read_text().splitlines():
                try:
                    event = json.loads(line)
                except ValueError:
                    continue            # 有的测试故意写坏日志
                if isinstance(event, dict) and event.get("kind") in ("planner-start", "verifier-start"):
                    try:
                        os.killpg(event["pid"], signal.SIGTERM)
                    except (ProcessLookupError, PermissionError):
                        pass
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
        # 阶段 3 起：进入 planning 后启动规划会话，next 是 wait（阶段 2 时是“规划未实现”的 error）
        r, mdir = self.new()
        self.assertIn("new → planning", r.stdout)
        self.assertEqual(self.next_line(r), "next: wait", r.stdout + r.stderr)
        self.assertEqual(r.stdout.strip().splitlines()[-1], self.next_line(r), "next: 必须是最后一行")
        self.assertEqual((mdir / "state").read_text().strip(), "planning")
        self.assertEqual((mdir / "request.md").read_text().strip(), "Add CSV export")
        self.assertEqual((mdir / "repo").read_text().strip(), str(self.repo))
        kinds = [(e["kind"], e.get("to")) for e in self.events(mdir)]
        self.assertEqual(kinds, [("created", None), ("state", "planning"), ("planner-start", None)])
        for sub in ("control", "control/tasks", "nodes", "questions", "answers", "plan"):
            self.assertTrue((mdir / sub).is_dir(), sub)

    def test_models_are_recorded_at_start_and_not_reread(self):
        _, mdir = self.new()
        models = json.loads((mdir / "models.json").read_text())
        self.assertEqual(set(models["roles"]), {"implement", "plan", "review", "review_light"})
        self.assertEqual(models["roles"]["implement"]["cli"], "claude")
        self.assertNotEqual(models["roles"]["review"]["model"], models["roles"]["implement"]["model"])
        self.assertTrue(models["roles"]["implement"]["model"])
        created = self.events(mdir)[0]
        self.assertEqual(len(created["models"]), 64)
        # 之后 models.toml 被改坏，运行中的 mission 不受影响
        bad = self.tmp / "bad.toml"
        bad.write_text("[implement]\n")
        env = dict(self.env, ORC_MODELS_TOML=str(bad))
        r = self.run_orc("step", "--mission", "m1", env=env)
        self.assertEqual(self.next_line(r), "next: wait", r.stdout + r.stderr)
        self.assertEqual(json.loads((mdir / "models.json").read_text())["roles"], models["roles"])

    def test_generated_name_and_default_repo(self):
        r = self.run_orc("step", "--new", "Fix the login bug")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)   # 规划会话在后台运行：next: wait
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
        self.assertEqual((r1.returncode, r2.returncode), (0, 0))   # 规划会话在跑：两次都是 next: wait
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
            with self.assertRaises(self.orc.OrcError):
                m.transition("plan-review", "test")   # 不能跳过验证（实现前写好验收测试）
            m.transition("verifying", "test")
            m.transition("plan-review", "test")
            m.transition("planning", "test")      # 审阅时打回重新规划
            m.transition("failed", "test", reason="测试")
            with self.assertRaises(self.orc.OrcError):
                m.transition("planning", "test")  # failed 是终态

    def test_blocked_question_answer_and_resume(self):
        _, mdir = self.new()
        m = self.orc.Mission("m1")
        with m:
            q = m.block("熔断", "节点 n1 连续 3 次偏离，要调整目标吗？", "ask-user", "test")
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
        self.assertEqual(kinds, ["created", "state", "planner-start", "ask", "state", "answer", "state"])

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


class ForgedLog(OrcCase):
    """评审意见 1a：状态只认合法的、首尾相接的转换；日志被追加伪造的状态事件时停下，不按它走。"""

    def forge(self, mdir, **event):
        line = {"ts": "x", "mission": "m1", "kind": "state", "by": "agent", **event}
        with open(mdir / "events.jsonl", "a") as f:
            f.write(json.dumps(line) + "\n")

    def test_jump_to_accepted_is_rejected(self):
        _, mdir = self.new()
        forged_line = len((mdir / "events.jsonl").read_text().splitlines()) + 1
        self.forge(mdir, **{"from": "planning", "to": "accepted"})
        r = self.run_orc("step", "--mission", "m1")
        self.assertIn("不是合法的状态转换", self.next_line(r))
        self.assertIn(f"第 {forged_line} 行", self.next_line(r))
        r = self.run_orc("status")
        self.assertNotIn("m1  accepted", r.stdout)
        self.assertIn("m1  日志无法回放", r.stdout)

    def test_from_must_match_previous_state(self):
        _, mdir = self.new()
        self.forge(mdir, **{"from": "plan-review", "to": "approved"})   # 单看是合法转换，但当时状态是 planning
        r = self.run_orc("step", "--mission", "m1")
        self.assertIn("当时的状态是 planning", self.next_line(r))

    def test_forged_blocked_without_question_and_forged_unblock(self):
        _, mdir = self.new()
        self.forge(mdir, **{"from": "planning", "to": "blocked"})       # 没有 question 的 blocked
        r = self.run_orc("step", "--mission", "m1")
        self.assertIn("不是合法的状态转换", self.next_line(r))


class BlockedNeedsQuestion(OrcCase):
    """评审意见 2：进入 blocked 必须带一个问题；离开 blocked 必须有这个问题的回答。"""

    def test_transition_to_blocked_without_question_is_refused(self):
        self.new()
        with self.orc.Mission("m1") as m:
            with self.assertRaises(self.orc.OrcError) as ctx:
                m.transition("blocked", "test", reason="熔断：节点连续 3 次 DRIFT")
            self.assertIn("block()", str(ctx.exception))
        r = self.run_orc("step", "--mission", "m1")
        self.assertNotIn("blocked → planning", r.stdout)

    def test_blocked_stays_until_its_own_question_is_answered(self):
        _, mdir = self.new()
        with self.orc.Mission("m1") as m:
            m.ask("一个无关的旧问题", "mediate", "test")
        self.run_orc("answer", "无关回答")
        with self.orc.Mission("m1") as m:
            m.block("熔断", "要调整目标吗？", "ask-user", "test")
        for _ in range(2):
            r = self.run_orc("step", "--mission", "m1")
            self.assertEqual(self.next_line(r), "next: ask-user 要调整目标吗？")
        self.assertEqual((mdir / "state").read_text().strip(), "blocked")
        self.run_orc("answer", "不调整")
        r = self.run_orc("step", "--mission", "m1")
        self.assertIn("blocked → planning", r.stdout)

    def test_mediate_question_prints_mediate_with_file(self):
        _, mdir = self.new()
        with self.orc.Mission("m1") as m:
            q = m.block("子任务提问", "接口用 v1 还是 v2？", "mediate", "test")
        r = self.run_orc("step", "--mission", "m1")
        self.assertEqual(self.next_line(r), f"next: mediate {q}")


class ApprovalReverified(OrcCase):
    """评审意见 1c：approved 之后的每一次 step 都重新校验签名和哈希。"""

    def setUp(self):
        super().setUp()
        _, self.mdir = self.new()
        c = self.mdir / "control"
        (c / "approved-design.md").write_text("design\n")
        (c / "approved-plan.md").write_text("plan\n")
        tests = c / "approved-tests" / "tests"
        tests.mkdir(parents=True)
        (tests / "test_a.py").write_text("def test_a(): assert open('a.txt').read() == 'a'\n")
        test_hash = hashlib.sha256((tests / "test_a.py").read_bytes()).hexdigest()
        checks = json.dumps({"version": 1, "mission": "m1", "base": "0" * 40, "test_files": {"tests/test_a.py": test_hash},
                             "checks": [{"id": "a", "node": "a", "acceptance": [1], "command": "pytest", "expect_before": "fail"}]})
        (c / "approved-checks.json").write_text(checks)
        (c / "brief-exec.md").write_text(
            f"brief\n\nchecks 清单的 sha256：`{hashlib.sha256(checks.encode()).hexdigest()}`（`approved-checks.json`）\n")
        (c / "approved-task-dag.json").write_text(json.dumps({"version": 1, "mission": "m1", "tasks": [
            {"id": "a", "depends_on": [], "files": ["a.txt"], "contracts": [], "verification": ["true"], "state": "ready"}]}))
        subprocess.run("shasum -a 256 approved-design.md approved-plan.md brief-exec.md approved-task-dag.json > approved.sha256",
                       shell=True, cwd=c, check=True)
        ns = self.tmp / "ns"
        (ns / "bin").mkdir(parents=True)
        self.sig_ok = self.tmp / "sig-ok"
        self.sig_ok.write_text("")
        (ns / "bin" / "northstar").write_text(
            f'#!/bin/sh\n[ "$1" = verify-mission ] && [ "$2" = "{os.path.realpath(c)}" ] && [ -f "{self.sig_ok}" ]\n')
        (ns / "bin" / "northstar").chmod(0o755)
        self.env["ORC_NORTHSTAR_ROOT"] = str(ns)
        with self.orc.Mission("m1") as m:
            for to in ("verifying", "plan-review", "approved", "executing"):
                m.transition(to, "test")

    def test_good_signature_and_hashes_pass_through(self):
        r = self.run_orc("step", "--mission", "m1")
        self.assertIn("executing 阶段的流程还没有实现", self.next_line(r))

    def test_tampered_frozen_file_stops_every_step(self):
        (self.mdir / "control" / "approved-design.md").write_text("design changed after go\n")
        for _ in range(2):
            r = self.run_orc("step", "--mission", "m1")
            self.assertIn("冻结文件和签名时的哈希不一致", self.next_line(r))
        self.assertEqual((self.mdir / "state").read_text().strip(), "executing")

    def test_tampered_frozen_test_stops_every_step(self):
        # 验收测试不在四个文件的哈希清单里，但它的哈希写在签名的 brief-exec.md 里：改了照样拦下
        (self.mdir / "control" / "approved-tests" / "tests" / "test_a.py").write_text("def test_a(): pass\n")
        for _ in range(2):
            r = self.run_orc("step", "--mission", "m1")
            self.assertIn("验收测试 tests/test_a.py 被改过", self.next_line(r))

    def test_extra_or_swapped_check_list_stops_step(self):
        c = self.mdir / "control"
        (c / "approved-tests" / "tests" / "extra_test.py").write_text("x\n")
        r = self.run_orc("step", "--mission", "m1")
        self.assertIn("approved-tests/ 里的文件和签名时的清单不一致", self.next_line(r))
        (c / "approved-tests" / "tests" / "extra_test.py").unlink()
        (c / "approved-checks.json").write_text((c / "approved-checks.json").read_text().replace('"pytest"', '"true"'))
        r = self.run_orc("step", "--mission", "m1")
        self.assertIn("approved-checks.json 和签名的 brief-exec.md 里记的哈希不一致", self.next_line(r))

    def test_bad_signature_stops_step(self):
        self.sig_ok.unlink()
        r = self.run_orc("step", "--mission", "m1")
        self.assertIn("签名校验失败", self.next_line(r))

    def test_blocked_after_approval_is_also_verified(self):
        with self.orc.Mission("m1") as m:
            m.block("熔断", "要调整吗？", "ask-user", "test")
        self.sig_ok.unlink()
        r = self.run_orc("step", "--mission", "m1")
        self.assertIn("签名校验失败", self.next_line(r))


class CreateLeftovers(OrcCase):
    """小问题：--name 新建在写 events.jsonl 之前失败时，不能留下无法接管的目录。"""

    def test_leftover_directory_without_events_is_taken_over(self):
        leftover = self.home / "missions" / "m1"
        leftover.mkdir(parents=True)
        (leftover / "request.md").write_text("half written\n")
        r, mdir = self.new()
        self.assertIn("接管", r.stdout)
        self.assertEqual((mdir / "request.md").read_text().strip(), "Add CSV export")
        self.assertEqual((mdir / "state").read_text().strip(), "planning")

    def test_failure_before_events_removes_the_directory(self):
        real = self.orc.write_atomic
        def flaky(path, text):
            if path.name == "models.json":
                raise OSError("disk full")
            real(path, text)
        self.orc.write_atomic = flaky
        try:
            with self.assertRaises(OSError):
                self.orc.create_mission("x", str(self.repo), "m1")
        finally:
            self.orc.write_atomic = real
        self.assertFalse((self.home / "missions" / "m1").exists())


class WorktreeLocation(OrcCase):
    """复核意见：节点 worktree 不能在 $ORC_HOME 下，否则 guard 会拦住节点里的所有写入。"""

    def test_default_is_outside_orc_home(self):
        os.environ.pop("ORC_WORKTREES", None)
        saved = os.environ.get("HOME")
        os.environ["HOME"] = str(self.tmp / "h")
        try:
            os.environ["ORC_HOME"] = str(self.tmp / "h" / ".orc")
            self.assertEqual(self.orc.Mission("m1").worktree("n1"), self.tmp / "h" / ".orc-worktrees" / "m1" / "n1")
        finally:
            os.environ["HOME"] = saved
            os.environ["ORC_HOME"] = str(self.home)

    def test_worktrees_inside_orc_home_are_refused(self):
        for inside in (self.home, self.home / "missions" / "m1" / "worktrees"):
            os.environ["ORC_WORKTREES"] = str(inside)
            try:
                with self.assertRaises(self.orc.OrcError) as ctx:
                    self.orc.worktrees_root()
                self.assertIn("不能放在 $ORC_HOME", str(ctx.exception))
            finally:
                os.environ.pop("ORC_WORKTREES", None)
        os.environ["ORC_WORKTREES"] = str(self.tmp / "elsewhere")
        try:
            self.assertEqual(self.orc.worktrees_root(), self.tmp / "elsewhere")
        finally:
            os.environ.pop("ORC_WORKTREES", None)


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
        self.assertEqual(set(minimal), {"implement", "plan", "review", "review_light"})
        try:
            import tomllib
        except ModuleNotFoundError:
            self.skipTest("这个 Python 没有 tomllib，只验证最小解析器")
        self.assertEqual(minimal, tomllib.loads(text))

    def test_config_errors_say_what_to_fix(self):
        def role(name, model, extra=""):
            return f'[{name}]\ncli = "claude"\nmodel = "{model}"\neffort = "high"\n{extra}'
        good = (role("implement", "opus") + role("plan", "opus")
                + role("review", "fable", 'deep_review_over_lines = "300"\n') + role("review_light", "opus"))
        p = self.tmp / "ok.toml"
        p.write_text(good)
        self.assertEqual(self.orc.resolve_models(p)["roles"]["review"]["model"], "fable")
        cases = [
            (role("implement", "opus"), "缺少 [plan]"),
            (good.replace('model = "fable"\n', ''), "[review] 缺少 model"),
            (good.replace('"fable"', '"opus"'), "重要的评审不能用 implement 的模型"),
            (good.replace('deep_review_over_lines = "300"\n', 'deep_review_over_lines = "300"\nfallback = "opus"\n'),
             "不能降级成 implement 的模型"),
            (good.replace('"300"', '"很多"'), "deep_review_over_lines"),
            (good.replace('[plan]\ncli = "claude"', '[plan]\ncli = "gemini"'), "cli 只能是 claude 或 codex"),
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


class ReviewTier(OrcCase):
    """重要、复杂的评审用 review（Fable），其余用 review_light（Opus）；由代码按固定规则判断。"""

    def test_tiering_rules(self):
        rr = lambda stage, lines=10, drift=False: self.orc.review_role(stage, lines, drift, 300)
        self.assertEqual(rr("node"), "review")                   # 节点整体评审
        self.assertEqual(rr("final"), "review")                  # 最终审查
        self.assertEqual(rr("commit"), "review_light")           # 平时的小步评审
        self.assertEqual(rr("commit", drift=True), "review")     # DRIFT 之后的复审
        self.assertEqual(rr("commit", lines=300), "review_light")
        self.assertEqual(rr("commit", lines=301), "review")      # 大改动
        with self.assertRaises(self.orc.OrcError):
            rr("whatever")


class Doctor(OrcCase):
    def fake_install(self, with_codex=True):
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
        for c in ("codex", "claude", "jq") if with_codex else ("claude", "jq"):
            (fakebin / c).write_text("#!/bin/sh\necho ok\n")
            (fakebin / c).chmod(0o755)
        # PATH 只放假命令和系统目录：不受这台机器上装没装真的 codex / claude 影响
        return dict(self.env, ORC_NORTHSTAR_ROOT=str(ns), ORC_CLAUDE_MANAGED_SETTINGS=str(managed),
                    ORC_CODEX_HOOKS=str(codex), PATH=f"{fakebin}:/usr/bin:/bin")

    def test_all_good(self):
        env = self.fake_install(with_codex=False)
        r = self.run_orc("doctor", env=env)
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertNotIn("FAIL", r.stdout)
        self.assertIn("skip  审阅页发布", r.stdout)
        self.assertIn("orc doctor --live", r.stdout)
        self.assertIn("skip  命令：codex", r.stdout)       # 没有角色用 codex 时不要求安装

    def test_codex_required_only_when_a_role_uses_it(self):
        env = self.fake_install(with_codex=False)
        text = (ORC_ROOT / "config" / "models.toml").read_text()
        light = text.index("[review_light]")
        p = self.tmp / "m.toml"
        p.write_text(text[:light] + text[light:].replace('cli    = "claude"', 'cli    = "codex"', 1))
        r = self.run_orc("doctor", env=dict(env, ORC_MODELS_TOML=str(p)))
        self.assertEqual(r.returncode, 1)
        self.assertIn("FAIL  命令：codex", r.stdout)

    def test_live_calls_each_model_once(self):
        env = self.fake_install(with_codex=False)
        r = self.run_orc("doctor", "--live", env=env)
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("ok  模型可用：claude-opus-5-5（implement、plan、review_light）", r.stdout)
        self.assertIn("ok  模型可用：claude-fable-5-1（review）", r.stdout)

    def test_live_requires_a_line_that_is_exactly_ok(self):
        env = self.fake_install(with_codex=False)
        fakebin = Path(env["PATH"].split(":")[0])
        (fakebin / "claude").write_text("#!/bin/sh\necho 'token limit reached'\n")   # 含 ok 子串，但不是 ok
        r = self.run_orc("doctor", "--live", env=env)
        self.assertEqual(r.returncode, 1)
        self.assertIn("FAIL  模型可用：claude-opus-5-5", r.stdout)
        (fakebin / "claude").write_text("#!/bin/sh\necho '  OK  '\n")
        r = self.run_orc("doctor", "--live", env=env)
        self.assertIn("ok  模型可用：claude-opus-5-5", r.stdout)

    def test_worktrees_inside_orc_home_fail_doctor(self):
        env = self.fake_install()
        env["ORC_WORKTREES"] = str(self.home / "worktrees")
        r = self.run_orc("doctor", env=env)
        self.assertEqual(r.returncode, 1)
        self.assertIn("FAIL  节点 worktree 位置", r.stdout)
        env["ORC_WORKTREES"] = str(self.tmp / "wt")
        r = self.run_orc("doctor", env=env)
        self.assertIn("ok  节点 worktree 位置", r.stdout)

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

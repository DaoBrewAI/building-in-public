#!/usr/bin/env python3
"""阶段 4 的契约测试：调度、执行会话、提交关口、broker、纠偏、整体评审、集成（docs/orc/STATE.md「执行」）。

不调用真实模型：执行会话和「判断测试对错」用假的 claude，对齐评审用假的 northstar-review，都按脚本编排。
commit-broker.sh、integrate-task.sh、检查的沙箱（sandbox-exec）都是真的。
执行会话的沙箱本身（git 只读、写不了 worktree 外、不能联网）是 Claude Code 的行为，这里只核对 orc 传给它的设置；
实测记录见 docs/orc/proposals/2026-11-07-stop-gate-implement.md。
"""
import json
import os
import subprocess
import sys
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_orc import ORC_ROOT  # noqa: E402
from test_planning import FAKE_NORTHSTAR, PlanningCase  # noqa: E402

FAKE_EXEC_CLAUDE = r'''#!/usr/bin/env python3
# 假 claude：ORC_ROLE=implement 时按 $ORC_FAKE/script-<node> 第 n 行（JSON）行事；ORC_ROLE=dispute 时按 script-dispute
import json, os, pathlib, sys, time
fake = pathlib.Path(os.environ["ORC_FAKE"])
args = sys.argv[1:]
prompt = sys.stdin.read()
role = os.environ.get("ORC_ROLE")
envelope = lambda result: print(json.dumps({"type": "result", "is_error": False, "result": result}, ensure_ascii=False))
if role == "publish":
    # 假发布（阶段 5 的状态页）：记下调用，输出 claude.ai 链接
    pages = sorted(pathlib.Path(".").glob("*.html"))
    n = len(list(fake.glob("publish-call-*.json"))) + 1
    (fake / f"publish-call-{n}.json").write_text(json.dumps({"args": args, "cwd": os.getcwd(), "prompt": prompt,
        "pages": [p.name for p in pages]}, ensure_ascii=False))
    envelope(json.dumps({"url": f"https://claude.ai/artifact/fake-{pages[0].stem if pages else 'none'}"}))
    sys.exit(0)
NAMES = {"final-review": "final", "notes": "notes", "canvas": "canvas", "phase-conclusion": "phase", "cross-review": "cross"}
DEFAULTS = {"final": '{"verdict": "pass", "issues": []}', "notes": "AUTO",
            "canvas": '{"components": [{"id": "core", "name": "核心", "paths": ["*"]}]}',
            "phase": '{"items": [{"criterion": "主线跑通", "status": "met", "evidence": "PR 已合并"}]}',
            "cross": '{"verdict": "pass", "issues": [], "overrides_applied": []}'}
if role in NAMES:
    # 最终审查 / 跨 mission 评审 / 画布 / phase 结论：按 script-<名字> 第 n 行，默认见 DEFAULTS。状态页说明默认 AUTO（引用提示词里列出的每个提交）
    name = NAMES[role]
    n = len(list(fake.glob(f"{name}-call-*.json"))) + 1
    cwd = pathlib.Path(os.getcwd())
    (fake / f"{name}-call-{n}.json").write_text(json.dumps({"args": args, "cwd": os.getcwd(), "prompt": prompt,
        "files": sorted(str(p.relative_to(cwd)) for p in cwd.rglob("*") if p.is_file())}, ensure_ascii=False))
    script = fake / f"script-{name}"
    lines = [l for l in script.read_text().splitlines() if l.strip()] if script.exists() else []
    line = lines[n - 1] if n - 1 < len(lines) else DEFAULTS[name]
    if line == "AUTO":
        import re
        line = "\n".join(f"- 提交 {h} 的改动 [commit:{h}]" for h in re.findall(r"^- `([0-9a-f]{7,})` ", prompt, re.M))
    elif line.startswith("raw:"):
        line = line[4:].replace("\\n", "\n")
    envelope(line)
    sys.exit(0)
session = args[args.index("--session-id") + 1] if "--session-id" in args else args[args.index("--resume") + 1]
name = f"exec-{os.environ.get('ORC_NODE')}" if role == "implement" else "dispute"
if role not in ("implement", "dispute"):
    sys.exit(9)
n = len(list(fake.glob(f"{name}-call-*.json"))) + 1
(fake / f"{name}-call-{n}.json").write_text(json.dumps({
    "args": args, "cwd": os.getcwd(), "prompt": prompt, "session": session,
    "env": {k: os.environ.get(k) for k in ("ORC_ROLE", "ORC_NODE", "PYTHONDONTWRITEBYTECODE", "PYTEST_ADDOPTS", "ORC_MISSION_CONTROL")}},
    ensure_ascii=False))
script = fake / f"script-{name[5:] if role == 'implement' else 'dispute'}"
lines = [l for l in script.read_text().splitlines() if l.strip()] if script.exists() else []
step = json.loads(lines[n - 1]) if n - 1 < len(lines) else {"out": {"status": "question", "question": "脚本用完了"}}
for rel, content in step.get("write", {}).items():
    p = pathlib.Path(rel)
    if content is None:
        p.unlink()
    else:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content)
if step.get("sleep"):
    time.sleep(step["sleep"])
if "exit" in step:
    sys.exit(step["exit"])
result = step["raw"] if "raw" in step else json.dumps(step["out"], ensure_ascii=False)
print(json.dumps({"type": "result", "is_error": False, "session_id": session, "result": result}, ensure_ascii=False))
'''

FAKE_REVIEW = r'''#!/usr/bin/env python3
# 假 northstar-review：按 $ORC_FAKE/script-review 第 n 行给结论（默认 ALIGNED），记下每次调用
import json, os, pathlib, sys
fake = pathlib.Path(os.environ["ORC_FAKE"])
args = sys.argv[1:]
get = lambda k: args[args.index(k) + 1] if k in args else None
diff = sys.stdin.read()
# 并行的提交关口会同时调用：用独占创建占一个编号，免得两次调用写进同一个文件
n = len(list(fake.glob("review-call-*.json"))) + 1
while True:
    try:
        fd = os.open(fake / f"review-call-{n}.json", os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        break
    except FileExistsError:
        n += 1
os.close(fd)
(fake / f"review-call-{n}.json").write_text(json.dumps({
    "args": args, "role": get("--role"), "prev": get("--prev"), "cwd": os.getcwd(), "diff": diff,
    "checks": open(get("--checks")).read() if get("--checks") else None,
    "northstar": os.path.isfile(".northstar/NORTHSTAR.md")}, ensure_ascii=False))
script = fake / "script-review"
lines = [l for l in script.read_text().splitlines() if l.strip()] if script.exists() else []
v = lines[n - 1] if n - 1 < len(lines) else "ALIGNED"
if v == "ALIGNED":
    print("ALIGNED"); sys.exit(0)
if v.startswith("DRIFT"):
    print("DRIFT\n违反项：" + v[6:] + "\n证据：diff 里的改动"); sys.exit(1)
if v == "LARGE":
    print("NORTHSTAR：这次的改动有 99999 字节，超过评审上限 60000。评审不截断：按验收标准拆成更小的提交。", file=sys.stderr); sys.exit(2)
print("NORTHSTAR：对齐评审没有返回结果。稍后重试提交；持续失败就停止并告诉用户。", file=sys.stderr); sys.exit(2)
'''


def task(node, files, acceptance, depends=()):
    return {"id": node, "depends_on": list(depends), "files": files, "contracts": [f"{node} 的文件内容"],
            "verification": [f"sh tests/orc/check_{node}.sh"], "state": "ready", "acceptance": acceptance,
            "clauses": ["N1"], "component": "core"}


def commit(writes, acceptance, files=None, message="完成"):
    """执行会话的一轮：写文件，然后交 commit 结果。files 默认是这次写过的文件（None 表示删除，不算）。"""
    files = files if files is not None else sorted(k for k, v in writes.items() if v is not None)
    return json.dumps({"write": writes, "out": {"status": "commit", "acceptance": acceptance,
                                                "files": files, "message": message}}, ensure_ascii=False)


class ExecCase(PlanningCase):
    def setUp(self):
        super().setUp()
        claude = self.tmp / "fakebin" / "claude"
        claude.write_text(FAKE_EXEC_CLAUDE.replace("#!/usr/bin/env python3", f"#!{sys.executable}", 1))
        claude.chmod(0o755)
        review = self.tmp / "ns" / "bin" / "northstar-review"
        review.write_text(FAKE_REVIEW.replace("#!/usr/bin/env python3", f"#!{sys.executable}", 1))
        review.chmod(0o755)
        self.config(max_parallel=3, session_timeout_seconds=600, crash_retries=1)
        self.env.update(ORC_EXEC_CONFIG=str(self.tmp / "orc.toml"),
                        GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
        self.mdir = self.home / "missions" / "m1"

    def config(self, **values):
        (self.tmp / "orc.toml").write_text("[execution]\n" + "".join(f'{k} = "{v}"\n' for k, v in values.items())
                                           + '[acceptance]\nrequired_checks = "verify,exam"\nci_timeout_seconds = "5"\n')

    # -- 搭一个已经签好名、停在 approved 的 mission（跳过规划和验证会话）
    def signed(self, tasks, checks, tests):
        orc = self.orc
        m = orc.create_mission("执行测试", str(self.repo), "m1")
        base = subprocess.run(["git", "-C", str(self.repo), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        plan, verify = m.dir / "plan", m.dir / "verify"
        (plan / "design.md").write_text("# 设计\n\n每个节点写一个文本文件，内容就是节点名。\n")
        (plan / "plan.md").write_text("# 计划\n每个节点一次提交。\n")
        (plan / "task-dag.json").write_text(json.dumps({"version": 1, "mission": "m1", "tasks": tasks}, ensure_ascii=False))
        for rel, body in tests.items():
            (verify / "files" / rel).parent.mkdir(parents=True, exist_ok=True)
            (verify / "files" / rel).write_text(body)
        (verify / "checks.json").write_text(json.dumps({"version": 1, "mission": "m1", "test_files": sorted(tests),
                                                        "checks": checks}, ensure_ascii=False))
        (verify / "results.json").write_text(json.dumps({"base": base, "results": [], "test_files": sorted(tests)}))
        with m:
            for to in ("planning", "verifying", "plan-review"):
                m.transition(to, "test")
            c = m.control
            brief = (ORC_ROOT / "templates" / "brief-exec.md").read_text(encoding="utf-8")
            brief = brief.replace("{{MISSION}}", "m1").replace("{{IMPLEMENT_MODEL}}", m.roles()["implement"]["model"])
            brief += orc.freeze_verification(m)
            written = {"approved-design.md": (plan / "design.md").read_bytes(),
                       "approved-plan.md": (plan / "plan.md").read_bytes(), "brief-exec.md": brief.encode()}
            for name, data in written.items():
                (c / name).write_bytes(data)
            orc.write_atomic(c / "approved.sha256", "".join(
                f"{__import__('hashlib').sha256(d).hexdigest()}  {n}\n" for n, d in written.items()))
            freeze = subprocess.run(["bash", str(orc.SCRIPTS / "validate-task-dag.sh"), "--freeze",
                                     str(plan / "task-dag.json"), os.path.realpath(c)], capture_output=True, text=True)
            self.assertEqual(freeze.returncode, 0, freeze.stderr)
            (c / "approved.sha256.sig").write_text("sig\n")
            (self.fake / "sig-ok").write_text("")
            m.transition("approved", "test")
        return m

    def simple(self, nodes=("a",), depends=None, two_acceptance=False):
        """每个节点一个文件 <node>.txt，验收标准是内容为节点名；检查 c<node> 用 grep 核对。"""
        depends = depends or {}
        tasks, checks, tests = [], [], {}
        for node in nodes:
            files = [f"{node}.txt", f"{node}2.txt"] if two_acceptance else [f"{node}.txt"]
            acceptance = [f"{node}.txt 的第一行是 {node}"] + ([f"{node}2.txt 的第一行是 {node}2"] if two_acceptance else [])
            tasks.append(task(node, files, acceptance, depends.get(node, ())))
            tests[f"tests/orc/check_{node}.sh"] = f"grep -q '^{node}$' {node}.txt\n"
            checks.append({"id": f"c{node}", "node": node, "acceptance": [1], "command": f"sh tests/orc/check_{node}.sh",
                           "expect_before": "fail"})
            if two_acceptance:
                tests[f"tests/orc/check_{node}2.sh"] = f"grep -q '^{node}2$' {node}2.txt\n"
                checks.append({"id": f"c{node}2", "node": node, "acceptance": [2],
                               "command": f"sh tests/orc/check_{node}2.sh", "expect_before": "fail"})
        return self.signed(tasks, checks, tests)

    def script(self, name, *lines):
        (self.fake / f"script-{name}").write_text("\n".join(lines) + "\n")

    def calls(self, name):
        return [json.loads(p.read_text()) for p in sorted(self.fake.glob(f"{name}-call-*.json"),
                                                          key=lambda p: int(p.stem.rsplit("-", 1)[1]))]

    def ev(self, kind=None, **match):
        return [e for e in self.events(self.mdir) if (kind is None or e["kind"] == kind)
                and all(e.get(k) == v for k, v in match.items())]

    def drive(self, steps=60):
        """反复 orc step；next 是 wait 就 orc wait。返回第一个不是 wait 的 step 结果。"""
        for _ in range(steps):
            r = self.step()
            if self.next_line(r) != "next: wait":
                return r
            w = self.run_orc("wait", "--mission", "m1", "--timeout", "60")
            self.assertEqual(w.returncode, 0, w.stdout + w.stderr)
        self.fail("orc step 一直在 wait")

    def answer(self, text):
        r = self.run_orc("answer", text, "--mission", "m1")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def git(self, *args, cwd=None):
        return subprocess.run(["git", "-C", str(cwd or self.repo), *args], capture_output=True, text=True,
                              env=self.env).stdout.strip()

    def wt(self, node):
        return self.tmp / "wt" / "m1" / node

    def reached_reviewing(self, r):
        """阶段 4 的测试到 reviewing 为止：最终审查（假评审默认通过）之后要开 PR，测试仓库没有 origin，停在这里。"""
        self.assertIn("没有 origin", self.next_line(r), r.stdout + r.stderr)
        self.assertEqual((self.mdir / "state").read_text().strip(), "reviewing")


class HappyPath(ExecCase):
    def test_two_independent_nodes_run_in_parallel_and_integrate_one_at_a_time(self):
        self.simple(("a", "b"))
        self.script("a", commit({"a.txt": "a\n"}, [1]))
        self.script("b", commit({"b.txt": "b\n"}, [1], message="[N1] b：完成"))   # 执行会话自己带了条款标签和节点名
        r = self.step()
        self.assertEqual(self.next_line(r), "next: wait", r.stdout + r.stderr)
        self.assertIn("approved → executing", r.stdout)
        starts = self.ev("job-start", type="executor")
        self.assertEqual(sorted(s["node"] for s in starts), ["a", "b"])        # 不重叠的两个节点同时启动
        # 冻结的测试先提交在 mission 分支上，节点里是已跟踪的文件
        setup, = self.ev("exec-setup")
        self.assertIn("冻结 mission m1 的验收测试", self.git("log", "-1", "--format=%s", setup["tests_commit"]))
        self.assertIn("tests/orc/check_a.sh", self.git("ls-files", cwd=self.wt("a")))
        r = self.drive()
        self.reached_reviewing(r)
        integrates = self.ev("job-start", type="integrate")
        self.assertEqual([s["node"] for s in integrates], ["a", "b"])
        a_done, = self.ev("job-exit", type="integrate", node="a")
        # 一次只集成一个：b 的集成在 a 结束之后开始，并且基于 a 集成后的 mission 分支
        self.assertLess(self.events(self.mdir).index(a_done), self.events(self.mdir).index(integrates[1]))
        self.assertEqual(integrates[1]["parent_tip"], a_done["sha"])
        tip = self.git("rev-parse", "orc/m1")
        for node in ("a", "b"):
            self.assertEqual(self.git("show", f"{tip}:{node}.txt"), node)
        self.assertEqual({e["node"]: e["to"] for e in self.ev("node-state")}, {"a": "integrated", "b": "integrated"})
        self.assertEqual(len(self.ev("commit")), 2)
        roles = [c["role"] for c in self.calls("review")]
        self.assertEqual(sorted(roles), ["auto", "auto", "review", "review"])   # 提交前 auto，整体评审 review
        for c in self.calls("review"):
            self.assertTrue(c["northstar"], "对齐评审在节点 worktree 里运行，能读到 NORTHSTAR")
        msg = self.git("log", "-1", "--format=%s", f"orc-task/m1/a")
        self.assertTrue(msg.startswith("[N1] a："), msg)                       # 提交说明带 N# 条款
        msg = self.git("log", "-1", "--format=%s", f"orc-task/m1/b")
        self.assertEqual(msg, "[N1] b：完成")                                   # 执行会话自带的标签和节点名不重复

    def test_only_declared_checks_and_previously_passed_checks_run(self):
        self.simple(("a",), two_acceptance=True)
        self.script("a", commit({"a.txt": "a\n"}, [1]), commit({"a2.txt": "a2\n"}, [2]))
        r = self.drive()
        self.reached_reviewing(r)
        by_job = {}
        for e in self.ev("check", node="a"):
            by_job.setdefault(e["log"], set()).add(e["id"])
        self.assertEqual(by_job["a.gate.1"], {"ca"})                  # 只跑声明完成的第 1 条
        self.assertEqual(by_job["a.gate.2"], {"ca2", "ca"})           # 第 2 条，加上此前通过的
        self.assertEqual(by_job["a.submit.1"], {"ca", "ca2"})         # 整体评审跑本节点全部冻结检查
        report = (self.mdir / "nodes" / "a" / "report.md").read_text()
        self.assertIn("遗留问题", report)
        second = self.calls("exec-a")[1]
        self.assertIn("--resume", second["args"])                    # 下一条回到同一个会话
        self.assertEqual(second["session"], self.calls("exec-a")[0]["session"])
        self.assertIn("提交成功", second["prompt"])
        self.assertIn("a2.txt 的第一行是 a2", second["prompt"])

    def test_executor_session_settings(self):
        """git 只读、写不了 worktree 外、Stop hook 放行：靠 orc 传给 Claude Code 的设置（实测见 stop-gate 提案）。"""
        m = self.simple(("a",))
        self.script("a", commit({"a.txt": "a\n"}, [1]))
        self.step()
        self.run_orc("wait", "--mission", "m1", "--timeout", "30")
        call, = self.calls("exec-a")
        args = call["args"]
        settings = json.loads(next(a for a in args if a.startswith("--settings="))[len("--settings="):])
        sandbox = settings["sandbox"]
        self.assertTrue(sandbox["enabled"] and sandbox["failIfUnavailable"])
        self.assertFalse(sandbox["allowUnsandboxedCommands"])
        self.assertEqual(sandbox["filesystem"]["denyWrite"], [os.path.realpath(self.repo / ".git")])  # git 只读
        wt = os.path.realpath(self.wt("a"))
        tools = next(a for a in args if a.startswith("--allowedTools="))[len("--allowedTools="):].split(",")
        self.assertEqual(sorted(t for t in tools if t.startswith(("Write", "Edit", "MultiEdit"))),
                         sorted(f"{t}(/{wt}/**)" for t in ("Edit", "MultiEdit", "Write")))   # 只能写自己的 worktree
        self.assertNotIn("--add-dir", args)          # --add-dir 会让 Bash 能写那个目录（阶段 3 实测）
        self.assertEqual(os.path.realpath(call["cwd"]), wt)
        self.assertEqual(call["env"]["ORC_ROLE"], "implement")
        self.assertEqual(call["env"]["ORC_NODE"], "a")
        self.assertEqual(args[args.index("--model") + 1], m.roles()["implement"]["model"])
        for text in ("执行规则", "a.txt 的第一行是 a", "sh tests/orc/check_a.sh", "每个节点写一个文本文件"):
            self.assertIn(text, call["prompt"])


class Scheduling(ExecCase):
    def test_overlapping_dependent_and_over_limit_nodes_wait(self):
        tasks = {"a": {"files": ["x"], "depends_on": []}, "c": {"files": ["x"], "depends_on": []},
                 "d": {"files": ["y"], "depends_on": ["a"]}, "e": {"files": ["z"], "depends_on": []},
                 "f": {"files": ["w"], "depends_on": []}}
        pending = {n: "pending" for n in tasks}
        self.assertEqual(self.orc.schedulable(tasks, pending, 3), ["a", "e", "f"])      # c 和 a 重叠，排队
        self.assertEqual(self.orc.schedulable(tasks, pending, 1), ["a"])                # 并发上限
        running = dict(pending, a="running")
        self.assertEqual(self.orc.schedulable(tasks, running, 3), ["e", "f"])           # d 等 a 集成，c 等 a 释放 x
        done = dict(pending, a="integrated")
        self.assertEqual(self.orc.schedulable(tasks, done, 5), ["c", "d", "e", "f"])
        blocked = dict(pending, a="blocked")
        self.assertEqual(self.orc.schedulable(tasks, blocked, 5), ["e", "f"])           # blocked 的节点仍占着文件

    def test_dependent_node_starts_after_its_dependency_is_integrated(self):
        self.simple(("a", "b"), depends={"b": ["a"]})
        self.script("a", commit({"a.txt": "a\n"}, [1]))
        self.script("b", commit({"b.txt": "b\n"}, [1]))
        r = self.drive()
        self.reached_reviewing(r)
        a_int, = self.ev("job-exit", type="integrate", node="a")
        b_start, = self.ev("node-start", node="b")
        self.assertLess(self.events(self.mdir).index(a_int), self.events(self.mdir).index(b_start))
        self.assertEqual(b_start["base"], a_int["sha"])               # b 从集成了 a 的 mission 分支开出


class Gate(ExecCase):
    def test_failing_checks_reject_without_calling_the_review_model(self):
        self.simple(("a",))
        self.script("a", commit({"a.txt": "wrong\n"}, [1]), commit({"a.txt": "a\n"}, [1]))
        self.step()
        self.run_orc("wait", "--mission", "m1", "--timeout", "30")
        self.step()                                                   # 启动提交关口
        self.run_orc("wait", "--mission", "m1", "--timeout", "60")
        self.step()                                                   # 关口结束：拒绝，发回同一个会话
        gate, = self.ev("job-exit", type="gate")
        self.assertEqual((gate["outcome"], gate["category"]), ("rejected", "checks"))
        self.assertEqual(self.calls("review"), [])                    # 检查不通过：不调用评审模型
        self.assertEqual(self.ev("commit"), [])
        card = Path(gate["card"]).read_text()
        self.assertIn("ca", card)
        self.assertIn("a.txt 的第一行是 a", card)                    # 纠偏单带验收标准原文
        r = self.drive()
        self.reached_reviewing(r)
        second = self.calls("exec-a")[1]
        self.assertIn("--resume", second["args"])
        self.assertIn("纠偏单", second["prompt"])

    def test_three_drifts_in_a_row_trip_the_breaker(self):
        self.simple(("a",))
        self.script("review", "DRIFT N1 被绕开", "DRIFT 仍然偏离", "DRIFT 第三次")
        self.script("a", *[commit({"a.txt": "a\n"}, [1])] * 4)
        r = self.drive()
        self.assertTrue(self.next_line(r).startswith("next: mediate "), r.stdout + r.stderr)
        self.assertEqual((self.mdir / "state").read_text().strip(), "blocked")
        self.assertTrue((self.mdir / "control" / "tasks" / "a" / "blocked").is_file())
        calls = self.calls("exec-a")
        self.assertEqual(len(calls), 3)
        # 第 1 次：纠偏单发回同一个会话
        self.assertIn("--resume", calls[1]["args"])
        self.assertIn("N1 被绕开", calls[1]["prompt"])
        # 第 2 次：改动撤回、存成补丁，新开会话（generation 2），发完整 brief 和纠偏单
        self.assertIn("--session-id", calls[2]["args"])
        self.assertNotEqual(calls[2]["session"], calls[0]["session"])
        self.assertIn("执行规则", calls[2]["prompt"])
        self.assertIn("仍然偏离", calls[2]["prompt"])
        self.assertTrue((self.mdir / "nodes" / "a" / "discarded-1.patch").is_file())
        self.assertIn("+a", (self.mdir / "nodes" / "a" / "discarded-1.patch").read_text())
        self.assertEqual((self.mdir / "control" / "tasks" / "a" / "generation").read_text().strip(), "2")
        # DRIFT 之后的复审带上上一次的原因（northstar-review 据此用 review 模型）
        reviews = self.calls("review")
        self.assertIsNone(reviews[0]["prev"])
        self.assertIn("N1 被绕开", reviews[1]["prev"])
        self.assertEqual([e["count"] for e in self.ev("correction")], [1, 2, 3])
        self.assertEqual(self.ev("commit"), [])
        # 裁决后：新开会话，带上回答，继续
        self.answer("按设计只写 a，不要动别的")
        r = self.drive()
        self.reached_reviewing(r)
        fourth = self.calls("exec-a")[3]
        self.assertIn("--session-id", fourth["args"])
        self.assertIn("按设计只写 a", fourth["prompt"])
        self.assertIn("已撤回", fourth["prompt"])                    # 熔断后重来，第 3 次被拒的改动也撤回
        self.assertTrue((self.mdir / "nodes" / "a" / "discarded-2.patch").is_file())

    def test_acceptance_already_satisfied_is_confirmed_by_checks_without_a_commit(self):
        """真实运行里遇到的：第一次提交顺带满足了第二条验收标准，第二轮没有可改的东西。"""
        self.simple(("a",), two_acceptance=True)
        self.script("a", commit({"a.txt": "a\n", "a2.txt": "a2\n"}, [1]), commit({}, [2]))
        r = self.drive()
        self.reached_reviewing(r)
        second = self.ev("job-exit", type="gate")[1]
        self.assertEqual(second["outcome"], "satisfied")
        self.assertEqual(set(second["checks"]), {"ca2", "ca"})             # 用冻结的检查确认
        self.assertEqual(len(self.ev("commit")), 1)                         # 没有新提交
        self.assertEqual([c["role"] for c in self.calls("review")], ["auto", "review"])   # 没有 diff，不评审
        self.assertIn("`files` 写 `[]`", self.calls("exec-a")[0]["prompt"])      # brief 里写明了这种情况怎么交

    def test_one_success_resets_the_streak(self):
        self.simple(("a",), two_acceptance=True)
        self.script("review", "DRIFT 一", "ALIGNED", "DRIFT 二", "ALIGNED")
        self.script("a", commit({"a.txt": "a\n"}, [1]), commit({"a.txt": "a\n"}, [1]),
                    commit({"a2.txt": "a2\n"}, [2]), commit({"a2.txt": "a2\n"}, [2]))
        r = self.drive()
        self.reached_reviewing(r)
        self.assertEqual([e["count"] for e in self.ev("correction")], [1, 1])   # 中间提交成功一次，计数清零
        self.assertFalse(list((self.mdir / "nodes" / "a").glob("discarded-*.patch")))

    def test_oversized_diff_is_rejected_not_truncated(self):
        self.simple(("a",))
        self.script("review", "LARGE")
        self.script("a", commit({"a.txt": "a\n"}, [1]), commit({"a.txt": "a\n"}, [1]))
        r = self.drive()
        self.reached_reviewing(r)
        first = self.ev("job-exit", type="gate")[0]
        self.assertEqual((first["outcome"], first["category"]), ("rejected", "too-large"))
        self.assertIn("拆成更小的提交", Path(first["card"]).read_text())
        self.assertEqual(len(self.ev("commit")), 1)                  # 拆小后的那次才提交

    def test_review_model_unavailable_blocks_instead_of_downgrading(self):
        self.simple(("a",))
        self.script("review", "UNAVAILABLE")
        self.script("a", commit({"a.txt": "a\n"}, [1]))
        r = self.drive()
        self.assertTrue(self.next_line(r).startswith("next: ask-user "), r.stdout + r.stderr)
        self.assertIn("不降级", self.next_line(r))
        self.assertEqual(len(self.calls("review")), 1)               # 没有换一个模型再审
        self.assertEqual(self.calls("review")[0]["role"], "auto")
        self.assertEqual(self.ev("commit"), [])
        self.assertTrue((self.mdir / "control" / "tasks" / "a" / "blocked").is_file())
        self.answer("重试")
        r = self.drive()
        self.reached_reviewing(r)
        self.assertEqual(len(self.calls("exec-a")), 1)               # 重跑提交关口，不用再找执行会话

    def test_commit_touching_frozen_tests_is_rejected(self):
        self.simple(("a",))
        self.script("a", commit({"a.txt": "a\n", "tests/orc/check_a.sh": "true\n"}, [1]),
                    commit({"a.txt": "a\n", "tests/orc/check_a.sh": "grep -q '^a$' a.txt\n"}, [1], files=["a.txt"]))
        r = self.drive()
        self.reached_reviewing(r)
        first = self.ev("job-exit", type="gate")[0]
        self.assertEqual((first["outcome"], first["category"]), ("rejected", "tests"))
        self.assertIn("tests/orc/check_a.sh", first["reason"])
        self.assertEqual(first["checks"], {})                        # 不跑检查、不评审
        self.assertEqual(len(self.calls("review")), 2)               # 只有第二次提交和整体评审
        tip = self.git("rev-parse", "orc/m1")
        self.assertEqual(self.git("show", f"{tip}:tests/orc/check_a.sh"), "grep -q '^a$' a.txt")

    def test_worktree_test_with_wrong_hash_is_rejected(self):
        self.simple(("a",))
        self.script("a", commit({"a.txt": "a\n"}, [1]))
        self.step()
        # 有人绕过 broker 直接在节点分支上改了冻结的测试：工作区是干净的，但哈希对不上
        wt = self.wt("a")
        (wt / "tests" / "orc" / "check_a.sh").write_text("true\n")
        subprocess.run(["git", "-C", str(wt), "-c", "core.hooksPath=/dev/null", "commit", "-qm", "x",
                        "--", "tests/orc/check_a.sh"], check=True, env=self.env)
        self.run_orc("wait", "--mission", "m1", "--timeout", "30")
        self.step()
        self.run_orc("wait", "--mission", "m1", "--timeout", "60")
        self.step()
        gate, = self.ev("job-exit", type="gate")
        self.assertEqual((gate["outcome"], gate["category"]), ("rejected", "tests"))
        self.assertIn("哈希不一致", gate["reason"])
        self.assertEqual(self.calls("review"), [])

    def test_files_outside_the_node_are_rejected(self):
        self.simple(("a", "b"), depends={"b": ["a"]})
        self.script("a", commit({"a.txt": "a\n", "b.txt": "b\n"}, [1]), commit({"b.txt": None}, [1], files=["a.txt"]))
        self.script("b", commit({"b.txt": "b\n"}, [1]))
        r = self.drive()
        self.reached_reviewing(r)
        first = self.ev("job-exit", type="gate", node="a")[0]
        self.assertEqual((first["outcome"], first["category"]), ("rejected", "scope"))
        self.assertIn("b.txt", first["reason"])


class ExecutorResults(ExecCase):
    def test_result_that_does_not_match_the_worktree_is_sent_back(self):
        self.simple(("a",))
        self.script("a", json.dumps({"write": {"a.txt": "a\n", "junk.tmp": "x"},
                                     "out": {"status": "commit", "acceptance": [1], "files": ["a.txt"], "message": "a"}}),
                    json.dumps({"write": {"junk.tmp": None}, "raw": "好了"}),
                    commit({"a.txt": "a\n"}, [1]))
        r = self.drive()
        self.reached_reviewing(r)
        exits = self.ev("job-exit", type="executor")
        self.assertEqual([e["outcome"] for e in exits], ["invalid", "invalid", "commit"])
        self.assertIn("junk.tmp", exits[0]["problems"][0])
        self.assertIn("没有 JSON 对象", exits[1]["problems"][0])
        self.assertIn("orc 没能接受", self.calls("exec-a")[1]["prompt"])
        self.assertIn("--resume", self.calls("exec-a")[1]["args"])

    def test_crash_is_retried_once_then_blocks(self):
        self.simple(("a",))
        self.script("a", json.dumps({"exit": 3}), json.dumps({"exit": 3}), commit({"a.txt": "a\n"}, [1]))
        r = self.drive()
        self.assertTrue(self.next_line(r).startswith("next: ask-user "), r.stdout)
        calls = self.calls("exec-a")
        self.assertEqual(len(calls), 2)
        self.assertIn("--resume", calls[1]["args"])
        self.assertIn("异常结束", calls[1]["prompt"])
        self.answer("继续")
        self.reached_reviewing(self.drive())

    def test_timeout_kills_the_round_and_counts_as_a_crash(self):
        self.config(max_parallel=3, session_timeout_seconds=2, crash_retries=1)
        self.simple(("a",))
        self.script("a", json.dumps({"sleep": 60, "out": {"status": "question", "question": "x"}}),
                    commit({"a.txt": "a\n"}, [1]))
        started = time.monotonic()
        r = self.drive()
        self.reached_reviewing(r)
        self.assertLess(time.monotonic() - started, 45)
        first = self.ev("job-exit", type="executor")[0]
        self.assertEqual((first["outcome"], first["reason"]), ("failed", "超时被结束"))

    def test_question_blocks_and_answer_goes_back_to_the_same_session(self):
        self.simple(("a",))
        self.script("a", json.dumps({"out": {"status": "question", "question": "a.txt 要不要换行？"}}),
                    commit({"a.txt": "a\n"}, [1]))
        r = self.drive()
        self.assertTrue(self.next_line(r).startswith("next: ask-user "), r.stdout)
        self.assertIn("a.txt 要不要换行？", self.next_line(r))
        self.answer("要换行")
        self.reached_reviewing(self.drive())
        second = self.calls("exec-a")[1]
        self.assertIn("--resume", second["args"])
        self.assertIn("要换行", second["prompt"])


class Disputes(ExecCase):
    def test_test_wrong_goes_to_the_review_model_and_test_ok_resumes(self):
        m = self.simple(("a",))
        self.script("a", json.dumps({"out": {"status": "test-wrong", "check": "ca", "reason": "设计没说要换行"}}),
                    commit({"a.txt": "a\n"}, [1]))
        self.script("dispute", json.dumps({"out": {"verdict": "test-ok", "reason": "设计要求内容就是节点名"}}))
        self.reached_reviewing(self.drive())
        call, = self.calls("dispute")
        args = call["args"]
        self.assertEqual(args[args.index("--model") + 1], m.roles()["review"]["model"])   # 不是执行用的模型
        self.assertIn("--allowedTools=Read", args)                                        # 只读
        self.assertEqual(call["env"]["ORC_ROLE"], "dispute")
        self.assertIn("设计没说要换行", call["prompt"])
        self.assertIn("sh tests/orc/check_a.sh", call["prompt"])
        second = self.calls("exec-a")[1]
        self.assertIn("没有错", second["prompt"])
        self.assertIn("设计要求内容就是节点名", second["prompt"])

    def test_test_wrong_confirmed_blocks_for_the_user(self):
        self.simple(("a",))
        self.script("a", json.dumps({"out": {"status": "test-wrong", "check": "ca", "reason": "测试要求的不对"}}))
        self.script("dispute", json.dumps({"out": {"verdict": "test-wrong", "reason": "测试多要求了换行"}}))
        r = self.drive()
        self.assertTrue(self.next_line(r).startswith("next: ask-user "), r.stdout)
        self.assertIn("重新审阅、go、签名", self.next_line(r))
        self.assertTrue((self.mdir / "control" / "tasks" / "a" / "blocked").is_file())
        self.assertEqual(self.ev("commit"), [])


class NodeReview(ExecCase):
    def test_node_review_drift_sends_the_node_back_to_rework(self):
        self.simple(("a",))
        self.script("review", "ALIGNED", "DRIFT 整体上绕开了设计", "ALIGNED", "ALIGNED")
        self.script("a", commit({"a.txt": "a\n"}, [1]), commit({"a.txt": "a\nfixed\n"}, []))
        r = self.drive()
        self.reached_reviewing(r)
        submits = self.ev("job-exit", type="submit")
        self.assertEqual([s["outcome"] for s in submits], ["rework", "aligned"])
        self.assertIn("rework", [e["to"] for e in self.ev("node-state", node="a")])
        self.assertFalse((self.mdir / "control" / "tasks" / "a" / "unresolved-rework").exists())
        second = self.calls("exec-a")[1]
        self.assertIn("整体评审没通过", second["prompt"])
        self.assertIn("整体上绕开了设计", second["prompt"])
        roles = [c["role"] for c in self.calls("review")]
        self.assertEqual(roles, ["auto", "review", "auto", "review"])


class Recheck(ExecCase):
    def test_protocol_files_are_rechecked_before_reviewing(self):
        self.simple(("a",))
        self.script("a", commit({"a.txt": "a\n"}, [1]))
        # 一直跑到集成任务启动，等它结束，但先不让 orc 处理它
        for _ in range(20):
            r = self.step()
            if self.ev("job-start", type="integrate"):
                break
            self.run_orc("wait", "--mission", "m1", "--timeout", "60")
        self.run_orc("wait", "--mission", "m1", "--timeout", "60")
        # 记录的集成提交被换成一个不在 mission 分支上的提交
        side = self.git("commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "不在 mission 分支上的提交")
        (self.mdir / "control" / "tasks" / "a" / "integrated_sha").write_text(side + "\n")
        r = self.step()
        self.assertIn("重新核对协议文件时发现", self.next_line(r))
        self.assertIn("不在 orc/m1 上", self.next_line(r))
        self.assertEqual((self.mdir / "state").read_text().strip(), "executing")


class Setup(ExecCase):
    def test_unsigned_northstar_stops_before_execution(self):
        self.simple(("a",))
        (self.fake / "ns-unsigned").write_text("")
        r = self.step()
        self.assertIn("NORTHSTAR 签名校验没有通过", self.next_line(r))
        self.assertEqual((self.mdir / "state").read_text().strip(), "approved")
        self.assertEqual(self.ev("job-start"), [])
        self.assertEqual(self.git("branch", "--list", "orc/m1"), "")   # 没有开 mission 分支

    def test_product_repo_without_northstar_stops_with_a_clear_error(self):
        self.simple(("a",))
        subprocess.run(["git", "-C", str(self.repo), "rm", "-rq", ".northstar"], check=True)
        r = self.step()
        self.assertIn("没有 .northstar/NORTHSTAR.md", self.next_line(r))
        self.assertEqual((self.mdir / "state").read_text().strip(), "approved")


if __name__ == "__main__":
    unittest.main(verbosity=2)

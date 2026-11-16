#!/usr/bin/env python3
"""阶段 4 的契约测试：调度、执行会话、提交关口、broker、纠偏、整体评审、集成（docs/orc/STATE.md「执行」）。

不调用真实模型：执行会话、「判断测试对错」和偏离评审都用假的 claude，按脚本编排。假的 northstar-review 还装着，只用来确认 orc 不再调用它（2026-11-16 起提交关口不做对齐评审）。
commit-broker.sh、integrate-task.sh、检查的沙箱（sandbox-exec）都是真的。
执行会话的沙箱本身（git 只读、写不了 worktree 外、不能联网）是 Claude Code 的行为，这里只核对 orc 传给它的设置；
实测记录见 docs/orc/proposals/2026-11-07-stop-gate-implement.md。
"""
import json
import os
import re
import subprocess
import sys
import time
import unittest
from unittest import mock
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
MODEL = args[args.index("--model") + 1] if "--model" in args else "claude-unknown-0"
OVERRIDE = fake / f"model-usage-{os.environ.get('ORC_ROLE')}"   # 测试用：让这个角色的调用报别的模型
USAGE = json.loads(OVERRIDE.read_text()) if OVERRIDE.exists() else {MODEL: {"inputTokens": 1}}
envelope = lambda result: print(json.dumps({"type": "result", "is_error": False, "modelUsage": USAGE, "result": result}, ensure_ascii=False))
if role == "publish":
    # 假发布（阶段 5 的状态页）：记下调用，输出 claude.ai 链接
    pages = sorted(pathlib.Path(".").glob("*.html"))
    n = len(list(fake.glob("publish-call-*.json"))) + 1
    (fake / f"publish-call-{n}.json").write_text(json.dumps({"args": args, "cwd": os.getcwd(), "prompt": prompt,
        "pages": [p.name for p in pages]}, ensure_ascii=False))
    envelope(json.dumps({"url": f"https://claude.ai/artifact/fake-{pages[0].stem if pages else 'none'}"}))
    sys.exit(0)
NAMES = {"final-review": "final", "drift-review": "drift", "notes": "notes", "canvas": "canvas", "phase-conclusion": "phase", "cross-review": "cross",
         "diagnose": "diagnose", "repair-review": "repairreview"}
DEFAULTS = {"final": '{"verdict": "aligned", "drift": [], "notes": []}', "drift": '{"verdict": "aligned", "drift": [], "notes": []}',
            "notes": "AUTO",
            "canvas": '{"components": [{"id": "core", "name": "核心", "paths": ["*"]}]}',
            "phase": '{"items": [{"criterion": "主线跑通", "status": "met", "evidence": "PR 已合并"}]}',
            "cross": '{"verdict": "pass", "issues": [], "overrides_applied": []}',
            "diagnose": '{"kind": "design", "cause": "测试没有编排诊断"}',
            "repairreview": '{"verdict": "ok", "reason": "改动就是诊断说的那件事"}'}
if role in NAMES:
    # 最终审查 / 跨 mission 评审 / 画布 / phase 结论：按 script-<名字> 第 n 行，默认见 DEFAULTS。状态页说明默认 AUTO（引用提示词里列出的每个提交）
    name = NAMES[role]
    n = len(list(fake.glob(f"{name}-call-*.json"))) + 1
    while True:                             # 几个节点的偏离评审会同时调用：用独占创建占一个编号
        try:
            os.close(os.open(fake / f"{name}-call-{n}.json", os.O_CREAT | os.O_EXCL | os.O_WRONLY))
            break
        except FileExistsError:
            n += 1
    cwd = pathlib.Path(os.getcwd())
    (fake / f"{name}-call-{n}.json").write_text(json.dumps({"args": args, "cwd": os.getcwd(), "prompt": prompt,
        "files": sorted(str(p.relative_to(cwd)) for p in cwd.rglob("*") if p.is_file())}, ensure_ascii=False))
    script = fake / f"script-{name}"
    lines = [l for l in script.read_text().splitlines() if l.strip()] if script.exists() else []
    line = lines[n - 1] if n - 1 < len(lines) else DEFAULTS[name]
    if line == "crash":                     # 模型进程出错退出
        sys.exit(1)
    if line == "kill-parent":               # 调用它的 orc 进程整个消失（没有写出结果）
        import signal
        os.kill(os.getppid(), signal.SIGKILL)
        sys.exit(1)
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
print(json.dumps({"type": "result", "is_error": False, "modelUsage": USAGE, "session_id": session, "result": result}, ensure_ascii=False))
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
        (plan / "design.md").write_text("# 设计\n\n## 简要设计\n\n- 每个节点只写自己的一个文本文件，内容就是节点名。\n"
                                        "- 不要新建别的文件。\n\n## 细节\n\n每个节点写一个文本文件，内容就是节点名。\n")
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
            brief = orc.render_brief_exec(m) + orc.freeze_verification(m)
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
        # 不再每次提交都评审：每个节点做完时一次偏离评审（review 模型、只放行 Read、看不到 .northstar 和 .github）
        self.assertEqual(self.calls("review"), [])
        drifts = self.calls("drift")
        self.assertEqual(len(drifts), 2)
        for c in drifts:
            self.assertIn(self.orc.resolve_models()["roles"]["review"]["model"], c["args"])
            self.assertIn("--allowedTools=Read", c["args"])
            self.assertFalse([f for f in c["files"] if f.startswith((".northstar", ".github"))])
            self.assertIn("只写自己的一个文本文件", c["prompt"])            # 签名的简要设计
            self.assertNotIn("## 细节", c["prompt"])                      # 只给简要设计，不给完整设计
            self.assertIn("NORTHSTAR", c["prompt"])
        msg = self.git("log", "-1", "--format=%s", f"orc-task/m1/a")
        self.assertTrue(msg.startswith("[N1] a："), msg)                       # 提交说明带 N# 条款
        msg = self.git("log", "-1", "--format=%s", f"orc-task/m1/b")
        self.assertEqual(msg, "[N1] b：完成")                                   # 执行会话自带的标签和节点名不重复

    def test_commit_message_body_is_kept_for_the_repo_conventions(self):
        # 实跑（2026-11-08，fintelli-p1-1）：说明只让写一句，执行会话把「根因: …」塞进第一行，
        # 过不了产品仓库「正文要有一行根因」的检查（proposals/2026-11-08-commit-message-body.md）
        self.simple(("a",))
        self.script("a", commit({"a.txt": "a\n"}, [1], message="[N1] a：加 a.txt\n\n根因: 节点 a 还没有文件\n第二行"))
        self.reached_reviewing(self.drive())
        body = self.git("log", "-1", "--format=%B", "orc-task/m1/a")
        self.assertEqual(body, "[N1] a：加 a.txt\n\n根因: 节点 a 还没有文件\n第二行")
        brief = self.calls("exec-a")[0]["prompt"]
        self.assertIn("空一行", brief)                       # 说明里写明：仓库约定要求的正文写在空一行之后
        self.assertIn("AGENTS.md", brief)

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
        self.assertEqual(self.calls("drift"), [])                     # 检查不通过：不调用评审模型
        self.assertEqual(self.ev("commit"), [])
        card = Path(gate["card"]).read_text()
        self.assertIn("ca", card)
        self.assertIn("a.txt 的第一行是 a", card)                    # 纠偏单带验收标准原文
        r = self.drive()
        self.reached_reviewing(r)
        second = self.calls("exec-a")[1]
        self.assertIn("--resume", second["args"])
        self.assertIn("纠偏单", second["prompt"])

    def test_three_rejections_in_a_row_trip_the_breaker(self):
        # 提交关口连续被拒（这里是检查不过）：第 2 次撤回改动、新开会话，第 3 次熔断问人
        self.simple(("a",))
        self.script("a", *[commit({"a.txt": "wrong\n"}, [1])] * 3, commit({"a.txt": "a\n"}, [1]))
        r = self.drive()
        self.assertTrue(self.next_line(r).startswith("next: mediate "), r.stdout + r.stderr)
        self.assertEqual((self.mdir / "state").read_text().strip(), "blocked")
        self.assertTrue((self.mdir / "control" / "tasks" / "a" / "blocked").is_file())
        calls = self.calls("exec-a")
        self.assertEqual(len(calls), 3)
        self.assertIn("--resume", calls[1]["args"])                  # 第 1 次：纠偏单发回同一个会话
        self.assertIn("--session-id", calls[2]["args"])              # 第 2 次：改动撤回、新开会话
        self.assertNotEqual(calls[2]["session"], calls[0]["session"])
        self.assertIn("执行规则", calls[2]["prompt"])
        self.assertTrue((self.mdir / "nodes" / "a" / "discarded-1.patch").is_file())
        self.assertEqual((self.mdir / "control" / "tasks" / "a" / "generation").read_text().strip(), "2")
        self.assertEqual([e["count"] for e in self.ev("correction")], [1, 2, 3])
        self.assertEqual(self.ev("commit"), [])
        self.answer("a.txt 的第一行写 a")
        r = self.drive()
        self.reached_reviewing(r)
        fourth = self.calls("exec-a")[3]
        self.assertIn("--session-id", fourth["args"])
        self.assertIn("a.txt 的第一行写 a", fourth["prompt"])
        self.assertIn("已撤回", fourth["prompt"])

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
        self.assertEqual(len(self.calls("drift")), 1)                       # 节点做完时一次偏离评审
        self.assertIn("不改 worktree，`acceptance` 写它的编号", self.calls("exec-a")[0]["prompt"])   # brief 里写明了这种情况怎么交

    def test_one_success_resets_the_streak(self):
        self.simple(("a",), two_acceptance=True)
        self.script("a", commit({"a.txt": "x\n"}, [1]), commit({"a.txt": "a\n"}, [1]),
                    commit({"a2.txt": "x\n"}, [2]), commit({"a2.txt": "a2\n"}, [2]))
        r = self.drive()
        self.reached_reviewing(r)
        self.assertEqual([e["count"] for e in self.ev("correction")], [1, 1])   # 中间提交成功一次，计数清零
        self.assertFalse(list((self.mdir / "nodes" / "a").glob("discarded-*.patch")))

    def test_gate_no_longer_reviews_each_commit(self):
        # 偏离评审提案第 2 条决定：提交只靠冻结检查和底线；评审在节点做完时
        self.simple(("a",), two_acceptance=True)
        self.script("a", commit({"a.txt": "a\n"}, [1]), commit({"a2.txt": "a2\n"}, [2]))
        self.reached_reviewing(self.drive())
        self.assertEqual([g["outcome"] for g in self.ev("job-exit", type="gate")], ["committed", "committed"])
        self.assertTrue(all("review" not in g for g in self.ev("job-exit", type="gate")))
        self.assertEqual(len(self.calls("drift")), 1)

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
        self.assertEqual(len(self.calls("drift")), 1)                # 提交关口不评审，节点做完时一次偏离评审
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
        self.assertEqual(self.calls("drift"), [])

    def test_files_outside_the_node_are_rejected(self):
        self.simple(("a", "b"), depends={"b": ["a"]})
        self.script("a", commit({"a.txt": "a\n", "b.txt": "b\n"}, [1]), commit({"b.txt": None}, [1], files=["a.txt"]))
        self.script("b", commit({"b.txt": "b\n"}, [1]))
        r = self.drive()
        self.reached_reviewing(r)
        first = self.ev("job-exit", type="gate", node="a")[0]
        self.assertEqual((first["outcome"], first["category"]), ("rejected", "scope"))
        self.assertIn("b.txt", first["reason"])


class TestCrossesDag(ExecCase):
    """提交关口的兜底：冻结的测试导入了不是前置节点的节点新建的文件（两层冻结前的检查都漏了），orc 直接停下说明。"""

    def sibling(self, service_test, service_py):
        tasks = [task("fakes", ["fake.py"], ["fake.py 有 done"]), task("service", ["service.py"], ["service.py 有 run"])]
        tests = {"tests/orc/test_fakes.py": "import sys\nsys.path.insert(0, '.')\nfrom fake import done\n",
                 "tests/orc/test_service.py": service_test}
        checks = [{"id": n, "node": n, "acceptance": [1], "command": f"python3 tests/orc/test_{n}.py", "expect_before": "fail"}
                  for n in ("fakes", "service")]
        self.signed(tasks, checks, tests)
        self.script("fakes", commit({"fake.py": "done = 1\n"}, [1]))
        self.script("service", commit({"service.py": service_py}, [1]),
                    json.dumps({"out": {"status": "question", "question": "停一下"}}))

    def test_frozen_test_importing_a_sibling_file_parks_the_node_for_diagnosis(self):
        self.sibling("import sys\nsys.path.insert(0, '.')\nfrom fake import done\nimport service\n", "run = 1\n")
        r = self.drive()                                            # 没编排诊断：默认判成设计问题，停下问用户
        self.assertTrue(self.next_line(r).startswith("next: ask-user 诊断（_mission.diagnose.1）"), r.stdout + r.stderr)
        gate = self.ev("job-exit", type="gate", node="service")
        self.assertEqual(gate[-1]["outcome"], "test-crosses-dag")
        self.assertIn("检查 `service` 失败在导入 fake.py 上", gate[-1]["reason"])
        self.assertIn("节点 fakes 新建", gate[-1]["reason"])
        parked, = self.ev("node-parked", node="service")
        self.assertIn("节点 fakes 新建", parked["reason"])
        self.assertIn("节点 fakes 新建", self.calls("diagnose")[0]["prompt"])
        question = sorted((self.mdir / "questions").glob("*.md"))[-1].read_text()
        self.assertIn("orc abandon --mission m1", question)
        self.assertEqual(len(self.calls("exec-service")), 1)        # 没有把纠偏单退回给执行会话

    def test_implementation_importing_a_sibling_file_is_the_executors_fault(self):
        # 测试本身没写 fake：是实现去导入了别的节点的文件，照常退回执行会话
        self.sibling("import sys\nsys.path.insert(0, '.')\nimport service\n", "from fake import done\nrun = 1\n")
        self.drive()
        gate = self.ev("job-exit", type="gate", node="service")
        self.assertEqual(gate[0]["outcome"], "rejected")
        self.assertEqual(len(self.calls("exec-service")), 2)


class ExecutorResults(ExecCase):
    def test_result_without_json_is_sent_back(self):
        self.simple(("a",))
        self.script("a", json.dumps({"write": {"a.txt": "a\n"}, "raw": "好了"}), commit({"a.txt": "a\n"}, [1]))
        r = self.drive()
        self.reached_reviewing(r)
        exits = self.ev("job-exit", type="executor")
        self.assertEqual([e["outcome"] for e in exits], ["invalid", "commit"])
        self.assertIn("没有 JSON 对象", exits[0]["problems"][0])
        self.assertIn("orc 没能接受", self.calls("exec-a")[1]["prompt"])
        self.assertIn("--resume", self.calls("exec-a")[1]["args"])

    def test_commit_needs_no_files_list_and_leftovers_are_committed_or_rejected(self):
        # 执行会话不再写 files：orc 用 worktree 里的实际改动。留下的临时文件算进这次提交，不在声明文件里就被提交关口拒绝
        self.simple(("a",))
        self.script("a", json.dumps({"write": {"a.txt": "a\n", "junk.tmp": "x"},
                                     "out": {"status": "commit", "acceptance": [1], "message": "a"}}),
                    json.dumps({"write": {"junk.tmp": None}, "out": {"status": "commit", "acceptance": [1], "message": "a"}}))
        r = self.drive()
        self.reached_reviewing(r)
        self.assertEqual([e["outcome"] for e in self.ev("job-exit", type="executor")], ["commit", "commit"])
        gates = self.ev("job-exit", type="gate")
        self.assertEqual((gates[0]["outcome"], gates[0]["category"]), ("rejected", "scope"))
        self.assertIn("junk.tmp", gates[0]["reason"])
        self.assertEqual(gates[1]["outcome"], "committed")
        self.assertEqual(self.git("show", "orc/m1:a.txt"), "a")

    def test_one_round_can_complete_several_criteria(self):
        # 不再一轮一条：一次交两条验收标准，一个提交就做完这个节点
        self.simple(("a",), two_acceptance=True)
        self.script("a", commit({"a.txt": "a\n", "a2.txt": "a2\n"}, [1, 2]))
        r = self.drive()
        self.reached_reviewing(r)
        self.assertEqual(len(self.calls("exec-a")), 1)
        gate, = self.ev("job-exit", type="gate")
        self.assertEqual((gate["outcome"], sorted(gate["checks"])), ("committed", ["ca", "ca2"]))
        prompt = self.calls("exec-a")[0]["prompt"]
        self.assertIn("一轮做多少由你决定", prompt)
        self.assertNotIn("一轮只做一条", prompt)
        self.assertNotIn('"files"', prompt)

    def test_mission_signed_under_another_flow_version_stops(self):
        # 签名的执行规则没有流程版本（流程版本加进来之前 go 的）：签名的规则和代码不一致，不按任何一种继续；放弃照样能做
        m = self.simple(("a",))
        c = m.control
        brief = (c / "brief-exec.md").read_text()
        line = f"流程版本：{self.orc.FLOW_VERSION}\n"
        self.assertIn(line, brief)
        old = brief.replace(line, "")
        (c / "brief-exec.md").write_text(old)
        digest = __import__("hashlib").sha256(old.encode()).hexdigest()
        lines = [(f"{digest}  brief-exec.md" if l.endswith("  brief-exec.md") else l)
                 for l in (c / "approved.sha256").read_text().splitlines()]
        (c / "approved.sha256").chmod(0o644)                       # 冻结时设成了只读
        (c / "approved.sha256").write_text("\n".join(lines) + "\n")
        self.script("a", commit({"a.txt": "a\n"}, [1]))
        r = self.step()
        self.assertTrue(self.next_line(r).startswith(f"next: error mission m1 是按流程版本 0 签名的，现在的 orc 是流程版本 {self.orc.FLOW_VERSION}"),
                        r.stdout + r.stderr)
        self.assertIn("orc abandon --mission m1", self.next_line(r))
        self.assertEqual(self.calls("exec-a"), [])
        a = self.run_orc("abandon", "--mission", "m1", "签名时的规则已经不用了")
        self.assertEqual(a.returncode, 0, a.stdout + a.stderr)
        self.assertEqual(self.ev("state")[-1]["to"], "failed")

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

    def test_test_wrong_confirmed_parks_the_node_and_the_fix_takes_effect_after_signing(self):
        # 以前只能回到验证这一步重新审阅、go、签名；现在诊断写好修正，用户签一次名就接着做，已经做的保留
        self.simple(("a",))
        self.script("a", json.dumps({"out": {"status": "test-wrong", "check": "ca", "reason": "测试要求的不对"}}),
                    commit({"a.txt": "a\n"}, [1]))
        self.script("dispute", json.dumps({"out": {"verdict": "test-wrong", "reason": "测试多要求了换行"}}))
        self.script("diagnose", json.dumps({"kind": "test", "cause": "检查多要求了一个设计里没有的换行",
                                            "test_fix": [{"file": "tests/orc/check_a.sh", "content": "grep -q '^a' a.txt\n"}]}))
        r = self.drive()
        self.assertTrue(self.next_line(r).startswith("next: ask-user 诊断（_mission.diagnose.1）认为冻结的验收测试本身有错"), r.stdout)
        parked, = self.ev("node-parked", node="a")
        self.assertIn("测试多要求了换行", parked["reason"])
        self.assertIn("测试多要求了换行", self.calls("diagnose")[0]["prompt"])
        (self.mdir / "control" / "approved.sha256.sig").write_text("sig\n")      # 用户签名
        self.reached_reviewing(self.drive())
        self.assertEqual(self.git("show", "orc/m1:tests/orc/check_a.sh"), "grep -q '^a' a.txt")
        self.assertIn("冻结的验收测试已按诊断修正", self.calls("exec-a")[1]["prompt"])
        self.assertEqual(len(self.ev("commit", node="a")), 1)

    def test_node_whose_problem_is_in_another_nodes_file_waits_for_that_fix(self):
        # b 依赖 a；a 的文件有问题，b 的第 2 条验收标准过不了。b 先交了第 1 条，再说 outside 停下；诊断让 a 修（要先复现），
        # a 修好集成后 b 合并最新提交继续。合并提交也要带 [N#]：产品 CI 检查 PR 上每个提交
        tasks = [task("a", ["a.txt"], ["a.txt 是 a"]), task("b", ["b.txt"], ["b.txt 是 b", "a.txt 没有 bad"], ("a",))]
        tests = {"tests/orc/check_a.sh": "grep -q '^a' a.txt\n", "tests/orc/check_b1.sh": "grep -q '^b$' b.txt\n",
                 "tests/orc/check_b2.sh": "grep -q '^b$' b.txt && ! grep -q bad a.txt\n"}
        checks = [{"id": "ca", "node": "a", "acceptance": [1], "command": "sh tests/orc/check_a.sh", "expect_before": "fail"},
                  {"id": "cb1", "node": "b", "acceptance": [1], "command": "sh tests/orc/check_b1.sh", "expect_before": "fail"},
                  {"id": "cb2", "node": "b", "acceptance": [2], "command": "sh tests/orc/check_b2.sh", "expect_before": "fail"}]
        self.signed(tasks, checks, tests)
        self.script("a", commit({"a.txt": "a\nbad\n"}, [1]),
                    commit({}, [1]),                                     # 修复没有改动、说验收标准已满足：拒绝（不能绕过修复关口）
                    commit({"a.txt": "a\n"}, []))
        self.script("b", commit({"b.txt": "b\n"}, [1]),
                    json.dumps({"write": {"b.tmp": "x"},
                                "out": {"status": "outside", "reason": "a.txt 第 2 行的 bad 让 cb2 失败，不在我的文件里"}}),
                    commit({}, [2]))                                     # a 修好后第 2 条已经满足
        self.script("diagnose", json.dumps({"kind": "code", "cause": "a.txt 多了 bad", "files": ["a.txt"], "change": "删掉 bad",
                                            "evidence": [{"file": "a.txt", "line": 2}]}),
                    json.dumps({"kind": "code", "cause": "a.txt 多了 bad", "files": ["a.txt"], "change": "删掉 bad",
                                "evidence": [{"file": "a.txt", "line": 2}],
                                "repro": {"file": ".orc-repro/no_bad.sh", "content": "! grep -q bad a.txt\n",
                                          "command": "sh .orc-repro/no_bad.sh"}}))
        self.reached_reviewing(self.drive())
        self.assertEqual([e["node"] for e in self.ev("node-parked")], ["b"])
        first, diag = self.ev("job-exit", type="diagnose")
        self.assertEqual(first["outcome"], "invalid")                   # 没有可重跑的失败检查，必须先写复现
        self.assertIn("repro", first["problems"][0])
        self.assertIn("这次必须写复现", self.calls("diagnose")[0]["prompt"])
        self.assertEqual(diag["trigger"], "node")
        self.assertEqual(diag["facts"], [{"id": "repro", "fails": 10, "runs": 10}])   # 复现在当前提交上真的失败
        self.assertIn("不在我的文件里", self.calls("diagnose")[0]["prompt"])
        repair, = self.ev("repair")
        self.assertEqual(repair["targets"], {"a": ["a.txt"]})
        self.assertEqual([e["node"] for e in self.ev("node-reopen")], ["a"])
        gates = self.ev("job-exit", type="gate", node="a")
        self.assertEqual((gates[1]["outcome"], gates[1]["category"]), ("rejected", "scope"))
        self.assertIn("没有任何改动", gates[1]["reason"])
        fixed = gates[2]
        self.assertEqual(fixed["repair"]["after"], {"repro": {"fails": 0, "runs": 10}})   # 修好后复现连跑 10 次全过
        self.assertEqual(fixed["repair"]["revert"]["fails"], 10)
        unparked, = self.ev("node-unparked", node="b")
        self.assertIn("已经由节点 a 修好并集成", unparked["message"])
        self.assertTrue(list((self.mdir / "nodes" / "b").glob("discarded-*.patch")))   # 没提交的改动存成补丁
        self.assertEqual(self.git("show", "orc/m1:a.txt"), "a")
        base = self.ev("exec-setup")[0]["base"]
        subjects = self.git("log", "--format=%s", f"{base}..orc/m1").splitlines()
        self.assertTrue(any("合并 mission 分支的最新提交" in s for s in subjects), subjects)   # b 先提交过，继续时不是快进
        self.assertEqual([s for s in subjects if not re.match(r"^\[(N[0-9]+(,N[0-9]+)*|NS|orc)\]", s)], [])

    def test_conflict_when_a_waiting_node_merges_the_fix_asks_the_user(self):
        # s.txt 归 a 和 b（b 依赖 a）。b 改过 s.txt 后停下等 a 修；a 修好集成后 b 合并最新提交时冲突：
        # orc 不替用户挑哪边，撤销合并、停下问；用户自己合并提交后回答「继续」，b 接着做
        tasks = [task("a", ["a.txt", "s.txt"], ["a.txt 是 a"]), task("b", ["b.txt", "s.txt"], ["b.txt 是 b", "s.txt 第一行是 2"], ("a",))]
        tests = {"tests/orc/check_a.sh": "grep -q '^a$' a.txt\n", "tests/orc/check_b1.sh": "grep -q '^b$' b.txt\n",
                 "tests/orc/check_b2.sh": "grep -q '^b$' b.txt && head -1 s.txt | grep -q '^2$'\n"}
        checks = [{"id": "ca", "node": "a", "acceptance": [1], "command": "sh tests/orc/check_a.sh", "expect_before": "fail"},
                  {"id": "cb1", "node": "b", "acceptance": [1], "command": "sh tests/orc/check_b1.sh", "expect_before": "fail"},
                  {"id": "cb2", "node": "b", "acceptance": [2], "command": "sh tests/orc/check_b2.sh", "expect_before": "fail"}]
        self.signed(tasks, checks, tests)
        self.script("a", commit({"a.txt": "a\n", "s.txt": "1\n"}, [1]), commit({"s.txt": "2\n"}, []))
        self.script("b", commit({"b.txt": "b\n", "s.txt": "1\nb\n"}, [1]),
                    json.dumps({"out": {"status": "outside", "reason": "s.txt 第一行该是 2，那一行是 a 写的"}}),
                    commit({}, [2]))
        self.script("diagnose", json.dumps({"kind": "code", "cause": "s.txt 第一行写成了 1", "files": ["s.txt"], "change": "改成 2",
                                            "evidence": [{"file": "s.txt", "line": 1}],
                                            "repro": {"file": ".orc-repro/two.sh", "content": "head -1 s.txt | grep -q '^2$'\n",
                                                      "command": "sh .orc-repro/two.sh"}}))
        r = self.drive()
        line = self.next_line(r)
        self.assertTrue(line.startswith("next: ask-user 节点 b 合并 mission 分支的最新提交"), r.stdout + r.stderr)
        question = sorted((self.mdir / "questions").glob("*.md"))[-1].read_text()
        self.assertIn("git merge", question)
        self.assertEqual(self.ev("node-unparked", node="b"), [])
        wt = Path(re.search(r"在 `([^`]+)` 里运行", question).group(1))
        tip = self.git("rev-parse", "orc/m1")
        self.assertEqual(self.git("status", "--porcelain", cwd=wt), "")       # 合并已经撤销，节点保持原样
        # 用户自己解决冲突、提交（首行带 [N1]）
        subprocess.run(["git", "-C", str(wt), "merge", "-q", tip], capture_output=True)
        (wt / "s.txt").write_text("2\nb\n")
        subprocess.run(["git", "-C", str(wt), "add", "s.txt"], check=True)
        subprocess.run(["git", "-C", str(wt), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm",
                        "[N1] 合并 mission 分支，解决 s.txt 的冲突"], check=True)
        self.answer("继续")
        self.reached_reviewing(self.drive())
        self.assertEqual(len(self.ev("node-unparked", node="b")), 1)
        self.assertEqual(self.git("show", "orc/m1:s.txt"), "2\nb")
        base = self.ev("exec-setup")[0]["base"]
        subjects = self.git("log", "--format=%s", f"{base}..orc/m1").splitlines()
        self.assertEqual([s for s in subjects if not re.match(r"^\[(N[0-9]+(,N[0-9]+)*|NS|orc)\]", s)], [])

    def test_unpark_that_crashes_before_the_event_is_retried(self):
        # 继续停着的节点时，记 node-unparked 之前断掉：节点不能既不是 parked、又没有事件让它往下走
        self.simple(("a",))
        self.script("a", json.dumps({"out": {"status": "test-wrong", "check": "ca", "reason": "测试要求的不对"}}),
                    commit({"a.txt": "a\n"}, [1]))
        self.script("dispute", json.dumps({"out": {"verdict": "test-wrong", "reason": "测试多要求了换行"}}))
        self.script("diagnose", json.dumps({"kind": "test", "cause": "检查多要求了一个设计里没有的换行",
                                            "test_fix": [{"file": "tests/orc/check_a.sh", "content": "grep -q '^a' a.txt\n"}]}))
        r = self.drive()
        self.assertTrue(self.next_line(r).startswith("next: ask-user 诊断（_mission.diagnose.1）认为冻结的验收测试本身有错"), r.stdout)
        (self.mdir / "control" / "approved.sha256.sig").write_text("sig\n")      # 用户签名
        orc, original = self.orc, self.orc.Mission.append

        def crash_on_unpark(m, kind, *args, **kwargs):
            if kind == "node-unparked":
                raise RuntimeError("断电")
            return original(m, kind, *args, **kwargs)
        orc.Mission.append = crash_on_unpark
        try:
            with mock.patch.dict(os.environ, self.env), self.assertRaises(RuntimeError):
                orc.step(orc.Mission("m1"))
        finally:
            orc.Mission.append = original
        self.assertEqual(self.ev("node-unparked", node="a"), [])
        self.reached_reviewing(self.drive())
        self.assertEqual(len(self.ev("node-unparked", node="a")), 1)

    def test_unpark_that_crashes_after_the_event_does_not_stay_parked(self):
        # 记了 node-unparked、还没删 parked 就断掉：再 step 时补删，节点接着做，不停在 parked
        self.simple(("a",))
        self.script("a", json.dumps({"out": {"status": "test-wrong", "check": "ca", "reason": "测试要求的不对"}}),
                    commit({"a.txt": "a\n"}, [1]))
        self.script("dispute", json.dumps({"out": {"verdict": "test-wrong", "reason": "测试多要求了换行"}}))
        self.script("diagnose", json.dumps({"kind": "test", "cause": "检查多要求了一个设计里没有的换行",
                                            "test_fix": [{"file": "tests/orc/check_a.sh", "content": "grep -q '^a' a.txt\n"}]}))
        r = self.drive()
        self.assertTrue(self.next_line(r).startswith("next: ask-user 诊断（_mission.diagnose.1）认为冻结的验收测试本身有错"), r.stdout)
        (self.mdir / "control" / "approved.sha256.sig").write_text("sig\n")      # 用户签名
        orc, original = self.orc, self.orc.unpark_node
        parked = self.mdir / "control" / "tasks" / "a" / "parked"

        def unpark_then_crash(m, node, message):
            saved = parked.read_text()
            original(m, node, message)
            parked.write_text(saved)                 # 相当于删 parked 之前断掉
            raise RuntimeError("断电")
        orc.unpark_node = unpark_then_crash
        try:
            with mock.patch.dict(os.environ, self.env), self.assertRaises(RuntimeError):
                orc.step(orc.Mission("m1"))
        finally:
            orc.unpark_node = original
        self.assertTrue(parked.exists())
        self.reached_reviewing(self.drive())
        self.assertFalse(parked.exists())
        self.assertEqual(len(self.ev("node-unparked", node="a")), 1)

    def test_signed_test_fix_resumes_after_a_crash_midway(self):
        # 签名生效时，继续停着的节点之后、记 test-fix-signed 之前断掉：再 step 不重复提交、不重复继续，补记 test-fix-signed
        self.simple(("a",))
        self.script("a", json.dumps({"out": {"status": "test-wrong", "check": "ca", "reason": "测试要求的不对"}}),
                    commit({"a.txt": "a\n"}, [1]))
        self.script("dispute", json.dumps({"out": {"verdict": "test-wrong", "reason": "测试多要求了换行"}}))
        self.script("diagnose", json.dumps({"kind": "test", "cause": "检查多要求了一个设计里没有的换行",
                                            "test_fix": [{"file": "tests/orc/check_a.sh", "content": "grep -q '^a' a.txt\n"}]}))
        r = self.drive()
        self.assertTrue(self.next_line(r).startswith("next: ask-user 诊断（_mission.diagnose.1）认为冻结的验收测试本身有错"), r.stdout)
        (self.mdir / "control" / "approved.sha256.sig").write_text("sig\n")      # 用户签名
        orc, original = self.orc, self.orc.unpark_node

        def unpark_then_crash(*args, **kwargs):
            original(*args, **kwargs)
            raise RuntimeError("断电")
        orc.unpark_node = unpark_then_crash
        try:
            with mock.patch.dict(os.environ, self.env), self.assertRaises(RuntimeError):
                orc.step(orc.Mission("m1"))
        finally:
            orc.unpark_node = original
        self.assertEqual(len(self.ev("node-unparked", node="a")), 1)
        self.assertEqual(self.ev("test-fix-signed"), [])                  # 还没记：再 step 会接着做
        self.reached_reviewing(self.drive())
        self.assertEqual(len(self.ev("test-fix-signed")), 1)
        self.assertEqual(len(self.ev("node-unparked", node="a")), 1)      # 没有重复继续
        base = self.ev("exec-setup")[0]["base"]
        fixes = [s for s in self.git("log", "--format=%s", f"{base}..orc/m1").splitlines() if "验收测试（第 1 次修正" in s]
        self.assertEqual(len(fixes), 1)                                    # 没有重复提交
        self.assertEqual(len(self.ev("commit", node="a")), 1)

    def parked_test_fix(self):
        self.simple(("a",))
        self.script("a", json.dumps({"out": {"status": "test-wrong", "check": "ca", "reason": "测试要求的不对"}}),
                    commit({"a.txt": "a\n"}, [1]))
        self.script("dispute", json.dumps({"out": {"verdict": "test-wrong", "reason": "测试多要求了换行"}}))
        self.script("diagnose", json.dumps({"kind": "test", "cause": "检查多要求了一个设计里没有的换行",
                                            "test_fix": [{"file": "tests/orc/check_a.sh", "content": "grep -q '^a' a.txt\n"}]}))
        r = self.drive()
        self.assertTrue(self.next_line(r).startswith("next: ask-user 诊断（_mission.diagnose.1）认为冻结的验收测试本身有错"), r.stdout)

    def test_conflict_while_signing_keeps_asking_instead_of_erroring(self):
        # 签名生效时节点合并冲突：问题问出去后，下一次 step（phase 里每次都会走）照常停在冲突问题上，不报「orc 的 bug」
        self.parked_test_fix()
        (self.mdir / "control" / "approved.sha256.sig").write_text("sig\n")      # 用户签名
        orc, original = self.orc, self.orc.sync_to_tip

        def conflict(m, node):
            raise orc.SyncConflict(node, orc.mission_tip(m), m.worktree(node), ["N1"], "CONFLICT (content)")
        orc.sync_to_tip = conflict
        try:
            with mock.patch.dict(os.environ, self.env):
                first = orc.step(orc.Mission("m1"))
                second = orc.step(orc.Mission("m1"))
        finally:
            orc.sync_to_tip = original
        self.assertTrue(first.startswith("ask-user 节点 a 合并 mission 分支的最新提交"), first)
        self.assertEqual(second, first)
        self.assertEqual(self.ev("test-fix-signed"), [])
        self.answer("继续")
        self.reached_reviewing(self.drive())
        self.assertEqual(len(self.ev("test-fix-signed")), 1)
        self.assertEqual(len(self.ev("node-unparked", node="a")), 1)

    def test_crash_while_withdrawing_a_test_fix_is_not_taken_as_signed(self):
        # 用户不同意测试修正；撤回做到一半（旧签名已经恢复、还没记 test-fix-withdrawn）断掉：再 step 接着撤回，不当成已签名
        self.parked_test_fix()
        self.answer("这个修正不对，不同意")
        orc, original = self.orc, self.orc.Mission.append

        def append(self_, kind, *args, **kwargs):
            if kind == "test-fix-withdrawn":
                raise RuntimeError("断电")
            return original(self_, kind, *args, **kwargs)
        orc.Mission.append = append
        try:
            with mock.patch.dict(os.environ, self.env), self.assertRaises(RuntimeError):
                orc.step(orc.Mission("m1"))
        finally:
            orc.Mission.append = original
        self.assertTrue((self.mdir / "control" / "approved.sha256.sig").is_file())   # 旧签名已经恢复
        r = self.drive()
        self.assertTrue(self.next_line(r).startswith("next: ask-user 诊断（_mission.diagnose.2）"), r.stdout + r.stderr)
        self.assertEqual(self.ev("test-fix-signed"), [])
        self.assertEqual(len(self.ev("test-fix-withdrawn")), 1)
        self.assertEqual(self.ev("node-unparked", node="a"), [])
        self.assertIn("这个修正不对，不同意", self.calls("diagnose")[1]["prompt"])


class NodeReview(ExecCase):
    DRIFT = json.dumps({"verdict": "drift", "drift": [{"rule": "extra", "evidence": {"side": "tip", "file": "a.txt", "line": 1},
                                                       "why": "整体上绕开了设计"}], "notes": []}, ensure_ascii=False)
    ALIGNED = json.dumps({"verdict": "aligned", "drift": [], "notes": ["顺带一提"]}, ensure_ascii=False)

    def test_node_review_drift_sends_the_node_back_to_rework(self):
        self.simple(("a",))
        self.script("drift", self.DRIFT, self.ALIGNED)
        self.script("a", commit({"a.txt": "a\n"}, [1]), commit({"a.txt": "a\nfixed\n"}, []))
        r = self.drive()
        self.reached_reviewing(r)
        submits = self.ev("job-exit", type="submit")
        self.assertEqual([s["outcome"] for s in submits], ["rework", "aligned"])
        self.assertIn("rework", [e["to"] for e in self.ev("node-state", node="a")])
        self.assertFalse((self.mdir / "control" / "tasks" / "a" / "unresolved-rework").exists())
        second = self.calls("exec-a")[1]
        self.assertIn("整体评审没通过", second["prompt"])
        self.assertIn("[extra] a.txt:1：整体上绕开了设计", second["prompt"])
        drifts = self.calls("drift")
        self.assertEqual(len(drifts), 2)
        self.assertIn("整体上绕开了设计", drifts[1]["prompt"])           # 重评带上上一次的原因
        self.assertIn('"id": "a"', drifts[0]["prompt"])                  # 节点评审带节点的 DAG 条目
        # 集成的就是偏离评审看过的那个提交
        reviewed = submits[1]["head"]
        self.assertEqual((self.mdir / "nodes" / "a" / "verification.sha").read_text().strip(), reviewed)
        self.assertIn("偏离评审 aligned", (self.mdir / "control" / "tasks" / "a" / "coordinator-verification.md").read_text())

    def test_second_drift_in_a_row_stops_and_asks(self):
        # 11-10 定：第二次还是 drift 就停下问你；回答发给执行会话，之后计数清零
        self.simple(("a",))
        self.script("drift", self.DRIFT, self.DRIFT, self.ALIGNED)
        self.script("a", commit({"a.txt": "a\n"}, [1]), commit({"a.txt": "a\nb\n"}, []), commit({"a.txt": "a\nc\n"}, []))
        r = self.drive()
        self.assertTrue(self.next_line(r).startswith("next: mediate "), r.stdout + r.stderr)
        self.assertIn("连续 2 次判 drift", Path(self.next_line(r)[len("next: mediate "):]).read_text())
        self.assertEqual(len(self.calls("exec-a")), 2)
        self.answer("这个节点只写 a.txt 的第一行，别的都不要")
        r = self.drive()
        self.reached_reviewing(r)
        self.assertIn("只写 a.txt 的第一行", self.calls("exec-a")[2]["prompt"])
        self.assertEqual([s["outcome"] for s in self.ev("job-exit", type="submit")], ["rework", "rework", "aligned"])

    BAD = json.dumps({"verdict": "drift", "drift": [{"rule": "N1", "evidence": {"side": "tip", "file": "a.txt", "line": 99},
                                                     "why": "x"}]})

    def test_bad_evidence_is_sent_back_to_be_rewritten(self):
        # orc 核对证据的文件和行：不对就发回重写一次
        self.simple(("a",))
        self.script("drift", self.BAD, self.ALIGNED)
        self.script("a", commit({"a.txt": "a\n"}, [1]))
        self.reached_reviewing(self.drive())
        drifts = self.calls("drift")
        self.assertEqual(len(drifts), 2)
        self.assertIn("a.txt 在 tip 上只有 1 行，没有第 99 行", drifts[1]["prompt"])
        self.assertEqual([s["outcome"] for s in self.ev("job-exit", type="submit")], ["aligned"])

    def test_output_failing_the_checks_twice_blocks(self):
        # 第二次还不合格：不放行、不降级，停下问；回答「重试」重新评审
        self.simple(("a",))
        nope = json.dumps({"verdict": "drift", "drift": [{"rule": "N99", "evidence": {"file": "nope.txt", "line": 1}, "why": "x"}]})
        self.script("drift", self.BAD, nope)
        self.script("a", commit({"a.txt": "a\n"}, [1]))
        r = self.drive()
        self.assertTrue(self.next_line(r).startswith("next: ask-user 节点 a 的整体评审没能完成"), r.stdout + r.stderr)
        question = sorted((self.mdir / "questions").glob("*.md"))[-1].read_text()
        self.assertIn("连续 2 次没有通过核对", question)
        self.assertIn("N99 不在 NORTHSTAR 里", question)
        self.answer("重试")
        self.reached_reviewing(self.drive())
        self.assertEqual(len(self.calls("drift")), 3)

    def test_head_changed_after_review_is_reviewed_again_before_integration(self):
        # 偏离评审之后节点的 HEAD 又变了（测试修正后同步、集成失败后改了提交）：不集成，回到整体评审，集成新评审过的提交
        self.simple(("a",))
        self.script("a", commit({"a.txt": "a\n"}, [1]))
        orc, original = self.orc, self.orc.launch_integrate
        changed = []

        def change_then_integrate(m, node):
            if not changed:
                wt = self.wt(node)
                (wt / "a.txt").write_text("a\n\n")
                subprocess.run(["git", "-C", str(wt), "-c", "core.hooksPath=/dev/null", "commit", "-qam", "[N1] a：评审之后的提交"],
                               check=True, env=self.env)
                changed.append(subprocess.run(["git", "-C", str(wt), "rev-parse", "HEAD"], capture_output=True,
                                              text=True).stdout.strip())
            return original(m, node)
        orc.launch_integrate = change_then_integrate
        try:
            with mock.patch.dict(os.environ, self.env):
                for _ in range(40):
                    nxt = orc.step(orc.Mission("m1"))
                    if changed or not str(nxt).startswith("wait"):
                        break
                    self.run_orc("wait", "--mission", "m1", "--timeout", "60")
        finally:
            orc.launch_integrate = original
        self.assertTrue(changed)
        deferred, = self.ev("integrate-deferred", node="a")
        self.assertEqual(deferred["head"], changed[0])
        self.reached_reviewing(self.drive())
        submits = self.ev("job-exit", type="submit")
        self.assertEqual([s["outcome"] for s in submits], ["aligned", "aligned"])
        self.assertEqual(submits[1]["head"], changed[0])
        self.assertEqual(len(self.calls("drift")), 2)
        self.assertEqual((self.mdir / "nodes" / "a" / "verification.sha").read_text().strip(), changed[0])
        self.assertEqual(self.git("show", "orc/m1:a.txt"), "a")      # 集成的是第二次评审过的提交（多一个空行）
        self.assertIn("\n\n", subprocess.run(["git", "-C", str(self.repo), "show", "orc/m1:a.txt"],
                                               capture_output=True, text=True).stdout)

    def test_review_crash_blocks_instead_of_downgrading(self):
        self.simple(("a",))
        self.script("drift", "crash")
        self.script("a", commit({"a.txt": "a\n"}, [1]))
        r = self.drive()
        self.assertTrue(self.next_line(r).startswith("next: ask-user "), r.stdout + r.stderr)
        self.assertIn("不降级", self.next_line(r))
        self.assertEqual(len(self.calls("drift")), 1)                # 没有换一个模型再审
        self.answer("重试")
        r = self.drive()
        self.reached_reviewing(r)
        self.assertEqual(len(self.calls("exec-a")), 1)               # 重做整体评审，不用再找执行会话

    def test_large_diff_goes_by_file_list_and_read(self):
        self.simple(("a",))
        self.script("a", commit({"a.txt": "a\n" + "x" * 70000 + "\n"}, [1]))
        self.reached_reviewing(self.drive())
        prompt = self.calls("drift")[0]["prompt"]
        self.assertIn("超过 60000", prompt)
        self.assertNotIn("x" * 1000, prompt)
        self.assertIn("a.txt", self.calls("drift")[0]["files"])       # 代码副本里有，评审用 Read 看


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

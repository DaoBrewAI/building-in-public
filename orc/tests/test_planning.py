#!/usr/bin/env python3
"""阶段 3：规划会话、审阅页发布、go 关口与签名。python3 orc/tests/test_planning.py

规划会话、验证会话和发布（都是 claude -p）、签名校验（northstar）都换成可编排的假命令：
$ORC_FAKE/script 每行决定第几次规划运行做什么；$ORC_FAKE/vscript 每行决定第几次验证运行做什么；
$ORC_FAKE/publish 决定发布成功还是失败。
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import textwrap
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_orc import ORC, ORC_ROOT, OrcCase  # noqa: E402

# 检查命令用的是 PATH 里的 python3，不是跑这些测试的解释器
PYTEST_PY = shutil.which("python3") or sys.executable
HAS_PYTEST = subprocess.run([PYTEST_PY, "-c", "import pytest"], capture_output=True).returncode == 0
# 没装 pytest 的解释器：python -m pytest 会以退出码 1 退出，但 pytest 根本没运行
NO_PYTEST_PY = "#!/bin/sh\necho \"$0: No module named pytest\" >&2\nexit 1\n"

FAKE_CLAUDE = r'''#!/usr/bin/env python3
import json, os, sys, time, pathlib
fake = pathlib.Path(os.environ["ORC_FAKE"])
args = sys.argv[1:]
if "-p" not in args:
    sys.exit(2)
prompt = sys.stdin.read()
if os.environ.get("ORC_ROLE") == "publish":
    # 假发布：记下调用，检查网页文件在当前目录里，输出和 claude -p --output-format json 一样的信封
    calls = fake / "publish-calls"
    calls.write_text((calls.read_text() if calls.exists() else "") + json.dumps({"args": args, "cwd": os.getcwd(), "prompt": prompt}) + "\n")
    mode = (fake / "publish").read_text().strip() if (fake / "publish").exists() else "ok"
    if not pathlib.Path("plan.html").is_file():
        line = json.dumps({"error": "no plan.html"})
    elif mode == "ok":
        line = json.dumps({"url": "https://claude.ai/code/artifact/fake-plan"})
    else:
        line = json.dumps({"error": "Artifact tool unavailable"})
    print(json.dumps({"type": "result", "is_error": False, "result": "发布好了。\n" + line}))
    sys.exit(0)
if os.environ.get("ORC_ROLE") == "verify":
    # 假验证会话：在 repo/ 里写测试，在工作目录根上写 checks.json
    n = len(list(fake.glob("verify-call-*.json"))) + 1
    session = args[args.index("--session-id") + 1] if "--session-id" in args else args[args.index("--resume") + 1]
    work = pathlib.Path(os.getcwd())
    (fake / f"verify-call-{n}.json").write_text(json.dumps({"args": args, "cwd": os.getcwd(), "prompt": prompt,
        "role": os.environ.get("ORC_ROLE"), "files": sorted(str(p.relative_to(work)) for p in work.rglob("*")
                                                           if ".runs" not in p.parts)}))
    vs = [l for l in (fake / "vscript").read_text().splitlines() if l.strip()] if (fake / "vscript").exists() else []
    action = vs[n - 1] if n - 1 < len(vs) else "ok"
    test = work / "repo" / "tests" / "orc" / "test_export.sh"
    def write(body, files=("tests/orc/test_export.sh",), acceptance=(1,), command="sh tests/orc/test_export.sh"):
        path = work / "repo" / files[0] if files[0].endswith(".py") else test
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body)
        (work / "checks.json").write_text(json.dumps({"version": 1, "mission": os.environ["ORC_MISSION"],
            "test_files": list(files), "checks": [{"id": "export-writes-csv", "node": "export", "acceptance": list(acceptance),
            "command": command, "expect_before": "fail"}]}))
    py = (fake / "pytest-python").read_text().strip() if (fake / "pytest-python").exists() else "python3"
    pytest_cmd = py + " -m pytest -q -p no:cacheprovider tests/orc/test_export_acceptance.py"
    if action.startswith("question:"):
        (work / "QUESTION.md").write_text(action.split(":", 1)[1])
    elif action == "ok":
        write("test -f src/export.py\n")
    elif action == "escape":
        write('echo x > "$ORC_FAKE/escaped"; curl -s -m 3 https://example.com > /dev/null && touch net-open; test -f src/export.py\n')
    elif action == "pytest-collect":       # 文件开头导入还不存在的模块：收集阶段就报错，断言没有运行
        write("from export import write_csv\n\ndef test_export():\n    assert write_csv() == 'a,b'\n",
              files=("tests/orc/test_export_acceptance.py",), command=pytest_cmd)
    elif action == "pytest-missing":       # 解释器里没有 pytest：退出码也是 1
        write("def test_export():\n    from export import write_csv\n    assert write_csv() == 'a,b'\n",
              files=("tests/orc/test_export_acceptance.py",),
              command=pytest_cmd.replace(py + " ", "nopytest-python ", 1))
    elif action == "pytest-assert":        # 在测试函数里导入：接口不存在时是这条测试失败
        write("def test_export():\n    from export import write_csv\n    assert write_csv() == 'a,b'\n",
              files=("tests/orc/test_export_acceptance.py",), command=pytest_cmd)
    elif action == "passing":
        write("true\n")                      # 实现之前就通过：什么也没测
    elif action == "overlap":
        (work / "repo" / "src").mkdir(parents=True, exist_ok=True)
        (work / "repo" / "src" / "export.py").write_text("x = 1\n")
        write("test -f src/export.py\n", files=("src/export.py",))
    elif action == "uncovered":
        write("test -f src/export.py\n", acceptance=(2,))
    elif action == "nochecks":
        test.parent.mkdir(parents=True, exist_ok=True); test.write_text("x\n")
        (work / "checks.json").unlink(missing_ok=True)
    print(json.dumps({"type": "result", "is_error": False, "session_id": session, "result": "done"}))
    sys.exit(0)
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

FAKE_NORTHSTAR = r'''#!/bin/sh
# 假 northstar：verify（产品仓库的 NORTHSTAR 签名）在 $ORC_FAKE/ns-unsigned 不存在时通过；
# verify-mission 在 $ORC_FAKE/sig-ok 存在且 control 里有签名文件时通过
if [ "$1" = verify ]; then
  [ -f "$ORC_FAKE/ns-unsigned" ] && { echo "缺少签名，请运行 northstar seal" >&2; exit 1; }
  exit 0
fi
[ "$1" = verify-mission ] && [ -f "$ORC_FAKE/sig-ok" ] && [ -f "$2/approved.sha256.sig" ]
'''


class PlanningCase(OrcCase):
    def setUp(self):
        super().setUp()
        self.fake = self.tmp / "fake"
        self.fake.mkdir()
        bin_ = self.tmp / "fakebin"
        bin_.mkdir()
        (self.fake / "pytest-python").write_text(PYTEST_PY)
        for name, body in (("claude", FAKE_CLAUDE), ("nopytest-python", NO_PYTEST_PY)):
            (bin_ / name).write_text(body.replace("#!/usr/bin/env python3", f"#!{sys.executable}", 1))
            (bin_ / name).chmod(0o755)
        ns = self.tmp / "ns"
        (ns / "bin").mkdir(parents=True)
        (ns / "bin" / "northstar").write_text(FAKE_NORTHSTAR)
        (ns / "bin" / "northstar").chmod(0o755)
        # 产品仓库带 NORTHSTAR：节点的 clauses 不能为空
        (self.repo / ".northstar").mkdir()
        (self.repo / ".northstar" / "NORTHSTAR.md").write_text("# NORTHSTAR\n- N1: 报表可以导出\n")
        (self.repo / "README.md").write_text("product\n")
        self.commit("初始提交")
        self.env.update(ORC_FAKE=str(self.fake), ORC_NORTHSTAR_ROOT=str(ns),
                        ORC_WORKTREES=str(self.tmp / "wt"), PATH=f"{bin_}:/usr/bin:/bin")
        os.environ["ORC_WORKTREES"] = str(self.tmp / "wt")

    def tearDown(self):
        os.environ.pop("ORC_WORKTREES", None)
        super().tearDown()

    def commit(self, message):
        subprocess.run(["git", "-C", str(self.repo), "add", "-A"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", message],
                       check=True, env=self.env)

    def vscript(self, *steps):
        (self.fake / "vscript").write_text("\n".join(steps) + "\n")

    def vcalls(self):
        return [json.loads(p.read_text()) for p in sorted(self.fake.glob("verify-call-*.json"), key=lambda p: int(p.stem[12:]))]

    def through_verify(self):
        """规划产出通过之后：这次 step 进入 verifying 并启动验证会话，再等它结束。"""
        r = self.step()
        self.assertEqual(self.next_line(r), "next: wait", r.stdout + r.stderr)
        self.assertIn("planning → verifying", r.stdout)
        self.wait()

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


class NorthstarSigned(PlanningCase):
    def test_unsigned_northstar_stops_before_planning(self):
        (self.fake / "ns-unsigned").write_text("")
        r, mdir = self.new()
        self.assertIn("NORTHSTAR 签名校验没有通过", self.next_line(r))
        self.assertIn("northstar seal", self.next_line(r))
        self.assertEqual((mdir / "state").read_text().strip(), "new")
        self.assertEqual(self.calls(), [])                         # 没有启动规划会话
        (self.fake / "ns-unsigned").unlink()
        r = self.step()
        self.assertEqual(self.next_line(r), "next: wait", r.stdout + r.stderr)   # 签好后接着走


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
        self.through_verify()
        r = self.step()
        self.assertTrue(self.next_line(r).startswith("next: go-gate "), r.stdout)

    def test_crash_with_nonzero_rc_is_retried_in_the_same_session(self):
        self.script("crash", "ok")
        r, mdir = self.new()
        self.wait()
        r = self.step()                        # 第 1 次失败：自动重跑（同一会话）
        self.assertEqual(self.next_line(r), "next: wait")
        self.wait()
        self.through_verify()
        r = self.step()
        self.assertTrue(self.next_line(r).startswith("next: go-gate "), r.stdout)
        self.assertIn("--resume", self.calls()[1]["args"])


class Outputs(PlanningCase):
    def test_valid_outputs_go_to_plan_review_and_publish(self):
        mdir = self.to_plan_review("ok")
        self.through_verify()
        r = self.step()
        self.assertEqual(self.next_line(r), "next: go-gate https://claude.ai/code/artifact/fake-plan", r.stdout + r.stderr)
        self.assertEqual((mdir / "state").read_text().strip(), "plan-review")
        for f in ("design.md", "plan.md", "task-dag.json"):
            self.assertTrue((mdir / "plan" / f).is_file(), f)
        kinds = [e["kind"] for e in self.events(mdir)]
        self.assertIn("plan-ready", kinds)
        self.assertIn("published", kinds)
        page = (self.tmp / "wt" / "m1" / "site" / "plan.html").read_text()
        self.assertTrue(page.startswith("<title>m1 计划审阅</title>"))   # Artifact 约定：不带 doctype，title 在最前
        self.assertIn("用 CSV", page)
        self.assertIn("导出 CSV", page)               # DAG 的验收标准出现在审阅页
        r2 = self.step()                               # 页面没变：不重复发布
        self.assertEqual(self.next_line(r2), self.next_line(r))
        self.assertEqual(len((self.fake / "publish-calls").read_text().splitlines()), 1)

    def publish_calls(self):
        return [json.loads(l) for l in (self.fake / "publish-calls").read_text().splitlines()]

    def test_publisher_only_reads_and_publishes(self):
        mdir = self.to_plan_review("ok")
        self.through_verify()
        self.step()
        call = self.publish_calls()[0]
        args = call["args"]
        self.assertIn("--allowedTools=Read,Artifact", args)
        self.assertFalse(any(a.startswith(("--add-dir", "--dangerously")) for a in args), args)
        models = json.loads((mdir / "models.json").read_text())["roles"]
        self.assertEqual(args[args.index("--model") + 1], models["plan"]["model"])
        self.assertEqual(os.path.realpath(call["cwd"]), os.path.realpath(self.tmp / "wt" / "m1" / "site"))
        self.assertIn("`plan.html`", call["prompt"])
        self.assertIn("第一次发布", call["prompt"])

    def test_changed_page_updates_the_same_artifact(self):
        mdir = self.to_plan_review("ok")
        self.through_verify()
        self.step()
        (mdir / "plan" / "plan.md").write_text("# 计划\n1. 导出\n2. 筛选\n")
        r = self.step()
        self.assertEqual(self.next_line(r), "next: go-gate https://claude.ai/code/artifact/fake-plan")
        calls = self.publish_calls()
        self.assertEqual(len(calls), 2)
        self.assertIn("https://claude.ai/code/artifact/fake-plan", calls[1]["prompt"])   # 带原链接更新，不新建
        self.assertNotIn("第一次发布", calls[1]["prompt"])

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
        self.through_verify()
        r = self.step()
        self.assertTrue(self.next_line(r).startswith("next: go-gate "), r.stdout)
        first, second = self.calls()
        session = first["args"][first["args"].index("--session-id") + 1]
        self.assertEqual(second["args"][second["args"].index("--resume") + 1], session)
        self.assertIn("不包含", second["prompt"])
        self.assertFalse((self.tmp / "wt" / "m1" / "plan-work" / "QUESTION.md").exists())


class Verify(PlanningCase):
    """验收测试在实现之前，由独立的验证会话写好（docs/orc/proposals/2026-11-07-tests-before-implement.md）。"""

    def test_verifier_gets_design_and_dag_but_not_the_plan(self):
        mdir = self.to_plan_review("ok")
        self.through_verify()
        (v,) = self.vcalls()
        args = v["args"]
        models = json.loads((mdir / "models.json").read_text())["roles"]
        self.assertEqual(args[args.index("--model") + 1], models["review"]["model"])   # 和执行用的模型不同
        self.assertNotEqual(models["review"]["model"], models["implement"]["model"])
        self.assertEqual(v["role"], "verify")
        self.assertIn("--session-id", args)
        work = self.tmp / "wt" / "m1" / "verify-work"
        self.assertEqual(os.path.realpath(v["cwd"]), os.path.realpath(work))
        self.assertIn("spec/design.md", v["files"])
        self.assertIn("spec/task-dag.json", v["files"])
        self.assertIn("repo/README.md", v["files"])                        # 当前提交的代码副本
        self.assertFalse(any(f.endswith("plan.md") for f in v["files"]), v["files"])   # 看不到计划
        self.assertFalse(any(".git" in Path(f).parts for f in v["files"]))
        settings = json.loads(next(a for a in args if a.startswith("--settings="))[len("--settings="):])
        self.assertEqual(settings["sandbox"]["filesystem"]["denyWrite"], [os.path.realpath(self.repo)])
        self.assertNotIn("# 计划", v["prompt"])
        r = self.step()
        self.assertTrue(self.next_line(r).startswith("next: go-gate "), r.stdout)
        ready = [e for e in self.events(mdir) if e["kind"] == "verify-ready"][0]
        self.assertEqual(ready["results"], {"export-writes-csv": 1})     # 实际运行过，实现前失败
        page = (self.tmp / "wt" / "m1" / "site" / "plan.html").read_text()
        self.assertIn("验收测试", page)
        self.assertLess(page.index("一图看懂"), page.index("核对用的哈希"))      # 图为主的一节放在最前面
        self.assertIn('<div class="card"><div class="ch"><b>export</b>', page)  # 每个节点一张卡片
        self.assertIn('<span class="pill new"', page)                           # 验收标准旁边是对应的检查
        self.assertIn("test -f src/export.py", page)                       # 测试全文在审阅页上
        self.assertIn(models["review"]["model"], page)

    def test_check_that_passes_before_implementation_is_sent_back(self):
        self.vscript("passing", "ok")
        mdir = self.to_plan_review("ok")
        self.through_verify()
        r = self.step()
        self.assertEqual(self.next_line(r), "next: wait", r.stdout)
        first, = [e for e in self.events(mdir) if e["kind"] == "verifier-exit"]
        self.assertEqual(first["outcome"], "invalid")
        self.assertIn("就通过了", first["problems"][0])
        self.wait()
        second = self.vcalls()[1]
        self.assertIn("--resume", second["args"])
        self.assertIn("就通过了", second["prompt"])
        r = self.step()
        self.assertTrue(self.next_line(r).startswith("next: go-gate "), r.stdout)

    @unittest.skipUnless(HAS_PYTEST, "PATH 里的 python3 没有 pytest")
    def test_pytest_check_must_fail_on_an_assertion_not_on_collection(self):
        self.vscript("pytest-collect", "pytest-missing", "pytest-assert")
        mdir = self.to_plan_review("ok")
        self.through_verify()
        for _ in range(2):
            r = self.step()
            self.assertEqual(self.next_line(r), "next: wait", r.stdout + r.stderr)
            self.wait()
        first, second = [e for e in self.events(mdir) if e["kind"] == "verifier-exit"][:2]
        for exit_ in (first, second):
            self.assertEqual(exit_["outcome"], "invalid")
            self.assertEqual(len(exit_["problems"]), 1, exit_["problems"])
            self.assertIn("断言没有运行", exit_["problems"][0])
        self.assertIn("退出码是 2", first["problems"][0])
        self.assertIn("error during collection", first["problems"][0])       # 附上了 pytest 的输出
        self.assertIn("退出码是 1", second["problems"][0])
        self.assertIn("No module named pytest", second["problems"][0])
        self.assertIn("--resume", self.vcalls()[1]["args"])
        self.assertIn("断言没有运行", self.vcalls()[1]["prompt"])
        r = self.step()
        self.assertTrue(self.next_line(r).startswith("next: go-gate "), r.stdout + r.stderr)
        result, = json.loads((mdir / "verify" / "results.json").read_text())["results"]
        self.assertEqual(result["rc"], 1)
        page = (self.tmp / "wt" / "m1" / "site" / "plan.html").read_text()
        self.assertIn("1 failed", page)                                # 审阅页显示检查失败时的输出

    def test_bad_outputs_are_rejected_with_reasons_then_mediated(self):
        self.vscript("overlap", "uncovered", "nochecks")
        mdir = self.to_plan_review("ok")
        self.through_verify()
        for _ in range(2):
            r = self.step()
            self.assertEqual(self.next_line(r), "next: wait", r.stdout)
            self.wait()
        r = self.step()
        self.assertTrue(self.next_line(r).startswith("next: mediate "), r.stdout)
        problems = [e["problems"] for e in self.events(mdir) if e["kind"] == "verifier-exit"]
        self.assertTrue(any("和节点声明的文件重叠" in p for p in problems[0]), problems[0])
        self.assertFalse(any("是仓库里已有的文件" in p for p in problems[0]))
        self.assertTrue(any("第 1 条验收标准没有检查" in p for p in problems[1]), problems[1])
        self.assertTrue(any("缺少 checks.json" in p for p in problems[2]), problems[2])
        self.assertEqual((mdir / "state").read_text().strip(), "blocked")

    def test_existing_file_cannot_be_used_as_a_test(self):
        (self.repo / "tests" / "orc").mkdir(parents=True)
        (self.repo / "tests" / "orc" / "test_export.sh").write_text("old\n")
        self.commit("已有测试")
        self.vscript("ok")
        mdir = self.to_plan_review("ok")
        self.through_verify()
        r = self.step()
        self.assertEqual(self.next_line(r), "next: wait")
        exit_ = [e for e in self.events(mdir) if e["kind"] == "verifier-exit"][0]
        self.assertTrue(any("是仓库里已有的文件" in p for p in exit_["problems"]), exit_["problems"])

    def test_question_blocks_and_answer_resumes_the_verifier(self):
        self.vscript("question:导出失败时要报错还是返回空文件？", "ok")
        mdir = self.to_plan_review("ok")
        self.through_verify()
        r = self.step()
        self.assertEqual(self.next_line(r), "next: ask-user 导出失败时要报错还是返回空文件？")
        self.assertEqual(self.run_orc("answer", "报错").returncode, 0)
        r = self.step()
        self.assertIn("blocked → verifying", r.stdout)
        self.assertEqual(self.next_line(r), "next: wait")
        self.wait()
        first, second = self.vcalls()
        self.assertEqual(second["args"][second["args"].index("--resume") + 1],
                         first["args"][first["args"].index("--session-id") + 1])
        self.assertIn("报错", second["prompt"])
        r = self.step()
        self.assertTrue(self.next_line(r).startswith("next: go-gate "), r.stdout)

    def test_checks_run_sandboxed_on_a_clean_copy(self):
        # 检查命令是 agent 写的：只能写快照目录和临时目录，不能联网
        self.vscript("escape")
        mdir = self.to_plan_review("ok")
        self.through_verify()
        r = self.step()
        self.assertTrue(self.next_line(r).startswith("next: go-gate "), r.stdout)
        self.assertFalse((self.fake / "escaped").exists())
        self.assertFalse((self.tmp / "wt" / "m1" / "verify-work" / ".check-run" / "net-open").exists())
        self.assertFalse((self.repo / "net-open").exists())

    def test_new_commit_in_product_repo_during_verify_stops(self):
        mdir = self.to_plan_review("ok")
        self.through_verify()
        (self.repo / "src").mkdir()
        (self.repo / "src" / "export.py").write_text("x = 1\n")
        self.commit("有人在验证期间提交了实现")
        r = self.step()
        self.assertTrue(self.next_line(r).startswith("next: error "), r.stdout)
        self.assertIn("当前提交", self.next_line(r))


class Publish(PlanningCase):
    def test_publish_failure_never_offers_a_local_file(self):
        (self.fake / "publish").write_text("fail")
        mdir = self.to_plan_review("ok")
        self.through_verify()
        r = self.step()
        self.assertTrue(self.next_line(r).startswith("next: error "), r.stdout)
        self.assertIn("审阅页发布失败", self.next_line(r))
        self.assertNotIn("go-gate", r.stdout)
        self.assertEqual((mdir / "state").read_text().strip(), "plan-review")
        (self.fake / "publish").write_text("ok")
        r = self.step()
        self.assertTrue(self.next_line(r).startswith("next: go-gate https://"), r.stdout)


class ReviseAndGo(PlanningCase):
    def at_gate(self, *steps):
        mdir = self.to_plan_review(*steps)
        self.through_verify()
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
        self.through_verify()
        r = self.step()
        self.assertTrue(self.next_line(r).startswith("next: go-gate "), r.stdout)
        # 重新规划之后，验证从头写：新会话（不 resume 上一轮），并带上用户的意见
        first, second = self.vcalls()
        self.assertIn("--session-id", second["args"])
        self.assertNotEqual(first["args"][first["args"].index("--session-id") + 1],
                            second["args"][second["args"].index("--session-id") + 1])
        self.assertIn("再加一个按日期筛选", second["prompt"])

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
        # 验收测试冻结进 control/，哈希写进签名的 brief-exec.md
        frozen_test = c / "approved-tests" / "tests" / "orc" / "test_export.sh"
        self.assertEqual(frozen_test.read_text(), "test -f src/export.py\n")
        checks = json.loads((c / "approved-checks.json").read_text())
        self.assertEqual([x["id"] for x in checks["checks"]], ["export-writes-csv"])
        brief = (c / "brief-exec.md").read_text()
        self.assertIn("## 冻结的验收测试", brief)
        self.assertIn(hashlib.sha256((c / "approved-checks.json").read_bytes()).hexdigest(), brief)
        self.assertIn(hashlib.sha256(frozen_test.read_bytes()).hexdigest(), brief)
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
        self.through_verify()
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

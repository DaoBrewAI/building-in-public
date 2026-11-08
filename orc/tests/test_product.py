#!/usr/bin/env python3
"""阶段 6 的契约测试：画布、DAG 组件和 mission 范围、推翻已有决定、phase（依赖、并行、人工 mission、等合并、结论）、
跨 mission 评审、汇总页（docs/orc/STATE.md「产品层」）。

不调用真实模型和 GitHub：用 test_execution 的假 claude（画布、phase 结论、跨 mission 评审按 $ORC_FAKE/script-<名字> 编排）
和 test_acceptance 的假 gh（$ORC_FAKE/gh-merged 里列出已合并的 PR）。信任层从签名的 control 目录读 scope / forbid 的测试在
docs/orc/northstar-staging/tests/test_guard_scope.sh。
"""
import json
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_acceptance import AcceptCase  # noqa: E402
from test_execution import commit  # noqa: E402

CANVAS = {"components": [
    {"id": "core", "name": "核心", "paths": ["src/core/*"]},
    {"id": "ui", "name": "界面", "paths": ["src/ui/*"], "depends_on": ["core"]},
    {"id": "docs", "name": "文档", "paths": ["*.md", "tests/*"]}]}


class ProductCase(AcceptCase):
    def setUp(self):
        super().setUp()
        self.strategy = self.tmp / "strategy"
        (self.strategy / "phases").mkdir(parents=True)
        (self.strategy / "missions").mkdir()
        (self.strategy / "design.md").write_text("# 产品设计\n\n核心算数，界面显示。\n")
        (self.repo / ".northstar" / "NORTHSTAR.md").write_text("# NORTHSTAR\n- N1: 报表可以导出\n- N2: 导出要有日志\n")
        subprocess.run(["git", "-C", str(self.repo), "add", "-A"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "NORTHSTAR"],
                       check=True, env=self.env)
        r = self.run_orc("product", "shop", "--design", str(self.strategy / "design.md"), "--phases", str(self.strategy / "phases"),
                         "--missions", str(self.strategy / "missions"), "--repo", f"main={self.repo}")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.pdir = self.home / "products" / "shop"
        self.env["ORC_MERGE_POLL_SECONDS"] = "1"

    def phase(self, deps, missions):
        """写 phase 文档 P1（依赖表）和 mission 文件。missions：id → 文件头的额外几行。"""
        (self.strategy / "phases" / "P1.md").write_text(
            "# P1\n\n## 依赖\n\n" + "".join(f"- {k}：{v}\n" for k, v in deps.items())
            + "\n## 完成标准\n\n- 主线跑通\n")
        for mid, head in missions.items():
            (self.strategy / "missions" / f"{mid}-x.md").write_text(f"# MISSION: {mid}\n服务的条款: N1\n{head}\n\n## 验收标准\n- [ ] 做 {mid}\n")

    def run_phase(self):
        return self.run_orc("phase", "--product", "shop", "--phase", "P1")

    def pevents(self, kind=None):
        path = self.pdir / "events.jsonl"
        evs = [json.loads(l) for l in path.read_text().splitlines()] if path.exists() else []
        return [e for e in evs if kind is None or e["kind"] == kind]

    def done_mission(self, mid, merged=True, design="# 设计\n\n所有导出都走 export_api。\n", recorded=False):
        """造一个已经跑完（cleaned）、开过 PR 的 phase mission，不跑真实流程。merged：PR 在假 gh 里已合并；
        recorded：产品的事件记录里已经记下合并（等于 orc phase 之前查到过）。"""
        orc = self.orc
        name = f"shop-{mid.lower()}"
        m = orc.create_mission(f"# MISSION: {mid}\n仓库: main\n", str(self.repo), name)
        for k, v in (("product", "shop"), ("phase", "P1"), ("mission-id", mid)):
            (m.dir / k).write_text(v + "\n")
        (m.control / "approved-design.md").write_text(design)
        url = f"https://github.com/o/r/pull/{100 + len(list(self.home.glob('missions/*')))}"
        with m:
            for to in ("planning", "verifying", "plan-review", "approved", "executing", "reviewing", "accepted", "cleaned"):
                m.transition(to, "test")
            m.append("pr", "test", url=url, number=1, tip="0" * 40, branch=f"orc/{name}")
        if merged:
            with open(self.fake / "gh-merged", "a") as f:
                f.write(url + "\n")
        if recorded:
            orc.Product("shop").append("merged", phase="P1", mission_id=mid, mission=name, sha="f" * 40)
        return m, url


class PlanValidation(ProductCase):
    """规划校验：组件只能从签名的画布里选，不越出 scope、不碰 forbid，「推翻的已有决定」要引用用户的回答。"""

    def mission(self, request):
        m = self.orc.create_mission(request, str(self.repo), "pv")
        work = self.tmp / "pv-work"
        work.mkdir()
        (work / "design.md").write_text("# 设计\n")
        return m, work

    def test_component_must_come_from_the_signed_canvas(self):
        (self.repo / ".northstar" / "architecture.json").write_text(json.dumps(CANVAS))
        m, work = self.mission("加导出")
        problems = self.orc.product_plan_problems(m, work, [
            {"id": "a", "component": "core", "files": ["src/core/x.py"]},
            {"id": "b", "component": "billing", "files": ["src/billing/y.py"]}])
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("component「billing」不在签名的画布里", problems[0])
        self.assertIn("core、ui、docs", problems[0])

    def test_without_a_canvas_any_component_name_is_fine(self):
        m, work = self.mission("加导出")
        self.assertEqual(self.orc.product_plan_problems(m, work, [{"id": "a", "component": "随便", "files": ["x.py"]}]), [])

    def test_files_outside_scope_and_inside_forbid_are_rejected(self):
        (self.repo / ".northstar" / "architecture.json").write_text(json.dumps(CANVAS))
        m, work = self.mission("# MISSION: x\nscope: core   # 注释\nforbid: src/core/secret*, package.json\n")
        problems = self.orc.product_plan_problems(m, work, [
            {"id": "ok", "component": "core", "files": ["src/core/a.py"]},
            {"id": "ui", "component": "ui", "files": ["src/ui/b.py"]},
            {"id": "out", "component": "core", "files": ["src/ui/c.py"]},
            {"id": "stop", "component": "core", "files": ["src/core/secret.py"]}])
        text = "\n".join(problems)
        self.assertIn("节点 ui 的 component「ui」不在这个 mission 的 scope 里", text)
        self.assertIn("节点 out 的文件越出了 mission 的 scope（core）：src/ui/c.py", text)
        self.assertIn("节点 stop 的文件碰到了 mission 的 forbid", text)
        self.assertNotIn("节点 ok", text)

    def test_overturned_decision_needs_a_user_answer(self):
        m, work = self.mission("加导出")
        (work / "design.md").write_text("# 设计\n\n## 推翻的已有决定\n\n- 推翻 P1-1 的「都走 API」：改成直接读库\n")
        problems = self.orc.product_plan_problems(m, work, [])
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("没有引用用户同意它的回答", problems[0])
        # 有用户的回答、并且引用了：放行
        q = m.ask("可以推翻 P1-1 的「都走 API」吗？", "ask-user", "test")
        (m.dir / "answers" / q.name).write_text("可以\n")
        m.append("answer", "test", id=q.stem, file=str(m.dir / "answers" / q.name))
        (work / "design.md").write_text(f"# 设计\n\n## 推翻的已有决定\n\n- 推翻 P1-1 的「都走 API」：改成直接读库 [answer:{q.stem}]\n")
        self.assertEqual(self.orc.product_plan_problems(m, work, []), [])
        # 引用了不存在的回答：退回
        (work / "design.md").write_text("# 设计\n\n## 推翻的已有决定\n\n- 推翻 X [answer:999]\n")
        self.assertEqual(len(self.orc.product_plan_problems(m, work, [])), 1)

    def test_planner_brief_lists_canvas_scope_and_the_overturn_rule(self):
        (self.repo / ".northstar" / "architecture.json").write_text(json.dumps(CANVAS))
        m, work = self.mission("# MISSION: x\nscope: core\nforbid: package.json\n")
        prompt = self.orc.planner_prompt(m, work)
        self.assertIn("`component` **只能**从这些组件 id 里选", prompt)
        self.assertIn("`core`（核心）：src/core/*", prompt)
        self.assertIn("scope = core；forbid = package.json", prompt)
        self.assertIn("不要自己决定推翻它", prompt)

    def test_scope_and_forbid_are_frozen_into_the_signed_brief(self):
        m, _ = self.mission("# MISSION: x\nscope: core, ui\nforbid: package.json\n")
        block = self.orc.scope_block(m)
        self.assertIn("scope: core, ui\n", block)
        self.assertIn("forbid: package.json\n", block)


class ExecutorScopeEnv(ProductCase):
    def test_executor_session_carries_the_signed_control_dir(self):
        m = self.simple(("a",))
        self.script("a", commit({"a.txt": "a\n"}, [1]))
        self.drive()
        call = self.calls("exec-a")[0]
        self.assertEqual(call["env"]["ORC_MISSION_CONTROL"], str(Path(m.control).resolve()))


class Canvas(ProductCase):
    def test_canvas_is_drafted_validated_and_published(self):
        bad = json.dumps({"components": [{"id": "core", "name": "核心", "paths": ["src/*"]}]})   # README.md 不在任何组件里
        good = json.dumps({"components": [{"id": "core", "name": "核心", "paths": ["src/*"]},
                                          {"id": "docs", "name": "文档", "paths": ["*.md", "tests/*"], "depends_on": ["core"]}]})
        self.script("canvas", bad, good)
        r = self.run_orc("canvas", "--product", "shop", "--repo", "main")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.next_line(r), "next: canvas https://claude.ai/artifact/fake-canvas-main")
        draft = json.loads((self.repo / "drafts" / "architecture.json").read_text())
        self.assertEqual([c["id"] for c in draft["components"]], ["core", "docs"])
        calls = self.calls("canvas")
        self.assertEqual(len(calls), 2)
        self.assertIn("不属于任何组件", calls[1]["prompt"])              # 第一次没过校验，问题发回去
        self.assertIn("核心算数，界面显示", calls[0]["prompt"])           # 读的是产品设计文档
        self.assertEqual(calls[0]["args"][calls[0]["args"].index("--tools") + 1], "")
        self.assertFalse((self.repo / ".northstar" / "architecture.json").exists())   # 只写草稿，签名由用户做
        self.assertEqual(self.pevents("canvas-draft")[0]["repo"], "main")


class Phase(ProductCase):
    def test_missions_start_in_dependency_order_and_independent_ones_in_parallel(self):
        self.phase({"P1-1": "无", "P1-2": "无", "P1-3": "依赖 P1-1、P1-2"},
                   {"P1-1": "仓库: main\nscope: core", "P1-2": "仓库: main\nscope: ui", "P1-3": "仓库: main"})
        r = self.run_phase()
        self.assertTrue(self.next_line(r).startswith("next: "), r.stdout + r.stderr)
        started = [e["mission_id"] for e in self.pevents("mission-start")]
        self.assertEqual(started, ["P1-1", "P1-2"])                     # 没有依赖的一起开始，P1-3 等着
        req = (self.home / "missions" / "shop-p1-1" / "request.md").read_text()
        self.assertIn("# MISSION: P1-1", req)                            # 请求就是 mission 文件全文
        self.assertEqual((self.home / "missions" / "shop-p1-1" / "product").read_text().strip(), "shop")

    def test_independent_missions_with_overlapping_scope_run_one_at_a_time(self):
        self.phase({"P1-1": "无", "P1-2": "无", "P1-3": "无"},
                   {"P1-1": "仓库: main\nscope: core", "P1-2": "仓库: main\nscope: core, ui", "P1-3": "仓库: main\nscope: docs"})
        r = self.run_phase()
        self.assertEqual([e["mission_id"] for e in self.pevents("mission-start")], ["P1-1", "P1-3"])
        self.assertIn("P1-2 和 P1-1 在同一个仓库里、scope 有重叠", r.stdout)

    def test_dependent_mission_waits_for_the_pr_to_be_merged(self):
        self.phase({"P1-1": "无", "P1-2": "依赖 P1-1"}, {"P1-1": "仓库: main", "P1-2": "仓库: main"})
        _, url = self.done_mission("P1-1", merged=False)
        r = self.run_phase()
        self.assertEqual(self.next_line(r), "next: wait", r.stdout + r.stderr)
        self.assertEqual(self.pevents("mission-start"), [])             # PR 还没合并，P1-2 不开始
        (self.fake / "gh-merged").write_text(url + "\n")
        w = self.run_orc("wait", "--product", "shop", "--phase", "P1", "--timeout", "30")
        self.assertEqual(w.returncode, 0, w.stdout + w.stderr)
        r = self.run_phase()
        self.assertEqual([e["mission_id"] for e in self.pevents("merged")], ["P1-1"])
        self.assertEqual([e["mission_id"] for e in self.pevents("mission-start")], ["P1-2"])

    def test_manual_mission_waits_for_orc_done_then_phase_concludes(self):
        self.phase({"P1-1": "无", "P1-2": "依赖 P1-1"}, {"P1-1": "仓库: main", "P1-2": "执行: 人工"})
        self.done_mission("P1-1")
        r = self.run_phase()
        self.assertTrue(self.next_line(r).startswith("next: ask-user phase P1 在等人工 mission：P1-2"), r.stdout + r.stderr)
        self.assertIn("orc done --product shop --phase P1", self.next_line(r))
        bad = self.run_orc("done", "P1-1", "--product", "shop", "--phase", "P1")
        self.assertNotEqual(bad.returncode, 0)                            # orc 跑的 mission 不能手动标完成
        self.assertEqual(self.run_orc("done", "P1-2", "--product", "shop", "--phase", "P1").returncode, 0)
        r = self.run_phase()
        self.assertEqual(self.next_line(r), "next: report https://claude.ai/artifact/fake-summary", r.stdout + r.stderr)
        concl, = self.pevents("phase-conclusion")
        self.assertEqual(concl["items"][0]["status"], "met")
        call, = self.calls("phase")
        self.assertIn("主线跑通", call["prompt"])                         # 对照的是 phase 文档的完成标准

    def test_bad_dependency_tables_stop_with_a_clear_message(self):
        cases = [
            ({"P1-1": "依赖 P1-2", "P1-2": "依赖 P1-1"}, {"P1-1": "仓库: main", "P1-2": "仓库: main"}, "依赖有环"),
            ({"P1-1": "依赖 P1-9"}, {"P1-1": "仓库: main"}, "不在这个 phase 的依赖表里"),
            ({"P1-1": "无"}, {"P1-1": "服务的条款: N1"}, "「仓库:」没有写"),
            ({"P1-1": "无"}, {"P1-1": "仓库: other"}, "不在产品配置的 [repos] 里"),
        ]
        for deps, missions, text in cases:
            for f in (self.strategy / "missions").glob("*.md"):
                f.unlink()
            self.phase(deps, missions)
            r = self.run_phase()
            self.assertTrue(self.next_line(r).startswith("next: error"), r.stdout + r.stderr)
            self.assertIn(text, self.next_line(r))
        (self.strategy / "phases" / "P1.md").write_text("# P1\n\nP1-1 和 P1-2 可以并行。\n")
        self.assertIn("没有「依赖」一节", self.next_line(self.run_phase()))


class CrossMission(ProductCase):
    def product_mission(self):
        m = self.simple(("a",))
        for k, v in (("product", "shop"), ("phase", "P1"), ("mission-id", "P1-2")):
            (m.dir / k).write_text(v + "\n")
        return m

    def test_conflict_reopens_the_node_instead_of_opening_a_pr(self):
        self.done_mission("P1-1", design="# 设计\n\n决定：所有导出都走 export_api。\n", recorded=True)
        self.product_mission()
        self.script("a", commit({"a.txt": "a\n"}, [1]), commit({"a.txt": "a\n\n"}, []))
        self.script("cross", json.dumps({"verdict": "conflict", "issues": [
            {"node": "a", "problem": "绕开了 P1-1 的「都走 export_api」", "evidence": "a.txt:1"}], "overrides_applied": []}),
            json.dumps({"verdict": "pass", "issues": [], "overrides_applied": []}))
        r = self.drive()
        self.assertEqual(self.next_line(r), "next: report https://claude.ai/artifact/fake-status", r.stdout + r.stderr)
        crosses = self.ev("job-exit", type="cross")
        self.assertEqual([e["outcome"] for e in crosses], ["rework", "passed"])
        reopen, = self.ev("node-reopen", node="a")
        self.assertEqual(reopen["stage"], "跨 mission 评审")
        pr, = self.ev("pr")
        # 冲突那一轮没有开 PR：PR 只针对通过评审的 tip
        self.assertEqual(pr["tip"], crosses[1]["tip"])
        self.assertNotEqual(crosses[0]["tip"], crosses[1]["tip"])
        prompt = self.calls("cross")[0]["prompt"]
        self.assertIn("决定：所有导出都走 export_api", prompt)           # 此前合并的 mission 签名的设计
        self.assertIn("核心算数，界面显示", prompt)                      # 产品设计文档
        self.assertIn("没有这一节：不允许推翻任何已有决定", prompt)
        self.assertIn("--allowedTools=Read", self.calls("cross")[0]["args"])
        self.assertIn("绕开了 P1-1", self.calls("exec-a")[1]["prompt"])

    def test_signed_overrides_are_given_to_the_reviewer(self):
        self.done_mission("P1-1")
        m = self.product_mission()
        design = m.control / "approved-design.md"
        for f in (design, m.control / "approved.sha256"):
            f.chmod(0o644)                                                  # 冻结的文件是只读的
        design.write_text(design.read_text() + "\n## 推翻的已有决定\n\n- 推翻 P1-1 的「都走 export_api」：改成直接读库 [answer:001]\n")
        self.script("a", commit({"a.txt": "a\n"}, [1]))
        # 改了冻结文件：签名校验在测试里是假的，哈希校验要跟着改
        orc = self.orc
        lines = (m.control / "approved.sha256").read_text().splitlines()
        lines = [f"{orc.sha256_file(design)}  approved-design.md" if l.endswith("approved-design.md") else l for l in lines]
        (m.control / "approved.sha256").write_text("\n".join(lines) + "\n")
        r = self.drive()
        self.assertEqual(self.next_line(r), "next: report https://claude.ai/artifact/fake-status", r.stdout + r.stderr)
        self.assertIn("改成直接读库 [answer:001]", self.calls("cross")[0]["prompt"])

    def test_three_conflicts_trip_the_breaker(self):
        self.done_mission("P1-1")
        self.product_mission()
        fix = lambda n: commit({"a.txt": "a\n" + "\n" * n}, [])
        self.script("a", commit({"a.txt": "a\n"}, [1]), fix(1), fix(2), fix(3))
        bad = json.dumps({"verdict": "conflict", "issues": [{"node": "a", "problem": "冲突", "evidence": "a.txt:1"}]})
        self.script("cross", bad, bad, bad)
        r = self.drive()
        self.assertTrue(self.next_line(r).startswith("next: mediate "), r.stdout + r.stderr)
        self.assertEqual(len(self.ev("node-reopen")), 2)
        self.assertEqual(self.ev("pr"), [])

    def test_missions_outside_a_product_skip_the_cross_review(self):
        self.simple(("a",))
        self.script("a", commit({"a.txt": "a\n"}, [1]))
        r = self.drive()
        self.assertEqual(self.next_line(r), "next: report https://claude.ai/artifact/fake-status", r.stdout + r.stderr)
        self.assertEqual(self.ev("job-exit", type="cross"), [])


class Summary(ProductCase):
    def test_summary_lists_every_mission_and_clause_and_flags_unimplemented_ones(self):
        (self.repo / ".northstar" / "architecture.json").write_text(json.dumps(CANVAS))
        self.phase({"P1-1": "无", "P1-2": "无"}, {"P1-1": "仓库: main", "P1-2": "执行: 人工"})
        m, _ = self.done_mission("P1-1")
        (m.control / "approved-task-dag.json").write_text(json.dumps({"tasks": [
            {"id": "export", "clauses": ["N1"], "files": ["src/core/x.py"], "component": "core"}]}))
        with m:
            m.append("commit", "test", node="export", sha="a" * 40, files=["src/core/x.py"])
            m.append("review", "test", node="export", verdict="DRIFT", reason="x")
        self.run_phase()                                                  # 记下 P1-1 合并
        html = self.orc.render_summary(self.orc.Product("shop"))
        self.assertIn("<code>P1-1</code>", html)
        self.assertIn("<code>P1-2</code>", html)
        self.assertIn("人工待办", html)
        self.assertIn("<b>N1</b>", html)
        self.assertIn("<b>N2</b>", html)
        n2 = html[html.index("<b>N2</b>"):].split("</tr>")[0]
        self.assertIn("没有任何 mission 实现", n2)                       # N2 没人实现，单独标出
        n1 = html[html.index("<b>N1</b>"):].split("</tr>")[0]
        self.assertIn("P1-1 / export", n1)
        self.assertIn("aaaaaaaaaa", n1)
        self.assertIn("日志 ", n1)                                       # 证据能追溯到日志行号
        self.assertIn("<td>1</td>", n1)                                  # 被 DRIFT 打回过一次
        cards = {c.split("<code>")[1].split("</code>")[0]: c for c in html.split("<details")[1:]}
        self.assertTrue(cards["core"].startswith(' class="comp done"'), cards["core"][:80])   # 改过它的 mission 都已合并
        self.assertTrue(cards["ui"].startswith(' class="comp none"'), cards["ui"][:80])       # 还没有 mission 改过


if __name__ == "__main__":
    unittest.main(verbosity=2)

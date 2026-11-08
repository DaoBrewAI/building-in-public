#!/usr/bin/env python3
"""阶段 5 的契约测试：最终审查、打回节点、开 PR、等 CI、验收前重新核对、状态页、清理（docs/orc/STATE.md「验收」）。

不调用真实模型和 GitHub：最终审查、状态页说明、发布用假的 claude（见 test_execution.FAKE_EXEC_CLAUDE），
PR 和 CI 用假的 gh（按 $ORC_FAKE 里的文件编排）。origin 是本地的裸仓库，推送是真的。
"""
import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_execution import ExecCase, commit, task  # noqa: E402

FAKE_GH = r'''#!/usr/bin/env python3
# 假 gh：pr list / pr create / pr view / pr checks / repo view。PR 记在 $ORC_FAKE/gh-prs.json；
# CI 结果来自 $ORC_FAKE/gh-checks-<n>.json（第 n 次 pr checks，没有就用 gh-checks.json，再没有就 verify、exam 都通过）
import json, os, pathlib, subprocess, sys
fake = pathlib.Path(os.environ["ORC_FAKE"])
args = sys.argv[1:]
log = fake / "gh-calls"
log.write_text((log.read_text() if log.exists() else "") + json.dumps({"args": args, "cwd": os.getcwd()}) + "\n")
prs_file = fake / "gh-prs.json"
prs = json.loads(prs_file.read_text()) if prs_file.exists() else []
if args[:2] == ["repo", "view"]:
    print("main")
elif args[:2] == ["pr", "list"]:
    print(json.dumps([p for p in prs if p["head"] == args[args.index("--head") + 1]]))
elif args[:2] == ["pr", "create"]:
    url = f"https://github.com/o/r/pull/{len(prs) + 7}"
    prs.append({"url": url, "number": len(prs) + 7, "head": args[args.index("--head") + 1], "base": args[args.index("--base") + 1]})
    prs_file.write_text(json.dumps(prs))
    print(url)
elif args[:2] == ["pr", "view"] and "state,mergeCommit" in args:
    # 合并了没有：$ORC_FAKE/gh-merged 里每行一个已合并的 PR 链接
    merged = (fake / "gh-merged").read_text().split() if (fake / "gh-merged").exists() else []
    print(f"MERGED {'f' * 40}" if args[2] in merged else "OPEN ")
elif args[:2] == ["pr", "view"]:
    head = fake / "gh-head"
    if head.exists():
        print(head.read_text().strip())
    else:
        pr = next(p for p in prs if p["url"] == args[2])
        print(subprocess.run(["git", "rev-parse", f"refs/heads/{pr['head']}"], capture_output=True, text=True).stdout.strip())
elif args[:2] == ["pr", "checks"]:
    n = len(list(fake.glob("gh-checks-call-*"))) + 1
    (fake / f"gh-checks-call-{n}").write_text("")
    f = fake / f"gh-checks-{n}.json"
    f = f if f.exists() else fake / "gh-checks.json"
    print(f.read_text() if f.exists() else json.dumps([{"name": "verify", "bucket": "pass"}, {"name": "exam", "bucket": "pass"}]))
else:
    sys.exit(3)
'''


class AcceptCase(ExecCase):
    def setUp(self):
        super().setUp()
        gh = self.tmp / "fakebin" / "gh"
        gh.write_text(FAKE_GH.replace("#!/usr/bin/env python3", f"#!{sys.executable}", 1))
        gh.chmod(0o755)
        self.origin = self.tmp / "origin.git"
        subprocess.run(["git", "init", "-q", "--bare", str(self.origin)], check=True)
        subprocess.run(["git", "-C", str(self.repo), "remote", "add", "origin", str(self.origin)], check=True)
        self.env["ORC_CI_POLL_SECONDS"] = "0"

    def gh_calls(self):
        log = self.fake / "gh-calls"
        return [json.loads(l)["args"] for l in log.read_text().splitlines()] if log.exists() else []

    def state(self):
        return (self.mdir / "state").read_text().strip()

    def transitions(self):
        return [(e["from"], e["to"]) for e in self.ev("state")]


class HappyPath(AcceptCase):
    def test_final_review_pr_ci_status_page_and_cleanup(self):
        m = self.simple(("a", "b"), depends={"b": ["a"]})
        self.script("a", commit({"a.txt": "a\n"}, [1]))
        self.script("b", commit({"b.txt": "b\n"}, [1]))
        r = self.drive()
        self.assertEqual(self.next_line(r), "next: report https://claude.ai/artifact/fake-status", r.stdout + r.stderr)
        self.assertEqual(self.state(), "cleaned")
        self.assertEqual(self.transitions()[-3:], [("executing", "reviewing"), ("reviewing", "accepted"), ("accepted", "cleaned")])
        tip = self.git("rev-parse", "orc/m1")
        # 合并提交带 [N#]，产品仓库 CI 的 commit 检查才过得去
        merges = self.git("log", "--merges", "--format=%s", "orc/m1").splitlines()
        self.assertEqual(sorted(merges), ["[N1] Integrate a", "[N1] Integrate b"])
        # 最终审查：合并后的代码上跑了全部冻结检查；评审只读、在仓库外、看不到 .northstar，材料都在提示词里
        final, = self.ev("job-exit", type="final")
        self.assertEqual((final["outcome"], final["tip"], final["checks"]), ("passed", tip, {"ca": True, "cb": True}))
        call, = self.calls("final")
        self.assertIn("--allowedTools=Read", call["args"])
        self.assertFalse(call["cwd"].startswith(str(self.repo)) or call["cwd"].startswith(str(self.tmp / "wt")), call["cwd"])
        self.assertIn("a.txt", call["files"])
        self.assertFalse(any(f.startswith(".northstar") for f in call["files"]), call["files"])
        self.assertIn("+a", call["prompt"])                                # diff 在提示词里
        self.assertIn(self.git("show", "HEAD:.northstar/NORTHSTAR.md")[:20], call["prompt"])
        # PR：推到 origin，指向默认分支；CI 等到 verify 和 exam 都通过
        self.assertEqual(subprocess.run(["git", "-C", str(self.origin), "rev-parse", "refs/heads/orc/m1"],
                                        capture_output=True, text=True).stdout.strip(), tip)
        create = next(a for a in self.gh_calls() if a[:2] == ["pr", "create"])
        self.assertEqual((create[create.index("--base") + 1], create[create.index("--head") + 1]), ("main", "orc/m1"))
        pr, = self.ev("pr")
        self.assertEqual((pr["url"], pr["tip"]), ("https://github.com/o/r/pull/7", tip))
        ci, = self.ev("job-exit", type="ci")
        self.assertEqual((ci["outcome"], ci["checks"]), ("passed", {"verify": "pass", "exam": "pass"}))
        # 状态页：每个节点一行，事实带日志行号；说明每条引用都核对过；清理后重新发布同一个链接
        html = (self.tmp / "wt" / "m1" / "site" / "status.html").read_text()
        for node in ("a", "b"):
            self.assertIn(f"<code>{node}</code><div class='muted'>", html)
        self.assertIn("日志 ", html)
        self.assertIn("https://github.com/o/r/pull/7", html)
        self.assertIn("orc/m1", html)                                      # 清理一节：mission 分支保留
        notes = self.ev("job-exit", type="notes")
        self.assertEqual([n["outcome"] for n in notes], ["valid"])
        publishes = self.calls("publish")
        self.assertEqual(len(publishes), 2)
        self.assertNotIn("https://claude.ai/artifact/fake-status", publishes[0]["prompt"])
        self.assertIn("https://claude.ai/artifact/fake-status", publishes[1]["prompt"])   # 更新同一个链接
        self.assertIn("--allowedTools=Read,Artifact", publishes[0]["args"])
        # 清理：只动 orc 记录过的；mission 分支留给 PR
        for node in ("a", "b"):
            self.assertFalse(self.wt(node).exists())
            self.assertEqual(self.git("branch", "--list", f"orc-task/m1/{node}"), "")
        self.assertFalse((self.tmp / "wt" / "m1" / "integration").exists())
        self.assertEqual(self.git("rev-parse", "orc/m1"), tip)
        cleanup, = self.ev("cleanup")
        self.assertEqual(cleanup["kept"], ["orc/m1"])
        # 终态重复 step：同样的 report，不重复发布
        again = self.step()
        self.assertEqual(self.next_line(again), "next: report https://claude.ai/artifact/fake-status")
        self.assertEqual(len(self.calls("publish")), 2)

    def test_cleanup_prints_the_list_and_leaves_other_branches_alone(self):
        self.simple(("a",))
        self.git("branch", "keep-me")
        self.script("a", commit({"a.txt": "a\n"}, [1]))
        outputs = []
        for _ in range(40):
            r = self.step()
            outputs.append(r.stdout)
            if self.next_line(r) != "next: wait":
                break
            self.run_orc("wait", "--mission", "m1", "--timeout", "60")
        text = "".join(outputs)
        self.assertIn("要清理的（只动 orc 记录过的）", text)
        self.assertLess(text.index("要清理的"), text.index("accepted → cleaned"))
        self.assertEqual(self.git("branch", "--list", "keep-me").strip(), "keep-me")
        self.assertEqual(self.state(), "cleaned")


class GitInCheckCopies(AcceptCase):
    """检查用的副本带 git 历史（proposals/2026-11-08-checks-need-git.md）：产品仓库自己的检查（daoharness-core 的
    core_checks.py）要用 git ls-files、git merge-base origin/main HEAD；副本是 git clone --shared，产品仓库不被写。"""

    GIT_CHECK = ("set -e\nbase=$(git merge-base origin/{br} HEAD)\ntest -n \"$base\"\n"
                 "git ls-files --cached --others --exclude-standard | grep -qx a.txt\ngrep -q '^a$' a.txt\n")

    def test_checks_that_use_git_pass_at_the_commit_gate_and_in_final_review(self):
        br = self.git("symbolic-ref", "--short", "HEAD")
        m = self.signed([task("a", ["a.txt"], ["a.txt 的第一行是 a"])],
                        [{"id": "ca", "node": "a", "acceptance": [1], "command": "sh tests/orc/check_a.sh", "expect_before": "fail"}],
                        {"tests/orc/check_a.sh": self.GIT_CHECK.format(br=br)})
        self.script("a", commit({"a.txt": "a\n"}, [1]))
        r = self.drive()
        self.assertEqual(self.next_line(r), "next: report https://claude.ai/artifact/fake-status", r.stdout + r.stderr)
        gate = [e for e in self.ev("job-exit", type="gate", node="a")]
        self.assertEqual([e["outcome"] for e in gate][-1:], ["committed"], gate)       # 提交关口：worktree 的改动盖在 clone 上
        final, = self.ev("job-exit", type="final")
        self.assertEqual((final["outcome"], final["checks"]), ("passed", {"ca": True}))

    def test_copies_are_clones_with_history_and_the_product_repo_is_not_written(self):
        orc = self.orc
        m = self.simple(("a",))
        refs = self.git("for-each-ref")
        head = self.git("rev-parse", "HEAD")
        snap = self.tmp / "snap"
        self.assertEqual(orc.snapshot_repo(m, snap), head)
        self.assertEqual(self.git("rev-parse", "HEAD", cwd=snap), head)
        self.assertEqual(self.git("ls-files", cwd=snap), self.git("ls-files"))           # git 在副本里能用
        # 节点 worktree：已提交的、改了没提交的、删掉的、新加的都要和 worktree 一样
        wt = self.tmp / "wt-copy-src"
        self.git("worktree", "add", "-q", "--detach", str(wt), "HEAD")
        tracked = self.git("ls-files", cwd=wt).split()
        (wt / "new.txt").write_text("new\n")
        (wt / tracked[0]).unlink()
        dest = self.tmp / "wt-copy"
        orc.copy_worktree(wt, dest)
        self.assertTrue((dest / ".git").is_dir())
        self.assertEqual((dest / "new.txt").read_text(), "new\n")
        self.assertFalse((dest / tracked[0]).exists())
        status = self.git("status", "--porcelain", cwd=dest)
        self.assertIn(f"D {tracked[0]}", status)
        self.assertIn("?? new.txt", status)
        self.git("worktree", "remove", "--force", str(wt))
        self.assertEqual(self.git("for-each-ref"), refs)                                 # 产品仓库的 ref 没被动过


class FinalReview(AcceptCase):
    def test_reopened_node_moves_to_mission_tip_and_reintegrates(self):
        self.simple(("a", "b"))
        self.script("a", commit({"a.txt": "a\n"}, [1]), commit({"a.txt": "a\n\n"}, []))
        self.script("b", commit({"b.txt": "b\n"}, [1]))
        self.script("final", json.dumps({"verdict": "fail", "issues": [{"node": "a", "problem": "违反 N1：多余空行检查", "evidence": "a.txt:1"}]}),
                    json.dumps({"verdict": "pass", "issues": []}))
        r = self.drive()
        self.assertEqual(self.next_line(r), "next: report https://claude.ai/artifact/fake-status", r.stdout + r.stderr)
        reopen, = self.ev("node-reopen", node="a")
        self.assertEqual(reopen["round"], 1)
        self.assertIn(("reviewing", "executing"), self.transitions())
        # 重新打开时，a 的基线是当时 mission 分支的 tip（已经包含 b）
        self.assertEqual(reopen["base"], self.ev("job-exit", type="final")[0]["tip"])
        prompts = [c["prompt"] for c in self.calls("exec-a")]
        self.assertIn("最终审查没通过", prompts[1])
        self.assertIn("违反 N1：多余空行检查", prompts[1])
        self.assertEqual(len(self.ev("job-exit", type="integrate", node="a", outcome="integrated")), 2)
        self.assertEqual([e["outcome"] for e in self.ev("job-exit", type="final")], ["rework", "passed"])
        self.assertEqual(self.git("show", "orc/m1:a.txt"), "a")            # 修复（多一个空行）在 mission 分支上
        self.assertIn("\n\n", subprocess.run(["git", "-C", str(self.repo), "show", "orc/m1:a.txt"],
                                             capture_output=True, text=True).stdout)

    def test_third_failing_round_trips_the_breaker(self):
        self.simple(("a",))
        fix = lambda n: commit({"a.txt": "a\n" + "\n" * n}, [])
        self.script("a", commit({"a.txt": "a\n"}, [1]), fix(1), fix(2), fix(3))
        bad = json.dumps({"verdict": "fail", "issues": [{"node": "a", "problem": "还是不对", "evidence": "a.txt:1"}]})
        self.script("final", bad, bad, bad)
        r = self.drive()
        self.assertTrue(self.next_line(r).startswith("next: mediate "), r.stdout + r.stderr)
        self.assertIn("连续 3 次没通过", Path(self.next_line(r)[len("next: mediate "):]).read_text())
        self.assertEqual(len(self.ev("node-reopen")), 2)                  # 打回 2 轮，第 3 次熔断
        self.assertEqual(self.state(), "blocked")
        # 回答后重新做最终审查（这次通过）
        self.answer("接受现状")
        r = self.drive()
        self.assertEqual(self.next_line(r), "next: report https://claude.ai/artifact/fake-status", r.stdout + r.stderr)
        self.assertEqual(len(self.calls("final")), 4)

    def test_check_failing_after_merge_is_routed_without_calling_the_model(self):
        tasks = [
            {"id": "a", "depends_on": [], "files": ["a.txt"], "contracts": ["a"], "verification": ["x"], "state": "ready",
             "acceptance": ["a.txt 是 a"], "clauses": ["N1"], "component": "core"},
            {"id": "b", "depends_on": [], "files": ["b.txt"], "contracts": ["b"], "verification": ["x"], "state": "ready",
             "acceptance": ["b.txt 是 b"], "clauses": ["N1"], "component": "core"}]
        # a 的检查要求 b.txt 不存在：在 a 自己的 worktree 里通过，合并后就不通过了
        tests = {"tests/orc/check_a.sh": "grep -q '^a$' a.txt && test ! -e b.txt\n", "tests/orc/check_b.sh": "grep -q '^b$' b.txt\n"}
        checks = [{"id": "ca", "node": "a", "acceptance": [1], "command": "sh tests/orc/check_a.sh", "expect_before": "fail"},
                  {"id": "cb", "node": "b", "acceptance": [1], "command": "sh tests/orc/check_b.sh", "expect_before": "fail"}]
        self.signed(tasks, checks, tests)
        self.script("a", commit({"a.txt": "a\n"}, [1]), json.dumps({"out": {"status": "question", "question": "b.txt 怎么办"}}))
        self.script("b", commit({"b.txt": "b\n"}, [1]))
        r = self.drive()
        self.assertTrue(self.next_line(r).startswith("next: ask-user 节点 a 的执行会话问"), r.stdout + r.stderr)
        final, = self.ev("job-exit", type="final")
        self.assertEqual((final["outcome"], final["checks"]), ("rework", {"ca": False, "cb": True}))
        self.assertEqual([i["node"] for i in final["issues"]], ["a"])
        self.assertEqual(self.calls("final"), [])                          # 检查没过，不调用评审模型
        self.assertIn("ca", self.calls("exec-a")[1]["prompt"])

    def test_reviewer_output_that_names_an_unknown_node_blocks(self):
        self.simple(("a",))
        self.script("a", commit({"a.txt": "a\n"}, [1]))
        self.script("final", json.dumps({"verdict": "fail", "issues": [{"node": "zzz", "problem": "p", "evidence": "e"}]}))
        r = self.drive()
        self.assertTrue(self.next_line(r).startswith("next: ask-user mission m1 的最终审查没能完成"), r.stdout)
        self.assertIn("zzz", self.next_line(r))
        self.assertEqual(self.ev("node-reopen"), [])
        self.answer("重试")
        r = self.drive()
        self.assertEqual(self.next_line(r), "next: report https://claude.ai/artifact/fake-status", r.stdout + r.stderr)


class PullRequestAndCI(AcceptCase):
    def test_ci_failure_blocks_and_answer_reruns_ci_only(self):
        self.simple(("a",))
        self.script("a", commit({"a.txt": "a\n"}, [1]))
        (self.fake / "gh-checks-1.json").write_text(json.dumps([{"name": "verify", "bucket": "pass"}, {"name": "exam", "bucket": "fail"}]))
        r = self.drive()
        self.assertTrue(self.next_line(r).startswith("next: ask-user mission m1 的 PR https://github.com/o/r/pull/7 的 CI 没通过"), r.stdout)
        self.assertIn("exam（fail）", self.next_line(r))
        self.answer("重试")
        r = self.drive()
        self.assertEqual(self.next_line(r), "next: report https://claude.ai/artifact/fake-status", r.stdout + r.stderr)
        self.assertEqual(len(self.calls("final")), 1)                      # 最终审查没有重做
        self.assertEqual(len([a for a in self.gh_calls() if a[:2] == ["pr", "create"]]), 1)
        self.assertEqual([e["outcome"] for e in self.ev("job-exit", type="ci")], ["failed", "passed"])

    def test_pending_checks_are_waited_for(self):
        self.simple(("a",))
        self.script("a", commit({"a.txt": "a\n"}, [1]))
        (self.fake / "gh-checks-1.json").write_text("[]")
        (self.fake / "gh-checks-2.json").write_text(json.dumps([{"name": "verify", "bucket": "pending"}]))
        r = self.drive()
        self.assertEqual(self.next_line(r), "next: report https://claude.ai/artifact/fake-status", r.stdout + r.stderr)
        self.assertGreaterEqual(len(list(self.fake.glob("gh-checks-call-*"))), 3)

    def test_missing_required_check_times_out_with_the_name(self):
        self.simple(("a",))
        self.script("a", commit({"a.txt": "a\n"}, [1]))
        (self.fake / "gh-checks.json").write_text(json.dumps([{"name": "verify", "bucket": "pass"}]))
        self.config(max_parallel=3, session_timeout_seconds=600, crash_retries=1)
        (self.tmp / "orc.toml").write_text((self.tmp / "orc.toml").read_text().replace('ci_timeout_seconds = "5"', 'ci_timeout_seconds = "1"'))
        r = self.drive()
        self.assertTrue(self.next_line(r).startswith("next: ask-user"), r.stdout)
        self.assertIn("PR 上没有这些检查：exam", self.next_line(r))

    def test_pr_head_that_is_not_the_reviewed_tip_is_refused(self):
        self.simple(("a",))
        self.script("a", commit({"a.txt": "a\n"}, [1]))
        (self.fake / "gh-head").write_text("0" * 40)
        r = self.drive()
        self.assertTrue(self.next_line(r).startswith("next: ask-user"), r.stdout)
        self.assertIn("不是 orc 审查过的", self.next_line(r))
        self.assertNotEqual(self.state(), "accepted")

    def test_existing_open_pr_is_reused(self):
        self.simple(("a",))
        self.script("a", commit({"a.txt": "a\n"}, [1]))
        (self.fake / "gh-prs.json").write_text(json.dumps([{"url": "https://github.com/o/r/pull/3", "number": 3, "head": "orc/m1", "base": "main"}]))
        r = self.drive()
        self.assertEqual(self.next_line(r), "next: report https://claude.ai/artifact/fake-status", r.stdout + r.stderr)
        self.assertEqual([a for a in self.gh_calls() if a[:2] == ["pr", "create"]], [])
        self.assertEqual(self.ev("pr")[0]["url"], "https://github.com/o/r/pull/3")


class StatusNotes(AcceptCase):
    def test_notes_without_references_are_sent_back_with_the_problems(self):
        self.simple(("a",))
        self.script("a", commit({"a.txt": "a\n"}, [1]))
        self.script("notes", "raw:- 这里没有引用，已完成", "AUTO")
        r = self.drive()
        self.assertEqual(self.next_line(r), "next: report https://claude.ai/artifact/fake-status", r.stdout + r.stderr)
        first, second = self.ev("job-exit", type="notes")
        self.assertEqual(first["outcome"], "invalid")
        self.assertTrue(any("没有引用证据" in p for p in first["problems"]))
        self.assertTrue(any("进度判断" in p for p in first["problems"]))
        self.assertTrue(any("没有在说明里交代" in p for p in first["problems"]))
        self.assertIn("没有引用证据", self.calls("notes")[1]["prompt"])
        call = self.calls("notes")[0]
        self.assertEqual(call["args"][call["args"].index("--tools") + 1], "")      # 没有工具
        self.assertEqual(call["files"], [])                                        # 在空目录里

    def test_notes_citing_unknown_commit_check_or_line_are_rejected(self):
        self.simple(("a",))
        self.script("a", commit({"a.txt": "a\n"}, [1]))
        bad = "raw:- x [commit:deadbeef]\\n- y [check:nope]\\n- z [file:a.txt:99]\\n- w [file:missing.txt:1]"
        self.script("notes", bad, bad, bad)
        r = self.drive()
        self.assertTrue(self.next_line(r).startswith("next: mediate "), r.stdout)
        problems = self.ev("job-exit", type="notes")[0]["problems"]
        for text in ("commit deadbeef 不是这个 mission 的提交", "检查 nope 不存在", "a.txt 没有第 99 行", "missing.txt 在合并后的代码里不存在"):
            self.assertTrue(any(text in p for p in problems), (text, problems))
        self.assertNotEqual(self.state(), "accepted")                      # 没有状态页就不验收


class NoRemote(ExecCase):
    def test_product_repo_without_origin_stops_with_how_to_fix(self):
        self.simple(("a",))
        self.script("a", commit({"a.txt": "a\n"}, [1]))
        r = self.drive()
        self.assertIn("没有 origin", self.next_line(r))
        self.assertIn("设成 origin", self.next_line(r))
        self.assertEqual(self.ev("pr"), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)

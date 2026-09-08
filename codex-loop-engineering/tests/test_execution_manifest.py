import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location("loop_doctor", ROOT / "scripts/loop_doctor.py")
DOCTOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DOCTOR)


def node(key, deps=(), paths=(), resources=()):
    return {
        "id": key,
        "owner": f"worker:{key}",
        "outcome": f"Complete {key}",
        "acceptance_criteria": [f"Observable evidence for {key}"],
        "verifier": "Supervisor",
        "max_attempts": 1,
        "read_only": not paths,
        "status": "planned",
        "depends_on": list(deps),
        "write_paths": list(paths),
        "exclusive_resources": list(resources),
        "session": {
            "model": "gpt-6-astra",
            "reasoning_effort": "medium",
            "service_tier": "default",
            "fast_mode": False,
        },
    }


def manifest(nodes):
    return {
        "schema_version": "codex-loop-execution.v1",
        "mode": "execute",
        "execution_authorized": True,
        "execution_authority_ref": "current-user-request",
        "max_parallelism": 2,
        "fast_authorized": False,
        "nodes": nodes,
    }


class ExecutionManifestTests(unittest.TestCase):
    def inspect(self, data):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("goal", "tracker", "constraints", "handoff"):
                (root / f"{name}.md").write_text(f"# {name}\n")
            (root / "execution.json").write_text(json.dumps(data))
            return DOCTOR.summarize(root)

    def execution(self, data):
        result = self.inspect(data)
        self.assertIn("execution", result, "DAG policy is not yet inspected")
        return result["execution"]

    def test_cycle_is_rejected(self):
        result = self.inspect(manifest([node("A", ["B"]), node("B", ["A"])]))
        self.assertFalse(result["ok"], "A cyclic execution graph must be rejected")

    def test_missing_dependency_and_duplicate_node_are_rejected(self):
        for nodes in ([node("A", ["missing"])], [node("A"), node("A")]):
            with self.subTest(nodes=nodes):
                self.assertFalse(self.inspect(manifest(nodes))["ok"])

    def test_only_accepted_predecessors_release_successors(self):
        a = node("A")
        a.update(status="complete", acceptance="passed", evidence=["evidence/A.json"])
        result = self.execution(manifest([a, node("B", ["A"]), node("C", ["B"])]))
        self.assertEqual(result["ready_candidates"], ["B"])
        self.assertEqual(result["dispatchable"], ["B"])
        del a["evidence"]
        self.assertFalse(self.inspect(manifest([a, node("B", ["A"])]))["ok"])

    def test_plan_review_and_missing_authority_never_dispatch(self):
        for mode, authorized in (("plan", True), ("review", True), ("execute", False)):
            data = manifest([node("A")])
            data.update(mode=mode, execution_authorized=authorized)
            self.assertEqual(self.execution(data)["dispatchable"], [])

    def test_authorized_execution_requires_current_authority_reference(self):
        data = manifest([node("A")])
        del data["execution_authority_ref"]
        self.assertFalse(self.inspect(data)["ok"])

    def test_dispatch_contract_fields_are_required(self):
        for field in ("owner", "outcome", "acceptance_criteria", "verifier", "max_attempts", "read_only"):
            a = node("A")
            del a[field]
            with self.subTest(field=field):
                self.assertFalse(self.inspect(manifest([a]))["ok"])

    def test_nodes_without_write_paths_must_be_explicitly_read_only(self):
        a = node("A")
        a["read_only"] = False
        self.assertFalse(self.inspect(manifest([a]))["ok"])

        writer = node("writer", paths=["src/writer.py"])
        writer["read_only"] = True
        self.assertFalse(self.inspect(manifest([writer]))["ok"])

        self.assertTrue(self.inspect(manifest([node("reader")]))["ok"])

    def test_fast_requires_explicit_authority(self):
        for tier, fast in (("priority", False), ("default", True)):
            a = node("A")
            a["session"].update(service_tier=tier, fast_mode=fast)
            self.assertFalse(self.inspect(manifest([a]))["ok"])
        a = node("A")
        a["session"].update(service_tier="priority", fast_mode=True)
        data = manifest([a])
        data.update(fast_authorized=True, fast_authority_ref="user-approved-fast")
        self.assertTrue(self.inspect(data)["ok"])

    def test_contradictory_speed_fields_are_rejected_even_with_authority(self):
        for tier, fast in (("priority", False), ("default", True)):
            a = node("A")
            a["session"].update(service_tier=tier, fast_mode=fast)
            data = manifest([a])
            data.update(fast_authorized=True, fast_authority_ref="user-approved-fast")
            self.assertFalse(self.inspect(data)["ok"])

    def test_malformed_policy_types_return_errors(self):
        for field in ("mode", "reasoning_effort", "service_tier", "status"):
            data = manifest([node("A")])
            if field == "mode":
                data[field] = []
            elif field == "status":
                data["nodes"][0][field] = []
            else:
                data["nodes"][0]["session"][field] = []
            with self.subTest(field=field):
                self.assertFalse(self.inspect(data)["ok"])

    def test_fast_and_runtime_references_must_be_nonempty_strings(self):
        a = node("A")
        a["session"].update(service_tier="priority", fast_mode=True)
        data = manifest([a])
        data.update(fast_authorized=True, fast_authority_ref=True)
        self.assertFalse(self.inspect(data)["ok"])
        a = node("A")
        a.update(status="running", runtime_ref=True)
        self.assertFalse(self.inspect(manifest([a]))["ok"])

    def test_ready_writers_with_overlapping_paths_are_serialized(self):
        data = manifest([node("A", paths=["src"]), node("B", paths=["src/a.py"]), node("C", paths=["tests/a.py"])])
        result = self.execution(data)
        self.assertEqual(result["ready_candidates"], ["A", "B", "C"])
        self.assertEqual(result["dispatchable"], ["A", "C"])

    def test_active_resources_and_capacity_are_reserved(self):
        a = node("A", resources=["port:8781"])
        a.update(status="running", runtime_ref="thread-A")
        data = manifest([a, node("B", resources=["port:8781"]), node("C", resources=["fixture:offline"])])
        self.assertEqual(self.execution(data)["dispatchable"], ["C"])
        data["max_parallelism"] = 1
        self.assertEqual(self.execution(data)["dispatchable"], [])

    def test_conflicting_active_workers_are_rejected(self):
        a, b = node("A", paths=["src/a.py"]), node("B", paths=["src/a.py"])
        a.update(status="running", runtime_ref="thread-A")
        b.update(status="launching", runtime_ref="reservation-B")
        self.assertFalse(self.inspect(manifest([a, b]))["ok"])

    def test_path_escape_and_incomplete_session_policy_are_rejected(self):
        for path in ("../outside", "/tmp/outside", "src/*.py", "src/../other"):
            self.assertFalse(self.inspect(manifest([node("A", paths=[path])]))["ok"])
        a = node("A")
        del a["session"]["fast_mode"]
        self.assertFalse(self.inspect(manifest([a]))["ok"])

    def test_malformed_manifest_fails_closed_and_cli_reports_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("goal", "tracker", "constraints", "handoff"):
                (root / f"{name}.md").write_text(f"# {name}\n")
            (root / "execution.json").write_text("{not json")
            run = subprocess.run([sys.executable, str(ROOT / "scripts/loop_doctor.py"), "--loop-dir", str(root), "--json"], capture_output=True, text=True)
            self.assertEqual(run.returncode, 1)
            self.assertFalse(json.loads(run.stdout)["ok"])

    def test_legacy_four_file_loop_remains_readable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("goal", "tracker", "constraints", "handoff"):
                (root / f"{name}.md").write_text(f"# {name}\n")
            self.assertTrue(DOCTOR.summarize(root)["ok"])

    def test_auto_chain_uses_only_active_handoff_preamble(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("goal", "tracker", "constraints", "handoff"):
                (root / f"{name}.md").write_text(f"# {name}\n")
            (root / "handoff.md").write_text(
                "# Handoff\n\n## History\n\n"
                "Prior value: auto_chain_next_session: true\n"
            )
            result = DOCTOR.summarize(root)
            self.assertFalse(result["auto_chain_enabled"])
            self.assertTrue(any("auto_chain_next_session" in line for line in result["key_lines"]["handoff"]))

            (root / "handoff.md").write_text(
                "# Handoff\nauto_chain_next_session: true\n\n## History\n"
            )
            self.assertTrue(DOCTOR.summarize(root)["auto_chain_enabled"])

    def test_auto_chain_rejects_fenced_or_conflicting_preamble_values(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("goal", "tracker", "constraints", "handoff"):
                (root / f"{name}.md").write_text(f"# {name}\n")
            for preamble in (
                "# Handoff\n```yaml\nauto_chain_next_session: true\n```\n",
                "# Handoff\nauto_chain_next_session: false\nauto_chain_next_session: true\n",
            ):
                with self.subTest(preamble=preamble):
                    (root / "handoff.md").write_text(f"{preamble}\n## Current state\n")
                    self.assertFalse(DOCTOR.summarize(root)["auto_chain_enabled"])

    def test_human_contract_cannot_conflict_with_execution_manifest(self):
        for header in ("mode: plan", "mode: execute\nexecution_authorized: false"):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                for name in ("goal", "tracker", "constraints", "handoff"):
                    (root / f"{name}.md").write_text(f"# {name}\n")
                (root / "goal.md").write_text(f"# Goal\n{header}\n## Objective\nRead the repo")
                (root / "execution.json").write_text(json.dumps(manifest([node("A")])))
                self.assertFalse(DOCTOR.summarize(root)["ok"])


if __name__ == "__main__":
    unittest.main()

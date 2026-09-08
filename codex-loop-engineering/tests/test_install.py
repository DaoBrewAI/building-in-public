import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class InstallTests(unittest.TestCase):
    def run_install(self, directory, **updates):
        env = {**os.environ, "LOOP_DIR": "docs/loop/custom", "DAG_TEMPLATE": "true", "OVERWRITE": "false"}
        env.pop("AUTO_CHAIN", None)
        env.update(updates)
        return subprocess.run(["bash", str(ROOT / "install.sh")], cwd=directory, env=env, capture_output=True, text=True)

    def test_new_dag_scaffold_does_not_authorize_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            run = self.run_install(directory)
            self.assertEqual(run.returncode, 0, run.stderr)
            target = Path(directory) / "docs/loop/custom"
            self.assertTrue((target / "execution.json").exists(), "DAG scaffold is missing")
            data = json.loads((target / "execution.json").read_text())
            self.assertEqual(data["mode"], "plan")
            self.assertFalse(data["execution_authorized"])
            self.assertFalse(data["fast_authorized"])
            self.assertEqual(data["nodes"][0]["session"]["service_tier"], "default")
            self.assertIn("auto_chain_next_session: false", (target / "handoff.md").read_text())
            self.assertIn("docs/loop/custom/tracker.md", (target / "goal.md").read_text())
            doctor = subprocess.run(
                ["python3", "-B", str(ROOT / "scripts/loop_doctor.py"), "--loop-dir", str(target), "--json"],
                capture_output=True,
                text=True,
            )
            self.assertEqual(doctor.returncode, 0, doctor.stdout + doctor.stderr)
            self.assertTrue(json.loads(doctor.stdout)["ok"])

    def test_auto_chain_can_be_enabled_explicitly(self):
        with tempfile.TemporaryDirectory() as directory:
            run = self.run_install(directory, AUTO_CHAIN="true")
            self.assertEqual(run.returncode, 0, run.stderr)
            handoff = Path(directory) / "docs/loop/custom/handoff.md"
            self.assertIn("auto_chain_next_session: true", handoff.read_text())

    def test_existing_loop_state_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "docs/loop/custom"
            target.mkdir(parents=True)
            for name in ("goal.md", "tracker.md", "constraints.md", "handoff.md", "execution.json"):
                (target / name).write_text("USER STATE")
            run = self.run_install(directory)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertTrue(all(p.read_text() == "USER STATE" for p in target.iterdir()))

    def test_invalid_boolean_does_not_install(self):
        with tempfile.TemporaryDirectory() as directory:
            run = self.run_install(directory, AUTO_CHAIN="not-a-boolean")
            self.assertNotEqual(run.returncode, 0)
            self.assertFalse((Path(directory) / "docs/loop/custom/goal.md").exists())

    def test_overwrite_does_not_follow_file_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "docs/loop/custom"
            target.mkdir(parents=True)
            outside = Path(directory) / "outside.md"
            outside.write_text("KEEP")
            (target / "goal.md").symlink_to(outside)
            run = self.run_install(directory, OVERWRITE="true")
            self.assertNotEqual(run.returncode, 0)
            self.assertEqual(outside.read_text(), "KEEP")

    def test_install_rejects_paths_outside_repo_or_with_escapes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            outside = root.parent / f"{root.name}-outside"
            for loop_dir in ("../outside", "docs/loop/../loop/custom", str(outside)):
                with self.subTest(loop_dir=loop_dir):
                    run = self.run_install(directory, LOOP_DIR=loop_dir)
                    self.assertNotEqual(run.returncode, 0)

    def test_absolute_canonical_path_inside_repo_is_allowed(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory).resolve() / "docs/loop/absolute"
            run = self.run_install(directory, LOOP_DIR=str(target))
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertTrue((target / "goal.md").exists())

    def test_install_rejects_symlinked_target_ancestry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            outside = root / "outside"
            outside.mkdir()
            (root / "docs").symlink_to(outside, target_is_directory=True)
            run = self.run_install(directory)
            self.assertNotEqual(run.returncode, 0)
            self.assertFalse((outside / "loop/custom/goal.md").exists())


if __name__ == "__main__":
    unittest.main()

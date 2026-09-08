import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class InstallTests(unittest.TestCase):
    def run_install(self, directory, **updates):
        env = {**os.environ, "LOOP_DIR": "docs/loop/custom", "DAG_TEMPLATE": "true", "AUTO_CHAIN": "true", "OVERWRITE": "false", **updates}
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
            self.assertIn("docs/loop/custom/tracker.md", (target / "goal.md").read_text())

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


if __name__ == "__main__":
    unittest.main()

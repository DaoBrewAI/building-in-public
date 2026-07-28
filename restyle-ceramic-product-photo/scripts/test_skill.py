import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SKILL_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = SKILL_ROOT / "scripts"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class SkillContractTests(unittest.TestCase):
    def test_required_resources_exist(self):
        expected = [
            SKILL_ROOT / "SKILL.md",
            SKILL_ROOT / "agents" / "openai.yaml",
            SCRIPTS / "restyle.py",
            SCRIPTS / "render.py",
            SCRIPTS / "preset.json",
            SCRIPTS / "requirements.lock",
        ]
        self.assertEqual([], [str(path) for path in expected if not path.is_file()])

    def test_requirements_are_exactly_pinned(self):
        lines = [
            line.strip()
            for line in (SCRIPTS / "requirements.lock").read_text().splitlines()
            if line.strip() and not line.startswith("#")
        ]
        self.assertTrue(lines)
        self.assertTrue(all("==" in line for line in lines), lines)

    def test_preset_locks_cpu_and_approved_v22_values(self):
        preset = json.loads((SCRIPTS / "preset.json").read_text())
        self.assertEqual(["CPUExecutionProvider"], preset["segmentation_providers"])
        self.assertEqual("isnet-general-use", preset["segmentation_model"])
        self.assertEqual(135.0, preset["light_angle_deg"])
        self.assertEqual(0.22, preset["relight_strength"])
        self.assertEqual(0.17, preset["backdrop_light_strength"])
        self.assertEqual(0.34, preset["shadow_dx"])
        self.assertEqual(0.06, preset["shadow_blur_frac"])

    def test_model_hash_is_locked(self):
        runner = load_module("restyle_runner", SCRIPTS / "restyle.py")
        self.assertEqual(
            "60920e99c45464f2ba57bee2ad08c919a52bbf852739e96947fbb4358c0d964a",
            runner.MODEL_SHA256,
        )
        with tempfile.NamedTemporaryFile() as fixture:
            fixture.write(b"wrong model")
            fixture.flush()
            with self.assertRaisesRegex(RuntimeError, "model checksum mismatch"):
                runner.verify_model(Path(fixture.name))

    def test_batch_outputs_are_stable_and_collision_safe(self):
        runner = load_module("restyle_runner_batch", SCRIPTS / "restyle.py")
        with tempfile.TemporaryDirectory() as source_dir:
            root = Path(source_dir)
            (root / "A.JPG").write_bytes(b"a")
            (root / "b.png").write_bytes(b"b")
            (root / "notes.txt").write_text("ignore")
            outputs = runner.plan_batch(root, root / "styled")
        self.assertEqual(
            ["A-styled.jpg", "b-styled.jpg"],
            [output.name for _, output in outputs],
        )

    def test_renderer_uses_fixed_random_seeds(self):
        source = (SCRIPTS / "render.py").read_text()
        self.assertIn("np.random.default_rng(11)", source)
        self.assertIn("np.random.default_rng(7)", source)


if __name__ == "__main__":
    unittest.main()

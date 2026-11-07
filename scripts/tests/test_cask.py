import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
SCRIPT = ROOT / "scripts/render_cask.sh"
SHA = "0123456789abcdef" * 4


def render(*args):
    return subprocess.run(["sh", str(SCRIPT), *args], capture_output=True, text=True)


class RenderCaskTests(unittest.TestCase):
    def test_fills_every_placeholder(self):
        r = render("1.2.3", SHA)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('version "1.2.3"', r.stdout)
        self.assertIn(f'sha256 "{SHA}"', r.stdout)
        self.assertIn("https://github.com/Arrows78/Shrinkbox/releases/download/v#{version}/Shrinkbox-#{version}.zip", r.stdout)
        self.assertNotIn("@", r.stdout.replace("@VERSION", "").replace("user@", ""))

    def test_base_url_can_be_overridden(self):
        self.assertIn('url "file:///tmp/x/v#{version}', render("1.0.0", SHA, "file:///tmp/x").stdout)

    def test_refuses_a_bad_checksum_or_version(self):
        for args in (("1.0.0", "xyz"), ("1.0.0", SHA[:-1]), ("1.0.0", SHA.upper()), ("1.0.0", ""), ("", SHA), ("1.0 0", SHA), ("1.0|0", SHA)):
            self.assertEqual(render(*args).returncode, 2, args)
        self.assertEqual(render("1.0.0").returncode, 2)

    @unittest.skipUnless(shutil.which("ruby"), "ruby is not installed")
    def test_output_is_valid_ruby(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "shrinkbox.rb"
            f.write_text(render("1.2.3", SHA).stdout)
            r = subprocess.run(["ruby", "-c", str(f)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)

    def test_cask_names_match_the_app(self):
        out = render("1.2.3", SHA).stdout
        self.assertIn('cask "shrinkbox" do', out)
        self.assertIn('app "Shrinkbox.app"', out)


if __name__ == "__main__":
    unittest.main()

import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "package-app.py"
sys.path.insert(0, str(SCRIPT.parent))
spec = importlib.util.spec_from_file_location("package_app", SCRIPT)
package_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package_module)


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        (self.root / "source.swift").write_text("source\n")
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("add", "source.swift")
        self.git("commit", "-m", "Fixture")

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *arguments):
        return subprocess.check_output(["git", "-C", str(self.root), *arguments], text=True, stderr=subprocess.DEVNULL)

    def test_clean_tree_can_be_packaged(self):
        package_module.require_clean_tree(self.root)

    def test_modified_tree_is_rejected(self):
        (self.root / "source.swift").write_text("changed\n")
        with self.assertRaisesRegex(ValueError, "Commit or stash changes before packaging source"):
            package_module.require_clean_tree(self.root)

    def test_untracked_source_is_rejected(self):
        (self.root / "new.swift").write_text("new source\n")
        with self.assertRaisesRegex(ValueError, "Commit or stash changes before packaging source"):
            package_module.require_clean_tree(self.root)


if __name__ == "__main__":
    unittest.main()

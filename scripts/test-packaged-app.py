#!/usr/bin/env python3
"""Release gate integration tests. Never modify the supplied app or installed apps.

Usage: python3 scripts/test-packaged-app.py APP_PATH VERIFIER_PATH
"""

import pathlib
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


class PackagedAppTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mr-package-regression-")
        self.addCleanup(self.temporary.cleanup)
        self.app = pathlib.Path(self.temporary.name) / "含空格 Test.app"
        shutil.copytree(APP, self.app, symlinks=True)

    def verify(self):
        return subprocess.run(
            [str(VERIFIER), str(self.app)],
            cwd=self.temporary.name,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=40,
        )

    def resource(self, name):
        matches = list((self.app / "Contents/Resources").rglob(name))
        self.assertEqual(len(matches), 1)
        return matches[0]

    def resign(self):
        signature = subprocess.run(
            ["codesign", "-dvv", str(APP)], capture_output=True, text=True, check=True
        ).stderr
        authority = re.search(r"^Authority=(.+)$", signature, re.MULTILINE)
        # 保持输入包的签名身份，避免将开发签名降为 ad-hoc 后被系统拒绝启动。
        identity = authority[1] if authority else "-"
        subprocess.run(
            ["codesign", "--force", "--deep", "--sign", identity, str(self.app)],
            check=True, capture_output=True,
        )

    def test_actual_packaged_executable_passes_outside_source_tree(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("打包主程序自检通过", result.stdout)

    def test_old_executable_with_valid_new_resources_is_rejected(self):
        # 模拟旧主程序没有自检能力；新资源全部保留。这是 v2.4.6 门禁漏检的组合。
        shutil.copyfile("/usr/bin/true", self.app / "Contents/MacOS/MarkdownReader")
        result = self.verify()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("主程序缺少打包自检入口", result.stdout)

    def test_main_and_extension_support_declared_minimum_macos(self):
        for bundle in [self.app, self.app / "Contents/PlugIns/MarkdownReaderQL.appex"]:
            with (bundle / "Contents/Info.plist").open("rb") as stream:
                info = plistlib.load(stream)
            executable = bundle / "Contents/MacOS" / info["CFBundleExecutable"]
            output = subprocess.check_output(
                ["xcrun", "vtool", "-show-build", str(executable)], text=True
            )
            minimum = re.search(r"minos\s+([\d.]+)", output)
            self.assertIsNotNone(minimum, output)
            version = lambda value: tuple((list(map(int, value.split("."))) + [0, 0])[:3])
            self.assertLessEqual(version(minimum[1]), version(info["LSMinimumSystemVersion"]), output)

    def test_missing_css_is_rejected(self):
        self.resource("markdown.css").unlink()
        result = self.verify()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("css/markdown.css", result.stdout)

    def test_nonempty_broken_javascript_fails_in_actual_app(self):
        self.resource("markdown-reader.js").write_text("window.MR = {};\n")
        self.resign()
        result = self.verify()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("missing_replaceContent", result.stdout)

    def test_nonempty_broken_css_fails_in_actual_app(self):
        self.resource("markdown.css").write_text("body { color: black; }\n")
        self.resign()
        result = self.verify()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("missing_css", result.stdout)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    APP, VERIFIER = (pathlib.Path(arg).resolve() for arg in sys.argv[1:])
    unittest.main(argv=[sys.argv[0]], verbosity=2)

"""Tests for the development-tool discovery and configuration logic in setup.py."""

from __future__ import annotations

import json
import os
import sys
import textwrap
import unittest
from pathlib import Path, PurePosixPath, PureWindowsPath
from unittest.mock import MagicMock, patch, PropertyMock

# ── Import discovery functions from setup.py ─────────────────────────
# setup.py lives in the repository root; add it to sys.path so we can
# import it directly as a module.
_REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO_ROOT))

import setup as setup_mod  # noqa: E402

# Convenience aliases
discover_java = setup_mod.discover_java
discover_android_sdk = setup_mod.discover_android_sdk
discover_adb = setup_mod.discover_adb
_get_java_version = setup_mod._get_java_version
_is_compatible_jdk = setup_mod._is_compatible_jdk
_resolve_java_home = setup_mod._resolve_java_home
_is_valid_android_sdk = setup_mod._is_valid_android_sdk
_write_devconfig = setup_mod._write_devconfig
_update_local_properties = setup_mod._update_local_properties


# ── Helpers ──────────────────────────────────────────────────────────

def _fake_javac(version_output: str):
    """Return a mock subprocess.run result for javac -version."""
    mock_result = MagicMock()
    mock_result.stdout = version_output
    mock_result.stderr = ""
    mock_result.returncode = 0
    return mock_result


def _fake_java_home(tmp_path: Path, name: str = "jdk-17", version: int = 17) -> Path:
    """Create a minimal fake JDK directory."""
    jdk = tmp_path / name
    (jdk / "bin").mkdir(parents=True)
    javac_name = "javac.exe" if sys.platform == "win32" else "javac"
    (jdk / "bin" / javac_name).touch()
    return jdk


# ── Java discovery tests ────────────────────────────────────────────

class TestGetJavaVersion(unittest.TestCase):
    """Tests for _get_java_version."""

    def test_parses_javac_17(self, ):
        jdk = _fake_java_home(Path(self._tmp()), version=17)
        with patch("setup.subprocess.run", return_value=_fake_javac("javac 17.0.12")):
            self.assertEqual(_get_java_version(jdk), 17)

    def test_parses_javac_21(self):
        jdk = _fake_java_home(Path(self._tmp()), "jdk-21", 21)
        with patch("setup.subprocess.run", return_value=_fake_javac("javac 21.0.1")):
            self.assertEqual(_get_java_version(jdk), 21)

    def test_parses_javac_23(self):
        jdk = _fake_java_home(Path(self._tmp()), "jdk-23", 23)
        with patch("setup.subprocess.run", return_value=_fake_javac("javac 23")):
            self.assertEqual(_get_java_version(jdk), 23)

    def test_returns_none_when_no_javac(self):
        tmp = Path(self._tmp())
        jdk = tmp / "jdk-no-javac"
        (jdk / "bin").mkdir(parents=True)
        # No javac binary
        self.assertIsNone(_get_java_version(jdk))

    def test_returns_none_on_subprocess_error(self):
        jdk = _fake_java_home(Path(self._tmp()))
        with patch("setup.subprocess.run", side_effect=OSError("not found")):
            self.assertIsNone(_get_java_version(jdk))

    def _tmp(self):
        import tempfile
        d = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(d, ignore_errors=True))
        return d


class TestIsCompatibleJdk(unittest.TestCase):
    """Tests for _is_compatible_jdk."""

    def test_jdk_17_compatible(self):
        jdk = _fake_java_home(Path(self._tmp()), "jdk-17", 17)
        with patch("setup.subprocess.run", return_value=_fake_javac("javac 17.0.12")):
            compat, ver = _is_compatible_jdk(jdk)
            self.assertTrue(compat)
            self.assertEqual(ver, 17)

    def test_jdk_23_compatible(self):
        jdk = _fake_java_home(Path(self._tmp()), "jdk-23", 23)
        with patch("setup.subprocess.run", return_value=_fake_javac("javac 23.0.1")):
            compat, ver = _is_compatible_jdk(jdk)
            self.assertTrue(compat)
            self.assertEqual(ver, 23)

    def test_jdk_11_incompatible(self):
        jdk = _fake_java_home(Path(self._tmp()), "jdk-11", 11)
        with patch("setup.subprocess.run", return_value=_fake_javac("javac 11.0.20")):
            compat, ver = _is_compatible_jdk(jdk)
            self.assertFalse(compat)
            self.assertEqual(ver, 11)

    def test_jdk_24_incompatible(self):
        jdk = _fake_java_home(Path(self._tmp()), "jdk-24", 24)
        with patch("setup.subprocess.run", return_value=_fake_javac("javac 24.0.1")):
            compat, ver = _is_compatible_jdk(jdk)
            self.assertFalse(compat)
            self.assertEqual(ver, 24)

    def test_no_javac_returns_not_compatible(self):
        tmp = Path(self._tmp())
        jdk = tmp / "jre-only"
        (jdk / "bin").mkdir(parents=True)
        compat, ver = _is_compatible_jdk(jdk)
        self.assertFalse(compat)
        self.assertIsNone(ver)

    def _tmp(self):
        import tempfile
        d = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(d, ignore_errors=True))
        return d


class TestDiscoverJava(unittest.TestCase):
    """Tests for discover_java."""

    def _tmp(self):
        import tempfile
        d = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(d, ignore_errors=True))
        return d

    @patch.dict(os.environ, {"JAVA_HOME": ""}, clear=False)
    @patch("setup.shutil.which", return_value=None)
    @patch("setup.subprocess.run", side_effect=OSError)
    @patch("setup._scan_java_dirs", return_value=[])
    def test_no_java_found(self, *_):
        """No compatible JDK anywhere → (None, None)."""
        java_home, version = discover_java()
        self.assertIsNone(java_home)
        self.assertIsNone(version)

    def test_java_from_java_home_env(self):
        """JAVA_HOME points to a compatible JDK."""
        tmp = Path(self._tmp())
        jdk = _fake_java_home(tmp, "jdk-17")
        with (
            patch.dict(os.environ, {"JAVA_HOME": str(jdk)}, clear=False),
            patch("setup.shutil.which", return_value=None),
            patch("setup.subprocess.run", return_value=_fake_javac("javac 17.0.12")),
            patch("setup._scan_java_dirs", return_value=[]),
        ):
            java_home, version = discover_java()
            self.assertEqual(java_home, jdk)
            self.assertEqual(version, 17)

    def test_java_from_path(self):
        """javac on PATH leads to a compatible JDK."""
        tmp = Path(self._tmp())
        jdk = _fake_java_home(tmp, "jdk-21")
        javac_path = jdk / "bin" / ("javac.exe" if sys.platform == "win32" else "javac")
        with (
            patch.dict(os.environ, {"JAVA_HOME": ""}, clear=False),
            patch("setup.shutil.which", return_value=str(javac_path)),
            patch("setup.subprocess.run", return_value=_fake_javac("javac 21.0.1")),
            patch("setup._scan_java_dirs", return_value=[]),
        ):
            java_home, version = discover_java()
            self.assertIsNotNone(java_home)
            self.assertEqual(version, 21)

    def test_incompatible_java_home_falls_back_to_scan(self):
        """JAVA_HOME has JDK 11, but a compatible JDK 17 is found via scan."""
        tmp = Path(self._tmp())
        jdk11 = _fake_java_home(tmp, "jdk-11")
        jdk17 = _fake_java_home(tmp, "jdk-17")

        def fake_run(cmd, **kw):
            path = cmd[0]
            if "jdk-11" in path:
                return _fake_javac("javac 11.0.20")
            return _fake_javac("javac 17.0.12")

        with (
            patch.dict(os.environ, {"JAVA_HOME": str(jdk11)}, clear=False),
            patch("setup.shutil.which", return_value=None),
            patch("setup.subprocess.run", side_effect=fake_run),
            patch("setup._scan_java_dirs", return_value=[jdk17]),
        ):
            java_home, version = discover_java()
            self.assertEqual(java_home, jdk17)
            self.assertEqual(version, 17)

    def test_prefers_java_17_over_21(self):
        """When both JDK 17 and 21 are available, prefer 17."""
        tmp = Path(self._tmp())
        jdk17 = _fake_java_home(tmp, "jdk-17")
        jdk21 = _fake_java_home(tmp, "jdk-21")

        def fake_run(cmd, **kw):
            path = cmd[0]
            if "jdk-17" in path:
                return _fake_javac("javac 17.0.12")
            return _fake_javac("javac 21.0.1")

        with (
            patch.dict(os.environ, {"JAVA_HOME": ""}, clear=False),
            patch("setup.shutil.which", return_value=None),
            patch("setup.subprocess.run", side_effect=fake_run),
            patch("setup._scan_java_dirs", return_value=[jdk21, jdk17]),
        ):
            java_home, version = discover_java()
            self.assertEqual(java_home, jdk17)
            self.assertEqual(version, 17)


# ── Android SDK discovery tests ─────────────────────────────────────

class TestDiscoverAndroidSdk(unittest.TestCase):
    """Tests for discover_android_sdk."""

    def _tmp(self):
        import tempfile
        d = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(d, ignore_errors=True))
        return d

    def _make_sdk(self, path: Path) -> Path:
        (path / "platform-tools").mkdir(parents=True)
        (path / "platforms").mkdir(parents=True)
        return path

    def test_from_android_home(self):
        sdk = self._make_sdk(Path(self._tmp()) / "sdk")
        with patch.dict(os.environ, {"ANDROID_HOME": str(sdk), "ANDROID_SDK_ROOT": ""}, clear=False):
            self.assertEqual(discover_android_sdk(), sdk)

    def test_from_android_sdk_root(self):
        sdk = self._make_sdk(Path(self._tmp()) / "sdk")
        with patch.dict(os.environ, {"ANDROID_HOME": "", "ANDROID_SDK_ROOT": str(sdk)}, clear=False):
            self.assertEqual(discover_android_sdk(), sdk)

    @patch.dict(os.environ, {"ANDROID_HOME": "", "ANDROID_SDK_ROOT": ""}, clear=False)
    def test_from_default_linux_location(self):
        """Finds SDK at ~/Android/Sdk when no env var is set."""
        tmp = Path(self._tmp())
        sdk = self._make_sdk(tmp / "Android" / "Sdk")
        with (
            patch("setup.sys.platform", "linux"),
            patch("setup.Path.home", return_value=tmp),
        ):
            self.assertEqual(discover_android_sdk(), sdk)

    @patch.dict(os.environ, {"ANDROID_HOME": "/nonexistent", "ANDROID_SDK_ROOT": ""}, clear=False)
    def test_invalid_android_home_ignored(self):
        """ANDROID_HOME pointing to non-existent directory is ignored."""
        result = discover_android_sdk()
        # May be None or a valid default; the point is it doesn't crash
        # and doesn't return the invalid path.
        if result is not None:
            self.assertTrue(result.is_dir())


# ── ADB discovery tests ─────────────────────────────────────────────

class TestDiscoverAdb(unittest.TestCase):
    """Tests for discover_adb."""

    def _tmp(self):
        import tempfile
        d = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(d, ignore_errors=True))
        return d

    def test_from_android_sdk(self):
        tmp = Path(self._tmp())
        sdk = tmp / "sdk"
        adb_name = "adb.exe" if sys.platform == "win32" else "adb"
        (sdk / "platform-tools").mkdir(parents=True)
        (sdk / "platform-tools" / adb_name).touch()
        result = discover_adb(sdk)
        self.assertIsNotNone(result)
        self.assertEqual(result.name, adb_name)

    def test_from_path(self):
        with patch("setup.shutil.which", return_value="/usr/bin/adb"):
            result = discover_adb(None)
            self.assertEqual(result, Path("/usr/bin/adb"))

    def test_missing_adb(self):
        with patch("setup.shutil.which", return_value=None):
            result = discover_adb(None)
            self.assertIsNone(result)

    def test_sdk_without_platform_tools(self):
        """SDK directory exists but has no platform-tools."""
        tmp = Path(self._tmp())
        sdk = tmp / "sdk"
        sdk.mkdir(parents=True)
        with patch("setup.shutil.which", return_value=None):
            result = discover_adb(sdk)
            self.assertIsNone(result)


# ── Config file tests ────────────────────────────────────────────────

class TestWriteDevconfig(unittest.TestCase):
    """Tests for _write_devconfig."""

    def _tmp(self):
        import tempfile
        d = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(d, ignore_errors=True))
        return d

    def test_all_found(self):
        tmp = Path(self._tmp())
        config = _write_devconfig(
            tmp,
            java_home=Path("/opt/jdk-17"),
            android_sdk=Path("/opt/android-sdk"),
            adb=Path("/opt/android-sdk/platform-tools/adb"),
        )
        data = json.loads(config.read_text())
        self.assertEqual(data["javaHome"], "/opt/jdk-17")
        self.assertEqual(data["androidSdk"], "/opt/android-sdk")
        self.assertEqual(data["adb"], "/opt/android-sdk/platform-tools/adb")

    def test_missing_java(self):
        tmp = Path(self._tmp())
        config = _write_devconfig(
            tmp,
            java_home=None,
            android_sdk=Path("/sdk"),
            adb=Path("/sdk/platform-tools/adb"),
        )
        data = json.loads(config.read_text())
        self.assertIsNone(data["javaHome"])
        self.assertEqual(data["androidSdk"], "/sdk")

    def test_all_missing(self):
        tmp = Path(self._tmp())
        config = _write_devconfig(tmp, None, None, None)
        data = json.loads(config.read_text())
        self.assertIsNone(data["javaHome"])
        self.assertIsNone(data["androidSdk"])
        self.assertIsNone(data["adb"])

    def test_paths_with_spaces(self):
        tmp = Path(self._tmp())
        config = _write_devconfig(
            tmp,
            java_home=Path("/Program Files/Java/jdk-17"),
            android_sdk=Path("/Users/My User/Android/Sdk"),
            adb=Path("/Users/My User/Android/Sdk/platform-tools/adb"),
        )
        data = json.loads(config.read_text())
        self.assertIn("Program Files", data["javaHome"])
        self.assertIn("My User", data["androidSdk"])


# ── local.properties tests ──────────────────────────────────────────

class TestUpdateLocalProperties(unittest.TestCase):
    """Tests for _update_local_properties."""

    def _tmp(self):
        import tempfile
        d = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(d, ignore_errors=True))
        return d

    def test_creates_file_when_missing(self):
        tmp = Path(self._tmp())
        project = tmp / "myproject"
        (project / "android").mkdir(parents=True)
        _update_local_properties(project, Path("/opt/sdk"))
        props = (project / "android" / "local.properties").read_text()
        self.assertIn("sdk.dir=/opt/sdk", props)

    def test_creates_directory_and_file(self):
        tmp = Path(self._tmp())
        project = tmp / "myproject"
        project.mkdir()
        # android/ dir doesn't exist yet
        _update_local_properties(project, Path("/opt/sdk"))
        self.assertTrue((project / "android" / "local.properties").is_file())

    def test_updates_existing_sdk_dir(self):
        tmp = Path(self._tmp())
        project = tmp / "myproject"
        (project / "android").mkdir(parents=True)
        props_file = project / "android" / "local.properties"
        props_file.write_text("# comment\nsdk.dir=/old/path\nother.prop=value\n")
        _update_local_properties(project, Path("/new/sdk"))
        content = props_file.read_text()
        self.assertIn("sdk.dir=/new/sdk", content)
        self.assertNotIn("/old/path", content)
        self.assertIn("# comment", content)
        self.assertIn("other.prop=value", content)

    def test_appends_when_no_sdk_dir(self):
        tmp = Path(self._tmp())
        project = tmp / "myproject"
        (project / "android").mkdir(parents=True)
        props_file = project / "android" / "local.properties"
        props_file.write_text("# existing content\nsome.key=value\n")
        _update_local_properties(project, Path("/opt/sdk"))
        content = props_file.read_text()
        self.assertIn("sdk.dir=/opt/sdk", content)
        self.assertIn("some.key=value", content)

    def test_no_op_when_sdk_is_none(self):
        tmp = Path(self._tmp())
        project = tmp / "myproject"
        (project / "android").mkdir(parents=True)
        _update_local_properties(project, None)
        self.assertFalse((project / "android" / "local.properties").exists())

    def test_windows_backslash_converted(self):
        tmp = Path(self._tmp())
        project = tmp / "myproject"
        (project / "android").mkdir(parents=True)
        # Simulate a Windows path (even on Linux for testing)
        _update_local_properties(project, Path("C:\\Users\\dev\\Android\\Sdk"))
        content = (project / "android" / "local.properties").read_text()
        self.assertIn("sdk.dir=C:/Users/dev/Android/Sdk", content)
        self.assertNotIn("\\", content)

    def test_path_with_spaces(self):
        tmp = Path(self._tmp())
        project = tmp / "myproject"
        (project / "android").mkdir(parents=True)
        _update_local_properties(project, Path("/Users/My User/Android/Sdk"))
        content = (project / "android" / "local.properties").read_text()
        self.assertIn("sdk.dir=/Users/My User/Android/Sdk", content)


# ── Bash config loader integration test ─────────────────────────────

class TestBashConfigLoader(unittest.TestCase):
    """Test that load-devconfig.sh correctly reads devconfig.json."""

    def _tmp(self):
        import tempfile
        d = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(d, ignore_errors=True))
        return d

    @unittest.skipIf(sys.platform == "win32", "bash not available on Windows")
    def test_exports_java_home(self):
        """Manual config values are picked up by the bash loader."""
        import subprocess as sp

        tmp = Path(self._tmp())
        project = tmp / "myproject"
        scripts = project / "scripts"
        scripts.mkdir(parents=True)
        (project / "android").mkdir()

        # Create a fake JDK directory
        jdk = tmp / "fake-jdk"
        (jdk / "bin").mkdir(parents=True)

        # Write devconfig.json
        config = {"javaHome": str(jdk), "androidSdk": None, "adb": None}
        (project / "devconfig.json").write_text(json.dumps(config))

        # Copy the loader script
        loader_src = _REPO_ROOT / "@supernote-plugin" / "sn-plugin-template" / "template" / "scripts" / "load-devconfig.sh"
        if loader_src.is_file():
            import shutil
            shutil.copy2(loader_src, scripts / "load-devconfig.sh")
        else:
            self.skipTest("load-devconfig.sh not found")

        # Source the loader and print JAVA_HOME
        result = sp.run(
            ["bash", "-c", f'source "{scripts}/load-devconfig.sh" && echo "$JAVA_HOME"'],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.stdout.strip(), str(jdk))

    @unittest.skipIf(sys.platform == "win32", "bash not available on Windows")
    def test_exports_adb_bin(self):
        """ADB path from config is exported as ADB_BIN."""
        import subprocess as sp

        tmp = Path(self._tmp())
        project = tmp / "myproject"
        scripts = project / "scripts"
        scripts.mkdir(parents=True)
        (project / "android").mkdir()

        config = {"javaHome": None, "androidSdk": None, "adb": "/custom/path/adb"}
        (project / "devconfig.json").write_text(json.dumps(config))

        loader_src = _REPO_ROOT / "@supernote-plugin" / "sn-plugin-template" / "template" / "scripts" / "load-devconfig.sh"
        if loader_src.is_file():
            import shutil
            shutil.copy2(loader_src, scripts / "load-devconfig.sh")
        else:
            self.skipTest("load-devconfig.sh not found")

        result = sp.run(
            ["bash", "-c", f'source "{scripts}/load-devconfig.sh" && echo "$ADB_BIN"'],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.stdout.strip(), "/custom/path/adb")

    @unittest.skipIf(sys.platform == "win32", "bash not available on Windows")
    def test_updates_local_properties(self):
        """The bash loader writes sdk.dir to android/local.properties."""
        import subprocess as sp

        tmp = Path(self._tmp())
        project = tmp / "myproject"
        scripts = project / "scripts"
        scripts.mkdir(parents=True)
        android_dir = project / "android"
        android_dir.mkdir()

        # Create a fake SDK directory
        sdk = tmp / "fake-sdk"
        (sdk / "platform-tools").mkdir(parents=True)

        config = {"javaHome": None, "androidSdk": str(sdk), "adb": None}
        (project / "devconfig.json").write_text(json.dumps(config))

        loader_src = _REPO_ROOT / "@supernote-plugin" / "sn-plugin-template" / "template" / "scripts" / "load-devconfig.sh"
        if loader_src.is_file():
            import shutil
            shutil.copy2(loader_src, scripts / "load-devconfig.sh")
        else:
            self.skipTest("load-devconfig.sh not found")

        sp.run(
            ["bash", "-c", f'source "{scripts}/load-devconfig.sh"'],
            capture_output=True, text=True, timeout=10,
        )
        props = (android_dir / "local.properties").read_text()
        self.assertIn(f"sdk.dir={sdk}", props)

    @unittest.skipIf(sys.platform == "win32", "bash not available on Windows")
    def test_no_op_without_devconfig(self):
        """Without devconfig.json, the loader does nothing."""
        import subprocess as sp

        tmp = Path(self._tmp())
        project = tmp / "myproject"
        scripts = project / "scripts"
        scripts.mkdir(parents=True)
        (project / "android").mkdir()

        loader_src = _REPO_ROOT / "@supernote-plugin" / "sn-plugin-template" / "template" / "scripts" / "load-devconfig.sh"
        if loader_src.is_file():
            import shutil
            shutil.copy2(loader_src, scripts / "load-devconfig.sh")
        else:
            self.skipTest("load-devconfig.sh not found")

        result = sp.run(
            ["bash", "-c", f'source "{scripts}/load-devconfig.sh" && echo "OK"'],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("OK", result.stdout)

    @unittest.skipIf(sys.platform == "win32", "bash not available on Windows")
    def test_preserves_existing_local_properties(self):
        """The bash loader preserves non-sdk.dir properties."""
        import subprocess as sp

        tmp = Path(self._tmp())
        project = tmp / "myproject"
        scripts = project / "scripts"
        scripts.mkdir(parents=True)
        android_dir = project / "android"
        android_dir.mkdir()

        # Write existing local.properties with other content
        props_file = android_dir / "local.properties"
        props_file.write_text("# my comment\nsdk.dir=/old/path\ncustom.key=value\n")

        sdk = tmp / "new-sdk"
        sdk.mkdir(parents=True)

        config = {"javaHome": None, "androidSdk": str(sdk), "adb": None}
        (project / "devconfig.json").write_text(json.dumps(config))

        loader_src = _REPO_ROOT / "@supernote-plugin" / "sn-plugin-template" / "template" / "scripts" / "load-devconfig.sh"
        if loader_src.is_file():
            import shutil
            shutil.copy2(loader_src, scripts / "load-devconfig.sh")
        else:
            self.skipTest("load-devconfig.sh not found")

        sp.run(
            ["bash", "-c", f'source "{scripts}/load-devconfig.sh"'],
            capture_output=True, text=True, timeout=10,
        )
        content = props_file.read_text()
        self.assertIn(f"sdk.dir={sdk}", content)
        self.assertIn("# my comment", content)
        self.assertIn("custom.key=value", content)
        self.assertNotIn("/old/path", content)


# ── Platform-specific path tests ─────────────────────────────────────

class TestPlatformDiscovery(unittest.TestCase):
    """Test platform-specific discovery logic."""

    def _tmp(self):
        import tempfile
        d = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(d, ignore_errors=True))
        return d

    def test_linux_default_android_sdk(self):
        """On Linux, the default SDK location is ~/Android/Sdk."""
        tmp = Path(self._tmp())
        sdk = tmp / "Android" / "Sdk"
        (sdk / "platform-tools").mkdir(parents=True)
        with (
            patch.dict(os.environ, {"ANDROID_HOME": "", "ANDROID_SDK_ROOT": ""}, clear=False),
            patch("setup.sys.platform", "linux"),
            patch("setup.Path.home", return_value=tmp),
        ):
            self.assertEqual(discover_android_sdk(), sdk)

    def test_macos_default_android_sdk(self):
        """On macOS, the default SDK location is ~/Library/Android/sdk."""
        tmp = Path(self._tmp())
        sdk = tmp / "Library" / "Android" / "sdk"
        (sdk / "platforms").mkdir(parents=True)
        with (
            patch.dict(os.environ, {"ANDROID_HOME": "", "ANDROID_SDK_ROOT": ""}, clear=False),
            patch("setup.sys.platform", "darwin"),
            patch("setup.Path.home", return_value=tmp),
        ):
            self.assertEqual(discover_android_sdk(), sdk)

    def test_windows_default_android_sdk(self):
        """On Windows, the default SDK location is %LOCALAPPDATA%\\Android\\Sdk."""
        tmp = Path(self._tmp())
        sdk = tmp / "Android" / "Sdk"
        (sdk / "build-tools").mkdir(parents=True)
        with (
            patch.dict(os.environ, {
                "ANDROID_HOME": "", "ANDROID_SDK_ROOT": "",
                "LOCALAPPDATA": str(tmp),
            }, clear=False),
            patch("setup.sys.platform", "win32"),
        ):
            self.assertEqual(discover_android_sdk(), sdk)


if __name__ == "__main__":
    unittest.main()

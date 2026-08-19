#!/usr/bin/env python3
"""Create a Supernote React Native project from the local template."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import stat
import subprocess
import sys
from pathlib import Path

def find_supernote_root(script_path: Path) -> Path | None:
    current = script_path.resolve().parent

    while True:
        template = current / "@supernote-plugin" / "sn-plugin-template"
        if template.is_dir():
            return current
        if current.parent == current:
            return None
        current = current.parent


def validate_project_name(name: str) -> str | None:
    if name in {".", ".."}:
        return "Project name cannot be '.' or '..'."
    if name.startswith("-"):
        return "Project name cannot start with '-'."
    if "/" in name or "\\" in name:
        return "Project name must be a single folder name."
    if any(character.isspace() for character in name):
        return "Project name cannot contain spaces."
    return None


# ── Development tool discovery ───────────────────────────────────────
#
# Compatible Java versions for the current Gradle / Android build toolchain.
# Gradle 8.13 supports JDK 17-23.  React Native 0.79 recommends JDK 17.
JAVA_MIN_VERSION = 17
JAVA_MAX_VERSION = 23
JAVA_PREFERRED_VERSION = 17

_JAVAC = "javac.exe" if sys.platform == "win32" else "javac"
_ADB = "adb.exe" if sys.platform == "win32" else "adb"


def _get_java_version(java_home: Path) -> int | None:
    """Return the major Java version for a JDK directory, or None."""
    javac = java_home / "bin" / _JAVAC
    if not javac.is_file():
        return None
    try:
        result = subprocess.run(
            [str(javac), "-version"],
            capture_output=True, text=True, timeout=10,
        )
        output = result.stdout.strip() or result.stderr.strip()
        match = re.search(r"(\d+)(?:\.\d+)*", output)
        if match:
            return int(match.group(1))
    except (subprocess.SubprocessError, OSError):
        pass
    return None


def _is_compatible_jdk(java_home: Path) -> tuple[bool, int | None]:
    """Check whether *java_home* points to a JDK in the accepted range."""
    version = _get_java_version(java_home)
    if version is None:
        return False, None
    return JAVA_MIN_VERSION <= version <= JAVA_MAX_VERSION, version


def _resolve_java_home(binary: Path) -> Path | None:
    """Given a java/javac binary, resolve its JAVA_HOME directory."""
    try:
        binary = binary.resolve()
    except OSError:
        return None
    if binary.parent.name == "bin":
        candidate = binary.parent.parent
        if (candidate / "bin" / _JAVAC).is_file():
            return candidate
    return None


def _scan_java_dirs(base: Path, suffix: str = "") -> list[Path]:
    """List candidate JDK directories under *base*, newest-looking first."""
    if not base.is_dir():
        return []
    candidates = []
    try:
        for entry in sorted(base.iterdir(), reverse=True):
            full = entry / suffix if suffix else entry
            if full.is_dir():
                candidates.append(full)
    except OSError:
        pass
    return candidates


def discover_java() -> tuple[Path | None, int | None]:
    """Find a compatible JDK.  Returns (java_home, version) or (None, None)."""
    candidates: list[Path] = []

    # 1. JAVA_HOME environment variable
    env_home = os.environ.get("JAVA_HOME")
    if env_home:
        candidates.append(Path(env_home))

    # 2. javac / java on PATH
    for name in (_JAVAC, "java.exe" if sys.platform == "win32" else "java"):
        which = shutil.which(name)
        if which:
            home = _resolve_java_home(Path(which))
            if home and home not in candidates:
                candidates.append(home)

    # 3. Platform-specific locations
    if sys.platform == "darwin":
        try:
            result = subprocess.run(
                ["/usr/libexec/java_home"],
                capture_output=True, text=True, timeout=10,
            )
            if result.returncode == 0 and result.stdout.strip():
                p = Path(result.stdout.strip())
                if p.is_dir() and p not in candidates:
                    candidates.append(p)
        except (subprocess.SubprocessError, OSError):
            pass
        candidates.extend(
            _scan_java_dirs(Path("/Library/Java/JavaVirtualMachines"), "Contents/Home"),
        )
    elif sys.platform == "win32":
        pf = os.environ.get("ProgramFiles", r"C:\Program Files")
        for base in (
            Path(pf) / "Java",
            Path(pf) / "Eclipse Adoptium",
            Path(pf) / "Microsoft",
        ):
            candidates.extend(
                d for d in _scan_java_dirs(base)
                if d.name.lower().startswith(("jdk", "jdk-"))
            )
    else:  # Linux and others
        for base in (Path("/usr/lib/jvm"), Path("/usr/java"), Path("/opt/java")):
            candidates.extend(_scan_java_dirs(base))

    # Deduplicate while preserving order
    seen: set[Path] = set()
    unique: list[Path] = []
    for c in candidates:
        try:
            resolved = c.resolve()
        except OSError:
            resolved = c
        if resolved not in seen:
            seen.add(resolved)
            unique.append(c)

    # Pick best: prefer JAVA_PREFERRED_VERSION, then any compatible
    preferred: tuple[Path, int] | None = None
    fallback: tuple[Path, int] | None = None
    for candidate in unique:
        compatible, version = _is_compatible_jdk(candidate)
        if not compatible:
            continue
        if version == JAVA_PREFERRED_VERSION and preferred is None:
            preferred = (candidate, version)
        elif fallback is None:
            fallback = (candidate, version)

    if preferred:
        return preferred
    if fallback:
        return fallback
    return None, None


def _is_valid_android_sdk(path: Path) -> bool:
    """Return True if *path* looks like an Android SDK root."""
    if not path.is_dir():
        return False
    return any(
        (path / sub).is_dir()
        for sub in ("platform-tools", "platforms", "build-tools")
    )


def discover_android_sdk() -> Path | None:
    """Find the Android SDK installation directory."""
    for env_var in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        value = os.environ.get(env_var)
        if value:
            p = Path(value)
            if _is_valid_android_sdk(p):
                return p

    # Platform defaults
    if sys.platform == "darwin":
        default = Path.home() / "Library" / "Android" / "sdk"
    elif sys.platform == "win32":
        local = os.environ.get("LOCALAPPDATA", "")
        default = Path(local) / "Android" / "Sdk" if local else None
    else:
        default = Path.home() / "Android" / "Sdk"

    if default and _is_valid_android_sdk(default):
        return default
    return None


def discover_adb(android_sdk: Path | None) -> Path | None:
    """Find the ADB executable."""
    if android_sdk:
        adb_path = android_sdk / "platform-tools" / _ADB
        if adb_path.is_file():
            return adb_path

    which = shutil.which("adb")
    if which:
        return Path(which)
    return None


def _write_devconfig(project_path: Path, java_home: Path | None,
                     android_sdk: Path | None, adb: Path | None) -> Path:
    """Write devconfig.json and return its path."""
    config = {
        "javaHome": str(java_home) if java_home else None,
        "androidSdk": str(android_sdk) if android_sdk else None,
        "adb": str(adb) if adb else None,
    }
    config_file = project_path / "devconfig.json"
    with open(config_file, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
        f.write("\n")
    return config_file


def _update_local_properties(project_path: Path, android_sdk: Path | None) -> None:
    """Update *only* the ``sdk.dir`` line in ``android/local.properties``."""
    if not android_sdk:
        return
    local_props = project_path / "android" / "local.properties"
    sdk_dir_value = str(android_sdk).replace("\\", "/")
    sdk_dir_line = f"sdk.dir={sdk_dir_value}"

    if local_props.is_file():
        lines = local_props.read_text(encoding="utf-8").splitlines(keepends=True)
        new_lines: list[str] = []
        found = False
        for line in lines:
            if line.rstrip("\n\r").startswith("sdk.dir="):
                new_lines.append(sdk_dir_line + "\n")
                found = True
            else:
                new_lines.append(line)
        if not found:
            if new_lines and not new_lines[-1].endswith("\n"):
                new_lines.append("\n")
            new_lines.append(sdk_dir_line + "\n")
        local_props.write_text("".join(new_lines), encoding="utf-8")
    else:
        local_props.parent.mkdir(parents=True, exist_ok=True)
        local_props.write_text(sdk_dir_line + "\n", encoding="utf-8")


def _print_dev_summary(java_home: Path | None, java_version: int | None,
                       android_sdk: Path | None, adb: Path | None,
                       config_file: Path) -> None:
    """Print a concise development-environment summary."""
    print("\nDevelopment environment:\n")
    print(f"  Java:        {java_home} (JDK {java_version})" if java_home
          else "  Java:        NOT FOUND")
    print(f"  Android SDK: {android_sdk}" if android_sdk
          else "  Android SDK: NOT FOUND")
    print(f"  ADB:         {adb}" if adb
          else "  ADB:         NOT FOUND")

    missing = []
    if not java_home:
        missing.append("javaHome")
    if not android_sdk:
        missing.append("androidSdk")
    if not adb:
        missing.append("adb")

    if missing:
        print(f"\n⚠ Some development tools could not be configured automatically.\n")
        print(f"  Edit: {config_file}\n")
        print(f"  Set:")
        for name in missing:
            print(f"    {name}")
    else:
        print("\n✓ Development tools configured")


class Setup:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.supernote_root = find_supernote_root(Path(__file__))

    def prompt_name(self) -> str:
        if self.args.project_name:
            return self.args.project_name.strip()
        if not sys.stdin.isatty():
            raise ValueError("A project name is required. Run: python3 setup.py <project-name>")
        return input("Project name: ").strip()

    def install_dependencies(self) -> bool:
        if self.args.install:
            return True
        if self.args.skip_install:
            return False
        if not sys.stdin.isatty():
            return False

        while True:
            answer = input("Install dependencies now? [y/n]: ").strip().lower()
            if answer in {"y", "yes"}:
                return True
            if answer in {"n", "no"}:
                return False
            print("Please enter y or n.")

    @staticmethod
    def run_command(command: list[str], working_directory: Path, activity: str) -> None:
        print(f"\n{activity}")
        result = subprocess.run(command, cwd=working_directory, check=False)
        if result.returncode != 0:
            raise RuntimeError(f"Command failed with exit code {result.returncode}.")

    def run(self) -> int:
        if self.supernote_root is None:
            print("Error: could not find the Supernote template above this script.", file=sys.stderr)
            return 1
        if shutil.which("npx") is None:
            print("Error: npx is required. Install Node.js, then try again.", file=sys.stderr)
            return 1

        project_name = self.prompt_name()
        if not project_name:
            print("Error: project name cannot be empty.", file=sys.stderr)
            return 1
        if error := validate_project_name(project_name):
            print(f"Error: {error}", file=sys.stderr)
            return 1

        template_path = self.supernote_root / "@supernote-plugin" / "sn-plugin-template"
        project_parent = Path.cwd().resolve()
        project_path = project_parent / project_name
        if project_path.exists() or project_path.is_symlink():
            print(f"Error: project already exists: {project_path}", file=sys.stderr)
            return 1

        install = self.install_dependencies()
        print("\n◆ Create Supernote Project")
        print(f"  Location:     {project_path}")
        print(f"  Dependencies: {'install' if install else 'skip'}")

        try:
            self.run_command(
                [
                    "npx",
                    "--yes",
                    "@react-native-community/cli@18.0.0",
                    "init",
                    project_name,
                    "--template",
                    str(template_path),
                    "--skip-install",
                ],
                project_parent,
                "Creating project...",
            )
            scripts_dir = project_path / "scripts"
            if scripts_dir.is_dir():
                for script in scripts_dir.glob("*.sh"):
                    script.chmod(script.stat().st_mode | stat.S_IEXEC)
            
            gradlew = project_path / "android" / "gradlew"
            if gradlew.is_file():
                gradlew.chmod(gradlew.stat().st_mode | stat.S_IEXEC)
        except (OSError, RuntimeError) as error:
            project_note = f"\nA partial project may be at: {project_path}" if project_path.is_dir() else ""
            print(f"\nProject creation failed: {error}{project_note}", file=sys.stderr)
            return 1

        if not (project_path.is_dir() and (project_path / "package.json").is_file()):
            print("\nProject creation failed: no usable project folder was produced.", file=sys.stderr)
            return 1

        if install:
            package_manager = "yarn" if (project_path / "yarn.lock").is_file() else "npm"
            if shutil.which(package_manager) is None:
                print(
                    f"\nProject created at: {project_path}\n"
                    f"{package_manager} is not installed; dependencies were not installed.",
                    file=sys.stderr,
                )
                return 1
            try:
                self.run_command(
                    [package_manager, "install"],
                    project_path,
                    "Installing dependencies...",
                )
            except (OSError, RuntimeError) as error:
                print(
                    f"\nProject created at: {project_path}\n"
                    f"Dependency installation failed: {error}\n"
                    f"Retry with: cd {project_path} && {package_manager} install",
                    file=sys.stderr,
                )
                return 1

        # ── Configure development tools ──────────────────────────────
        try:
            java_home, java_version = discover_java()
            android_sdk = discover_android_sdk()
            adb = discover_adb(android_sdk)

            config_file = _write_devconfig(project_path, java_home, android_sdk, adb)
            _update_local_properties(project_path, android_sdk)
            _print_dev_summary(java_home, java_version, android_sdk, adb, config_file)
        except Exception as exc:
            print(f"\nWarning: could not configure development tools: {exc}", file=sys.stderr)

        print(f"\n✓ Project created: {project_path}")
        return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project_name", nargs="?", help="name of the project directory")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--install", action="store_true", help="install dependencies without prompting")
    group.add_argument("--skip-install", action="store_true", help="skip dependency installation")
    return parser.parse_args()


if __name__ == "__main__":
    try:
        raise SystemExit(Setup(parse_args()).run())
    except (KeyboardInterrupt, EOFError):
        print("\nCancelled.", file=sys.stderr)
        raise SystemExit(130)

#!/usr/bin/env python3
"""Create a Supernote React Native project from the local template."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


def find_supernote_root(script_path: Path) -> Path | None:
    current = script_path.resolve().parent

    while True:
        template = current / "template" / "@supernote-plugin" / "sn-plugin-template"
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


class Setup:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.supernote_root = find_supernote_root(Path(__file__))

    def prompt_name(self) -> str:
        if self.args.project_name:
            return self.args.project_name.strip()
        if not sys.stdin.isatty():
            raise ValueError("A project name is required. Run: python3 setup.fixed.py <project-name>")
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

        template_path = self.supernote_root / "template" / "@supernote-plugin" / "sn-plugin-template"
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

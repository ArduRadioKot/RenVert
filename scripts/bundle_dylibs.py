#!/usr/bin/env python3
"""Copy non-system dylibs beside a Mach-O tool and retarget them to @rpath.

Homebrew ffmpeg is a symlink farm into Cellar. Copying the binary alone
leaves it unable to start on a machine without those exact library paths.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

SYSTEM_PREFIXES = ("/usr/lib/", "/System/Library/")


def otool_deps(path: Path) -> list[str]:
    output = subprocess.check_output(["otool", "-L", str(path)], text=True)
    deps: list[str] = []
    for index, line in enumerate(output.splitlines()):
        if index == 0:
            continue
        dep = line.strip().split(" (", 1)[0]
        if dep:
            deps.append(dep)
    return deps


def otool_rpaths(path: Path) -> list[str]:
    output = subprocess.check_output(["otool", "-l", str(path)], text=True)
    lines = output.splitlines()
    rpaths: list[str] = []
    for index, line in enumerate(lines):
        if line.strip() != "cmd LC_RPATH":
            continue
        for nxt in lines[index + 1 : index + 6]:
            stripped = nxt.strip()
            if stripped.startswith("path "):
                rpaths.append(stripped.split(" ", 1)[1].rsplit(" (", 1)[0])
                break
    return rpaths


def is_system(dep: str) -> bool:
    return dep.startswith(SYSTEM_PREFIXES)


def same_file(dep: str, owner: Path) -> bool:
    if not dep.startswith("/"):
        return False
    try:
        return Path(dep).resolve() == owner.resolve()
    except OSError:
        return False


def resolve(dep: str, owner: Path) -> Path:
    if dep.startswith("/"):
        path = Path(dep)
        if not path.exists():
            raise SystemExit(f"Missing dependency {dep} required by {owner}")
        return path.resolve()

    name = Path(dep).name
    search: list[Path] = []
    if dep.startswith("@loader_path/"):
        search.append(owner.parent / dep.removeprefix("@loader_path/"))
    elif dep.startswith("@executable_path/"):
        search.append(owner.parent / dep.removeprefix("@executable_path/"))
    elif dep.startswith("@rpath/"):
        relative = dep.removeprefix("@rpath/")
        for rpath in otool_rpaths(owner):
            if rpath.startswith("@loader_path"):
                root = owner.parent / rpath.removeprefix("@loader_path").lstrip("/")
            elif rpath.startswith("@executable_path"):
                root = owner.parent / rpath.removeprefix("@executable_path").lstrip("/")
            else:
                root = Path(rpath)
            search.append(root / relative)
        search.append(owner.parent / name)
    else:
        raise SystemExit(f"Unsupported install name {dep} in {owner}")

    for candidate in search:
        if candidate.exists():
            return candidate.resolve()
    raise SystemExit(f"Cannot resolve {dep} from {owner}")


def collect(owner: Path, acc: dict[str, tuple[Path, str]]) -> None:
    for dep in otool_deps(owner):
        if is_system(dep) or dep in acc or same_file(dep, owner):
            continue
        real = resolve(dep, owner)
        name = Path(dep).name
        acc[dep] = (real, name)
        collect(real, acc)
        alias = str(real)
        acc.setdefault(alias, (real, name))


def rewrite(path: Path, acc: dict[str, tuple[Path, str]], own_name: str | None, rpath: str) -> None:
    subprocess.run(["codesign", "--remove-signature", str(path)], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    path.chmod(0o755)
    command = ["install_name_tool"]
    if own_name:
        command.extend(["-id", f"@rpath/{own_name}"])
    current = set(otool_deps(path))
    changes = 0
    for dep, (_, name) in acc.items():
        if dep in current and dep != f"@rpath/{name}":
            command.extend(["-change", dep, f"@rpath/{name}"])
            changes += 1
    if len(command) > 1:
        subprocess.check_call(command + [str(path)])
    for existing in otool_rpaths(path):
        drop_executable = own_name is None and existing.startswith("@executable_path") and existing != rpath
        if existing.startswith("/opt/homebrew") or existing.startswith("/usr/local") or drop_executable:
            subprocess.check_call(["install_name_tool", "-delete_rpath", existing, str(path)])
    if rpath not in otool_rpaths(path):
        subprocess.check_call(["install_name_tool", "-add_rpath", rpath, str(path)])
    if changes == 0 and own_name is None:
        return


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: bundle_dylibs.py BINARY FRAMEWORKS_DIR")
    binary = Path(sys.argv[1]).resolve()
    frameworks = Path(sys.argv[2]).resolve()
    frameworks.mkdir(parents=True, exist_ok=True)

    acc: dict[str, tuple[Path, str]] = {}
    collect(binary, acc)

    by_name: dict[str, Path] = {}
    for _dep, (real, name) in acc.items():
        previous = by_name.get(name)
        if previous is not None and previous != real:
            raise SystemExit(f"Two libraries would both be named {name}: {previous} and {real}")
        by_name[name] = real

    for name, real in by_name.items():
        destination = frameworks / name
        shutil.copy2(real, destination, follow_symlinks=True)
        os.chmod(destination, 0o755)

    relative = Path(os.path.relpath(frameworks, binary.parent))
    rewrite(binary, acc, None, f"@executable_path/{relative.as_posix()}")
    for name in by_name:
        rewrite(frameworks / name, acc, name, "@loader_path")

    print(f"Bundled {len(by_name)} libraries next to {binary.name}")


if __name__ == "__main__":
    main()

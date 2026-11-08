#!/usr/bin/env python3
"""Install GuildProf into a game client's AddOns folder, for testing.

    python3 -I tools/install.py status            # what the installed copy matches
    python3 -I tools/install.py dev               # the working tree's addon folder
    python3 -I tools/install.py release [vX.Y.Z]  # a released version (default: the newest tag)

The AddOns folder is the first line of .addons-path at the repository root
(ignored by git), or --addons PATH. The installed folder is replaced as a
whole: the new copy is written next to it, swapped in, then compared file by
file with its source.

dev refuses a TOC version that has no release tag: every copy announces its
version to the guild, so members on the released version would be told that
a newer one is out. Keep the TOC at the released version while testing, or
pass --unreleased.
"""
import argparse
import pathlib
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ADDON = "GuildProf"
TOC = f"{ADDON}.toc"
PATH_FILE = ROOT / ".addons-path"
EXTRA = {"LICENSE.txt"}  # added by the release zip, not part of the source tree


def git(*args, binary=False):
    out = subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True)
    return out.stdout if binary else out.stdout.decode()


def fail(message):
    print("install: " + message, file=sys.stderr)
    sys.exit(1)


def addons_dir(arg):
    if arg:
        path = pathlib.Path(arg)
    elif PATH_FILE.exists():
        path = pathlib.Path(PATH_FILE.read_text().splitlines()[0].strip())
    else:
        fail(f"no AddOns folder: write its path in {PATH_FILE.name} or pass --addons")
    if path.name != "AddOns" or not path.is_dir():
        fail(f"{path} is not an AddOns folder")
    return path


# A tree is {path inside the addon folder: bytes}.

def tree_at(ref):
    names = [n for n in git("ls-tree", "-r", "-z", "--name-only", ref, ADDON).split("\0") if n]
    return {n[len(ADDON) + 1:]: git("show", f"{ref}:{n}", binary=True) for n in names}


def tree_worktree():
    names = git("ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", ADDON).split("\0")
    files = (ROOT / n for n in names if n)
    return {str(f.relative_to(ROOT / ADDON)): f.read_bytes() for f in files if f.is_file()}


def tree_installed(folder):
    tree = {}
    for f in sorted(folder.rglob("*")):
        if f.is_symlink():
            fail(f"{f} is a symbolic link: replace it by hand")
        if f.is_file():
            tree[str(f.relative_to(folder))] = f.read_bytes()
    return tree


def version(tree):
    m = re.search(rb"^## Version: *(\S+)", tree.get(TOC, b""), re.M)
    return m.group(1).decode() if m else "?"


def tags():
    return [t for t in git("tag", "--list", "v*", "--sort=-v:refname").split() if t]


def differences(a, b):
    return sorted(n for n in set(a) | set(b) if a.get(n) != b.get(n))


def status(addons):
    folder = addons / ADDON
    if not folder.exists():
        print(f"{folder}: not installed")
        return
    installed = {n: d for n, d in tree_installed(folder).items() if n not in EXTRA}
    print(f"installed: GuildProf {version(installed)}, {len(installed)} files")
    sources = [("working tree", tree_worktree()), ("HEAD", tree_at("HEAD"))]
    sources += [(t, tree_at(t)) for t in tags()]
    matches = [label for label, tree in sources if not differences(installed, tree)]
    if matches:
        print("matches: " + ", ".join(matches))
    else:
        print("matches nothing; differs from the working tree in: "
              + ", ".join(differences(installed, sources[0][1])))


def install(addons, tree, label):
    folder, new, old = addons / ADDON, addons / f".{ADDON}.new", addons / f".{ADDON}.old"
    if folder.is_symlink():
        fail(f"{folder} is a symbolic link: replace it by hand")
    if folder.exists() and not (folder / TOC).exists():
        fail(f"{folder} has no {TOC}: not touching it")
    before = tree_installed(folder) if folder.exists() else {}
    for leftover in (new, old):
        if leftover.exists():
            shutil.rmtree(leftover)
    for name, data in tree.items():
        path = new / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    if folder.exists():
        folder.rename(old)
    new.rename(folder)
    if old.exists():
        shutil.rmtree(old)
    wrong = differences(tree_installed(folder), tree)
    if wrong:
        fail(f"installed copy differs from {label} in: " + ", ".join(wrong))
    print(f"installed {label}: GuildProf {version(tree)}, {len(tree)} files, identical to the source")
    # Files added to the TOC of an installed addon load on /reload; only a
    # folder the client has never seen gets a full restart.
    if not before:
        print("next: quit and restart the game (new addon)")
    elif before == tree:
        print("next: nothing, the same files were already installed")
    else:
        print("next: /reload in game")


def main():
    parser = argparse.ArgumentParser(description="Install GuildProf into AddOns for testing.")
    parser.add_argument("mode", choices=["status", "dev", "release"])
    parser.add_argument("tag", nargs="?", help="release: the tag to install (default: the newest)")
    parser.add_argument("--addons", help="the AddOns folder (default: first line of .addons-path)")
    parser.add_argument("--unreleased", action="store_true",
                        help="dev: allow a TOC version that has no release tag")
    args = parser.parse_args()
    addons = addons_dir(args.addons)
    if args.mode == "status":
        return status(addons)
    if args.tag and args.mode != "release":
        fail("a tag goes with release only")
    if args.mode == "release":
        known = tags()
        tag = args.tag or (known[0] if known else None)
        if tag not in known:
            fail(f"no release tag {tag}" if tag else "no release tag yet")
        return install(addons, tree_at(tag), tag)
    tree = tree_worktree()
    v = version(tree)
    if f"v{v}" not in tags() and not args.unreleased:
        fail(f"the TOC says {v}, which has no release tag: the guild would be told it is out. "
             "Keep the released version while testing, or pass --unreleased")
    install(addons, tree, "working tree")


if __name__ == "__main__":
    main()

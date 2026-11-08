#!/usr/bin/env python3
"""Build the release zip and, with --publish, tag and publish it on GitHub.

    python3 -I tools/release.py            # dist/GuildProf.zip from the committed addon
    python3 -I tools/release.py --publish  # also tag v<version>, push the tag, create the release

The zip holds only the addon folder (GuildProf/ and its LICENSE), read from
the committed tree, so dragging that one folder into AddOns installs it.
The version is the committed TOC's "## Version": bump it and commit before
a release. The asset keeps one name, so
https://github.com/simonfou/GuildProf/releases/latest/download/GuildProf.zip
always serves the newest release.
"""
import pathlib
import re
import subprocess
import sys
import time
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
ADDON = "GuildProf"
TOC = f"{ADDON}/{ADDON}.toc"
ASSET = "GuildProf.zip"

NOTES = """\
**Install or update**

1. Download **GuildProf.zip** below.
2. In the Battle.net app, select World of Warcraft and its **Forever**
   version, click the gear next to **Play**, then **Show in Explorer**
   (**Show in Finder** on a Mac). Open `_forever_` if the window is not
   already in it, then `Interface`, then `AddOns`. Create `Interface` and
   `AddOns` if they are missing (exact spelling).
3. Delete the old `GuildProf` folder there, if there is one.
4. Double-click `GuildProf.zip` to open it and drag the **GuildProf** folder
   it contains into `AddOns`. The result is `AddOns\\GuildProf\\GuildProf.toc`.
   Windows' **Extract All** adds a second folder level
   (`AddOns\\GuildProf\\GuildProf\\`), which the game does not load.
5. Quit and restart the game. At character select, **AddOns** lists
   GuildProf.

Shared data is kept in the game's `WTF` folder and survives updates.
"""


def run(*args, binary=False):
    out = subprocess.run(args, cwd=ROOT, check=True, capture_output=True)
    return out.stdout if binary else out.stdout.decode()


def fail(message):
    print("release: " + message, file=sys.stderr)
    sys.exit(1)


def build(version):
    names = [n for n in run("git", "ls-tree", "-r", "-z", "--name-only", "HEAD", ADDON).split("\0") if n]
    stamp = time.gmtime(int(run("git", "log", "-1", "--format=%ct").strip()))[:6]
    entries = [(n, run("git", "show", f"HEAD:{n}", binary=True)) for n in sorted(names)]
    entries.append((f"{ADDON}/LICENSE.txt", run("git", "show", "HEAD:LICENSE", binary=True)))
    folders = sorted({str(pathlib.PurePosixPath(n).parent) + "/" for n, _ in entries})
    out = ROOT / "dist" / ASSET
    out.parent.mkdir(exist_ok=True)
    with zipfile.ZipFile(out, "w") as z:
        for folder in folders:
            info = zipfile.ZipInfo(folder, date_time=stamp)
            info.external_attr = (0o40755 << 16) | 0x10
            z.writestr(info, b"")
        for name, data in entries:
            info = zipfile.ZipInfo(name, date_time=stamp)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            z.writestr(info, data)
    print(f"built {out.relative_to(ROOT)}: GuildProf {version}, {len(entries)} files")
    return out


def main():
    args = sys.argv[1:]
    if args not in ([], ["--publish"]):
        fail("usage: release.py [--publish]")
    m = re.search(r"^## Version: (\d+\.\d+\.\d+)\s*$", run("git", "show", f"HEAD:{TOC}"), re.M)
    if not m:
        fail(f"no x.y.z '## Version' in the committed {TOC}")
    version = m.group(1)
    tag = "v" + version
    if run("git", "status", "--porcelain", "--", ADDON, "LICENSE").strip():
        fail(f"uncommitted changes under {ADDON}/: commit them first")
    if run("git", "tag", "--list", tag).strip():
        fail(f"tag {tag} exists: bump '## Version' in {TOC} and commit")
    out = build(version)
    if not args:
        return
    run("git", "fetch", "origin", "main")
    if run("git", "rev-parse", "HEAD") != run("git", "rev-parse", "origin/main"):
        fail("HEAD is not origin/main: push first")
    run("git", "tag", "-a", tag, "-m", f"GuildProf {version}")
    run("git", "push", "origin", tag)
    print(run("gh", "release", "create", tag, str(out), "--title", f"GuildProf {version}",
              "--notes", NOTES).strip())


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Build the release zip and publish it on GitHub and CurseForge.

    python3 -I tools/release.py                    # dist/GuildProf.zip from the committed addon
    python3 -I tools/release.py --publish          # also tag v<version>, push the tag, create the
                                                   # GitHub release, then upload to CurseForge
    python3 -I tools/release.py --curseforge-check # read-only: token and game version on CurseForge
    python3 -I tools/release.py --curseforge-only  # upload the tagged version to CurseForge only

The zip holds only the addon folder (GuildProf/ and its LICENSE), read from
the committed tree, so dragging that one folder into AddOns installs it.
The version is the committed TOC's "## Version": bump it and commit before
a release. The asset keeps one name, so
https://github.com/simonfou/GuildProf/releases/latest/download/GuildProf.zip
always serves the newest release.

CurseForge uploads need the TOC's "## X-Curse-Project-ID" and an author API
token in ~/.curseforge-token (outside the repository; never printed). The
game version is the CurseForge entry whose apiVersion is the TOC's
"## Interface" (16001 is 1.60.1). Without the ID or the token, --publish
skips CurseForge.
"""
import json
import pathlib
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
ADDON = "GuildProf"
TOC = f"{ADDON}/{ADDON}.toc"
ASSET = "GuildProf.zip"
CF_API = "https://wow.curseforge.com/api"
CF_TOKEN = pathlib.Path.home() / ".curseforge-token"

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


def toc_field(toc, name, pattern):
    m = re.search(rf"^## {name}: ({pattern})\s*$", toc, re.M)
    return m.group(1) if m else None


def build(version, ref="HEAD"):
    names = [n for n in run("git", "ls-tree", "-r", "-z", "--name-only", ref, ADDON).split("\0") if n]
    stamp = time.gmtime(int(run("git", "log", "-1", "--format=%ct", ref).strip()))[:6]
    entries = [(n, run("git", "show", f"{ref}:{n}", binary=True)) for n in sorted(names)]
    entries.append((f"{ADDON}/LICENSE.txt", run("git", "show", f"{ref}:LICENSE", binary=True)))
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


# ---------------------------------------------------------------- CurseForge

def cf_token():
    return CF_TOKEN.read_text().strip() if CF_TOKEN.exists() else None


def cf_call(token, path, body=None, content_type=None):
    headers = {"X-Api-Token": token, "User-Agent": "GuildProf-release"}
    if content_type:
        headers["Content-Type"] = content_type
    req = urllib.request.Request(CF_API + path, data=body, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.loads(r.read().decode() or "null")
    except urllib.error.HTTPError as e:
        hint = {401: ": no token sent", 403: f": token refused, replace {CF_TOKEN}"}.get(e.code, "")
        fail(f"CurseForge {path}: HTTP {e.code}{hint} {e.read().decode(errors='replace')[:300]}")
    except urllib.error.URLError as e:
        fail(f"CurseForge {path}: {e.reason}")


def cf_game_version(token, interface):
    found = [v for v in cf_call(token, "/game/versions") if str(v.get("apiVersion")) == interface]
    if len(found) != 1:
        listed = ", ".join(f"{v.get('id')} {v.get('name')} (type {v.get('gameVersionTypeID')})"
                           for v in found)
        fail(f"CurseForge game versions for interface {interface}: {len(found)} [{listed}]")
    return found[0]["id"], found[0].get("name")


def multipart(fields, file_field, file_name, file_data):
    boundary = uuid.uuid4().hex
    parts = []
    for name, value in fields.items():
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n'
                     f"{value}\r\n".encode())
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{file_field}"; '
                 f'filename="{file_name}"\r\nContent-Type: application/zip\r\n\r\n'.encode()
                 + file_data + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def changelog(tag):
    previous = subprocess.run(["git", "describe", "--tags", "--abbrev=0", f"{tag}^"], cwd=ROOT,
                              capture_output=True, text=True)
    span = f"{previous.stdout.strip()}..{tag}" if previous.returncode == 0 else tag
    return run("git", "log", "--format=- %s", span).strip() or f"- GuildProf {tag[1:]}"


def cf_upload(token, project, version, game_version_id, archive, notes):
    metadata = json.dumps({"displayName": f"GuildProf {version}", "releaseType": "release",
                           "gameVersions": [game_version_id], "changelog": notes,
                           "changelogType": "markdown"})
    body, content_type = multipart({"metadata": metadata}, "file", archive.name, archive.read_bytes())
    result = cf_call(token, f"/projects/{project}/upload-file", body, content_type)
    print(f"CurseForge: uploaded GuildProf {version}, file id {result.get('id') if result else '?'}")


def curseforge(toc, version, archive, upload):
    project = toc_field(toc, "X-Curse-Project-ID", r"\d+")
    token = cf_token()
    if not project or not token:
        missing = " and ".join(m for m, ok in (("## X-Curse-Project-ID in the TOC", project),
                                               (f"token file {CF_TOKEN}", token)) if not ok)
        if upload:
            print(f"CurseForge skipped: no {missing}")
            return
        fail(f"no {missing}")
    interface = toc_field(toc, "Interface", r"\d+")
    gid, game = cf_game_version(token, interface)
    print(f"CurseForge: project {project}, interface {interface} = game version {game} "
          f"(id {gid}), token accepted")
    if upload:
        cf_upload(token, project, version, gid, archive, changelog("v" + version))


# ---------------------------------------------------------------- main

def main():
    args = sys.argv[1:]
    modes = ([], ["--publish"], ["--curseforge-check"], ["--curseforge-only"])
    if args not in modes:
        fail("usage: release.py [--publish | --curseforge-check | --curseforge-only]")
    toc = run("git", "show", f"HEAD:{TOC}")
    version = toc_field(toc, "Version", r"\d+\.\d+\.\d+")
    if not version:
        fail(f"no x.y.z '## Version' in the committed {TOC}")
    tag = "v" + version
    if args == ["--curseforge-check"]:
        return curseforge(toc, version, None, upload=False)
    tagged = bool(run("git", "tag", "--list", tag).strip())
    if args == ["--curseforge-only"]:
        if not tagged:
            fail(f"{tag} is not released: run --publish")
        return curseforge(toc, version, build(version, tag), upload=True)
    if run("git", "status", "--porcelain", "--", ADDON, "LICENSE").strip():
        fail(f"uncommitted changes under {ADDON}/: commit them first")
    if tagged:
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
    curseforge(toc, version, out, upload=True)


if __name__ == "__main__":
    main()

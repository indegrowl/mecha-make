#!/bin/bash
# Snapshot what a profile builds from, so config refactors can be checked for
# "same image content" without running a full build.
#
# Usage: tests/frogger/snapshot-profile.sh <out-prefix> [profile]
#   <out-prefix>.summary  `mkosi summary` with run-specific lines (Seed, Image
#                         Version) dropped and tree/script fields reduced to
#                         their names (their content is in .tree)
#   <out-prefix>.tree     one line per file the profile copies in, keyed by the
#                         field and the destination path, with its sha256
#                         (symlinks: their target). Trees of one field are
#                         merged in order, so a later tree overriding an
#                         earlier one counts once. Preset files are reduced to
#                         their lines, so splitting a preset doesn't count.
set -euo pipefail

out=${1:?usage: snapshot-profile.sh <out-prefix> [profile]}
profile=${2:-comet}
repo=$(cd "$(dirname "$0")/../.." && pwd)
CONTAINER_NAME=mecha-build

if ! podman image exists "$CONTAINER_NAME"; then
    podman build -t "$CONTAINER_NAME" -f "$repo/Containerfile" "$repo" >&2
fi

raw=$(mktemp)
trap 'rm -f "$raw"' EXIT
podman run --rm --cap-add=SYS_ADMIN -v "$repo":/build -w /build "$CONTAINER_NAME" \
    bash -euc "git config --global --add safe.directory /build; mkosi --profile=$profile summary" >"$raw"

python3 -I - "$raw" "$repo" "$out" <<'EOF'
import hashlib, os, re, sys

raw, repo, out = sys.argv[1:]
TREES = {"Skeleton Trees", "Extra Trees", "Sandbox Trees", "Repart Directories"}
SCRIPTS = {"Postinstall Scripts", "Finalize Scripts"}
DROP = {"Seed", "Image Version", "Environment Files"}  # Environment Files: the local, gitignored mkosi.env

summary, fields, image, key = [], {}, None, None
for line in open(raw):
    line = re.sub(r"/tmp/tmp[^/\s]+", "/tmp/<tmp>", line.rstrip("\n"))
    m = re.match(r"^IMAGE: (.*)$", line)
    if m:
        image, key = m.group(1), None
        summary.append(line)
        continue
    m = re.match(r"^\s*([A-Za-z][^:]*): ?(.*)$", line)
    if m and not line.lstrip().startswith("/"):
        key, val = m.group(1).strip(), m.group(2).strip()
        if key in DROP:
            continue
        if key in TREES | SCRIPTS:
            fields.setdefault((image, key), [])
            if val and val != "none":
                fields[(image, key)].append(val)
            summary.append(f"{key}: <see .tree>")
            continue
        summary.append(line)
        continue
    if key in DROP:
        continue
    if key in TREES | SCRIPTS:
        if line.strip():
            fields[(image, key)].append(line.strip())
        continue
    summary.append(line)

def local(p):
    p = p.split(":", 1)[0]  # "src:dst" tree syntax
    return os.path.join(repo, os.path.relpath(p, "/build")) if p.startswith("/build") else p

def digest(path):
    if os.path.islink(path):
        return "link:" + os.readlink(path)
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()

rows = set()
for (image, key), vals in fields.items():
    if key in SCRIPTS:
        for v in vals:
            rows.add(f"{image}\t{key}\t-\t{digest(local(v))}")
        continue
    merged = {}
    for v in vals:
        root = local(v)
        for dirpath, dirnames, filenames in os.walk(root):
            for name in filenames + [d for d in dirnames if os.path.islink(os.path.join(dirpath, d))]:
                path = os.path.join(dirpath, name)
                merged[os.path.relpath(path, root)] = digest(path)
    for rel, h in merged.items():
        if "/system-preset/" in "/" + rel and not h.startswith("link:"):
            src = next(os.path.join(local(v), rel) for v in reversed(vals)
                       if os.path.exists(os.path.join(local(v), rel)))
            for pl in open(src):
                pl = pl.strip()
                if pl and not pl.startswith("#"):
                    rows.add(f"{image}\t{key}\tpreset\t{pl}")
            continue
        rows.add(f"{image}\t{key}\t{rel}\t{h}")

with open(out + ".summary", "w") as f:
    f.write("\n".join(summary) + "\n")
with open(out + ".tree", "w") as f:
    f.write("\n".join(sorted(rows)) + "\n")
EOF

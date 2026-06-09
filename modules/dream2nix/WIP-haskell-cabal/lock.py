#!/usr/bin/env python3

# Generate a lock file based on plan.json. Unfortunately plan.json doesn't
# inlude all required information - it's missing revision of cabal file which
# breaks the compilation later on due to invalid version constraints, so we
# are augmenting it with correct revision and link to the valid cabal file

from hashlib import sha256
from urllib.parse import urljoin
import json
import os
import requests
import subprocess
import sys

with open("./dist-newstyle/cache/plan.json") as f:
    plan = json.load(f)


def to_sri(h):
    return subprocess.run(
        ["nix", "hash", "to-sri", "--type", "sha256", h],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


def prefetch_unpack(url):
    raw = subprocess.run(
        ["nix-prefetch-url", "--unpack", "--type", "sha256", url],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    return to_sri(raw)


hackage = {}
git = {}

install_plan = plan["install-plan"]

hackage_pkgs = [
    pkg for pkg in install_plan if pkg.get("pkg-src", {}).get("type") == "repo-tar"
]
git_pkgs = [
    pkg for pkg in install_plan if pkg.get("pkg-src", {}).get("type") == "source-repo"
]

for i, pkg in enumerate(hackage_pkgs):
    name = pkg["pkg-name"]
    version = pkg["pkg-version"]
    id = pkg["id"]

    print(f"[hackage {i+1}/{len(hackage_pkgs)}] Resolving {name}-{version}")

    revisions = requests.get(
        f"https://hackage.haskell.org/package/{name}-{version}/revisions/",
        headers={"Accept": "application/json"},
    ).json()

    base_url = pkg["pkg-src"]["repo"]["uri"]
    src_url = urljoin(base_url, f"package/{name}/{name}-{version}.tar.gz")

    for rev in revisions:
        no = rev["number"]
        rev_url = (
            f"https://hackage.haskell.org/package/{name}-{version}/revision/{no}.cabal"
        )
        rev_cabal = requests.get(rev_url).text
        rev_hash = sha256(rev_cabal.encode("utf-8")).hexdigest()

        if rev_hash == pkg["pkg-cabal-sha256"]:
            hackage[id] = {
                "name": name,
                "version": version,
                "cabal": {
                    "url": rev_url,
                    "hash": to_sri(rev_hash),
                },
                "src": {
                    "url": src_url,
                    "hash": prefetch_unpack(src_url),
                },
            }
            break
    else:
        print(f"Could not find revision for {name}-{version}", file=sys.stderr)
        sys.exit(1)

for i, pkg in enumerate(git_pkgs):
    name = pkg["pkg-name"]
    version = pkg["pkg-version"]
    id = pkg["id"]
    repo = pkg["pkg-src"]["source-repo"]
    location = repo["location"]
    tag = repo["tag"]

    print(f"[git {i+1}/{len(git_pkgs)}] Fetching {name}-{version} @ {tag[:12]}")

    repo_base = location.rstrip("/").removesuffix(".git")
    archive_url = f"{repo_base}/archive/{tag}.tar.gz"

    git[id] = {
        "name": name,
        "version": version,
        "location": location,
        "tag": tag,
        "src": {
            "url": archive_url,
            "hash": prefetch_unpack(archive_url),
        },
    }

with open(os.environ["out"], "w") as f:
    json.dump({"hackage": hackage, "git": git}, f, indent=2)

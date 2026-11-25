"""Publish three verified engine variants from a successful build run.

To authorize publication, add request.json on a dedicated otzaria-publish-* branch.
Use runId (integer), buildCommit (full SHA), and a tags object with a distinct
otzaria-3.47.7-* tag for each variant. Push that branch to the engine fork.
"""

from contextlib import ExitStack
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from typing import BinaryIO
import zipfile


ARCHITECTURES = ("x64", "arm64")
VARIANTS = {
    "windows-numpad": {
        "title": "Windows numpad navigation",
        "patches": ("windows-numpad",),
    },
    "skia-style": {
        "title": "Skia paragraph style lookup",
        "patches": ("skia-style",),
    },
    "both": {
        "title": "Windows numpad navigation and Skia paragraph style lookup",
        "patches": ("windows-numpad", "skia-style"),
    },
}
A11Y_SOURCE = "78b942eaf6b38a3ec398d35404336bdc032ba310"
ENGINE_VERSION = "deb287481e3ce9468f3434937ced4240a70539ca"
SKIA_VERSION = "8df24be66531469e576a806749a0202ae26b8d08"
PATCH_SHA256 = {
    "windows-numpad": "544bd5c5799b8227636c3e4b53f36ff184f334003cf09b2552f8a54ff88b4a57",
    "skia-style": "f62f946e95820e1e52f680a8d517ea5c6a2617c7c85889f39157485404df3407",
}
BINARIES = {
    "flutter_windows.dll",
    "flutter_windows.dll.exp",
    "flutter_windows.dll.lib",
    "flutter_windows.dll.pdb",
}
REPOSITORY = "Y-PLONI/flutter"


def api(path, *options):
    return json.loads(subprocess.check_output(["gh", "api", f"repos/{REPOSITORY}/{path}", *options]))


def releases_by_tag():
    pages = api("releases?per_page=100", "--paginate", "--slurp")
    return {release["tag_name"]: release for page in pages for release in page}


def sha256(stream: BinaryIO):
    return hashlib.file_digest(stream, "sha256").hexdigest()


def download_verified_artifact(artifact, destination):
    artifact_id = int(artifact["id"])
    with destination.open("wb") as output:
        subprocess.run(
            ["gh", "api", f"repos/{REPOSITORY}/actions/artifacts/{artifact_id}/zip"],
            stdout=output,
            check=True,
        )
    with destination.open("rb") as stream:
        actual = sha256(stream)
    if artifact["expired"] or artifact.get("digest") != f"sha256:{actual}":
        raise ValueError(f"Artifact {artifact['name']} has an invalid digest")


def read_checksums(checksums):
    result = {}
    for line in checksums.splitlines():
        digest, name = line.split("  ", 1)
        if name in result or not re.fullmatch(r"[a-f0-9]{64}", digest):
            raise ValueError(f"Invalid SHA256 manifest entry for {name}")
        result[name] = digest
    return result


def prepare_asset(outer, directory, arch, variant, run):
    filename = f"flutter_windows-windows-{arch}-release.zip"
    asset_path = directory / filename
    provenance = json.loads(outer.read(f"{variant}/provenance.json"))
    patch_hashes = {name: PATCH_SHA256[name] for name in VARIANTS[variant]["patches"]}
    expected = {
        "variant": variant,
        "architecture": arch,
        "runtimeMode": "release",
        "sourceCommit": A11Y_SOURCE,
        "compatibilityEngineVersion": ENGINE_VERSION,
        "skiaCommit": SKIA_VERSION,
        "patchSha256": patch_hashes,
        "workflowCommit": run["head_sha"],
        "workflowRun": run["html_url"],
    }
    for key, value in expected.items():
        if provenance.get(key) != value:
            raise ValueError(f"Unexpected {variant}/{arch} provenance for {key}")

    checksums = read_checksums(outer.read(f"{variant}/SHA256SUMS.txt").decode("utf-8"))
    if checksums.keys() != BINARIES | {filename}:
        raise ValueError(f"Unexpected checksum entries in {variant}/{arch}")
    with outer.open(f"{variant}/{filename}") as source, asset_path.open("wb") as output:
        shutil.copyfileobj(source, output)
    with asset_path.open("rb") as stream:
        if sha256(stream) != checksums[filename]:
            raise ValueError(f"Archive digest mismatch for {variant}/{arch}")

    with zipfile.ZipFile(asset_path) as engine:
        if len(engine.namelist()) != len(BINARIES) or set(engine.namelist()) != BINARIES:
            raise ValueError(f"Unexpected binary files in {variant}/{arch}")
        for binary in sorted(BINARIES):
            with engine.open(binary) as stream:
                if sha256(stream) != checksums[binary]:
                    raise ValueError(f"Digest mismatch for {variant}/{arch}/{binary}")

    provenance_path = directory / f"provenance-{arch}.json"
    provenance_path.write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")
    return f"{checksums[filename]}  {filename}"


def validate_request(request):
    commit = request.get("buildCommit", "")
    if not re.fullmatch(r"[a-f0-9]{40}", commit):
        raise ValueError("buildCommit must be the exact GitHub Actions build commit SHA")
    run_id = request.get("runId")
    if type(run_id) is not int or run_id < 1:
        raise ValueError("runId must be a positive integer")
    tags = request.get("tags", {})
    if tags.keys() != VARIANTS.keys() or len(set(tags.values())) != len(VARIANTS):
        raise ValueError("tags must contain a unique tag for every engine variant")
    for tag in tags.values():
        if not re.fullmatch(r"otzaria-3\.47\.7-[a-zA-Z0-9.-]+", tag):
            raise ValueError(f"Unexpected release tag {tag}")
    return run_id, commit, tags


def check_release_assets(release, commit, files):
    tag = release["tag_name"]
    if release["target_commitish"] != commit or not release["prerelease"]:
        raise ValueError(f"Release {tag} has a different target or is not a prerelease")
    expected = {path.name: path for path in files}
    missing = set(expected)
    for asset in release["assets"]:
        name = asset["name"]
        if name not in expected:
            raise ValueError(f"Unexpected asset {name} in release {tag}")
        with expected[name].open("rb") as stream:
            digest = sha256(stream)
        if asset.get("digest") != f"sha256:{digest}":
            raise ValueError(f"Existing asset {name} has a different digest in release {tag}")
        missing.remove(name)
    if missing and not release["draft"]:
        raise ValueError(f"Published release {tag} is missing assets")
    return [expected[name] for name in sorted(missing)]


def load_verified_build():
    if os.environ.get("GITHUB_REPOSITORY") != REPOSITORY:
        raise ValueError(f"Publication workflow must run in {REPOSITORY}")
    request = json.loads(Path(__file__).with_name("request.json").read_text(encoding="utf-8"))
    run_id, commit, tags = validate_request(request)
    run = api(f"actions/runs/{run_id}")
    if (
        run["conclusion"] != "success"
        or run["head_sha"] != commit
        or run["head_repository"]["full_name"] != REPOSITORY
        or not run["head_branch"].startswith("otzaria-native-fixes-")
        or run["path"].split("@", 1)[0] != ".github/workflows/otzaria-native-fixes.yml"
    ):
        raise ValueError("The requested run is not a successful Otzaria engine build")

    artifacts = {
        artifact["name"]: artifact
        for artifact in api(f"actions/runs/{run_id}/artifacts?per_page=100")["artifacts"]
    }
    validation = "otzaria-windows-x64-paragraph-validation"
    if validation not in artifacts or artifacts[validation]["expired"]:
        raise ValueError("The successful build did not retain x64 paragraph validation evidence")
    return run, artifacts, tags


def prepare_arm64_validation(run, artifacts):
    arch = "arm64"
    name = f"otzaria-windows-{arch}-release"
    with tempfile.TemporaryDirectory(prefix="otzaria-validate-arm64-") as temp:
        path = Path(temp) / f"{name}.zip"
        download_verified_artifact(artifacts[name], path)
        with zipfile.ZipFile(path) as package:
            for variant in VARIANTS:
                directory = Path("engine-artifacts") / variant
                directory.mkdir(parents=True)
                print(prepare_asset(package, directory, arch, variant, run), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-arm64", action="store_true")
    args = parser.parse_args()

    run, artifacts, tags = load_verified_build()
    if args.prepare_arm64:
        prepare_arm64_validation(run, artifacts)
        return

    commit = run["head_sha"]
    with tempfile.TemporaryDirectory(prefix="otzaria-publish-") as temp, ExitStack() as stack:
        work = Path(temp)
        archives = {}
        for arch in ARCHITECTURES:
            name = f"otzaria-windows-{arch}-release"
            path = work / f"{name}.zip"
            download_verified_artifact(artifacts[name], path)
            archives[arch] = stack.enter_context(zipfile.ZipFile(path))
        release_files = {}
        for variant, spec in VARIANTS.items():
            directory = work / variant
            directory.mkdir()
            checksums = [prepare_asset(archives[arch], directory, arch, variant, run) for arch in ARCHITECTURES]
            (directory / "SHA256SUMS.txt").write_text("\n".join(checksums) + "\n", encoding="utf-8")
            release_files[variant] = sorted(directory.iterdir())
            print(f"Verified {spec['title']} package hashes", *checksums, sep="\n", flush=True)

        # Stage every release and its assets before publishing any of them.
        releases = releases_by_tag()
        for variant, spec in VARIANTS.items():
            tag = tags[variant]
            if tag not in releases:
                notes = (
                    f"Flutter 3.47.7 Windows release engine for x64 and ARM64 with "
                    f"{spec['title']} and the existing accessibility fixes. "
                    f"The release archives contain the engine DLL and its PDB, LIB, and EXP files.\n\n"
                    f"Build and validation evidence: {run['html_url']}"
                )
                subprocess.run(
                    [
                        "gh", "release", "create", tag,
                        "--repo", REPOSITORY,
                        "--target", commit,
                        "--draft", "--prerelease", "--latest=false",
                        "--title", f"Flutter 3.47.7 – {spec['title']}",
                        "--notes", notes,
                    ],
                    check=True,
                )

        releases = releases_by_tag()
        for variant, files in release_files.items():
            tag = tags[variant]
            release = releases[tag]
            missing = check_release_assets(release, commit, files)
            if missing:
                subprocess.run(
                    ["gh", "release", "upload", tag, "--repo", REPOSITORY, *map(str, missing)],
                    check=True,
                )

        releases = releases_by_tag()
        for variant, files in release_files.items():
            release = releases[tags[variant]]
            if check_release_assets(release, commit, files):
                raise ValueError(f"Missing release assets for {tags[variant]}")

        for tag in tags.values():
            if releases[tag]["draft"]:
                subprocess.run(
                    [
                        "gh", "release", "edit", tag,
                        "--repo", REPOSITORY,
                        "--draft=false", "--prerelease", "--latest=false",
                    ],
                    check=True,
                )



if __name__ == "__main__":
    main()

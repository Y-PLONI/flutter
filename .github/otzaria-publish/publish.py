"""Publish verified Flutter 3.47.9 engine variants from a successful build run.

To validate a build, add validation.json to an otzaria-publish-* branch.
Record the runId, buildCommit (full SHA) and the x64/arm64 artifactDigests.

To authorize publication after reviewing that run, add request.json to the same
branch. Record its validationRunId and a tags object for the variants to publish.
"""

from contextlib import ExitStack
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from typing import BinaryIO
import xml.etree.ElementTree as ET
import zipfile


ARCHITECTURES = ("x64", "arm64")
FLUTTER_VERSION = "3.47.9"
FLUTTER_COMMIT = "c197ca5199e9ee5661e865596c9c07294dfab51c"
VARIANTS = {
    "skia-style": {
        "title": "Skia paragraph layout fixes",
        "patches": ("skia-style",),
    },
    "both": {
        "title": "Skia paragraph layout and Windows numpad navigation",
        "patches": ("skia-style", "windows-numpad"),
    },
}
A11Y_SOURCE = "e86b9d824eeade0a241ce91bb877fdd0d1da3941"
ENGINE_VERSION = "89c39edfdfae2949f6806e4a315c0c08522238b7"
SKIA_VERSION = "8df24be66531469e576a806749a0202ae26b8d08"
PATCH_SHA256 = {
    "windows-numpad": "544bd5c5799b8227636c3e4b53f36ff184f334003cf09b2552f8a54ff88b4a57",
    "skia-style": "02b37d56b7ab6e82814f22d0b7653908f65f836077bfa22ccfe540c94c88debb",
}
A11Y_COMMITS = (
    ("b207278eda", "Keep AccessibilityBridge usable after nested reparenting (flutter/flutter#175041)"),
    ("2f3076b1ab", "Measure text length without converting it to UTF-16 (flutter/flutter#196183)"),
    ("b3667ab814", "Make ITextProvider::GetVisibleRanges linear in the number of lines (flutter/flutter#196183)"),
    ("78b942eaf6", "Tie the text length cache to the embedded object behavior (flutter/flutter#196183)"),
)
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
        "sourceRepository": "https://github.com/Y-PLONI/flutter",
        "sourceCommit": A11Y_SOURCE,
        "dartCommit": "416e33b0ffaef062a60ec966bb8c82ed2b83f128",
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


def validate_build_reference(request):
    commit = request.get("buildCommit", "")
    if not re.fullmatch(r"[a-f0-9]{40}", commit):
        raise ValueError("buildCommit must be the exact GitHub Actions build commit SHA")
    run_id = request.get("runId")
    if type(run_id) is not int or run_id < 1:
        raise ValueError("runId must be a positive integer")
    return run_id, commit


def validate_release_tags(request):
    tags = request.get("tags", {})
    if not tags or not tags.keys() <= VARIANTS.keys() or len(set(tags.values())) != len(tags):
        raise ValueError("tags must contain a unique tag for each selected engine variant")
    for tag in tags.values():
        if not re.fullmatch(r"otzaria-3\.47\.9-[a-zA-Z0-9.-]+", tag):
            raise ValueError(f"Unexpected release tag {tag}")
    return tags


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


def file_request(name):
    return json.loads(Path(__file__).with_name(name).read_text(encoding="utf-8"))


def load_verified_build(request):
    run_id, commit = validate_build_reference(request)
    run = api(f"actions/runs/{run_id}")
    if (
        run["status"] != "completed"
        or run["head_sha"] != commit
        or run["head_repository"]["full_name"] != REPOSITORY
        or not run["head_branch"].startswith("otzaria-native-fixes-")
        or run["path"].split("@", 1)[0] != ".github/workflows/otzaria-native-fixes.yml"
    ):
        raise ValueError("The requested run is not a completed Otzaria engine build")

    jobs = {
        job["name"]: job
        for job in api(f"actions/runs/{run_id}/jobs?per_page=100")["jobs"]
    }
    for arch in ARCHITECTURES:
        job = jobs[f"Windows engine ({arch})"]
        steps = {step["name"]: step["conclusion"] for step in job["steps"]}
        for required in (
            "Prepare pinned engine sources and Windows toolchain",
            "Build engine variants and verify exports",
            "Upload engine variants and build evidence",
        ):
            if steps.get(required) != "success":
                raise ValueError(f"The {arch} build did not pass {required}")
        failures = {name for name, result in steps.items() if result == "failure"}
        if job["conclusion"] != "success" or failures:
            raise ValueError(f"The {arch} build did not finish successfully: {failures}")

    artifacts = {
        artifact["name"]: artifact
        for artifact in api(f"actions/runs/{run_id}/artifacts?per_page=100")["artifacts"]
    }
    for arch in ARCHITECTURES:
        name = f"otzaria-windows-{arch}-release"
        if artifacts[name]["expired"] or artifacts[name]["digest"] != request["artifactDigests"][arch]:
            raise ValueError(f"Unexpected artifact digest for {arch}")
    return run, artifacts


def verify_build_evidence(package, arch):
    baseline_exports = package.read("baseline-exports.txt")
    if b"Name: " not in baseline_exports:
        raise ValueError(f"The {arch} baseline export list is empty")
    for variant in VARIANTS:
        if package.read(f"{variant}-exports.txt") != baseline_exports:
            raise ValueError(f"PE exports changed for {variant}/{arch}")

    if arch == "x64":
        baseline = ET.fromstring(package.read("keyboard-unittests-baseline.xml"))
        fixed = ET.fromstring(package.read("keyboard-unittests.xml"))
        expected_failures = {
            "NumpadAndDedicatedArrowsStayDistinct",
            "NumpadNavigationKeepsIdentityAcrossNumLock",
            "NumpadNavigationUsesNativeVirtualKeys",
            "NumpadRecoversAfterMissedRelease",
        }
        baseline_cases = baseline.findall(".//testcase")
        failed = {case.attrib["name"] for case in baseline_cases if case.find("failure") is not None}
        fixed_cases = fixed.findall(".//testcase")
        fixed_numpad = {case.attrib["name"] for case in fixed_cases if case.attrib["name"].startswith("Numpad")}
        if len(baseline_cases) != 6 or failed != expected_failures:
            raise ValueError("The keyboard baseline XML does not show the four expected regressions")
        if (
            len(fixed_cases) != 25
            or fixed_numpad != {case.attrib["name"] for case in baseline_cases}
            or any(case.find("failure") is not None for case in fixed_cases)
            or fixed.attrib["errors"] != "0"
            or fixed.attrib["failures"] != "0"
        ):
            raise ValueError("The patched keyboard suite XML does not show 25 passing tests")
        print("Verified four expected baseline failures and 25 passing keyboard tests", flush=True)


def prepare_runtime(run, artifacts, arch):
    name = f"otzaria-windows-{arch}-release"
    with tempfile.TemporaryDirectory(prefix=f"otzaria-validate-{arch}-") as temp:
        path = Path(temp) / f"{name}.zip"
        download_verified_artifact(artifacts[name], path)
        with zipfile.ZipFile(path) as package:
            verify_build_evidence(package, arch)
            for variant in VARIANTS:
                directory = Path("engine-artifacts") / variant
                directory.mkdir(parents=True)
                print(prepare_asset(package, directory, arch, variant, run), flush=True)


def check_runtime_validation(request, build_request):
    run_id = request.get("validationRunId")
    if type(run_id) is not int or run_id < 1:
        raise ValueError("validationRunId must be a positive integer")
    validation = api(f"actions/runs/{run_id}")
    if (
        validation["conclusion"] != "success"
        or validation["head_repository"]["full_name"] != REPOSITORY
        or not validation["head_branch"].startswith("otzaria-publish-")
        or validation["path"].split("@", 1)[0] != ".github/workflows/otzaria-runtime-validation.yml"
    ):
        raise ValueError("The requested Windows runtime validation run did not pass")
    commit = validation["head_sha"]
    payload = api(f"contents/.github/otzaria-publish/validation.json?ref={commit}")
    validated_request = json.loads(base64.b64decode(payload["content"]))
    if validated_request != build_request:
        raise ValueError("Runtime validation used a different build or different artifact digests")

    artifacts = {
        artifact["name"]: artifact
        for artifact in api(f"actions/runs/{run_id}/artifacts?per_page=100")["artifacts"]
    }
    for arch in ARCHITECTURES:
        name = f"otzaria-windows-{arch}-paragraph-validation"
        if name not in artifacts or artifacts[name]["expired"]:
            raise ValueError(f"The validation run did not retain {arch} paragraph evidence")
    return validation


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-runtime", choices=ARCHITECTURES)
    args = parser.parse_args()

    if os.environ.get("GITHUB_REPOSITORY") != REPOSITORY:
        raise ValueError(f"This workflow must run in {REPOSITORY}")
    build_request = file_request("validation.json")
    run, artifacts = load_verified_build(build_request)
    if args.prepare_runtime:
        prepare_runtime(run, artifacts, args.prepare_runtime)
        return

    release_request = file_request("request.json")
    tags = validate_release_tags(release_request)
    validation = check_runtime_validation(release_request, build_request)
    commit = run["head_sha"]
    server = os.environ["GITHUB_SERVER_URL"]
    publication = f"{server}/{REPOSITORY}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
    with tempfile.TemporaryDirectory(prefix="otzaria-publish-") as temp, ExitStack() as stack:
        work = Path(temp)
        archives = {}
        for arch in ARCHITECTURES:
            name = f"otzaria-windows-{arch}-release"
            path = work / f"{name}.zip"
            download_verified_artifact(artifacts[name], path)
            archives[arch] = stack.enter_context(zipfile.ZipFile(path))
            verify_build_evidence(archives[arch], arch)
        release_files = {}
        for variant in tags:
            spec = VARIANTS[variant]
            directory = work / variant
            directory.mkdir()
            checksums = [prepare_asset(archives[arch], directory, arch, variant, run) for arch in ARCHITECTURES]
            (directory / "SHA256SUMS.txt").write_text("\n".join(checksums) + "\n", encoding="utf-8")
            release_files[variant] = sorted(directory.iterdir())
            print(f"Verified {spec['title']} package hashes", *checksums, sep="\n", flush=True)

        # Stage every release and its assets before publishing any of them.
        releases = releases_by_tag()
        for variant, tag in tags.items():
            spec = VARIANTS[variant]
            if tag not in releases:
                fixes = f"{spec['title']} and the accessibility fixes" if spec["patches"] else "the accessibility fixes"
                commits = "\n".join(f"- `{sha}` (cherry-picked) {title}" for sha, title in A11Y_COMMITS)
                notes = (
                    f"Flutter {FLUTTER_VERSION} Windows release engine for x64 and ARM64 with {fixes}. "
                    f"It replaces `flutter_windows.dll` of Flutter {FLUTTER_VERSION} (engine `{ENGINE_VERSION}`). "
                    "The release archives contain the engine DLL and its PDB, LIB, and EXP files.\n\n"
                    f"Source: Flutter tag {FLUTTER_VERSION} (`{FLUTTER_COMMIT}`) with the accessibility commits "
                    f"(`{A11Y_SOURCE}`):\n\n{commits}\n\n"
                    f"[Engine build, exports, and keyboard tests]({run['html_url']})\n\n"
                    f"[Native x64 and ARM64 runtime validation]({validation['html_url']})\n\n"
                    f"[Publication checks]({publication})"
                )
                subprocess.run(
                    [
                        "gh", "release", "create", tag,
                        "--repo", REPOSITORY,
                        "--target", commit,
                        "--draft", "--prerelease", "--latest=false",
                        "--title", f"Flutter {FLUTTER_VERSION} – {spec['title']}",
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

#!/usr/bin/env python3
"""Prepare an audited source ZIP from the working tree, without old Git history.

Includes approved project paths only. No remote is contacted, index changed,
or commit created. The output directory defaults to ignored dist/github.
"""

import argparse
import hashlib
import json
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path

from public_preflight import git, scan_tree

ROOT_FILES = {".gitattributes", ".gitignore", ".swift-format", "AGENTS.md", "LICENSE", "README.md", "PROJECT_STATUS.md", "THIRD_PARTY_NOTICES.md"}
ROOT_DIRECTORIES = {".github", "Config", "Design", "Metaliquartz.xcodeproj", "Scripts", "Sources", "Tests", "UITests", "Vendor", "docs", "wiki"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", nargs="?", type=Path, default=Path("dist/github"))
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    candidates = sorted(set(git(root, "ls-files", "-z", "--cached", "--others", "--exclude-standard").decode().split("\0")) - {""})
    selected = [name for name in candidates if name in ROOT_FILES or Path(name).parts[0] in ROOT_DIRECTORIES]
    with tempfile.TemporaryDirectory(prefix="metaliquartz-public-", dir=output) as temporary:
        stage = Path(temporary) / "Metaliquartz"
        stage.mkdir()
        for name in selected:
            source = root / name
            if source.is_symlink() or not source.is_file():
                raise SystemExit(f"Package blocked: missing file or symlink: {name}")
            target = stage / name
            target.parent.mkdir(parents=True, exist_ok=True)
            # Copy bytes and permissions only; no local xattrs or Finder metadata.
            shutil.copyfile(source, target)
            target.chmod(0o755 if source.stat().st_mode & 0o111 else 0o644)
        names, findings = scan_tree(stage)
        if findings:
            for label, name in sorted(set(findings)):
                print(f"Package blocked: {label}: {name}")
            raise SystemExit(1)
        subprocess.run(["python3", str(stage / "Scripts/verify-docs"), "--strict", "--repo-root", str(stage)], check=True)
        subprocess.run(["python3", str(stage / "Scripts/generate-swift-color-patches.py"), "--check"], check=True)
        manifest = {
            "scope": "Working-tree source snapshot; no Git history, local reference material, credentials, build products, or file xattrs.",
            "privacy_scan": "No prohibited paths or recognized private-information patterns found; public vendored license attribution retained.",
            "files": [{"path": name, "sha256": hashlib.sha256((stage / name).read_bytes()).hexdigest()} for name in names],
        }
        temporary_zip = Path(temporary) / "Metaliquartz-source.zip"
        with zipfile.ZipFile(temporary_zip, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name in names:
                path = stage / name
                info = zipfile.ZipInfo("Metaliquartz/" + name, date_time=(2026, 1, 1, 0, 0, 0))
                info.create_system = 3
                info.external_attr = (0o100755 if path.stat().st_mode & 0o111 else 0o100644) << 16
                archive.writestr(info, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED)
        # Read back every member to verify ZIP integrity before delivering it.
        with zipfile.ZipFile(temporary_zip) as archive:
            if archive.testzip() is not None:
                raise SystemExit("ZIP integrity verification failed")
        archive_path = output / temporary_zip.name
        shutil.move(str(temporary_zip), archive_path)
        digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
        (output / "Metaliquartz-source.zip.sha256").write_text(f"{digest}  {archive_path.name}\n")
        (output / "Metaliquartz-source-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print(f"GitHub source package prepared: {len(names)} files, {archive_path.stat().st_size} bytes.")
        print(f"SHA-256: {digest}")
        print("Privacy scan passed; documentation and generated-definition checks passed. No upload performed.")


if __name__ == "__main__":
    main()

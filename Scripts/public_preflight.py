#!/usr/bin/env python3
"""Scan prospective public files and reachable Git history without printing secrets.

Default: tracked files, non-ignored untracked files, staged contents and all reachable history.
--tree PATH: scan an exported directory with no Git history (source ZIP preparation).
Public third-party contact addresses in Vendor are retained as license attribution.
"""

import argparse
import re
import struct
import subprocess
import sys
from pathlib import Path

MAXIMUM_BLOB_BYTES = 10 * 1024 * 1024
CONTENT_PATTERNS = {
    "private key": rb"-----BEGIN ([A-Z ]+ )?PRIVATE KEY-----",
    "GitHub token": rb"\b(?:gh[pousr]_[A-Za-z0-9_]{30,}|github_pat_[A-Za-z0-9_]{30,})\b",
    "AWS access key": rb"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b",
    "service token": rb"\b(?:xox[baprs]-[A-Za-z0-9-]{20,}|sk-[A-Za-z0-9_-]{32,})\b",
    "credential assignment": rb"(?i)(?:api[_-]?key|access[_-]?token|client[_-]?secret|password)\s*[:=]\s*[\"']?[A-Za-z0-9_+/-]{8,}",
    "personal absolute path": rb"(?:/(?:Users|home)/[^/\s\"'<>]+/|[A-Z]:\\Users\\[^\\\s]+\\)",
    "Xcode development team": rb"DEVELOPMENT_TEAM\s*=\s*[A-Z0-9]{5,}",
    "credential in URL": rb"https?://[^\s/:@]+:[^\s/@]+@",
}
EMAIL = re.compile(rb"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
SENSITIVE_SUFFIXES = {".mobileprovision", ".provisionprofile", ".p12", ".pfx", ".pem", ".key", ".keystore"}


def git(root, *arguments):
    return subprocess.check_output(["git", "-C", str(root), *arguments])


def prohibited_path(name):
    parts = Path(name).parts
    if any(p in {".private", "Documentation", "xcuserdata", ".git", ".DS_Store", "__MACOSX"} for p in parts):
        return True
    leaf = Path(name).name
    return (leaf == ".env" or leaf.startswith(".env.")
            or Path(name).suffix.lower() in SENSITIVE_SUFFIXES
            or leaf == "quartz-composer-visual-reference.png")


def dimension_only_exif(data):
    """Accept only a TIFF EXIF pointer, colour space and pixel dimensions."""
    try:
        if data[:4] not in {b"II\x2a\x00", b"MM\x00\x2a"}:
            return False
        order = "<" if data[:2] == b"II" else ">"
        pending = [struct.unpack_from(order + "I", data, 4)[0]]
        visited = set()
        while pending:
            offset = pending.pop()
            if offset in visited:
                return False
            visited.add(offset)
            count = struct.unpack_from(order + "H", data, offset)[0]
            for index in range(count):
                tag, kind, length, value = struct.unpack_from(order + "HHII", data, offset + 2 + index * 12)
                if length != 1 or kind not in {3, 4}:
                    return False
                if tag == 0x8769 and kind == 4:
                    pending.append(value)
                elif tag not in {0xA001, 0xA002, 0xA003}:
                    return False
            if struct.unpack_from(order + "I", data, offset + 2 + count * 12)[0] != 0:
                return False
        return True
    except struct.error:
        return False


def content_findings(name, data):
    findings = [label for label, pattern in CONTENT_PATTERNS.items() if re.search(pattern, data)]
    is_png = data.startswith(b"\x89PNG\r\n\x1a\n")
    if not name.startswith("Vendor/") and not is_png:
        addresses = [address for address in EMAIL.findall(data)
                     if not re.fullmatch(rb"icon_[0-9]+x[0-9]+@2x\.png", address)]
        if any(not address.lower().endswith(b"@users.noreply.github.com") for address in addresses):
            findings.append("personal/contact email")
    # PNG text and EXIF chunks may hold metadata invisible in a rendered image.
    if is_png:
        offset = 8
        while offset + 12 <= len(data):
            size = int.from_bytes(data[offset:offset + 4], "big")
            kind = data[offset + 4:offset + 8]
            payload = data[offset + 8:offset + 8 + size]
            if kind in {b"tEXt", b"zTXt", b"iTXt"} or (kind == b"eXIf" and not dimension_only_exif(payload)):
                findings.append("PNG text/EXIF metadata requires review")
            offset += size + 12
    return findings


def scan_tree(root, repository=False):
    if repository:
        names = sorted(set(git(root, "ls-files", "-z", "--cached", "--others", "--exclude-standard").decode().split("\0")) - {""})
    else:
        names = sorted(p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file() or p.is_symlink())
    findings = []
    for name in names:
        path = root / name
        if prohibited_path(name):
            findings.append(("private/reference/signing path", name))
        if path.is_symlink():
            findings.append(("symlink requires review", name))
            continue
        if not path.is_file():
            findings.append(("missing prospective public file", name))
            continue
        data = path.read_bytes()
        if len(data) > MAXIMUM_BLOB_BYTES:
            findings.append(("file exceeds 10 MiB", name))
        findings.extend((label, name) for label in content_findings(name, data))
    return names, findings


def scan_history(root):
    findings = []
    metadata = git(root, "log", "--all", "--format=%an%n%ae%n%cn%n%ce%n%B")
    findings.extend((label, "commit metadata") for label in content_findings("metadata", metadata))
    objects = git(root, "rev-list", "--objects", "--all")
    descriptions = subprocess.check_output(
        ["git", "-C", str(root), "cat-file", "--batch-check=%(objecttype) %(objectname) %(objectsize) %(rest)"],
        input=objects,
    )
    blob_count = 0
    # Stream blobs through one process; never echo matched content.
    with subprocess.Popen(["git", "-C", str(root), "cat-file", "--batch"], stdin=subprocess.PIPE, stdout=subprocess.PIPE) as process:
        for line in descriptions.decode().splitlines():
            fields = line.split(" ", 3)
            if fields[0] != "blob":
                continue
            _, oid, size, name = fields
            blob_count += 1
            if prohibited_path(name):
                findings.append(("private/reference/signing path in history", name))
            if int(size) > MAXIMUM_BLOB_BYTES:
                findings.append(("history blob exceeds 10 MiB", name))
            process.stdin.write((oid + "\n").encode())
            process.stdin.flush()
            header = process.stdout.readline().split()
            if len(header) != 3 or header[1] != b"blob":
                raise RuntimeError("unable to read history blob")
            data = process.stdout.read(int(header[2]))
            if process.stdout.read(1) != b"\n":
                raise RuntimeError("invalid history blob framing")
            findings.extend((label + " in history", name) for label in content_findings(name, data))
        process.stdin.close()
        if process.wait() != 0:
            raise RuntimeError("history scan failed")
    return blob_count, findings


def scan_index(root):
    """A staged secret must still fail if the working copy was subsequently cleaned."""
    entries = []
    findings = []
    for record in git(root, "ls-files", "--stage", "-z").decode().split("\0"):
        if not record:
            continue
        description, name = record.split("\t", 1)
        mode, oid, stage = description.split()
        if stage != "0" or mode not in {"100644", "100755"}:
            findings.append(("nonregular or conflicted index entry", name))
        entries.append((oid, name))
    response = subprocess.check_output(["git", "-C", str(root), "cat-file", "--batch"],
                                       input="".join(oid + "\n" for oid, _ in entries).encode())
    offset = 0
    for _, name in entries:
        end = response.index(b"\n", offset)
        header = response[offset:end].split()
        if len(header) != 3 or header[1] != b"blob":
            raise RuntimeError("unable to read staged blob")
        size = int(header[2])
        data = response[end + 1:end + 1 + size]
        offset = end + 2 + size
        if size > MAXIMUM_BLOB_BYTES:
            findings.append(("staged blob exceeds 10 MiB", name))
        findings.extend((label + " in index", name) for label in content_findings(name, data))
    return len(entries), findings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tree", type=Path, help="scan exported files only, without Git history")
    args = parser.parse_args()
    root = args.tree.resolve() if args.tree else Path(git(Path.cwd(), "rev-parse", "--show-toplevel").decode().strip())
    if not root.is_dir():
        parser.error("scan directory does not exist")
    names, findings = scan_tree(root, repository=not args.tree)
    if not args.tree:
        staged_count, staged_findings = scan_index(root)
        findings.extend(staged_findings)
        count, history_findings = scan_history(root)
        findings.extend(history_findings)
        print(f"Scanned {len(names)} prospective files, {staged_count} index entries and {count} reachable history blobs.")
    else:
        print(f"Scanned {len(names)} exported files; Git history is outside this scan.")
    unique = sorted(set(findings))
    for label, name in unique[:30]:
        print(f"PUBLIC PREFLIGHT FAILED: {label}: {name}", file=sys.stderr)
    if unique:
        print(f"Public release blocked by {len(unique)} preflight finding(s). Matched contents are redacted.", file=sys.stderr)
        return 1
    print("Public preflight passed: no prohibited paths or recognized private-information patterns found.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Regression checks for the public-package privacy gate (no external services)."""

import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

from public_preflight import content_findings, dimension_only_exif, prohibited_path, scan_history, scan_index, scan_tree


class PublicPreflightTests(unittest.TestCase):
    def test_tokens_and_keys(self):
        for data in [b"ghp_" + b"a" * 36, b"github_pat_" + b"a" * 40,
                     b"AKIA" + b"A" * 16, b"xoxb-" + b"a" * 30,
                     b"sk-" + b"a" * 40, b"-----BEGIN " + b"PRIVATE KEY-----"]:
            self.assertTrue(content_findings("sample", data))

    def test_assignments_and_paths(self):
        for data in [b"client_secret" + b' = "' + b"a" * 12,
                     b"DEVELOPMENT_" + b"TEAM = ABCDE12345",
                     b"/" + b"Users/tester/project/",
                     b"/" + b"home/tester/project/",
                     b"https://" + b"user:credential" + b"@" + b"host.test"]:
            self.assertTrue(content_findings("sample", data))

    def test_private_email(self):
        self.assertIn("personal/contact email", content_findings("sample", b"private" + b"@" + b"example.test"))

    def test_public_attribution_and_retina_filenames(self):
        self.assertFalse(content_findings("Vendor/license", b"author" + b"@" + b"example.test"))
        self.assertFalse(content_findings("sample", b"123+author" + b"@users.noreply.github.com"))
        self.assertFalse(content_findings("Contents.json", b"icon_128x128@2x.png"))

    def test_sensitive_paths(self):
        for name in [".private/backup", "Documentation/ref", ".env", ".env.example",
                     "signing.p12", "signing.pem", "xcuserdata/session", ".git/config"]:
            self.assertTrue(prohibited_path(name))

    def test_png_text_metadata(self):
        payload = b"Author\0private" + b"@" + b"example.test"
        png = b"\x89PNG\r\n\x1a\n" + struct.pack(">I", len(payload)) + b"tEXt" + payload + b"\0" * 4
        self.assertIn("PNG text/EXIF metadata requires review", content_findings("image.png", png))

    def test_exif_dimensions_and_personal_tags(self):
        dimensions = b"MM\0*\0\0\0\x08" + struct.pack(">H", 1) + struct.pack(">HHII", 0xA002, 4, 1, 128) + b"\0" * 4
        self.assertTrue(dimension_only_exif(dimensions))
        artist = dimensions[:10] + struct.pack(">HHII", 0x013B, 4, 1, 128) + b"\0" * 4
        self.assertFalse(dimension_only_exif(artist))
        self.assertFalse(dimension_only_exif(b"invalid"))

    def test_symlink_is_blocked(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "outside").symlink_to("/tmp")
            self.assertIn(("symlink requires review", "outside"), scan_tree(root)[1])

    def test_untracked_and_historical_content(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def run(*args):
                subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True)
            run("init", "-q")
            run("config", "user.name", "Privacy Test")
            run("config", "user.email", "test" + "@users.noreply.github.com")
            (root / "sample.txt").write_bytes(b"ghp_" + b"a" * 36)
            run("add", "sample.txt")
            (root / "sample.txt").write_text("working copy cleaned after staging\n")
            self.assertIn(("GitHub token in index", "sample.txt"), scan_index(root)[1])
            run("commit", "-qm", "Synthetic privacy fixture")
            (root / "sample.txt").write_text("clean\n")
            run("add", "sample.txt")
            run("commit", "-qm", "Remove synthetic fixture")
            (root / "untracked.txt").write_bytes(b"private" + b"@" + b"example.test")
            self.assertIn(("personal/contact email", "untracked.txt"), scan_tree(root, repository=True)[1])
            self.assertIn(("GitHub token in history", "sample.txt"), scan_history(root)[1])
            (root / ".gitignore").write_text("ignored.txt\n")
            (root / "ignored.txt").write_bytes(b"private" + b"@" + b"example.test")
            self.assertNotIn("ignored.txt", scan_tree(root, repository=True)[0])


if __name__ == "__main__":
    unittest.main()

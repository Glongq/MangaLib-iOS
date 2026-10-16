#!/usr/bin/env python3
"""Test CDN polarity changes and cache refreshes, optionally against a local HAR."""

from pathlib import Path
import argparse
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--har", type=Path)
arguments = parser.parse_args()
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="mangalib-hitomi-routing-tests-") as temporary:
    workspace = Path(temporary)
    executable = workspace / "routing-tests"
    subprocess.run([
        "swiftc", "-swift-version", "5", "-module-cache-path", str(workspace / "module-cache"),
        str(root / "App/ExternalSites/HitomiGG.swift"),
        str(root / "Tests/HitomiGGTests.swift"), "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable)] + ([str(arguments.har)] if arguments.har else []), check=True)

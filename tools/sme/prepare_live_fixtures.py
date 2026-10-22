#!/usr/bin/env python3
"""Prepare original authored input WAVs; never runtime output or an oracle.

Uses only the standard library. Existing mismatched files are never replaced.
The original integer-only synthesis and score are preserved without changes.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile


def matches(path, record):
    data = path.read_bytes()
    return len(data) == record["bytes"] and hashlib.sha256(data).hexdigest() == record["sha256"]


def prepare(root, verify_only=False):
    manifest = json.loads((root / "tools/sme/live-fixtures.json").read_text())
    if manifest["schema"] != "bugu.headless.live-fixtures/v1":
        raise ValueError("unsupported fixture manifest")
    records = manifest["files"]
    if len(records) != 16 or len({r["path"] for r in records}) != 16:
        raise ValueError("expected sixteen distinct authored source WAVs")
    missing = []
    for record in records:
        relative = Path(record["path"])
        if relative.is_absolute() or ".." in relative.parts or relative.parent.as_posix() != "tests/fixtures/sme/readiness_causal/four_stem/audio":
            raise ValueError("invalid fixture destination")
        destination = root / relative
        destination.resolve().relative_to(root.resolve())
        if destination.exists():
            if not matches(destination, record):
                raise ValueError("existing fixture mismatch: " + record["path"])
        else:
            missing.append(record)
    if missing and verify_only:
        raise ValueError("missing authored fixture: " + missing[0]["path"])
    if missing:
        generator = root / manifest["generator"]
        if manifest["generator"] != "examples/sme/assets/generate.py" or manifest["score"] != "examples/sme/assets/score.json":
            raise ValueError("unexpected generator identity")
        spec = importlib.util.spec_from_file_location("bugu_original_fixture_generator", generator)
        module = importlib.util.module_from_spec(spec)
        sys.dont_write_bytecode = True
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory(prefix="bugu-authored-inputs-") as temporary:
            output = Path(temporary)
            module.generate(output, write_metadata=False)
            # Validate the entire source set before publishing any missing file.
            for record in records:
                if not matches(output / Path(record["path"]).name, record):
                    raise ValueError("generated fixture mismatch: " + record["path"])
            for record in missing:
                destination = root / record["path"]
                destination.parent.mkdir(parents=True, exist_ok=True)
                with destination.open("xb") as stream:
                    stream.write((output / destination.name).read_bytes())
    for record in records:
        if not matches(root / record["path"], record):
            raise ValueError("prepared fixture mismatch: " + record["path"])
    print(json.dumps({"scope": "authored-input-source-only", "verified_files": len(records), "generated_files": len(missing), "bytes": sum(r["bytes"] for r in records)}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    prepare(Path(__file__).resolve().parents[2], args.verify_only)

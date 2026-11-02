#!/usr/bin/env python3
"""Independent eager/preload acceptance and observations, not a universal RSS gate.

Run after building the checkout's release library. Each cell runs in a fresh
OpenResty process. Input creation and typed semantic oracles run on the host.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def same_json(actual, expected):
    if isinstance(expected, (bool, str)) or expected is None:
        return type(actual) is type(expected) and actual == expected
    if isinstance(expected, (int, float)):
        return type(actual) in (int, float) and actual == expected
    if isinstance(expected, list):
        return isinstance(actual, list) and len(actual) == len(expected) and all(
            same_json(a, b) for a, b in zip(actual, expected))
    return isinstance(actual, dict) and actual.keys() == expected.keys() and all(
        same_json(actual[key], value) for key, value in expected.items())


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise AssertionError(f"normalized output retained duplicate key {key!r}")
        result[key] = value
    return result


def fixture(name):
    value = {"model": "original", "unselected": "still-readable"}
    if name == "wide":
        value.update({f"k{i:05d}": {"id": i, "active": True} for i in range(32768)})
        value.update(flags={"enabled": False, "nothing": None}, empty_array=[])
    else:
        value["prompt"] = "large prompt \u2603\n" * 131072
        value["items"] = [{"role": "user", "content": "message " * 256} for _ in range(1024)]
        value["deep"] = {"a": {"b": {"c": {"d": {"value": "route-value", "unused": False}}}}}
    raw = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()
    # Distinct lexical keys with identical decoded names exercise final-value
    # semantics without asking the measured process to generate its own input.
    return b'{"mo\\u0064el":"obsolete",' + raw[1:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    parser.add_argument("--target-volume", required=True)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--cases", nargs="+", choices=("wide", "selected", "wildcards"),
                        default=["wide", "selected", "wildcards"])
    parser.add_argument("--sources", nargs="+", choices=("memory", "file", "feed"),
                        default=["memory", "file", "feed"])
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    output = (args.output_dir or Path(tempfile.mkdtemp(prefix="leanjson-loading-"))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise RuntimeError(f"output directory must be empty: {output}")
    image_id = subprocess.check_output(["docker", "image", "inspect", args.image,
                                       "--format", "{{.Id}}"], text=True).strip()
    base = ["docker", "run", "--rm", "--mount", f"type=bind,source={repo},target=/workspace,readonly",
            "--mount", f"type=bind,source={output},target=/measurement",
            "--mount", f"type=volume,source={args.target_volume},target=/workspace/target,readonly",
            "--env", "LD_LIBRARY_PATH=/workspace/target/release"]

    def fingerprint():
        native = subprocess.check_output(base + ["--entrypoint", "sha256sum", image_id,
                "/workspace/target/release/libleanjson.so"], text=True).split()[0]
        digest = hashlib.sha256()
        for path in sorted((repo / "lua").rglob("*.lua")):
            digest.update(str(path.relative_to(repo)).encode() + b"\0" + path.read_bytes() + b"\0")
        return {"native_sha256": native, "lua_sha256": digest.hexdigest()}

    runtime = fingerprint()
    environment = {"image_id": image_id, "runtime": runtime,
        "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
        "status": subprocess.check_output(["git", "status", "--porcelain"], cwd=repo, text=True),
        "cases": args.cases, "sources": args.sources,
        "index_depth": 0, "index_array_limit": 0, "index_budget_bytes": 0,
        "methodology": "one fresh native OpenResty process per cell; no concurrent workloads; no forced GC during phases",
        "comparison": "cjson decodes retained raw input with decode_array_with_array_mt(true); eager returns plain values; both use full encode; preload retains selected immutable values and uses bounded reader output"}
    (output / "environment.json").write_text(json.dumps(environment, indent=2) + "\n")
    results = []
    with (output / "results.jsonl").open("w") as records:
        for name in args.cases:
            raw = fixture(name)
            input_name = name + "-input.json"
            (output / input_name).write_bytes(raw)
            expected = json.loads(raw)
            for source in args.sources:
                for mode in ("cjson", "eager") if name == "wide" else ("cjson", "preload"):
                    cell = f"{name}-{source}-{mode}"
                    result_name = cell + ".json"
                    command = base + ["--entrypoint", "/usr/local/openresty/bin/resty", image_id,
                        "-I", "/workspace/lua", "-I", "/workspace/tests/openresty",
                        "/workspace/tests/openresty/loading-modes.lua", mode, source, name,
                        "/measurement/" + input_name, "/measurement/" + result_name]
                    completed = subprocess.run(command, capture_output=True, text=True, timeout=300)
                    (output / (cell + ".log")).write_text(completed.stdout + completed.stderr)
                    if completed.returncode:
                        raise RuntimeError(f"{cell} failed; see {output / (cell + '.log')}")
                    row = json.loads(completed.stdout)
                    untouched = (output / (result_name + ".untouched")).read_bytes()
                    assert same_json(json.loads(untouched), expected), f"untouched oracle: {cell}"
                    if mode == "preload":
                        assert untouched == raw, f"preloading changed original bytes: {cell}"
                    modified = (output / result_name).read_bytes()
                    changed = dict(expected, model="rewritten")
                    assert same_json(json.loads(modified, object_pairs_hook=unique_object), changed), f"modified oracle: {cell}"
                    assert row["input_bytes"] == len(raw) and row["output_bytes"] == len(modified)
                    assert row["untouched_bytes"] == len(untouched)
                    row.update(oracle_passed=True, input_sha256=hashlib.sha256(raw).hexdigest(),
                        untouched_sha256=hashlib.sha256(untouched).hexdigest(),
                        modified_sha256=hashlib.sha256(modified).hexdigest())
                    records.write(json.dumps(row) + "\n"); records.flush()
                    results.append(row)
                    print(f"PASS {cell}: peak={row['peak_rss_kib']/1024:.2f} MiB "
                          f"decode={row['decode_cpu_s']*1000:.1f} ms cpu={row['workload_cpu_s']*1000:.1f} ms", flush=True)
                    (output / result_name).unlink()
                    (output / (result_name + ".untouched")).unlink()
            (output / input_name).unlink()
    assert fingerprint() == runtime, "runtime changed during measurements"
    (output / "summary.json").write_text(json.dumps({"passed": True, "cells": len(results)}, indent=2) + "\n")
    print(f"Evidence: {output}")


if __name__ == "__main__":
    main()

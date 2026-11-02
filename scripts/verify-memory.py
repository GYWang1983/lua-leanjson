#!/usr/bin/env python3
"""Paired native OpenResty process memory gate; no production-provider calls.

Run on a Docker host after building the checkout's Linux release library, or
pass --runtime-image to measure an immutable packaged runtime. Fixture creation
and semantic comparison happen outside every measured process. No forced GC is
performed between the measured parse/read/edit/length/output phases.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise AssertionError(f"normalized output contains a duplicate key: {key!r}")
        result[key] = value
    return result


def same_json(actual, expected):
    if isinstance(expected, bool) or expected is None or isinstance(expected, str):
        return type(actual) is type(expected) and actual == expected
    if isinstance(expected, (int, float)):
        return type(actual) in (int, float) and actual == expected
    if isinstance(expected, list):
        return isinstance(actual, list) and len(actual) == len(expected) and all(map(same_json, actual, expected))
    return isinstance(actual, dict) and actual.keys() == expected.keys() and all(
        same_json(actual[key], value) for key, value in expected.items())


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    parser.add_argument("--runtime-image", action="store_true")
    parser.add_argument("--target-volume", help="Docker volume containing the built Linux target directory")
    parser.add_argument("--cases", nargs="+", default=[
        "short-elements", "wide-objects", "wide-scalars", "duplicate-tail",
        "wide-duplicates", "deep-objects", "prompt", "messages",
        "short-elements:far", "wide-objects:scan", "wide-objects:scan-auto",
    ])
    parser.add_argument("--sources", nargs="+", choices=["memory", "file", "feed"], default=["memory", "file", "feed"])
    parser.add_argument("--bytes", type=int, default=1048576)
    parser.add_argument("--branches", type=int, default=2, help="independent forks; 0 edits the decoded root directly")
    parser.add_argument("--index-budget-bytes", type=int, default=1048576)
    parser.add_argument("--index-depth", type=int, default=3)
    parser.add_argument("--index-array-limit", type=int, default=3)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--report-only", action="store_true", help="record baseline failures without making them pass")
    args = parser.parse_args()
    if args.bytes < 1 or min(args.branches, args.index_budget_bytes, args.index_depth, args.index_array_limit) < 0 or args.timeout < 1:
        parser.error("bytes and timeout must be positive; branches and index options must be nonnegative")
    return args


def main():
    args = arguments()
    repo = Path(__file__).resolve().parent.parent
    output = (args.output_dir or Path(tempfile.mkdtemp(prefix="leanjson-memory-"))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise RuntimeError(f"output directory must be empty: {output}")
    library = "/opt/leanjson/lua" if args.runtime_image else "/workspace/lua"
    library_path = "/opt/leanjson/lib" if args.runtime_image else "/workspace/target/release"
    base = ["docker", "run", "--rm", "--mount", f"type=bind,source={repo},target=/workspace,readonly",
            "--mount", f"type=bind,source={output},target=/measurement",
            "--env", f"LD_LIBRARY_PATH={library_path}"]
    if args.target_volume:
        base.extend(["--mount", f"type=volume,source={args.target_volume},target=/workspace/target,readonly"])
    digest_command = base + ["--entrypoint", "sha256sum", args.image, f"{library_path}/libleanjson.so"]
    base.extend(["--entrypoint", "/usr/local/openresty/bin/resty", args.image,
                 "-I", library, "-I", "/workspace/tests/openresty"])

    def runtime_fingerprint():
        native = subprocess.check_output(digest_command, text=True).split()[0]
        lua_digest = hashlib.sha256()
        if not args.runtime_image:
            for path in sorted((repo / "lua").rglob("*.lua")):
                lua_digest.update(str(path.relative_to(repo)).encode() + b"\0" + path.read_bytes() + b"\0")
        return {"native_sha256": native, "lua_sha256": None if args.runtime_image else lua_digest.hexdigest()}

    def run(script, values):
        began = time.monotonic()
        completed = subprocess.run(base + [f"/workspace/tests/openresty/{script}"] + list(map(str, values)),
                                   capture_output=True, text=True, timeout=args.timeout)
        if completed.returncode:
            raise RuntimeError(f"{script} failed ({completed.returncode}):\n{completed.stdout}\n{completed.stderr}")
        return completed.stdout, time.monotonic() - began

    image_id = subprocess.check_output(["docker", "image", "inspect", args.image, "--format", "{{.Id}}"], text=True).strip()
    image_revision = subprocess.check_output(["docker", "image", "inspect", args.image, "--format",
        '{{index .Config.Labels "org.opencontainers.image.revision"}}'], text=True).strip()
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
    dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=repo, text=True).strip())
    runtime = runtime_fingerprint()
    environment = {"kind": "environment", "image": args.image, "image_id": image_id, "image_revision": image_revision,
                   "runtime": runtime,
                   "checkout_revision": revision, "checkout_dirty": dirty, "runtime_image": args.runtime_image,
                   "target_bytes": args.bytes, "branches": args.branches, "sources": args.sources,
                   "cases": args.cases, "index_budget_bytes": args.index_budget_bytes,
                   "index_depth": args.index_depth, "index_array_limit": args.index_array_limit,
                   "target_volume": args.target_volume,
                   "methodology": "one fresh native OpenResty process per cell; no concurrent requests; external input/oracle; no forced GC during phases",
                   "gate": "LeanJSON process peak RSS <= native cjson process peak RSS for every paired cell"}
    failures, receipts = [], []
    with (output / "results.jsonl").open("w") as records:
        records.write(json.dumps(environment) + "\n")
        for case in args.cases:
            scenario, _, access = case.partition(":")
            access = access or "model"
            name = case.replace(":", "-")
            input_name = f"{name}-input.json"
            run("memory-fixture.lua", [scenario, args.bytes, f"/measurement/{input_name}"])
            input_bytes = (output / input_name).read_bytes()
            expected = json.loads(input_bytes)
            expected["model"] = "rewritten-1"
            input_sha = hashlib.sha256(input_bytes).hexdigest()
            for source in args.sources:
                pair = {}
                for method in ("cjson", "leanjson"):
                    result_name = f"{name}-{source}-{method}-output.json"
                    stdout, wall = run("memory-phases.lua", [method, source, f"/measurement/{input_name}",
                        f"/measurement/{result_name}", access, args.index_budget_bytes, args.branches,
                        args.index_depth, args.index_array_limit])
                    row = json.loads(stdout.strip())
                    result = (output / result_name).read_bytes()
                    if not same_json(json.loads(result, object_pairs_hook=unique_object), expected):
                        raise AssertionError(f"semantic oracle failed: {case}/{source}/{method}")
                    if len(result) != row["output_bytes"] or row["source_bytes"] != len(input_bytes):
                        raise AssertionError(f"byte count failed: {case}/{source}/{method}")
                    row.update(case=case, input_sha256=input_sha, output_sha256=hashlib.sha256(result).hexdigest(),
                               oracle_passed=True, subprocess_wall_s=wall)
                    records.write(json.dumps(row) + "\n"); records.flush()
                    pair[method] = row
                    (output / result_name).unlink()
                ratio = pair["leanjson"]["worker_hwm_kib"] / pair["cjson"]["worker_hwm_kib"]
                passed = ratio <= 1.0
                receipt = {"case":case, "source":source, "passed":passed, "rss_ratio":ratio,
                           "cjson_hwm_kib":pair["cjson"]["worker_hwm_kib"],
                           "leanjson_hwm_kib":pair["leanjson"]["worker_hwm_kib"]}
                receipts.append(receipt)
                if not passed: failures.append(receipt)
                print(f"{'PASS' if passed else 'FAIL'} {case}/{source}: "
                      f"cjson={receipt['cjson_hwm_kib']/1024:.2f} MiB "
                      f"leanjson={receipt['leanjson_hwm_kib']/1024:.2f} MiB ratio={ratio:.3f}", flush=True)
            (output / input_name).unlink()
    if runtime_fingerprint() != runtime:
        raise AssertionError("runtime changed during measurement; results are not accepted")
    summary = {"passed":not failures, "pairs":len(receipts), "failures":failures, "receipts":receipts,
               "results":str(output / "results.jsonl")}
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"Evidence: {output}", flush=True)
    return 0 if not failures or args.report_only else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, AssertionError, subprocess.TimeoutExpired, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        sys.exit(2)

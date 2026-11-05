#!/usr/bin/env python3
"""Compare complete-memory/incremental decode against cjson, without body I/O in timings.

Requires a built Linux target directory (or Docker target volume) and an existing
OpenResty image. Evidence and complete semantic receipts go to --output, never
into the source tree by default. No provider, Kong, database or network is used.
"""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import tempfile


def digest(value):
    return hashlib.sha256(value).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    parser.add_argument("--target-volume")
    parser.add_argument("--input", type=Path, action="append", default=[])
    parser.add_argument("--schema", type=Path)
    parser.add_argument("--synthetic", action="store_true")
    parser.add_argument("--sources", nargs="+", choices=("memory", "feed"), default=["memory", "feed"])
    parser.add_argument("--loading", nargs="+", choices=("lazy", "preload", "eager"), default=["lazy"])
    parser.add_argument("--trials", type=int, default=21)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.trials < 3 or not (args.input or args.synthetic):
        parser.error("at least 3 trials and one input or --synthetic are required")
    repo = Path(__file__).resolve().parent.parent
    output = (args.output or Path(tempfile.mkdtemp(prefix="leanjson-cjson-scan-"))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    image = json.loads(subprocess.check_output(["docker", "image", "inspect", args.image]))[0]
    image_id = image["Id"]
    command = ["docker", "run", "--rm", "--mount", f"type=bind,src={repo},dst=/workspace,readonly",
               "--mount", f"type=bind,src={output},dst=/measurement", "--workdir", "/workspace",
               "--env", "LD_LIBRARY_PATH=/workspace/target/release",
               "--env", "LUA_PATH=/workspace/lua/?.lua;/usr/local/openresty/lualib/?.lua;/usr/local/openresty/lualib/?/init.lua;;"]
    if args.target_volume:
        command += ["--mount", f"type=volume,src={args.target_volume},dst=/workspace/target,readonly"]
    fingerprint = subprocess.check_output(command + ["--entrypoint", "sha256sum", image_id,
                                                      "/workspace/target/release/libleanjson.so"], text=True).split()[0]
    lua_hash = hashlib.sha256()
    for path in sorted((repo / "lua").rglob("*.lua")):
        lua_hash.update(str(path.relative_to(repo)).encode() + b"\0" + path.read_bytes() + b"\0")
    fixtures = [("input-" + str(i + 1), path.read_bytes()) for i, path in enumerate(args.input)]
    if args.synthetic:
        marker = {"model": "bench", "marker": "0123456789abcdef"}
        def fixture(name, extra):
            fixtures.append((name, json.dumps(dict(marker, **extra), ensure_ascii=False, separators=(",", ":")).encode()))
        fixture("plain-2m", {"prompt": "x" * (2 * 1024 * 1024)})
        fixture("plain-16m", {"prompt": "x" * (16 * 1024 * 1024)})
        fixture("wide-objects-32768", {f"k{i}": {"x": i} for i in range(32768)})
        fixture("wide-scalars-32768", {f"k{i}": i for i in range(32768)})
        fixture("escaped-2m", {"prompt": ('quote"\\\n中' * 200000)})
    schema_name = "-"
    if args.schema:
        schema_bytes = args.schema.read_bytes()
        (output / "schema.json").write_bytes(schema_bytes)
        schema_name = "/measurement/schema.json"
    else:
        schema_bytes = None
    summary = {"image": args.image, "image_id": image_id, "architecture": image["Architecture"],
               "native_sha256": fingerprint, "lua_sha256": lua_hash.hexdigest(), "trials": args.trials,
               "schema_sha256": digest(schema_bytes) if schema_bytes else None,
               "methodology": "fresh OpenResty process per fixture/source/loading cell; pre-read identical-size input with unique fixed-width marker per trial; implementations interleaved within process; source storage and full output oracles outside timings; feed includes substring/feed overhead; cjson baseline is always memory decode and has no Schema validation",
               "cells": []}
    for name, raw in fixtures:
        if b"0123456789abcdef" not in raw:
            raise ValueError("fixture needs fixed-width marker: " + name)
        (output / (name + ".json")).write_bytes(raw)
        expected = json.loads(raw)
        for source in args.sources:
            for loading in args.loading:
                cell_name = name + "-" + source + "-" + loading
                cell_dir = output / cell_name
                cell_dir.mkdir(exist_ok=True)
                result = subprocess.run(command + ["--entrypoint", "/usr/local/openresty/bin/resty", image_id,
                    "-I", "/workspace/lua", "/workspace/benches/memory_decode.lua", "/measurement/" + name + ".json",
                    str(args.trials), "/measurement/" + cell_name, schema_name, source, loading],
                    capture_output=True, text=True, timeout=300)
                (cell_dir / "stderr.log").write_text(result.stderr)
                if result.returncode:
                    raise RuntimeError(cell_name + ": " + result.stderr)
                records = json.loads(result.stdout)
                (cell_dir / "results.json").write_text(json.dumps(records, indent=2) + "\n")
                cell = {"fixture": name, "source": source, "loading": loading, "bytes": len(raw),
                        "input_sha256": digest(raw), "full_output_oracle": {}, "methods": {},
                        "cjson_version": records["cjson_version"], "luajit": records["luajit"]}
                for method in ("cjson", "legacy", "cjson-scanner"):
                    encoded = (cell_dir / (method + "-output.json")).read_bytes()
                    if json.loads(encoded) != expected:
                        raise AssertionError("full semantic mismatch: " + cell_name + "/" + method)
                    cell["full_output_oracle"][method] = {"matches_input": True, "output_sha256": digest(encoded)}
                    rows = [r for r in records["measurements"] if r["name"] == method]
                    assert len(rows) == args.trials
                    cell["methods"][method] = {
                        "cpu_median_ms": statistics.median(r["cpu"] for r in rows) * 1000,
                        "wall_median_ms": statistics.median(r["wall"] for r in rows) * 1000,
                        "cpu_min_ms": min(r["cpu"] for r in rows) * 1000,
                        "cpu_max_ms": max(r["cpu"] for r in rows) * 1000,
                    }
                new = cell["methods"]["cjson-scanner"]["cpu_median_ms"]
                cell["legacy_speedup"] = cell["methods"]["legacy"]["cpu_median_ms"] / new
                cell["new_over_cjson"] = new / cell["methods"]["cjson"]["cpu_median_ms"]
                summary["cells"].append(cell)
                print(cell_name, json.dumps({k: round(v["cpu_median_ms"], 3) for k, v in cell["methods"].items()}), flush=True)
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(output / "summary.json")


if __name__ == "__main__":
    main()

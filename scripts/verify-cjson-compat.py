#!/usr/bin/env python3
"""Execute the pinned upstream definitions, without changing the vendor tree.

Python stays on the host: the pinned development image intentionally has no
Python. Each suite/block still gets its own LuaJIT process inside one temporary
container. Reports are evidence, not a claim that differing cases are compatible.
"""

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
PIN = "617164a0fe3bb647128178f9caefb304b8573bb6"
IMAGE = "lua-qjson-dev:task3-repro"
IMAGE_ID = "sha256:1a287857f8122e23a0ae0e5cf74227b747ea0dd40fa71b4b2be2f5ce58036a47"
DEFAULT_OUTPUT = ".superpowers/sdd/2026-11-02-upstream-cjson-matrix/task-1-artifacts"
MODES = ("lazy", "eager", "preload")
SOURCES = ("memory", "file", "feed")
PROJECT_VERSION = re.search(r'^version = "([^"]+)"', (ROOT / "Cargo.toml").read_text(), re.M).group(1)
EXPECTED_DIFFERENCES = {
    "module_identity": "LeanJSON uses its own module name and Cargo package version.",
    "lazy_array_semantics": "Lazy arrays preserve [] and reject non-index fields.",
    "userdata_carrier": "Lazy userdata containers have equal contents but are not Lua tables.",
}
USERDATA_DECODE_IDS = {f"test.lua:L{line}" for line in
                       (101, 110, 113, 116, 161, 167, 224, 226, 228, 231, 339, 341, 345, 347, 349, 351, 410)}
USERDATA_CYCLE_IDS = {"decode-cycle:" + name + ".json" for name in
                      ("example1", "example2", "example3", "example4", "example5", "numbers",
                       "rfc-example1", "rfc-example2", "types")}


class HarnessError(RuntimeError):
    pass


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=True) + "\n")


def lua_tokens(source):
    """Minimal lexical scanner; braces inside strings/comments are not code.

    It only inventories the fixed upstream table; Lua itself executes every
    expression. It is deliberately not a Lua-to-Python test translation.
    """
    i = 0
    while i < len(source):
        if source[i].isspace():
            i += 1
            continue
        start = i
        comment = source.startswith("--", i)
        if comment:
            i += 2
        long = re.match(r"\[(=*)\[", source[i:])
        if long:
            end = source.find("]" + long[1] + "]", i + len(long[0]))
            if end < 0:
                raise HarnessError("unterminated Lua long string/comment")
            i = end + len(long[1]) + 2
            if not comment:
                yield source[start:i], start, i
        elif comment:
            end = source.find("\n", i)
            i = len(source) if end < 0 else end + 1
        elif source[i] in "\"'":
            quote = source[i]
            i += 1
            while i < len(source):
                if source[i] == "\\":
                    i += 2
                elif source[i] == quote:
                    i += 1
                    break
                else:
                    i += 1
            else:
                raise HarnessError("unterminated Lua string")
            yield source[start:i], start, i
        else:
            name = re.match(r"[A-Za-z_][A-Za-z_0-9]*", source[i:])
            i += len(name[0]) if name else 1
            yield source[start:i], start, i


def inventory(vendor):
    vendor = Path(vendor)
    source = (vendor / "tests/test.lua").read_text()
    tokens = list(lua_tokens(source))
    start = next(i + 2 for i, token in enumerate(tokens) if token[0] == "cjson_tests" and tokens[i + 1][0] == "=")
    if tokens[start][0] != "{":
        raise HarnessError("cannot find upstream cjson_tests table")
    cases, depth, row_start = [], 0, None
    for token, left, right in tokens[start:]:
        if token == "{":
            if depth == 1:
                row_start = left
            depth += 1
        elif token == "}":
            depth -= 1
            if depth == 1 and row_start is not None:
                row = source[row_start:right]
                row_tokens = list(lua_tokens(row))
                label = row_tokens[1][0][1:-1].replace('\\"', '"').replace("\\'", "'")
                apis = []
                for i, (name, _, _) in enumerate(row_tokens[:-2]):
                    if name in ("json", "json_safe") and row_tokens[i + 1][0] == ".":
                        prefix = "cjson." if name == "json" else "cjson.safe."
                        apis.append(prefix + row_tokens[i + 2][0])
                        if row_tokens[i + 2][0] == "new" and row_tokens[i + 3][0] == "(":
                            level, j = 1, i + 4
                            while level and j < len(row_tokens):
                                level += (row_tokens[j][0] == "(") - (row_tokens[j][0] == ")")
                                j += 1
                            if j + 1 < len(row_tokens) and row_tokens[j][0] == ".":
                                apis.append(prefix + row_tokens[j + 1][0])
                helper = not re.search(r"\b(?:true|false)\s*,\s*\{", row)
                if helper:
                    category = "helper"
                elif any(a.endswith(".decode") for a in apis):
                    category = "direct_decode"
                elif any(a.endswith(".encode") for a in apis):
                    category = "encode_only"
                else:
                    category = "settings"
                line = source.count("\n", 0, row_start) + 1
                cases.append({"id": f"test.lua:L{line}", "suite": "test.lua", "line": line,
                              "end_line": source.count("\n", 0, right) + 1,
                              "name": label, "category": category,
                              "source": "vendor/lua-cjson/tests/test.lua",
                              "definition_sha256": hashlib.sha256(row.encode()).hexdigest(),
                              "declared_apis": sorted(set(apis))})
                row_start = None
            if depth == 0:
                break
    blocks = agent_blocks(vendor / "tests/agentzh.t")
    for block in blocks:
        code_tokens = list(lua_tokens(block["code"]))
        prefix = "cjson.safe." if re.search(r'local\s+cjson\s*=\s*require\s*["\']cjson\.safe["\']', block["code"]) else "cjson."
        apis = sorted(set(prefix + code_tokens[i + 2][0] for i, token in enumerate(code_tokens[:-2])
                          if token[0] == "cjson" and code_tokens[i + 1][0] == "."))
        modules = sorted(set(re.findall(r'\brequire\s*(?:\(\s*)?["\']([^"\']+)', block["code"])))
        cases.append({"id": f"agentzh.t:TEST{block['number']}", "suite": "agentzh.t",
                      "line": block["line"], "name": block["name"],
                      "source": "vendor/lua-cjson/tests/agentzh.t",
                      "category": "conditional_noop" if block["number"] == 24 else "agent_block",
                      "declared_apis": apis, "required_modules": modules, "definition_sha256": block["sha256"],
                      "condition": ({"expression": "Lua minor version >= 3", "otherwise": "canned output"}
                                    if block["number"] == 24 else
                                    {"expression": "jit.version contains LuaJIT 2.1.0", "otherwise": "ordinary table"}
                                    if block["number"] == 15 else None)})
    fixtures = sorted((vendor / "tests").glob("*.json"))
    for path in fixtures:
        cases.append({"id": f"decode-cycle:{path.name}", "suite": "decode-cycle", "line": 1,
                      "source": f"vendor/lua-cjson/tests/{path.name}", "name": "Decode cycle " + path.name,
                      "category": "decode_cycle", "declared_apis": ["cjson.decode", "cjson.encode"],
                      "definition_sha256": digest(path), "fixture": path.name})
    check_completeness(cases, cases)
    return {"schema_version": 1, "upstream_commit": PIN, "cases": cases,
            "counts": dict(Counter(c["suite"] for c in cases)),
            "assertions": sum(c["category"] != "helper" for c in cases),
            "helpers": sum(c["category"] == "helper" for c in cases),
            "setup_definitions": ["test.lua:gen_raw_octets", "test.lua:gen_utf16_escaped", "test.lua:load_testdata",
                                  "cjson.util", "tests.sort_json", "genutf8.pl -> utf8.dat"],
            "excluded": [{"path": "tests/bench.lua", "reason": "performance driver, no functional assertions"},
                         {"path": "runtests.sh", "reason": "build/package orchestration; its test.lua definitions are included"},
                         {"path": "build-packages.sh", "reason": "package orchestration"},
                         {"path": "tests/TestLua.pm", "reason": "Perl process runner replaced; every agentzh block and both output/exit verdicts retained"}],
            "source_sha256": {str(p.relative_to(vendor)): digest(p) for p in sorted(vendor.rglob("*"))
                              if p.is_file() and p.suffix not in (".so", ".o") and ".git" not in p.parts}}


def agent_blocks(path):
    source = Path(path).read_text()
    matches = list(re.finditer(r"^=== TEST (\d+): (.*)$", source, re.M))
    blocks = []
    for i, match in enumerate(matches):
        chunk = source[match.end():matches[i + 1].start() if i + 1 < len(matches) else len(source)]
        parts = re.fullmatch(r"\n--- lua\n(.*?)^--- out\n(.*)", chunk, re.S | re.M)
        if not parts:
            raise HarnessError("unrecognized agentzh block " + match[1])
        blocks.append({"number": int(match[1]), "name": match[2],
                       "line": source.count("\n", 0, match.start()) + 1,
                       "code": parts[1], "expected": parts[2].rstrip("\n") + "\n",
                       "sha256": hashlib.sha256(source[match.start():match.end()] .encode() + chunk.encode()).hexdigest()})
    return blocks


def check_completeness(expected, actual):
    wanted = Counter(c["id"] for c in expected)
    found = Counter(c["id"] for c in actual)
    problems = []
    for label, counts in (("inventory duplicate", wanted), ("duplicate", found)):
        ids = sorted(k for k, n in counts.items() if n != 1)
        if ids:
            problems.append(f"{label}: {', '.join(ids)}")
    missing, unexpected = sorted(wanted.keys() - found.keys()), sorted(found.keys() - wanted.keys())
    if missing:
        problems.append("missing: " + ", ".join(missing))
    if unexpected:
        problems.append("unexpected: " + ", ".join(unexpected))
    if problems:
        raise HarnessError("; ".join(problems))


def lua_literal(value):
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        # Decimal byte escapes also work under Lua 5.1, unlike JSON \u escapes.
        return '"' + "".join(chr(b) if 32 <= b < 127 and b not in (34, 92) else f"\\{b:03d}" for b in value.encode()) + '"'
    if isinstance(value, (list, tuple)):
        return "setmetatable({" + ",".join(lua_literal(v) for v in value) + "},{__json_array=true})"
    if isinstance(value, dict):
        return "{" + ",".join(f"[{lua_literal(k)}]={lua_literal(v)}" for k, v in value.items()) + "}"
    raise TypeError(type(value))


class Environment:
    def __init__(self, root, output, docker=True, image=IMAGE, tag="", locale_dir=None, proxy_mode="table"):
        self.root, self.output = Path(root).resolve(), Path(output).resolve()
        self.docker, self.image, self.container = docker, image, None
        self.tag = tag + "-" if tag else ""
        self.proxy_mode = proxy_mode
        self.locale_dir = Path(locale_dir).resolve() if locale_dir else None
        if self.locale_dir and not (self.locale_dir / "cs_CZ/LC_NUMERIC").is_file():
            raise HarnessError("locale directory does not contain cs_CZ/LC_NUMERIC")
        self.output.mkdir(parents=True, exist_ok=True)

    def path(self, path):
        path = Path(path).resolve()
        return "/workspace/" + str(path.relative_to(self.root)) if self.docker else str(path)

    def run(self, args, cwd=None, log=None, env=None, check=True):
        command = list(map(str, args))
        env = dict(env or {})
        if self.locale_dir:
            env["LOCPATH"] = self.path(self.locale_dir)
        if self.docker and self.container:
            prefix = ["docker", "exec", "-w", self.path(cwd or self.root)]
            for key, value in (env or {}).items():
                prefix += ["-e", key + "=" + value]
            command = prefix + [self.container] + command
        started = time.time()
        result = subprocess.run(command, cwd=self.root if self.docker else cwd or self.root,
                                env=None if self.docker else dict(os.environ, **(env or {})),
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps({"command": command, "cwd": str(cwd or self.root), "exit_code": result.returncode,
                                     "elapsed_seconds": round(time.time() - started, 3),
                                     "log": str(log.relative_to(self.output)) if log else None}) + "\n")
        if log:
            log.parent.mkdir(parents=True, exist_ok=True)
            log.write_bytes(result.stdout)
        if check and result.returncode:
            raise HarnessError(f"exit {result.returncode}: {command!r}\n{result.stdout.decode(errors='replace')[-4000:]}")
        return result

    def __enter__(self):
        try:
            return self.start()
        except BaseException:
            self.__exit__()
            raise

    def start(self):
        if self.docker:
            observed = self.run(["docker", "image", "inspect", self.image, "--format", "{{.Id}} {{.Architecture}}"]).stdout.decode().strip()
            if observed != IMAGE_ID + " arm64":
                raise HarnessError("pinned image provenance mismatch: " + observed)
            self.container = self.run(["docker", "run", "--rm", "-d", "-v", str(self.root) + ":/workspace",
                                       "-v", "leanjson-bounded-target:/workspace/target",
                                       "-v", "qjson-cargo-registry:/usr/local/cargo/registry", "-w", "/workspace",
                                       self.image, "sleep", "infinity"]).stdout.decode().strip()
        self.temp = tempfile.TemporaryDirectory(prefix=".native-", dir=self.output)
        self.native = Path(self.temp.name) / "lua-cjson"
        shutil.copytree(self.root / "vendor/lua-cjson", self.native,
                        ignore=shutil.ignore_patterns(".git", "*.o", "*.so"))
        self.run(["make", "-C", self.path(self.native), "LUA_INCLUDE_DIR=/usr/local/openresty/luajit/include/luajit-2.1"],
                 log=self.output / (self.tag + "build.log"))
        self.run(["perl", "genutf8.pl"], cwd=self.native / "tests", log=self.output / (self.tag + "genutf8.log"))
        original = (self.native / "tests/test.lua").read_text()
        header = ':format(json._VERSION))'
        if original.count(header) != 1:
            raise HarnessError("upstream display header changed")
        # A missing metadata field must be observed by its actual assertion,
        # rather than aborting the entire group in the presentation header.
        (self.native / "tests/test-driver.lua").write_text(original.replace(header, ':format(tostring(json._VERSION)))'))
        utf8 = self.native / "tests/utf8.dat"
        if hashlib.md5(utf8.read_bytes()).hexdigest() != "cff03b039d850f370a7362f3313e5268":
            raise HarnessError("upstream generated UTF-8 fixture hash mismatch")
        self.provenance = {"image": self.image if self.docker else None, "image_id": IMAGE_ID if self.docker else None,
                           "proxy_mode": self.proxy_mode,
                           "build_directory": self.path(self.native), "native_library": self.path(self.native / "cjson.so"),
                           "native_library_sha256": digest(self.native / "cjson.so"),
                           "build_settings": {"target": "cjson.so", "cc": "cc", "CFLAGS": "-O3 -Wall -pedantic -DNDEBUG -g",
                                              "CJSON_CFLAGS": "-fpic", "CJSON_LDFLAGS": "-shared", "FPCONV_OBJS": "fpconv.o",
                                              "LUA_INCLUDE_DIR": "/usr/local/openresty/luajit/include/luajit-2.1"},
                           "utf8": {"bytes": utf8.stat().st_size, "md5": hashlib.md5(utf8.read_bytes()).hexdigest(), "sha256": digest(utf8)},
                           "target_dependency_mode": "cjson preload explicitly denied during LeanJSON load; standalone null and empty-array sentinels",
                           "target_no_native_cjson_fallback": True,
                           "generated_runner_adaptation": {"original_sha256": digest(self.native / "tests/test.lua"),
                               "driver_sha256": digest(self.native / "tests/test-driver.lua"),
                               "change": "display header only: tostring(json._VERSION); all definitions and expected values unchanged"},
                           "target_library": self.run(["sha256sum", "target/release/libleanjson.so"]).stdout.decode().strip(),
                           "target_source_sha256": {str(p.relative_to(self.root)): digest(p)
                               for directory in ("src", "lua", "include") for p in sorted((self.root / directory).rglob("*")) if p.is_file()},
                           "target_library_prebuilt": True,
                           "platform": self.run(["uname", "-a"]).stdout.decode().strip(),
                           "compiler": self.run(["cc", "--version"]).stdout.decode().splitlines()[0],
                           "luajit": self.run(["/usr/local/openresty/luajit/bin/luajit", "-v"]).stdout.decode().strip()}
        # Git's worktree link points outside the container bind mount. Verify it
        # on the host, independently of _VERSION or the C module's own strings.
        self.provenance["upstream_commit"] = subprocess.check_output(["git", "-C", str(self.root / "vendor/lua-cjson"), "rev-parse", "HEAD"], text=True).strip()
        if self.provenance["upstream_commit"] != PIN:
            raise HarnessError("vendor revision differs from the binding specification")
        if self.locale_dir:
            self.provenance["locale"] = {"LOCPATH": self.path(self.locale_dir),
                "source_files_sha256": {str(p.relative_to(self.locale_dir)): digest(p) for p in sorted(self.locale_dir.rglob("*")) if p.is_file()},
                "setlocale_probe": self.run(["/usr/local/openresty/luajit/bin/luajit", "-e", 'assert(os.setlocale("cs_CZ")); print(os.setlocale(nil))']).stdout.decode().strip()}
        shutil.copy2(self.native / "cjson.so", self.output / (self.tag + "native-reference.so"))
        write_json(self.output / (self.tag + "provenance.json"), self.provenance)
        return self

    def __exit__(self, *_):
        if hasattr(self, "temp"):
            self.temp.cleanup()
        if self.container:
            container = self.container
            self.container = None
            self.run(["docker", "stop", "--time", "1", container], check=False)

    def worker(self, directory, implementation, mode, source, cases, kind="test", **extra):
        directory.mkdir(parents=True, exist_ok=True)
        config = {"root": self.path(self.root), "native": self.path(self.native),
                  "output": self.path(directory / "records.jsonl"), "blobs": self.path(self.output / "blobs"),
                  "implementation": implementation, "mode": mode, "source": source, "kind": kind,
                  "proxy_mode": self.proxy_mode,
                  "cases": cases, "cell": "baseline" if implementation == "reference" else mode + "-" + source,
                  **extra}
        (self.output / "blobs").mkdir(exist_ok=True)
        config_path = directory / "config.lua"
        config_path.write_text("return " + lua_literal(config) + "\n")
        self.run(["/usr/local/openresty/luajit/bin/luajit", self.path(self.root / "tests/upstream-cjson/worker.lua"), self.path(config_path)],
                 cwd=self.native / "tests", log=directory / "raw.log",
                 env={"LD_LIBRARY_PATH": "/workspace/target/release" if self.docker else str(self.root / "target/release")})
        records = [json.loads(line) for line in (directory / "records.jsonl").read_text().splitlines()]
        results = [r for r in records if r["record_type"] == "case"]
        check_completeness(cases, results)
        return results, [r for r in records if r["record_type"] == "runtime"]


def canonical(value):
    """Only remove observation metadata; values, arity, bytes and errors stay exact."""
    if isinstance(value, list):
        return [canonical(v) for v in value]
    if isinstance(value, dict):
        return {k: canonical(v) for k, v in value.items() if k not in ("storage", "container", "lua_type", "artifact")}
    return value


def carrier_contents(value, preserve_shape=False):
    """Compare contents without erasing the original evidence's carrier types."""
    if isinstance(value, list):
        return [carrier_contents(v, preserve_shape) for v in value]
    if isinstance(value, dict):
        out = {k: carrier_contents(v, preserve_shape) for k, v in value.items()
               if k not in ("storage", "lua_type", "artifact") and (k != "container" or preserve_shape)}
        if value.get("type") == "userdata" and value.get("storage") == "proxy" and "entries" in value:
            out["type"] = "table"
        return out
    return value


def observed_string(value, expected):
    raw = expected.encode()
    return canonical(value) == {"type": "string", "bytes": len(raw), "hex": raw.hex(),
                                "sha256": hashlib.sha256(raw).hexdigest()}


def expected_difference(reference, target):
    """Allow observed, documented behavior only; an ID alone never grants a pass."""
    case_id = target.get("id")
    result = target.get("result", {})
    values = result.get("values", [])
    if case_id == "test.lua:L94" and target.get("success") and result.get("arity") == 2 and len(values) == 2:
        if observed_string(values[0], "leanjson") and observed_string(values[1], PROJECT_VERSION):
            return "module_identity"
    if target.get("mode") not in ("lazy", "preload") or target.get("proxy_mode") not in ("table", "userdata"):
        return None
    if case_id in ("agentzh.t:TEST12", "agentzh.t:TEST14") and target.get("success"):
        if result == {"arity": 0, "values": []} and observed_string(
                target.get("stdout"), 'decoded JSON array has metatable: false\n{"my_array":[]}\n'):
            return "lazy_array_semantics"
    if case_id == "agentzh.t:TEST13" and target.get("success") is False:
        if (result.get("arity") == 1 and len(values) == 1 and observed_string(target.get("stdout"), "")
                and observed_string(values[0], "leanjson: array index must be a positive integer")):
            return "lazy_array_semantics"
    if target.get("proxy_mode") != "userdata" or not target.get("success"):
        return None
    if case_id in USERDATA_DECODE_IDS and reference.get("success"):
        dispatch = reference.get("dispatch", [])
        if (canonical(result) != carrier_contents(result) and carrier_contents(result) == canonical(reference.get("result"))
                and len(dispatch) == 1 and carrier_contents(result, True) == carrier_contents(dispatch[0].get("reference_shape_result"), True)):
            return "userdata_carrier"
    if case_id in USERDATA_CYCLE_IDS and result == {"arity": 1, "values": [{"type": "boolean", "value": False}]}:
        native, actual = reference.get("dispatch", []), target.get("dispatch", [])
        if (native and len(native) == len(actual)
                and canonical(native[0].get("input")) == canonical(actual[0].get("input")) and all(
            a.get("success") is True and b.get("success") is True
            and "decoded_result" in b and canonical(b["decoded_result"]) != carrier_contents(b["decoded_result"])
            and carrier_contents(b["decoded_result"]) == canonical(a.get("reference_result"))
            # Cycles must retain the ORIGINAL JSON shape. Native re-encoding
            # may turn an unmarked [] into {}, the declared lazy-array behavior.
            and carrier_contents(b["decoded_result"], True) == carrier_contents(native[0].get("reference_shape_result"), True)
            for a, b in zip(native, actual)
        )):
            return "userdata_carrier"
    return None


def classify(reference, target):
    target.pop("expected_difference", None)
    target["matches_reference_result"] = canonical(target.get("result")) == canonical(reference.get("result"))
    if target.get("environment_inapplicable") or reference.get("environment_inapplicable"):
        return "environment_inapplicable"
    if reference.get("helper"):
        if not reference.get("success"):
            return "baseline_failure"
        if target.get("unsupported") or target.get("dependencies"):
            return "unsupported"
        return "setup_success" if target.get("success") else "setup_failure"
    if not reference.get("upstream_exact_pass"):
        return "baseline_failure"
    if target.get("unsupported") or target.get("dependencies"):
        return "unsupported"
    if target.get("upstream_exact_pass"):
        return "pass"
    difference = expected_difference(reference, target)
    if difference in EXPECTED_DIFFERENCES:
        target["expected_difference"] = difference
        return "expected_difference"
    return "behavioral_difference"


def summarize(records):
    return {"total": len(records), "assertions": sum(not r.get("helper") for r in records),
            "helpers": sum(bool(r.get("helper")) for r in records),
            "classifications": dict(Counter(r["classification"] for r in records)),
            "expected_differences": dict(Counter(r["expected_difference"] for r in records if r.get("expected_difference"))),
            "by_category": {category: dict(Counter(r["classification"] for r in records if r["category"] == category))
                            for category in sorted({r["category"] for r in records})},
            "upstream_exact_passes": sum(r.get("upstream_exact_pass") is True and not r.get("helper") for r in records),
            "logical_passes": sum(r.get("logical_pass") is True and not r.get("helper") for r in records),
            "actual_decode_cases": sum(bool(r.get("dispatch")) for r in records),
            "decode_calls": sum(len(r.get("dispatch", [])) for r in records)}


def write_records(path, records):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(r, ensure_ascii=True) + "\n" for r in records))


def run_suites(env, out, inv, implementation, mode, source):
    rows = [c for c in inv["cases"] if c["suite"] in ("test.lua", "decode-cycle")]
    records, runtimes = env.worker(out / "test-lua", implementation, mode, source, rows)
    block_cases = {c["id"]: c for c in inv["cases"] if c["suite"] == "agentzh.t"}
    for block in agent_blocks(env.native / "tests/agentzh.t"):
        case = block_cases[f"agentzh.t:TEST{block['number']}"]
        values, runtime = env.worker(out / f"agentzh-{block['number']:02}", implementation, mode, source, [case],
                                     kind="agent", code=block["code"], expected_stdout=block["expected"], block_number=block["number"])
        records.extend(values)
        runtimes.extend(runtime)
    check_completeness(inv["cases"], records)
    write_records(out / "records.jsonl", records)
    write_json(out / "runtimes.json", runtimes)
    return records


def exit_status(report, strict=False):
    accepted = report.get("accepted", report.get("compatible", False))
    return 2 if not report.get("harness_healthy") else 1 if strict and not accepted else 0


def sparse_selection(call):
    """Choose from the reference observation, never through a target cjson load."""
    values = call["reference_result"]["values"]
    if not call["success"] or not values:
        return {"selected_paths": ["$"], "selection_reason": "reference decode failed; exercise original malformed input"}
    value = values[0]
    if value["type"] != "table":
        return {"selected_paths": ["$"], "selection_reason": "scalar root has no unselected child"}
    entries = value["entries"]
    if not entries:
        return {"selected_paths": ["$.__upstream_matrix_absent_selection__"], "selection_reason": "empty container has no selectable child"}
    def key(entry):
        typed = entry["key"]
        return int(typed["repr"]) if typed["type"] == "number" else bytes.fromhex(typed["hex"]).decode("utf-8")
    selected = key(entries[0])
    path = f"$[{selected - 1}]" if isinstance(selected, int) else "$[" + json.dumps(selected, ensure_ascii=False) + "]"
    out = {"selected_paths": [path], "selected_key": selected, "selection_reason": "one existing child; all other members remain unselected"}
    if len(entries) > 1:
        out.update(unselected_key=key(entries[1]), reference_unselected_value=entries[1]["value"])
    return out


def run_selective(env, output, reference):
    replay = []
    for case in reference:
        for i, call in enumerate(case.get("dispatch", []), 1):
            replay.append({"id": f"{case['id']}#decode{i}", "suite": "selective-replay", "line": case["line"],
                           "source": case["source_location"], "name": case["name"], "category": "decode_replay",
                           "origin_id": case["id"], "input_blob": call["input"]["artifact"],
                           "reference_success": call["success"], "reference_result": call["reference_result"],
                           "reference_configuration": call.get("configuration", {}),
                           "reference_decode_settings": call["decode_settings"],
                           "reference_shape_result": call["reference_shape_result"],
                           "reference_safe": call["safe"], "reference_api": call["upstream_api"],
                           "declared_apis": ["cjson.decode"], **sparse_selection(call)})
    write_json(output / "selective/inventory.json", {"cases": replay})
    summaries, compatible = {}, True
    for source in SOURCES:
        records, runtime = env.worker(output / "selective" / source, "target", "selective", source, replay, kind="replay")
        for record, wanted in zip(records, replay):
            record["matches_reference_result"] = canonical(record["result"]) == canonical(wanted["reference_result"])
            record["classification"] = "pass" if record["success"] == wanted["reference_success"] and record["matches_reference_result"] else "behavioral_difference"
            if "unselected_key" in wanted and record.get("success"):
                record["unselected_access_matches_reference"] = canonical(record.get("unselected_value")) == canonical(wanted["reference_unselected_value"])
                if not record["unselected_access_matches_reference"]:
                    record["classification"] = "behavioral_difference"
            for dispatch in record.get("dispatch", []):
                stats = dispatch.get("initial_source_stats")
                if stats and stats.get("index_bytes") != 0:
                    raise HarnessError("selective replay allocated automatic indexes: " + record["id"])
            record["logical_pass"] = record["classification"] == "pass"
            if (record["classification"] == "behavioral_difference" and env.proxy_mode == "userdata"
                    and "userdata_carrier" in EXPECTED_DIFFERENCES
                    and record["success"] == wanted["reference_success"]
                    and carrier_contents(record["result"]) == canonical(wanted["reference_result"])
                    and carrier_contents(record["result"], True) == carrier_contents(wanted["reference_shape_result"], True)
                    and ("unselected_key" not in wanted or carrier_contents(record.get("unselected_value"))
                         == canonical(wanted["reference_unselected_value"]))):
                record["classification"] = "expected_difference"
                record["expected_difference"] = "userdata_carrier"
            if record["classification"] != "pass":
                compatible = False
        write_records(output / "selective" / source / "records.jsonl", records)
        write_json(output / "selective" / source / "runtimes.json", runtime)
        summaries[source] = summarize(records)
        # Lossless encoding is stronger than the native default-precision
        # contract. Retain it as evidence without changing decode compatibility.
        summaries[source]["encoded_roundtrip_diagnostics"] = {
            "complete": sum(r.get("encoded_roundtrip_complete") is True for r in records),
            "incomplete": sum(r.get("encoded_roundtrip_complete") is False for r in records),
            "not_run": sum("encoded_roundtrip_complete" not in r for r in records),
        }
        print("selective-" + source + ": " + json.dumps(summaries[source]["classifications"]), flush=True)
    return summaries, compatible


def run_matrix(root, output, docker=True, image=IMAGE, locale_dir=None, proxy_mode="table"):
    inv = inventory(root / "vendor/lua-cjson")
    write_json(output / "inventory.json", inv)
    with Environment(root, output, docker, image, locale_dir=locale_dir, proxy_mode=proxy_mode) as env:
        reference = run_suites(env, output / "baseline", inv, "reference", "native", "memory")
        baseline = {r["id"]: r for r in reference}
        for record in reference:
            record["classification"] = ("environment_inapplicable" if record.get("environment_inapplicable") else
                                        "setup_success" if record.get("helper") and record.get("success") else
                                        "pass" if record.get("upstream_exact_pass") else "baseline_failure")
        write_records(output / "baseline/records.jsonl", reference)
        print("baseline: " + json.dumps(summarize(reference)["classifications"]), flush=True)
        summary = {"schema_version": 2, "harness_healthy": True, "compatible": True,
                   "accepted": not any(r["classification"] == "baseline_failure" for r in reference),
                   "expected_difference_policy": EXPECTED_DIFFERENCES,
                   "proxy_mode": proxy_mode,
                   "inventory_total_per_cell": len(inv["cases"]), "baseline": summarize(reference), "matrix": {}, "selective": {}}
        for mode in MODES:
            for source in SOURCES:
                cell = mode + "-" + source
                records = run_suites(env, output / "matrix" / cell, inv, "target", mode, source)
                for record in records:
                    record["classification"] = classify(baseline[record["id"]], record)
                write_records(output / "matrix" / cell / "records.jsonl", records)
                summary["matrix"][cell] = summarize(records)
                print(cell + ": " + json.dumps(summary["matrix"][cell]["classifications"]), flush=True)
                if any(r["classification"] in ("unsupported", "behavioral_difference", "setup_failure", "baseline_failure") for r in records):
                    summary["accepted"] = False
                if any(r["classification"] in ("unsupported", "behavioral_difference", "expected_difference", "setup_failure", "baseline_failure") for r in records):
                    summary["compatible"] = False
        summary["selective"], selective_compatible = run_selective(env, output, reference)
        summary["compatible"] = summary["compatible"] and selective_compatible
        summary["accepted"] = summary["accepted"] and all(
            not set(cell["classifications"]) - {"pass", "expected_difference"} for cell in summary["selective"].values())
        write_json(output / "summary.json", summary)
        return summary


def run_negative_controls(root, output, proxy_mode="table"):
    root, output = Path(root), Path(output)
    with Environment(root, output, proxy_mode=proxy_mode) as env:
        def control(name, rows, code, **options):
            reference, _ = env.worker(output / name / "reference", "reference", "native", "memory", rows,
                                      kind="control", code=code)
            target, _ = env.worker(output / name / "target", "target", "lazy", options.pop("source", "memory"), rows,
                                   kind="control", code=code, **options)
            for a, b in zip(reference, target):
                b["classification"] = classify(a, b)
            write_records(output / name / "classified.jsonl", target)
            return reference, target

        def case(name, category="direct_decode", apis=None):
            return {"id": name, "suite": "negative-control", "name": name, "line": 1,
                    "source": "negative-control:" + name, "category": category,
                    "declared_apis": apis if apis is not None else ["cjson.decode"]}

        _, different = control("different", [case("different")],
                               'util.run_test_group({{"different",json.decode,{"1"},true,{1}}})', fault_return=True)
        # These are deliberate control faults, independent of which public APIs
        # or syntax diagnostics the target has already implemented.
        _, missing = control("missing", [case("missing", "settings", ["cjson.decode_max_depth"])],
                             'util.run_test_group({{"missing",function(value) '
                             'return json[CONTROL_TARGET and "control_missing_api" or "decode_max_depth"](value) '
                             'end,{5},true,{5}}})')
        _, safe_constant = control("safe-constant", [case("safe-constant", "settings", ["cjson.safe.empty_array_mt"])],
                             'util.run_test_group({{"safe-constant",function() return require("cjson.safe").empty_array_mt end,{},true,{json.empty_array_mt}}})', fault_missing_safe=True)
        _, reset_getter = control("reset-getter", [case("reset", "helper", ["cjson.new"]), case("getter", "settings", ["cjson.encode_sparse_array"])],
                             'util.run_test_group({{"reset",function() if CONTROL_TARGET then error("intentional reset failure",0) end json=json.new() end},'
                             '{"getter",function() return json.encode_sparse_array() end,{},true,{false,2,10}}})')
        _, setup = control("setup", [case("setup", "helper", []), case("dependent")],
                           'util.run_test_group({{"setup",function() if CONTROL_TARGET then error("intentional setup failure",0) end end},'
                           '{"dependent",json.decode,{"true"},true,{true}}})')
        _, malformed = control("malformed", [case("malformed")],
                               'util.run_test_group({{"malformed",function(raw) '
                               'if CONTROL_TARGET then local ok=pcall(json.decode,raw); assert(not ok); '
                               'error("intentional malformed error divergence",0) end return json.decode(raw) '
                               'end,{"{bad"},false,{"Expected object key string but found invalid token at character 2"}}})')
        _, arity = control("arity", [case("arity", "settings", [])],
                           'util.run_test_group({{"arity",function() return nil,false,json.null,"\\000\\255",0/0,math.huge,-math.huge end,{},true,{nil,false,json.null,"\\000\\255",0/0,math.huge,-math.huge}}})')
        _, boundary = control("boundary", [case("boundary")],
                              'util.run_test_group({{"boundary",json.decode,{[[{"escaped":"\\uD83D\\uDE00","utf8":"😀","number":-1.25e+3,"items":[true,false,null]}]]},true,'
                              '{{escaped="😀",utf8="😀",number=-1250,items={true,false,json.null}}}}})', source="feed", feed_one_byte=True)
        selected_reference, _ = control("selective-source", [case("precision", "settings", ["cjson.encode_number_precision"]), case("selective-source")],
                              'util.run_test_group({{"precision",json.encode_number_precision,{14},true,{14}},'
                              '{"selective-source",json.decode,{[[{"a.b":{"x":1},"tail":{"y":false}}]]},true,'
                              '{{["a.b"]={x=1},tail={y=false}}}}})')
        call = selected_reference[1]["dispatch"][0]
        replay_case = dict(case("selective-existing-child"), input_blob=call["input"]["artifact"],
                           reference_configuration=call["configuration"], reference_decode_settings=call["decode_settings"],
                           reference_safe=call["safe"], reference_api=call["upstream_api"], **sparse_selection(call))
        selected, _ = env.worker(output / "selective-existing-child", "target", "selective", "feed", [replay_case], kind="replay")
        selection = selected[0]
        selection_stats = selection["dispatch"][0].get("initial_source_stats", {})
        omitted = duplicate = False
        try:
            check_completeness([case("different")], [])
        except HarnessError:
            omitted = True
        try:
            check_completeness([case("different")], different + different)
        except HarnessError:
            duplicate = True
        values = arity[0]["result"]["values"]
        result = {"differing_return": different[0]["classification"], "missing_api": missing[0]["classification"],
                  "failed_setup_dependency": setup[1]["classification"], "malformed_input": malformed[0]["classification"],
                  "omitted_detected": omitted, "duplicate_detected": duplicate,
                  "typed_arity_preserved": arity[0]["result"]["arity"] == 7 and
                      [v["type"] for v in values] == ["nil", "boolean", "json_null", "string", "number", "number", "number"],
                  "feed_boundary_split": boundary[0]["logical_pass"] and boundary[0]["dispatch"][0]["max_chunk_bytes"] == 1}
        result["selective_existing_child"] = (selection.get("encoded_roundtrip_complete") is True and
            canonical(selection["result"]) == canonical(call["reference_result"]) and
            selection_stats.get("index_bytes") == 0 and selection_stats.get("preloaded_nodes", 0) > 0 and
            selection["selected_paths"] == ['$["a.b"]'] and
            canonical(selection.get("unselected_value")) == canonical(replay_case["reference_unselected_value"]))
        result["safe_constant"] = safe_constant[0]["classification"]
        result["getter_after_failed_reset"] = reset_getter[1]["classification"]
        result["getter_raw_exact_pass"] = reset_getter[1]["upstream_exact_pass"]
        result["healthy"] = all((result["differing_return"] == "behavioral_difference", result["missing_api"] == "unsupported",
                                 result["failed_setup_dependency"] == "unsupported", result["malformed_input"] == "behavioral_difference",
                                 omitted, duplicate, result["typed_arity_preserved"], result["feed_boundary_split"], result["selective_existing_child"],
                                 result["safe_constant"] == "unsupported", result["getter_after_failed_reset"] == "unsupported", result["getter_raw_exact_pass"]))
        write_json(output / "summary.json", result)
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(DEFAULT_OUTPUT))
    parser.add_argument("--docker", action="store_true", help="use the immutable pinned ARM64 development image")
    parser.add_argument("--image", default=IMAGE)
    parser.add_argument("--proxy-mode", choices=("table", "userdata"), default="table")
    parser.add_argument("--strict", action="store_true", help="exit 1 for unexpected differences/unsupported APIs; declared differences are recorded, harness errors exit 2")
    parser.add_argument("--locale-dir", type=Path, help="prepared LOCPATH directory containing cs_CZ/LC_NUMERIC; hashed in provenance")
    parser.add_argument("--inventory-only", action="store_true")
    parser.add_argument("--controls", action="store_true", help="execute focused fault-injection controls, not the complete matrix")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    try:
        for status in ("summary.json", "harness-error.json"):
            (output / status).unlink(missing_ok=True)
        if args.inventory_only:
            write_json(output / "inventory.json", inventory(ROOT / "vendor/lua-cjson"))
            return 0
        if args.controls:
            return 0 if run_negative_controls(ROOT, output, args.proxy_mode)["healthy"] else 2
        report = run_matrix(ROOT, output, args.docker, args.image, args.locale_dir, args.proxy_mode)
        print(json.dumps({"harness_healthy": report["harness_healthy"], "compatible": report["compatible"],
                          "accepted": report["accepted"], "output": str(output)}))
        return exit_status(report, args.strict)
    except (HarnessError, OSError, ValueError, KeyError) as error:
        (output / "summary.json").unlink(missing_ok=True)
        write_json(output / "harness-error.json", {"harness_healthy": False, "error": str(error)})
        print("HARNESS FAILURE: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

"""Negative controls for the upstream runner, including real Lua worker execution.

Run with python3 -m unittest discover -s tests/upstream-cjson -p 'test_*.py'.
The worker controls use the same pinned Docker image as the complete matrix.
"""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/verify-cjson-compat.py"
TEST_OUTPUT = Path(os.environ.get("CJSON_COMPAT_TEST_OUTPUT", ROOT / ".superpowers/upstream-cjson-tests")).resolve()


class RunnerControls(unittest.TestCase):
    def test_userdata_observation_retains_types_and_native_exact_failure(self):
        runner = self.runner()
        scratch = TEST_OUTPUT / "userdata-types"
        case = {"id": "userdata-types", "suite": "negative-control", "line": 1,
                "name": "userdata-types", "category": "direct_decode", "source": "negative-control:userdata-types",
                "declared_apis": ["cjson.decode"]}
        code = ('util.run_test_group({{"userdata-types",json.decode,{[[{"child":[false]}]]},'
                'true,{{child={false}}}}})')
        with runner.Environment(ROOT, scratch, proxy_mode="userdata") as environment:
            reference, _ = environment.worker(scratch / "reference", "reference", "native", "memory",
                                               [case], kind="control", code=code)
            for mode in ("lazy", "preload", "eager"):
                for source in ("memory", "file", "feed"):
                    with self.subTest(mode=mode, source=source):
                        target, runtimes = environment.worker(scratch / (mode + "-" + source), "target", mode, source,
                                                              [case], kind="control", code=code)
                        row = target[0]
                        actual_type = "table" if mode == "eager" else "userdata"
                        self.assertEqual("userdata", row["proxy_mode"])
                        self.assertEqual("userdata", row["dispatch"][0]["options"]["proxy_mode"])
                        self.assertEqual("userdata", runtimes[0]["proxy_mode"])
                        result = row["result"]["values"][0]
                        self.assertEqual(actual_type, result["type"])
                        self.assertEqual(actual_type, result["entries"][0]["value"]["type"])
                        self.assertTrue(row["logical_pass"], row)
                        self.assertEqual(mode == "eager", row["upstream_exact_pass"])
                        verdict = runner.classify(reference[0], row)
                        self.assertEqual("pass" if mode == "eager" else "behavioral_difference", verdict)
                        self.assertEqual(mode == "eager", row["matches_reference_result"])

    def test_safe_module_and_factory_preserve_pairs_in_all_source_modes(self):
        runner = self.runner()
        scratch = TEST_OUTPUT / "safe-dispatch-control"
        case = {"id": "safe-dispatch", "suite": "negative-control", "line": 1,
                "name": "safe-dispatch", "category": "direct_decode", "source": "negative-control:safe-dispatch",
                "declared_apis": ["cjson.safe.decode", "cjson.safe.new"]}
        code = ('util.run_test_group({{"safe-dispatch",function() '
                'local safe=require("cjson.safe"); local child=safe.new(); '
                'local function pack(...) return {n=select("#",...),...} end; '
                'local f=safe.decode("false"); local n=child.decode("null"); '
                'local a=pack(safe.decode("Oops")); local b=pack(child.decode("{bad")); '
                'return f,n==safe.null,a.n,a[1]==nil,type(a[2]),b.n,b[1]==nil,type(b[2]) '
                'end,{},true,{false,true,2,true,"string",2,true,"string"}}})')
        with runner.Environment(ROOT, scratch) as environment:
            for mode in ("lazy", "eager", "preload"):
                for source, api in (("memory", "decode"), ("file", "decode_file"), ("feed", "new_decoder:feed:finish")):
                    with self.subTest(mode=mode, source=source):
                        rows, _ = environment.worker(scratch / (mode + "-" + source), "target", mode, source,
                                                     [case], kind="control", code=code)
                        row = rows[0]
                        self.assertTrue(row["upstream_exact_pass"], row)
                        self.assertEqual([], row["unsupported"])
                        self.assertEqual(["module", "instance", "module", "instance"],
                                         [event["codec_scope"] for event in row["dispatch"]])
                        for event in row["dispatch"]:
                            self.assertEqual("leanjson.safe." + api, event["actual_path"])
                            if mode == "eager":
                                self.assertIs(False, event["options"]["lazyload"])
                            if mode == "preload":
                                self.assertEqual(["$"], event["options"]["preload_paths"])
                            if source == "feed":
                                self.assertTrue(event["decoder_closed"])

    def test_instance_decode_keeps_source_and_loading_matrix_dispatch(self):
        runner = self.runner()
        scratch = TEST_OUTPUT / "instance-dispatch-control"
        case = {"id": "instance-dispatch", "suite": "negative-control", "line": 1,
                "name": "instance-dispatch", "category": "direct_decode",
                "source": "negative-control:instance-dispatch", "declared_apis": ["cjson.new", "cjson.decode"]}
        code = ('util.run_test_group({{"instance-dispatch",function() '
                'local codec=json.new(); local value=codec.decode([[{"child":{"n":1},"other":2}]]); '
                'return value.child.n,value.other end,{},true,{1,2}}})')
        paths = {"memory": "leanjson.decode", "file": "leanjson.decode_file",
                 "feed": "leanjson.new_decoder:feed:finish"}
        with runner.Environment(ROOT, scratch) as environment:
            safe_code = ('util.run_test_group({{"instance-dispatch",function() '
                         'local safe=require("cjson.safe"); return safe.decode("1"),safe.new().decode("2") '
                         'end,{},true,{1,2}}})')
            reference, _ = environment.worker(scratch / "safe-reference", "reference", "native", "memory",
                                               [case], kind="control", code=safe_code)
            self.assertEqual(["module", "instance"], [e["codec_scope"] for e in reference[0]["dispatch"]])
            for mode in ("lazy", "eager", "preload"):
                for source in paths:
                    with self.subTest(mode=mode, source=source):
                        records, _ = environment.worker(scratch / (mode + "-" + source), "target", mode,
                                                        source, [case], kind="control", code=code)
                        row = records[0]
                        self.assertTrue(row["upstream_exact_pass"])
                        self.assertEqual(1, len(row["dispatch"]), "instance bypassed matrix dispatch")
                        event = row["dispatch"][0]
                        self.assertEqual(paths[source], event["actual_path"])
                        self.assertEqual("instance", event["codec_scope"])
                        if mode == "eager":
                            self.assertIs(False, event["options"]["lazyload"])
                        elif mode == "preload":
                            self.assertEqual(["$"], event["options"]["preload_paths"])
                        if source == "feed":
                            self.assertTrue(event["decoder_closed"])
                            self.assertGreater(event["feed_chunks"], 1)

    def runner(self):
        self.assertTrue(SCRIPT.is_file(), "upstream compatibility runner is not implemented")
        spec = importlib.util.spec_from_file_location("cjson_compat", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_omitted_case_cannot_be_counted_as_a_healthy_run(self):
        runner = self.runner()
        with self.assertRaisesRegex(runner.HarnessError, "missing.*case:b"):
            runner.check_completeness([{"id": "case:a"}, {"id": "case:b"}], [{"id": "case:a"}])

    def test_duplicate_case_cannot_hide_an_omission(self):
        runner = self.runner()
        with self.assertRaisesRegex(runner.HarnessError, "duplicate.*case:a"):
            runner.check_completeness([{"id": "case:a"}], [{"id": "case:a"}, {"id": "case:a"}])

    def test_unexpected_case_is_a_harness_failure(self):
        runner = self.runner()
        with self.assertRaisesRegex(runner.HarnessError, "unexpected.*case:b"):
            runner.check_completeness([{"id": "case:a"}], [{"id": "case:a"}, {"id": "case:b"}])

    def test_inventory_includes_helpers_blocks_and_all_supplied_json(self):
        runner = self.runner()
        inventory = runner.inventory(ROOT / "vendor/lua-cjson")
        self.assertEqual(164, len(inventory["cases"]))
        self.assertEqual(3, sum(c["category"] == "helper" for c in inventory["cases"]))
        self.assertEqual(24, sum(c["suite"] == "agentzh.t" for c in inventory["cases"]))
        self.assertEqual(9, sum(c["suite"] == "decode-cycle" for c in inventory["cases"]))

    def test_inventory_resolves_safe_factory_decode_and_module_aliases(self):
        runner = self.runner()
        cases = runner.inventory(ROOT / "vendor/lua-cjson")["cases"]
        factory = next(c for c in cases if c["name"] == "Decode (safe) error generation after new()")
        self.assertEqual("direct_decode", factory["category"])
        self.assertIn("cjson.safe.decode", factory["declared_apis"])
        safe_block = next(c for c in cases if c["id"] == "agentzh.t:TEST18")
        self.assertEqual(["cjson", "cjson.safe"], safe_block.get("required_modules"))
        self.assertEqual(["cjson.safe.empty_array_mt", "cjson.safe.encode"], safe_block["declared_apis"])

    def test_real_worker_detects_differences_missing_api_failed_setup_and_malformed_input(self):
        runner = self.runner()
        # This executes native cjson and LeanJSON in isolated LuaJIT processes;
        # it does not construct pre-classified JSON records as a stand-in.
        scratch = TEST_OUTPUT / "negative-controls"
        result = runner.run_negative_controls(ROOT, scratch)
        self.assertTrue(result["healthy"], json.dumps(result, indent=2))
        self.assertEqual("behavioral_difference", result["differing_return"])
        self.assertEqual("unsupported", result["missing_api"])
        self.assertEqual("unsupported", result["failed_setup_dependency"])
        self.assertEqual("behavioral_difference", result["malformed_input"])
        self.assertTrue(result["omitted_detected"])
        self.assertTrue(result["duplicate_detected"])
        self.assertTrue(result["feed_boundary_split"])
        self.assertTrue(result["typed_arity_preserved"])
        self.assertTrue(result.get("selective_existing_child"), "selective replay did not preload a real child and retain its sibling")
        self.assertEqual("unsupported", result.get("safe_constant"), "missing safe-module constants were misclassified")
        self.assertEqual("unsupported", result.get("getter_after_failed_reset"), "a failed reset did not taint its getter")
        self.assertTrue(result.get("getter_raw_exact_pass"), "the getter control must demonstrate a coincidental raw pass")

    def test_strict_exit_distinguishes_compatibility_from_report_generation(self):
        runner = self.runner()
        report = {"harness_healthy": True, "compatible": False}
        self.assertEqual(0, runner.exit_status(report, strict=False))
        self.assertEqual(1, runner.exit_status(report, strict=True))
        self.assertEqual(2, runner.exit_status({"harness_healthy": False}, strict=False))

    def test_shared_native_target_precision_loss_does_not_fail_selective_compatibility(self):
        runner = self.runner()
        scratch = TEST_OUTPUT / "roundtrip-controls"
        case = {"id": "shared-default-precision", "suite": "negative-control", "line": 1,
                "name": "shared-default-precision", "category": "direct_decode",
                "source": "negative-control:shared-default-precision", "declared_apis": ["cjson.decode", "cjson.encode"]}
        code = ('util.run_test_group({{"shared-default-precision",function() '
                'local value=json.decode("9007199254740992"); local encoded=json.encode(value); '
                'return value,encoded,json.decode(encoded)==value end,{},true,'
                '{9007199254740992,"9.007199254741e+15",false}}})')
        with runner.Environment(ROOT, scratch) as environment:
            reference, _ = environment.worker(scratch / "reference", "reference", "native", "memory", [case], kind="control", code=code)
            target, _ = environment.worker(scratch / "target", "target", "lazy", "memory", [case], kind="control", code=code)
            self.assertTrue(reference[0]["upstream_exact_pass"])
            self.assertTrue(target[0]["upstream_exact_pass"])
            # Both processes really encode with their default precision, produce
            # the same bytes, and lose the same original integer on re-decode.
            self.assertEqual(reference[0]["result"]["values"][1], target[0]["result"]["values"][1])
            self.assertEqual({"type": "boolean", "value": False}, reference[0]["result"]["values"][2])
            self.assertEqual({"type": "boolean", "value": False}, target[0]["result"]["values"][2])
            summaries, compatible = runner.run_selective(environment, scratch, reference)
            report = {"harness_healthy": True, "compatible": compatible, "selective": summaries}
            runner.write_json(scratch / "summary.json", report)
            self.assertTrue(compatible, json.dumps(report, indent=2))
            self.assertEqual(0, runner.exit_status(report, strict=True))
            for source, summary in summaries.items():
                self.assertEqual({"pass": 2}, summary["classifications"], source)
                self.assertEqual({"complete": 1, "incomplete": 1, "not_run": 0}, summary["encoded_roundtrip_diagnostics"], source)
                rows = [json.loads(line) for line in (scratch / "selective" / source / "records.jsonl").read_text().splitlines()]
                self.assertTrue(rows[0]["matches_reference_result"])
                self.assertFalse(rows[0]["encoded_roundtrip_complete"])
                self.assertEqual("pass", rows[0]["classification"])
                self.assertEqual(reference[0]["result"]["values"][1], rows[0]["encoded_output"])

    def test_reusing_output_keeps_only_the_current_invocation_status(self):
        scratch = TEST_OUTPUT / "status-reuse-controls"
        scratch.mkdir(parents=True, exist_ok=True)
        for transition in (("success", "failure"), ("failure", "success")):
            with self.subTest(transition=" -> ".join(transition)):
                output = Path(tempfile.mkdtemp(prefix="-".join(transition) + "-", dir=scratch))
                history = output / "historical-diagnostic.log"
                history.write_text("preserve historical diagnostics\n")
                for step, operation in enumerate(transition, 1):
                    command = [sys.executable, str(SCRIPT), "--docker", "--output", str(output)]
                    if operation == "success":
                        # Real focused worker controls generate a healthy summary.
                        command.append("--controls")
                    else:
                        # Invalid locale preparation fails before any full-matrix
                        # worker starts, exercising the real CLI error handler.
                        command += ["--locale-dir", str(output / "missing-locale")]
                    result = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                    (output / f"{step}-{operation}.log").write_text(result.stdout)
                    summary, error = output / "summary.json", output / "harness-error.json"
                    with (output / "invocations.jsonl").open("a") as stream:
                        stream.write(json.dumps({"command": command, "exit_code": result.returncode,
                                                 "summary_exists": summary.exists(), "harness_error_exists": error.exists()}) + "\n")
                    self.assertEqual("preserve historical diagnostics\n", history.read_text())
                    if operation == "success":
                        self.assertEqual(0, result.returncode, result.stdout)
                        self.assertTrue(json.loads(summary.read_text())["healthy"])
                        self.assertFalse(error.exists(), "successful invocation retained an older harness-error.json")
                    else:
                        self.assertEqual(2, result.returncode, result.stdout)
                        self.assertIn("locale directory does not contain cs_CZ/LC_NUMERIC", json.loads(error.read_text())["error"])
                        self.assertFalse(summary.exists(), "failed invocation retained an older healthy summary.json")


if __name__ == "__main__":
    unittest.main()

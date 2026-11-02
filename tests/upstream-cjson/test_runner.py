"""Negative controls for the upstream runner, including real Lua worker execution.

Run with python3 -m unittest discover -s tests/upstream-cjson -p 'test_*.py'.
The worker controls use the same pinned Docker image as the complete matrix.
"""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/verify-cjson-compat.py"


class RunnerControls(unittest.TestCase):
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
        scratch = ROOT / ".superpowers/sdd/2026-11-02-upstream-cjson-matrix/task-1-artifacts/negative-controls"
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
        scratch = ROOT / ".superpowers/sdd/2026-11-02-upstream-cjson-matrix/task-1-artifacts/roundtrip-controls"
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


if __name__ == "__main__":
    unittest.main()

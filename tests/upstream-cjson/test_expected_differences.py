"""Acceptance must allow only the three declared differences, not regressions."""

import copy
import hashlib
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("compat_runner", ROOT / "scripts/verify-cjson-compat.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def string(value):
    raw = value.encode()
    return {"type": "string", "hex": raw.hex(), "bytes": len(raw),
            "sha256": hashlib.sha256(raw).hexdigest()}


def packed(*values):
    return {"arity": len(values), "values": list(values)}


def pair(case_id, result, reference_result=None, **fields):
    reference = {"id": case_id, "success": True, "upstream_exact_pass": True,
                 "result": reference_result or result}
    target = {"id": case_id, "mode": "lazy", "proxy_mode": "table", "requested_source": "memory",
              "category": "direct_decode", "success": True, "upstream_exact_pass": False,
              "logical_pass": False, "unsupported": [], "dependencies": [], "result": result, **fields}
    return reference, target


class ExpectedDifferenceControls(unittest.TestCase):
    def test_brand_difference_is_accepted_without_changing_exact_verdict(self):
        reference, target = pair("test.lua:L94", packed(string("leanjson"), string("0.1.0")),
                                 packed(string("cjson"), string("2.1.0.11")))
        self.assertEqual("expected_difference", runner.classify(reference, target))
        self.assertEqual("module_identity", target["expected_difference"])
        self.assertFalse(target["upstream_exact_pass"])
        for bad in (packed(string("leanjson")), packed(string("leanjson"), string("wrong"))):
            changed = copy.deepcopy(target)
            changed["result"] = bad
            self.assertEqual("behavioral_difference", runner.classify(reference, changed))
            self.assertNotIn("expected_difference", changed)

    def test_array_allowance_checks_actual_output_and_error(self):
        for case_id in ("agentzh.t:TEST12", "agentzh.t:TEST14"):
            reference, target = pair(case_id, packed(), category="agent_block",
                stdout=string('decoded JSON array has metatable: false\n{"my_array":[]}\n'))
            self.assertEqual("expected_difference", runner.classify(reference, target))
            target["stdout"] = string('{"my_array":["lost data"]}\n')
            self.assertEqual("behavioral_difference", runner.classify(reference, target))
        reference, target = pair("agentzh.t:TEST13",
            packed(string("leanjson: array index must be a positive integer")),
            success=False, stdout=string(""))
        self.assertEqual("expected_difference", runner.classify(reference, target))
        target["result"] = packed(string("unrelated runtime error"))
        self.assertEqual("behavioral_difference", runner.classify(reference, target))

    def test_userdata_allowance_requires_equal_contents_and_known_case(self):
        plain = {"type": "table", "container": "object", "entries": [{"key": string("n"), "value": {"type": "number", "repr": "7"}}]}
        proxy = {**copy.deepcopy(plain), "type": "userdata", "storage": "proxy", "lua_type": "userdata"}
        reference, target = pair("test.lua:L110", packed(proxy), packed(plain), proxy_mode="userdata")
        reference["dispatch"] = [{"reference_shape_result": packed(plain)}]
        self.assertEqual("expected_difference", runner.classify(reference, target))
        for overrides in ({"mode": "eager"}, {"id": "unknown-case"}, {"proxy_mode": "table"}):
            changed = {**target, **overrides}
            self.assertEqual("behavioral_difference", runner.classify(reference, changed))
        changed = copy.deepcopy(target)
        changed["result"]["values"][0]["entries"][0]["value"]["repr"] = "8"
        self.assertEqual("behavioral_difference", runner.classify(reference, changed))
        changed = copy.deepcopy(target)
        changed["result"]["values"][0].pop("storage")
        self.assertEqual("behavioral_difference", runner.classify(reference, changed))

    def test_userdata_allowance_does_not_erase_object_array_kind(self):
        native = {"type": "table", "container": "object", "entries": []}
        actual = {"type": "userdata", "storage": "proxy", "container": "array", "entries": []}
        reference, target = pair("test.lua:L110", packed(actual), packed(native), proxy_mode="userdata")
        reference["dispatch"] = [{"reference_shape_result": packed(native)}]
        self.assertEqual("behavioral_difference", runner.classify(reference, target))

    def test_removing_declared_policy_removes_its_acceptance(self):
        reference, target = pair("test.lua:L94", packed(string("leanjson"), string("0.1.0")))
        with patch.dict(runner.EXPECTED_DIFFERENCES, {}, clear=True):
            self.assertEqual("behavioral_difference", runner.classify(reference, target))

    def test_cycle_requires_observed_decode_contents_not_just_false_result(self):
        reference, target = pair("decode-cycle:example1.json", packed({"type": "boolean", "value": False}),
                                 packed({"type": "boolean", "value": True}), proxy_mode="userdata")
        native_value = packed({"type": "table", "container": "object", "entries": []})
        proxy_value = packed({"type": "userdata", "container": "object", "storage": "proxy", "entries": []})
        reference["dispatch"] = [{"success": True, "input": string("{}"), "reference_result": native_value,
                                  "reference_shape_result": native_value}]
        target["dispatch"] = [{"success": True, "input": string("{}"), "decoded_result": proxy_value}]
        self.assertEqual("expected_difference", runner.classify(reference, target))
        target["dispatch"][0].pop("decoded_result")
        self.assertEqual("behavioral_difference", runner.classify(reference, target))

    def test_setup_errors_and_missing_apis_are_never_allowlisted(self):
        reference, target = pair("test.lua:L94", packed(string("leanjson"), string("0.1.0")))
        target["unsupported"] = ["missing field"]
        self.assertEqual("unsupported", runner.classify(reference, target))
        target["unsupported"] = []
        target["dependencies"] = ["failed reset"]
        self.assertEqual("unsupported", runner.classify(reference, target))
        reference["upstream_exact_pass"] = False
        self.assertEqual("baseline_failure", runner.classify(reference, target))

    def test_strict_exit_uses_acceptance_but_preserves_non_equivalence(self):
        report = {"harness_healthy": True, "compatible": False, "accepted": True}
        self.assertEqual(0, runner.exit_status(report, strict=True))
        report["accepted"] = False
        self.assertEqual(1, runner.exit_status(report, strict=True))
        report["harness_healthy"] = False
        self.assertEqual(2, runner.exit_status(report, strict=True))


if __name__ == "__main__":
    unittest.main()

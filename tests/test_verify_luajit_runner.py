"""Exit and evidence controls for the shell Memcheck runner."""
import hashlib
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class LuaJITRunnerControls(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.runtime = self.directory / "luajit"
        self.runtime.write_text("#!/bin/sh\nexit 0\n")
        self.runtime.chmod(0o755)
        self.checker = self.directory / "valgrind"
        self.checker.write_text('''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
if '--version' in sys.argv:
    print('controlled-memcheck')
    sys.exit(0)
case = os.environ['RUNNER_CONTROL_CASE']
pattern = next(arg.split('=', 1)[1] for arg in sys.argv if arg.startswith('--log-file='))
def log(pid, errors):
    Path(pattern.replace('%p', str(pid))).write_text(
        '==%s== ERROR SUMMARY: %s errors from %s contexts (suppressed: 0 from 0)\\n' % (pid, errors, errors))
if case != 'missing':
    if case == 'incomplete':
        Path(pattern.replace('%p', str(os.getpid()))).write_text('Memcheck started\\n')
    else:
        log(os.getpid(), 0)
        malformed = {
            'summary-heading-only': '==999999== ERROR SUMMARY:\\n',
            'summary-truncated': '==999999== ERROR SUMMARY: 0 errors from\\n',
            'summary-invalid-count': '==999999== ERROR SUMMARY: NaN errors from 0 contexts (suppressed: 0 from 0)\\n',
        }
        if case in malformed:
            Path(pattern.replace('%p', str(os.getpid() + 100000))).write_text(malformed[case])
        elif case in ('child-incomplete', 'child-empty'):
            Path(pattern.replace('%p', str(os.getpid() + 100000))).write_text(
                'Memcheck started\\n' if case == 'child-incomplete' else '')
        else:
            log(os.getpid() + 100000, 1 if case == 'child-error' else 0)
sys.exit(42 if case == 'checker-failure' else 0)
''')
        self.checker.chmod(0o755)
        (self.directory / "libleanjson.so").write_bytes(b"runner control library")

    def run_control(self, case, repository=ROOT):
        environment = dict(os.environ, LUAJIT_BIN=str(self.runtime),
                           VALGRIND_BIN=str(self.checker),
                           LEANJSON_LIBRARY_DIR=str(self.directory),
                           LEANJSON_VERIFY_OUTPUT=str(self.directory / "output"),
                           RUNNER_CONTROL_CASE=case)
        return subprocess.run(["bash", str(repository / "scripts/verify-luajit.sh"), "memcheck"],
                              cwd=repository, env=environment, capture_output=True, text=True)

    def test_child_error_fails_even_when_checker_parent_returns_zero(self):
        self.assertEqual(1, self.run_control("child-error").returncode)

    def test_missing_memcheck_logs_fail(self):
        self.assertEqual(1, self.run_control("missing").returncode)

    def test_logs_without_a_summary_fail(self):
        self.assertEqual(1, self.run_control("incomplete").returncode)

    def test_zero_error_parent_and_child_pass(self):
        self.assertEqual(0, self.run_control("pass").returncode)

    def test_complete_parent_cannot_hide_an_incomplete_child_log(self):
        self.assertEqual(1, self.run_control("child-incomplete").returncode)

    def test_complete_parent_cannot_hide_an_empty_child_log(self):
        self.assertEqual(1, self.run_control("child-empty").returncode)

    def test_summary_heading_without_counts_fails(self):
        self.assertEqual(1, self.run_control("summary-heading-only").returncode)

    def test_summary_truncated_after_from_fails(self):
        self.assertEqual(1, self.run_control("summary-truncated").returncode)

    def test_nonnumeric_error_count_fails(self):
        self.assertEqual(1, self.run_control("summary-invalid-count").returncode)

    def test_checker_failure_exit_code_is_preserved(self):
        self.assertEqual(42, self.run_control("checker-failure").returncode)

    def test_reused_output_cannot_ingest_an_earlier_child_error(self):
        self.assertEqual(1, self.run_control("child-error").returncode)
        second = self.run_control("pass")
        self.assertEqual(0, second.returncode, second.stdout + second.stderr)

    def test_reused_output_retains_each_library_and_source_provenance(self):
        repository = self.directory / "source-snapshot"
        for name in ["scripts", "src", "lua", "include", "tests/lua"]:
            (repository / name).mkdir(parents=True, exist_ok=True)
        for name in ["verify-luajit.sh", "run-busted.lua", "check-memcheck.awk"]:
            shutil.copy2(ROOT / "scripts" / name, repository / "scripts" / name)
        shutil.copy2(ROOT / "valgrind.supp", repository / "valgrind.supp")
        source = repository / "src/control.rs"
        source.write_bytes(b"first source snapshot")
        first_library = hashlib.sha256((self.directory / "libleanjson.so").read_bytes()).hexdigest()
        first_source = hashlib.sha256(source.read_bytes()).hexdigest()
        first = self.run_control("pass", repository)
        self.assertEqual(0, first.returncode, first.stderr)
        output = self.directory / "output"
        runtime_manifest = next(output.rglob("runtime.txt"))
        source_manifest = next(output.rglob("source-sha256.txt"))
        saved_runtime, saved_source = runtime_manifest.read_bytes(), source_manifest.read_bytes()
        (self.directory / "libleanjson.so").write_bytes(b"second library snapshot")
        source.write_bytes(b"second source snapshot")
        second_library = hashlib.sha256((self.directory / "libleanjson.so").read_bytes()).hexdigest()
        second_source = hashlib.sha256(source.read_bytes()).hexdigest()
        second = self.run_control("pass", repository)
        self.assertEqual(0, second.returncode, second.stderr)
        self.assertEqual(saved_runtime, runtime_manifest.read_bytes())
        self.assertEqual(saved_source, source_manifest.read_bytes())
        runtimes = "\n".join(path.read_text() for path in output.rglob("runtime.txt"))
        sources = "\n".join(path.read_text() for path in output.rglob("source-sha256.txt"))
        for value in [first_library, second_library]: self.assertIn(value, runtimes)
        for value in [first_source, second_source]: self.assertIn(value, sources)


if __name__ == "__main__":
    unittest.main()

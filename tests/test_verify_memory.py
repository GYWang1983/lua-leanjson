"""Provenance checks for the Docker-backed memory runner, without Docker load."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "verify-memory.py"
SPEC = importlib.util.spec_from_file_location("verify_memory", SCRIPT)
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)
IMAGE_ID = "sha256:" + "a" * 64
IMAGE_TAG = "mutable-runtime:latest"
LUA_FILES = {"lua/leanjson.lua": b"return {}\n", "lua/leanjson/lib.lua": b"return true\n"}


class FakeDocker:
    def __init__(self, test, output, enforce_pin, mutate_lua):
        self.test, self.output = test, output
        self.enforce_pin, self.mutate_lua = enforce_pin, mutate_lua
        self.resolved, self.tar_calls, self.commands = False, 0, []
        self.raw = b'{"model":"original","items":[false,null,1]}'

    def launched(self, command):
        self.test.assertTrue(self.resolved, "container launched before resolving image ID")
        self.commands.append(command)
        if self.enforce_pin:
            image = command[command.index("--entrypoint") + 2]
            self.test.assertEqual(IMAGE_ID, image, "container executed mutable image tag")
            self.test.assertNotIn(IMAGE_TAG, command)

    def check_output(self, command, **_kwargs):
        if command[:3] == ["docker", "image", "inspect"]:
            if command[-1] == "{{.Id}}":
                self.resolved = True  # The mutable tag is reassigned after this lookup.
                return IMAGE_ID + "\n"
            if self.enforce_pin:
                self.test.assertEqual(IMAGE_ID, command[3], "revision inspected mutable image tag")
            return "committed-source\n"
        if command[0] == "git":
            return "source-sha\n" if command[1] == "rev-parse" else ""
        self.launched(command)
        entrypoint = command[command.index("--entrypoint") + 1]
        if entrypoint == "sha256sum":
            return "b" * 64 + "  libleanjson.so\n"
        self.test.assertEqual("tar", entrypoint)
        self.tar_calls += 1
        files = dict(LUA_FILES)
        if self.mutate_lua and self.tar_calls > 1:
            files["lua/leanjson.lua"] = b"return { changed = true }\n"
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode="w") as output:
            # Ordering and timestamps vary while code stays unchanged.
            entries = sorted(files.items(), reverse=self.tar_calls % 2 == 1)
            for name, content in entries:
                info = tarfile.TarInfo(name)
                info.size, info.mtime = len(content), self.tar_calls
                output.addfile(info, io.BytesIO(content))
        return archive.getvalue()

    def run(self, command, **_kwargs):
        self.launched(command)
        for index, part in enumerate(command):
            if part.endswith("/memory-fixture.lua"):
                path = self.output / Path(command[index + 3]).name
                path.write_bytes(self.raw)
                return subprocess.CompletedProcess(command, 0, "", "")
            if part.endswith("/memory-phases.lua"):
                values = command[index + 1:]
                result = json.loads(self.raw)
                result["model"] = "rewritten-1"
                encoded = json.dumps(result).encode()
                (self.output / Path(values[3]).name).write_bytes(encoded)
                row = {"worker_hwm_kib": 10, "source_bytes": len(self.raw), "output_bytes": len(encoded)}
                return subprocess.CompletedProcess(command, 0, json.dumps(row), "")
        raise AssertionError(f"unexpected Docker command: {command}")


class MemoryRunnerProvenanceTests(unittest.TestCase):
    def run_case(self, runtime_image=True, enforce_pin=True, mutate_lua=False, proxy_mode="table"):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "evidence"
            args = SimpleNamespace(image=IMAGE_TAG, runtime_image=runtime_image, target_volume=None,
                                   output_dir=output, bytes=128, branches=0, sources=["file"], cases=["prompt"],
                                   index_budget_bytes=0, index_depth=0, index_array_limit=0,
                                   timeout=10, report_only=False, proxy_mode=proxy_mode)
            docker = FakeDocker(self, output, enforce_pin, mutate_lua)
            with mock.patch.object(RUNNER, "arguments", return_value=args), \
                    mock.patch.object(RUNNER.subprocess, "check_output", side_effect=docker.check_output), \
                    mock.patch.object(RUNNER.subprocess, "run", side_effect=docker.run), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(0, RUNNER.main())
            environment = json.loads((output / "results.jsonl").read_text().splitlines()[0])
            return environment, docker

    def test_proxy_mode_is_recorded_and_forwarded_to_every_measured_worker(self):
        for mode in ("table", "userdata"):
            with self.subTest(proxy_mode=mode):
                environment, docker = self.run_case(proxy_mode=mode)
                self.assertEqual(mode, environment.get("proxy_mode"))
                workers = [command for command in docker.commands
                           if any(part.endswith("/memory-phases.lua") for part in command)]
                self.assertEqual(2, len(workers))
                for command in workers:
                    self.assertEqual(mode, command[-1])

    def test_mutable_tag_is_resolved_once_and_every_container_executes_its_id(self):
        for runtime_image in (False, True):
            with self.subTest(runtime_image=runtime_image):
                environment, docker = self.run_case(runtime_image=runtime_image)
                self.assertEqual(IMAGE_TAG, environment["image"])
                self.assertEqual(IMAGE_ID, environment["image_id"])
                self.assertGreaterEqual(len(docker.commands), 5)

    def test_packaged_lua_digest_hashes_names_and_contents_not_archive_metadata(self):
        environment, docker = self.run_case(enforce_pin=False)
        expected = hashlib.sha256()
        for name, content in sorted(LUA_FILES.items(), key=lambda item: Path(item[0])):
            expected.update(name.encode() + b"\0" + content + b"\0")
        self.assertEqual(expected.hexdigest(), environment["runtime"]["lua_sha256"])
        self.assertEqual(2, docker.tar_calls)

    def test_packaged_lua_change_is_rejected_even_when_native_hash_stays_identical(self):
        with self.assertRaisesRegex(AssertionError, "runtime changed during measurement"):
            self.run_case(enforce_pin=False, mutate_lua=True)


if __name__ == "__main__":
    unittest.main()

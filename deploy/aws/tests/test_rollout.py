"""Exercise container handoff and rollback against stateful Docker/AWS doubles.

Run in an isolated Linux container as root (the production script uses /srv
and /var/lock). No AWS calls or Docker daemon access are made by these tests.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

IMAGE = "123456789012.dkr.ecr.us-east-1.amazonaws.com/reno:" + "a" * 40
SCRIPT = Path(__file__).resolve().parents[1] / "rollout-ec2.sh"


def mock_command():
    path = Path(os.environ["MOCK_STATE"])
    state = json.loads(path.read_text())
    tool, *args = sys.argv[2:]
    state["calls"].append([tool, *args])
    result, code = "", 0
    containers = state["containers"]
    if tool == "aws":
        result = "mock-token"
    elif tool == "docker":
        command = args[0]
        target = args[-1]
        if command == "pull" and state["scenario"] == "pull-failure":
            code = 1
        elif command == "inspect":
            if target not in containers:
                code = 1
            elif "--format" in args:
                fmt = args[args.index("--format") + 1]
                container = containers[target]
                if fmt == "{{.State.Running}}":
                    result = "true" if container["running"] else "false"
                elif "Config.Image" in fmt:
                    result = container["image"] + " " + container["health"]
                elif "State.Status" in fmt:
                    result = ("running " if container["running"] else "exited ") + container["health"]
                else:
                    result = container["health"]
        elif command == "create":
            name = args[args.index("--name") + 1]
            containers[name] = {"running": False, "image": IMAGE, "health": "healthy"}
        elif command == "stop":
            if target in containers:
                containers[target]["running"] = False
        elif command == "rename":
            old, new = args[-2:]
            if new in containers or old not in containers:
                code = 1
            else:
                containers[new] = containers.pop(old)
        elif command == "start":
            containers[target]["running"] = True
            if target.startswith("reno-candidate") and state["scenario"] == "candidate-exits":
                containers[target]["running"] = False
                containers[target]["health"] = "unhealthy"
        elif command == "rm":
            containers.pop(target, None)
        elif command == "ps":
            result = "\n".join(name for name in containers if name.startswith("reno-rollback-"))
    path.write_text(json.dumps(state))
    if result:
        print(result)
    raise SystemExit(code)


class RolloutTests(unittest.TestCase):
    def run_scenario(self, scenario):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            state_path = directory / "state.json"
            state_path.write_text(json.dumps({"scenario": scenario, "calls": [], "containers": {
                "reno": {"running": True, "health": "healthy", "image": IMAGE if scenario == "already-live" else "reno:old"}
            }}))
            for command in ("docker", "aws"):
                wrapper = directory / command
                wrapper.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{Path(__file__).resolve()}" --mock {command} "$@"\n')
                wrapper.chmod(0o755)
            config = Path("/srv/reno/config")
            config.mkdir(parents=True, exist_ok=True)
            (config / "config.txt").write_text("HUB\n")
            result = subprocess.run(["bash", str(SCRIPT), "--image-uri", IMAGE, "--public-ip", "192.0.2.1"],
                env={**os.environ, "PATH": str(directory) + ":" + os.environ["PATH"], "MOCK_STATE": str(state_path)},
                capture_output=True, text=True, timeout=15)
            return result, json.loads(state_path.read_text())

    def test_success_promotes_candidate_and_retains_previous_container(self):
        result, state = self.run_scenario("success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["containers"]["reno"]["image"], IMAGE)
        self.assertTrue(state["containers"]["reno"]["running"])
        backups = [item for name, item in state["containers"].items() if name.startswith("reno-rollback-")]
        self.assertEqual(len(backups), 1)
        self.assertFalse(backups[0]["running"])
        calls = [call[1] for call in state["calls"] if call[0] == "docker"]
        self.assertLess(calls.index("pull"), calls.index("stop"))

    def test_pull_failure_keeps_current_server_running(self):
        result, state = self.run_scenario("pull-failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(state["containers"]["reno"]["running"])
        self.assertEqual(state["containers"]["reno"]["image"], "reno:old")

    def test_candidate_exit_restores_old_server(self):
        result, state = self.run_scenario("candidate-exits")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["containers"]["reno"]["image"], "reno:old")
        self.assertTrue(state["containers"]["reno"]["running"])
        self.assertEqual(list(state["containers"]), ["reno"])

    def test_retry_of_healthy_live_image_does_not_stop_it(self):
        result, state = self.run_scenario("already-live")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(call[:2] == ["docker", "stop"] for call in state["calls"]))

    def test_missing_argument_returns_usage(self):
        result = subprocess.run(["bash", str(SCRIPT), "--image-uri"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 64)


class HealthcheckTests(unittest.TestCase):
    def check(self, current_log, previous_log="Initializations complete within 1 seconds!\n"):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / ".startup-log-directory").write_text("current\n")
            for name, content in (("current", current_log), ("previous", previous_log)):
                directory = root / "data/logs" / name
                directory.mkdir(parents=True)
                (directory / "runtime.log").write_text(content)
            nc = root / "nc"
            nc.write_text("#!/bin/sh\nexit 0\n")
            nc.chmod(0o755)
            return subprocess.run(["sh", str(SCRIPT.parents[1] / "../docker/healthcheck.sh")],
                env={**os.environ, "SERVER_ROOT": str(root), "PATH": str(root) + ":" + os.environ["PATH"]},
                capture_output=True, timeout=5).returncode

    def test_old_saved_completion_does_not_qualify_new_startup(self):
        self.assertNotEqual(self.check("Loading Reno...\n"), 0)

    def test_current_startup_completion_is_healthy(self):
        self.assertEqual(self.check("Loading Reno...\nInitializations complete within 45 seconds!\n"), 0)

    def test_failed_map_does_not_qualify_even_after_initialization(self):
        self.assertNotEqual(self.check("RED ALERT! The following map files failed to load: Reno.dmm\nInitializations complete within 45 seconds!\n"), 0)


if __name__ == "__main__":
    if sys.argv[1:2] == ["--mock"]:
        mock_command()
    unittest.main()

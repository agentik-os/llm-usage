import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

FILE = Path(__file__).resolve().parents[2] / "Integrations/hermes-headroom/__init__.py"
spec = importlib.util.spec_from_file_location("headroom_local", FILE)
plugin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plugin)


class HeadroomMiddlewareTests(unittest.TestCase):
    def run_hook(self, original, name="terminal", args=None):
        calls = []
        def execute(value):
            calls.append(value)
            return original
        result = plugin.compress_tool_output(tool_name=name, args=args or {"command": "rg example ."}, next_call=execute)
        self.assertEqual(len(calls), 1)
        return result

    def test_outage_preserves_original_and_executes_once(self):
        original = json.dumps({"output": "data\n" * 1000, "exit_code": 0})
        with patch.object(plugin, "_post", side_effect=TimeoutError):
            self.assertIs(self.run_hook(original), original)

    def test_terminal_envelope_preserved_without_mutation(self):
        original = {"output": "path:1:match\n" * 1000, "exit_code": 0, "stderr": "", "session_id": 123}
        snapshot = dict(original)
        def compress(payload):
            messages = payload["messages"]
            return {"messages": [messages[0], dict(messages[1], content="path\n1:match [repeated 1000 times]")],
                    "tokens_before": 5000, "tokens_after": 15, "ccr_hashes": []}
        with patch.object(plugin, "_post", side_effect=compress):
            result = self.run_hook(original)
        self.assertEqual(original, snapshot)
        self.assertEqual({k:v for k,v in result.items() if k != "output"}, {k:v for k,v in original.items() if k != "output"})
        self.assertLess(len(result["output"]), len(original["output"]))

    def test_file_reads_and_failed_tools_are_untouched(self):
        original = "file contents\n" * 500
        with patch.object(plugin, "_post") as post:
            self.assertIs(self.run_hook(original, "read_file"), original)
            self.assertIs(self.run_hook(original, args={"command": "sed -n '1,10p' file.py"}), original)
            failed = {"output": original, "exit_code": 1}
            self.assertIs(self.run_hook(failed), failed)
            post.assert_not_called()

    def test_tool_exception_is_not_swallowed_or_retried(self):
        calls = []
        def execute(args):
            calls.append(args)
            raise RuntimeError("real tool failure")
        with self.assertRaisesRegex(RuntimeError, "real tool failure"):
            plugin.compress_tool_output(tool_name="terminal", args={}, next_call=execute)
        self.assertEqual(len(calls), 1)

    def test_invalid_response_is_ignored(self):
        original = "data\n" * 1000
        with patch.object(plugin, "_post", return_value={"messages": [{"role": "system", "content": "changed"}]}):
            self.assertIs(self.run_hook(original, "search"), original)


if __name__ == "__main__":
    unittest.main()

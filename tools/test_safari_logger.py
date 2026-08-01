import csv
import io
import json
import tempfile
import threading
import unittest
import uuid
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from tools.safari_logger import LoggerHTTPServer, LoggerStore, load_or_create_token


class LoggerStoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.store = LoggerStore(Path(self.temporary_directory.name) / "logger.sqlite3")

    def tearDown(self):
        self.temporary_directory.cleanup()

    def test_checkpoint_rejects_stale_revision(self):
        current = self.store.checkpoint(8, "running", False, 4)
        stale = self.store.checkpoint(2, "walking", False, 3)

        self.assertEqual(current["count"], 8)
        self.assertFalse(stale["accepted"])
        self.assertEqual(stale["count"], 8)
        self.assertEqual(stale["baseMode"], "running")

    def test_submit_is_idempotent_and_resets_counter(self):
        observation_id = str(uuid.uuid4())
        self.store.checkpoint(47, "walking", False, 1)
        first = self.store.submit(
            observation_id,
            47,
            "walking",
            "walking",
            "2026-07-30T10:00:00.000Z",
            1,
        )
        second = self.store.submit(
            observation_id,
            47,
            "walking",
            "walking",
            "2026-07-30T10:00:00.000Z",
            first["revision"],
        )

        self.assertEqual(first["count"], 0)
        self.assertEqual(second["observationCount"], 1)
        self.assertEqual(len(self.store.observations()), 1)

    def test_undo_add_restores_mixed_mode_and_exact_sum(self):
        observation_id = str(uuid.uuid4())
        submitted = self.store.submit(
            observation_id,
            38,
            "mixed_uncertain",
            "running",
            "2026-07-30T10:00:00.000Z",
            1,
        )
        revision = submitted["revision"] + 1
        self.store.checkpoint(4, "running", False, revision)

        undone = self.store.undo(4, "add", revision)

        self.assertEqual(undone["count"], 42)
        self.assertEqual(undone["baseMode"], "running")
        self.assertTrue(undone["mixed"])
        self.assertEqual(undone["observationCount"], 0)

    def test_exports_preserve_one_observation_per_row(self):
        self.store.submit(
            str(uuid.uuid4()),
            12,
            "walking",
            "walking",
            "2026-07-30T10:00:00.000Z",
            1,
        )

        rows = list(csv.reader(io.StringIO(self.store.export_csv().decode("utf-8"))))
        document = json.loads(self.store.export_json())

        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[1][4], "12")
        self.assertEqual(document["observations"][0]["stepCount"], 12)


class LoggerHTTPTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        root = Path(self.temporary_directory.name)
        self.token = load_or_create_token(root / "access.token")
        self.server = LoggerHTTPServer(
            ("127.0.0.1", 0),
            LoggerStore(root / "logger.sqlite3"),
            self.token,
        )
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.temporary_directory.cleanup()

    def test_health_is_public_but_logger_state_requires_token(self):
        with urlopen(self.base_url + "/health", timeout=2) as response:
            self.assertEqual(json.load(response), {"status": "ok"})

        with self.assertRaises(HTTPError) as context:
            urlopen(self.base_url + "/api/state", timeout=2)
        try:
            self.assertEqual(context.exception.code, 404)
        finally:
            context.exception.close()

        request = Request(
            self.base_url + "/api/state",
            headers={"X-Logger-Token": self.token},
        )
        with urlopen(request, timeout=2) as response:
            state = json.load(response)
        self.assertEqual(state["count"], 0)
        self.assertEqual(state["baseMode"], "walking")


if __name__ == "__main__":
    unittest.main()

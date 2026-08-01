#!/usr/bin/env python3
"""Deterministic unit and loopback tests for adventurebar_receiver.py."""

from __future__ import annotations

import csv
import hashlib
import hmac
import http.client
import io
import json
import sqlite3
import tempfile
import threading
import unittest
from pathlib import Path

try:
    from . import adventurebar_receiver as receiver
except ImportError:  # Direct execution from tools/.
    import adventurebar_receiver as receiver


FIXED_TIME = 1_750_000_000
SECRET = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"


def valid_csv_bytes() -> bytes:
    buffer = io.StringIO(newline="")
    writer = csv.DictWriter(buffer, fieldnames=sorted(receiver.REQUIRED_CSV_COLUMNS))
    writer.writeheader()
    writer.writerow(
        {
            "session_id": "11111111-1111-1111-1111-111111111111",
            "session_name": "Test, Session",
            "observation_id": "22222222-2222-2222-2222-222222222222",
            "encounter_number": "1",
            "step_count": "68",
            "movement_mode": "Walking",
            "submitted_at": "2026-07-29T12:00:00Z",
            "last_edited_at": "",
            "measurement_uncertainty": "1",
            "source": "iPhone logger",
            "questionable": "false",
            "questionable_reason": "",
            "note": "quoted \"note\"",
        }
    )
    return buffer.getvalue().encode("utf-8")


def valid_json_bytes(step_count: int = 68) -> bytes:
    return json.dumps(
        {
            "schemaVersion": 1,
            "sessions": [
                {
                    "id": "11111111-1111-1111-1111-111111111111",
                    "name": "Test Session",
                    "gameVersion": "Nintendo Switch",
                }
            ],
            "observations": [
                {
                    "id": "22222222-2222-2222-2222-222222222222",
                    "sessionID": "11111111-1111-1111-1111-111111111111",
                    "encounterNumber": 1,
                    "stepCount": step_count,
                    "movementMode": "walking",
                    "submittedAt": "2026-07-29T12:00:00Z",
                    "measurementUncertainty": 1,
                    "source": "iPhone logger",
                    "auditHistory": [],
                }
            ],
        },
        separators=(",", ":"),
    ).encode("utf-8")


def full_snapshot_json_bytes(
    observation_ids: tuple[str, ...],
    *,
    exported_at: str | None = None,
    store_last_modified_at: str | None = None,
    step_base: int = 60,
    source_store_id: str | None = None,
    source_mutation_sequence: int | None = None,
    session_id: str = "11111111-1111-1111-1111-111111111111",
) -> bytes:
    document = {
            "schemaVersion": 1,
            "content": "observationsAndSessionMetadata",
            "sessions": [
                {
                    "id": session_id,
                    "name": "Test Session",
                    "gameVersion": "Nintendo Switch",
                }
            ],
            "observations": [
                {
                    "id": observation_id,
                    "sessionID": session_id,
                    "encounterNumber": index,
                    "stepCount": step_base + index,
                    "movementMode": "walking",
                    "submittedAt": f"2026-07-29T12:00:{index:02d}Z",
                    "measurementUncertainty": 1,
                    "source": "iPhone logger",
                    "auditHistory": [],
                }
                for index, observation_id in enumerate(observation_ids, start=1)
            ],
        }
    if exported_at is not None:
        document["exportedAt"] = exported_at
    if store_last_modified_at is not None:
        document["storeLastModifiedAt"] = store_last_modified_at
    if source_store_id is not None:
        document["sourceStoreID"] = source_store_id
    if source_mutation_sequence is not None:
        document["sourceMutationSequence"] = source_mutation_sequence
    return json.dumps(document, separators=(",", ":")).encode("utf-8")


def multi_session_snapshot_json_bytes(
    entries: tuple[tuple[str, str, int], ...],
    *,
    exported_at: str,
    source_store_id: str,
    source_mutation_sequence: int,
) -> bytes:
    session_ids = list(dict.fromkeys(session_id for session_id, _, _ in entries))
    encounter_numbers: dict[str, int] = {}
    observations: list[dict[str, object]] = []
    for session_id, observation_id, step_count in entries:
        encounter_numbers[session_id] = encounter_numbers.get(session_id, 0) + 1
        observations.append(
            {
                "id": observation_id,
                "sessionID": session_id,
                "encounterNumber": encounter_numbers[session_id],
                "stepCount": step_count,
                "movementMode": "walking",
                "submittedAt": exported_at,
                "measurementUncertainty": 1,
                "source": "iPhone logger",
                "auditHistory": [],
            }
        )
    return json.dumps(
        {
            "schemaVersion": 1,
            "content": "observationsAndSessionMetadata",
            "exportedAt": exported_at,
            "sourceStoreID": source_store_id,
            "sourceMutationSequence": source_mutation_sequence,
            "sessions": [
                {"id": session_id, "name": f"Session {index}", "gameVersion": "Nintendo Switch"}
                for index, session_id in enumerate(session_ids, start=1)
            ],
            "observations": observations,
        },
        separators=(",", ":"),
    ).encode("utf-8")


def signed_headers(
    body: bytes,
    *,
    filename: str = "AdventureBar_Test.json",
    content_type: str = "application/json",
    timestamp: int = FIXED_TIME,
    nonce: str = "123e4567-e89b-12d3-a456-426614174000",
    secret: str = SECRET,
) -> dict[str, str]:
    body_hash = hashlib.sha256(body).hexdigest()
    canonical = receiver.build_canonical_request(
        "POST",
        "/upload",
        str(timestamp),
        nonce,
        content_type,
        filename,
        body_hash,
    )
    signature = hmac.new(bytes.fromhex(secret), canonical.encode("utf-8"), hashlib.sha256).hexdigest()
    return {
        "Content-Type": content_type,
        "Content-Length": str(len(body)),
        receiver.FILENAME_HEADER: filename,
        receiver.TIMESTAMP_HEADER: str(timestamp),
        receiver.NONCE_HEADER: nonce,
        receiver.CONTENT_SHA256_HEADER: body_hash,
        receiver.SIGNATURE_HEADER: f"v1={signature}",
    }


class ValidationTests(unittest.TestCase):
    def test_valid_json_and_csv_counts(self) -> None:
        self.assertEqual(receiver.validate_json(valid_json_bytes()), 1)
        self.assertEqual(receiver.validate_csv(valid_csv_bytes()), 1)

    def test_invalid_json_schema_is_rejected(self) -> None:
        with self.assertRaises(receiver.UploadValidationError):
            receiver.validate_json(b'{"unrelated":true}')

    def test_csv_missing_column_is_rejected(self) -> None:
        with self.assertRaises(receiver.UploadValidationError):
            receiver.validate_csv(b"session_id,step_count\nx,4\n")

    def test_csv_short_row_is_rejected(self) -> None:
        header = ",".join(sorted(receiver.REQUIRED_CSV_COLUMNS))
        with self.assertRaises(receiver.UploadValidationError):
            receiver.validate_csv((header + "\nonly-one-value\n").encode())

    def test_filename_is_restricted_to_safe_characters(self) -> None:
        safe = receiver._safe_filename("../../bad name;$(x).json", "json")
        self.assertEqual(safe, "bad_name_x.json")
        self.assertNotIn("/", safe)
        self.assertNotIn("\\", safe)

    def test_unique_save_never_overwrites(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            first = receiver.save_unique(output, "data.json", "json", b"one")
            second = receiver.save_unique(output, "data.json", "json", b"two")
            self.assertNotEqual(first, second)
            self.assertEqual(first.read_bytes(), b"one")
            self.assertEqual(second.read_bytes(), b"two")

    def test_signature_vector_exactly_matches_swift_test(self) -> None:
        body = b'{"sessions":[],"observations":[]}'
        headers = signed_headers(body)
        self.assertEqual(
            headers[receiver.CONTENT_SHA256_HEADER],
            "872b471c1c219036676622e2aaa862b5065f3054104774175987950307851cfd",
        )
        self.assertEqual(
            headers[receiver.SIGNATURE_HEADER],
            "v1=30337b005da1b96e8570a187340c8e05361f9fabdfe8899fe49e354e838ba92c",
        )

    def test_generate_secret_file_is_exclusive_and_valid(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "receiver.secret"
            created = receiver.generate_secret_file(path)
            self.assertRegex(created.read_text().strip(), r"^[0-9a-f]{64}$")
            with self.assertRaises(FileExistsError):
                receiver.generate_secret_file(path)

    def test_database_migration_adds_current_state_columns_idempotently(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            database = Path(temporary) / "legacy.sqlite3"
            connection = sqlite3.connect(database)
            try:
                connection.executescript(
                    """
                    CREATE TABLE uploads (
                        upload_id INTEGER PRIMARY KEY AUTOINCREMENT,
                        received_at TEXT NOT NULL,
                        original_filename TEXT NOT NULL,
                        stored_path TEXT NOT NULL UNIQUE,
                        media_type TEXT NOT NULL,
                        payload_sha256 TEXT NOT NULL,
                        observation_count INTEGER NOT NULL,
                        remote_address TEXT NOT NULL
                    );
                    CREATE TABLE observations (
                        observation_id TEXT PRIMARY KEY,
                        session_id TEXT,
                        encounter_number INTEGER,
                        step_count INTEGER NOT NULL,
                        movement_mode TEXT NOT NULL,
                        submitted_at TEXT,
                        last_edited_at TEXT,
                        measurement_uncertainty INTEGER,
                        source TEXT,
                        questionable INTEGER,
                        questionable_reason TEXT,
                        note TEXT,
                        audit_history_json TEXT NOT NULL,
                        raw_json TEXT NOT NULL,
                        first_upload_id INTEGER NOT NULL,
                        last_upload_id INTEGER NOT NULL,
                        first_seen_at TEXT NOT NULL,
                        last_seen_at TEXT NOT NULL
                    );
                    INSERT INTO uploads VALUES (
                        1, '2026-01-01T00:00:00Z', 'old.json', 'old.json',
                        'application/json', 'hash', 1, '127.0.0.1'
                    );
                    INSERT INTO observations VALUES (
                        'legacy-observation', 'legacy-session', 1, 12, 'walking',
                        NULL, NULL, 1, 'legacy', 0, NULL, NULL, '[]', '{}',
                        1, 1, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z'
                    );
                    """
                )
                connection.commit()
            finally:
                connection.close()

            receiver.initialize_database(database)
            receiver.initialize_database(database)
            connection = sqlite3.connect(database)
            try:
                upload = connection.execute(
                    """SELECT snapshot_scope, is_full_snapshot, exported_at,
                              store_last_modified_at, snapshot_order_us,
                              membership_decision, source_store_id,
                              source_mutation_sequence
                       FROM uploads"""
                ).fetchone()
                observation = connection.execute(
                    "SELECT is_current, managed_by_full_snapshot FROM observations"
                ).fetchone()
                version = connection.execute(
                    "SELECT value FROM schema_metadata WHERE key='schema_version'"
                ).fetchone()[0]
                source_table_exists = connection.execute(
                    """SELECT COUNT(*) FROM sqlite_master
                       WHERE type='table' AND name='snapshot_sources'"""
                ).fetchone()[0]
            finally:
                connection.close()
            self.assertEqual(
                upload,
                ("partial", 0, None, None, None, "not_authoritative", None, None),
            )
            self.assertEqual(observation, (1, 0))
            self.assertEqual(version, str(receiver.DATABASE_SCHEMA_VERSION))
            self.assertEqual(source_table_exists, 1)


class ReceiverHTTPTestCase(unittest.TestCase):
    require_auth = False

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.server = receiver.create_server(
            "127.0.0.1",
            0,
            self.root,
            require_auth=self.require_auth,
            auth_secret_hex=SECRET if self.require_auth else "",
            clock=lambda: FIXED_TIME,
        )
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.host, self.port = self.server.server_address[:2]

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.temporary.cleanup()

    def request(
        self,
        method: str,
        path: str,
        body: bytes | None = None,
        headers: dict[str, str] | None = None,
    ) -> tuple[int, dict[str, object]]:
        connection = http.client.HTTPConnection(self.host, self.port, timeout=3)
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        decoded = json.loads(response.read().decode("utf-8"))
        status = response.status
        connection.close()
        return status, decoded

    def table_count(self, table: str) -> int:
        connection = sqlite3.connect(self.server.database_path)
        try:
            return int(connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0])
        finally:
            connection.close()


class HTTPTests(ReceiverHTTPTestCase):
    def test_health_endpoint_is_generic(self) -> None:
        status, response = self.request("GET", "/health")
        self.assertEqual(status, 200)
        self.assertEqual(response, {"status": "ok"})

    def test_unknown_endpoint_does_not_disclose_protocol(self) -> None:
        status, response = self.request("GET", "/anything")
        self.assertEqual(status, 404)
        self.assertEqual(response, {"error": "not found"})

    def test_valid_json_upload_is_raw_saved_and_indexed(self) -> None:
        body = valid_json_bytes()
        status, response = self.request(
            "POST",
            "/upload",
            body,
            {
                "Content-Type": "application/json",
                "Content-Length": str(len(body)),
                receiver.FILENAME_HEADER: "../../My Unsafe Export.json",
            },
        )
        self.assertEqual(status, 201)
        self.assertEqual(response["observationCount"], 1)
        files = list(self.server.raw_upload_dir.iterdir())
        self.assertEqual(len(files), 1)
        self.assertTrue(files[0].name.endswith("_My_Unsafe_Export.json"))
        self.assertEqual(files[0].read_bytes(), body)
        self.assertEqual(self.table_count("uploads"), 1)
        self.assertEqual(self.table_count("sessions"), 1)
        self.assertEqual(self.table_count("observations"), 1)
        self.assertEqual(self.table_count("upload_observations"), 1)

    def test_valid_csv_upload_is_saved(self) -> None:
        body = valid_csv_bytes()
        status, response = self.request(
            "POST",
            "/upload",
            body,
            {
                "Content-Type": "text/csv; charset=utf-8",
                "Content-Length": str(len(body)),
                receiver.FILENAME_HEADER: "AdventureBar.csv",
            },
        )
        self.assertEqual(status, 201)
        self.assertEqual(response["observationCount"], 1)
        self.assertEqual(self.table_count("observations"), 1)

    def test_malformed_upload_is_not_saved_or_indexed(self) -> None:
        body = b'{"not":"an export"}'
        status, response = self.request(
            "POST",
            "/upload",
            body,
            {
                "Content-Type": "application/json",
                "Content-Length": str(len(body)),
                receiver.FILENAME_HEADER: "bad.json",
            },
        )
        self.assertEqual(status, 400)
        self.assertIn("error", response)
        self.assertFalse(self.server.raw_upload_dir.exists())
        self.assertEqual(self.table_count("uploads"), 0)

    def test_extension_mismatch_is_rejected(self) -> None:
        body = valid_json_bytes()
        status, _ = self.request(
            "POST",
            "/upload",
            body,
            {
                "Content-Type": "application/json",
                "Content-Length": str(len(body)),
                receiver.FILENAME_HEADER: "wrong.csv",
            },
        )
        self.assertEqual(status, 400)

    def test_later_full_snapshot_tombstones_absent_uuid_but_preserves_history(self) -> None:
        first_ids = (
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        )
        first = full_snapshot_json_bytes(first_ids)
        second = full_snapshot_json_bytes((first_ids[0],))
        filename = "AdventureBar_AllSessions_20260730_120000.json"
        for body in (first, second):
            status, _ = self.request(
                "POST",
                "/upload",
                body,
                {
                    "Content-Type": "application/json",
                    "Content-Length": str(len(body)),
                    receiver.FILENAME_HEADER: filename,
                },
            )
            self.assertEqual(status, 201)

        connection = sqlite3.connect(self.server.database_path)
        try:
            states = dict(
                connection.execute(
                    "SELECT observation_id, is_current FROM observations"
                ).fetchall()
            )
            second_tombstone = connection.execute(
                """SELECT tombstoned_by_upload_id FROM observations
                   WHERE observation_id = ?""",
                (first_ids[1],),
            ).fetchone()[0]
            events = connection.execute(
                """SELECT is_current, reason FROM observation_membership_events
                   WHERE observation_id = ? ORDER BY event_id""",
                (first_ids[1],),
            ).fetchall()
            upload_metadata = connection.execute(
                """SELECT content_kind, snapshot_scope, is_full_snapshot
                   FROM uploads ORDER BY upload_id"""
            ).fetchall()
            membership_rows = connection.execute(
                "SELECT COUNT(*) FROM upload_observations"
            ).fetchone()[0]
        finally:
            connection.close()

        self.assertEqual(states[first_ids[0]], 1)
        self.assertEqual(states[first_ids[1]], 0)
        self.assertEqual(second_tombstone, 2)
        self.assertEqual(
            events,
            [
                (1, "first_seen"),
                (0, "absent_from_full_all_sessions_snapshot"),
            ],
        )
        self.assertEqual(
            upload_metadata,
            [
                ("observationsAndSessionMetadata", "all_sessions", 1),
                ("observationsAndSessionMetadata", "all_sessions", 1),
            ],
        )
        self.assertEqual(membership_rows, 3)
        raw_payloads = {path.read_bytes() for path in self.server.raw_upload_dir.iterdir()}
        self.assertEqual(raw_payloads, {first, second})

    def test_partial_upload_is_not_erased_by_unrelated_full_snapshot(self) -> None:
        partial_document = json.loads(valid_json_bytes())
        partial_id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        partial_document["observations"][0]["id"] = partial_id
        partial = json.dumps(partial_document, separators=(",", ":")).encode("utf-8")
        full = full_snapshot_json_bytes(
            ("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",)
        )

        for body, filename in (
            (partial, "Compatible_Manual_Observations.json"),
            (full, "AdventureBar_AllSessions_20260730_120001.json"),
        ):
            status, _ = self.request(
                "POST",
                "/upload",
                body,
                {
                    "Content-Type": "application/json",
                    "Content-Length": str(len(body)),
                    receiver.FILENAME_HEADER: filename,
                },
            )
            self.assertEqual(status, 201)

        connection = sqlite3.connect(self.server.database_path)
        try:
            current, managed = connection.execute(
                """SELECT is_current, managed_by_full_snapshot FROM observations
                   WHERE observation_id = ?""",
                (partial_id,),
            ).fetchone()
        finally:
            connection.close()
        self.assertEqual((current, managed), (1, 0))

    def test_out_of_order_and_equal_full_snapshots_do_not_roll_membership_back(self) -> None:
        observation_a = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        observation_b = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        observation_c = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        uploads = (
            full_snapshot_json_bytes(
                (observation_a,), exported_at="2026-07-30T12:00:02Z", step_base=100
            ),
            full_snapshot_json_bytes(
                (observation_a, observation_b),
                exported_at="2026-07-30T12:00:01Z",
                step_base=200,
            ),
            full_snapshot_json_bytes(
                (observation_a, observation_c),
                exported_at="2026-07-30T12:00:02Z",
                step_base=300,
            ),
        )
        for body in uploads:
            status, _ = self.request(
                "POST", "/upload", body,
                {
                    "Content-Type": "application/json",
                    "Content-Length": str(len(body)),
                    receiver.FILENAME_HEADER: "AdventureBar_AllSessions_Ordered.json",
                },
            )
            self.assertEqual(status, 201)

        connection = sqlite3.connect(self.server.database_path)
        try:
            rows = connection.execute(
                """SELECT observation_id, step_count, is_current
                   FROM observations ORDER BY observation_id"""
            ).fetchall()
            decisions = connection.execute(
                "SELECT membership_decision FROM uploads ORDER BY upload_id"
            ).fetchall()
            watermark_upload = connection.execute(
                """SELECT upload_id FROM authoritative_snapshot_watermarks
                   WHERE scope_key='all_sessions'"""
            ).fetchone()[0]
        finally:
            connection.close()
        self.assertEqual(
            rows,
            [
                (observation_a, 101, 1),
                (observation_b, 202, 0),
                (observation_c, 302, 0),
            ],
        )
        self.assertEqual(decisions, [("applied",), ("stale_ignored",), ("stale_ignored",)])
        self.assertEqual(watermark_upload, 1)
        self.assertEqual(self.table_count("upload_observations"), 5)
        self.assertEqual(len(list(self.server.raw_upload_dir.iterdir())), 3)

    def test_store_last_modified_time_orders_snapshots_before_export_time(self) -> None:
        observation_a = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        observation_b = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        newer_state = full_snapshot_json_bytes(
            (observation_a,),
            exported_at="2026-07-30T12:00:03Z",
            store_last_modified_at="2026-07-30T12:00:02Z",
        )
        older_state_exported_later = full_snapshot_json_bytes(
            (observation_a, observation_b),
            exported_at="2026-07-30T12:00:04Z",
            store_last_modified_at="2026-07-30T12:00:01Z",
        )
        for body in (newer_state, older_state_exported_later):
            status, _ = self.request(
                "POST", "/upload", body,
                {
                    "Content-Type": "application/json",
                    "Content-Length": str(len(body)),
                    receiver.FILENAME_HEADER: "AdventureBar_AllSessions_StoreOrdered.json",
                },
            )
            self.assertEqual(status, 201)
        connection = sqlite3.connect(self.server.database_path)
        try:
            current_b, decision = connection.execute(
                """SELECT o.is_current, u.membership_decision
                   FROM observations o JOIN uploads u ON u.upload_id = 2
                   WHERE o.observation_id = ?""",
                (observation_b,),
            ).fetchone()
        finally:
            connection.close()
        self.assertEqual((current_b, decision), (0, "stale_ignored"))

    def test_source_sequence_and_epoch_retirement_override_wall_clock_order(self) -> None:
        source_one = "10000000-0000-4000-8000-000000000001"
        source_two = "20000000-0000-4000-8000-000000000002"
        observation_a = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        observation_b = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        snapshots = (
            full_snapshot_json_bytes(
                (observation_a,), exported_at="2026-07-30T12:00:10Z",
                source_store_id=source_one, source_mutation_sequence=10,
            ),
            full_snapshot_json_bytes(
                (observation_b,), exported_at="2026-07-30T12:00:01Z",
                source_store_id=source_two, source_mutation_sequence=1,
            ),
            full_snapshot_json_bytes(
                (observation_a,), exported_at="2026-07-30T12:00:20Z",
                source_store_id=source_one, source_mutation_sequence=11,
            ),
            full_snapshot_json_bytes(
                (observation_a, observation_b), exported_at="2026-07-30T12:00:30Z",
                source_store_id=source_two, source_mutation_sequence=1,
            ),
        )
        for body in snapshots:
            status, _ = self.request(
                "POST", "/upload", body,
                {
                    "Content-Type": "application/json",
                    "Content-Length": str(len(body)),
                    receiver.FILENAME_HEADER: "AdventureBar_AllSessions_SourceOrdered.json",
                },
            )
            self.assertEqual(status, 201)

        connection = sqlite3.connect(self.server.database_path)
        try:
            states = dict(connection.execute(
                "SELECT observation_id, is_current FROM observations"
            ).fetchall())
            decisions = [row[0] for row in connection.execute(
                "SELECT membership_decision FROM uploads ORDER BY upload_id"
            ).fetchall()]
            sources = connection.execute(
                """SELECT source_store_id, is_active, max_mutation_sequence
                   FROM snapshot_sources ORDER BY source_store_id"""
            ).fetchall()
        finally:
            connection.close()
        self.assertEqual(states, {observation_a: 0, observation_b: 1})
        self.assertEqual(
            decisions,
            [
                "new_source_epoch_applied",
                "new_source_epoch_applied",
                "retired_source_ignored",
                "equal_generation_scope_ignored",
            ],
        )
        self.assertEqual(sources, [(source_one, 0, "10"), (source_two, 1, "1")])
        self.assertEqual(len(list(self.server.raw_upload_dir.iterdir())), 4)

    def test_equal_generation_listed_then_all_extends_authority(self) -> None:
        source_id = "30000000-0000-4000-8000-000000000003"
        session_one = "11111111-1111-4111-8111-111111111111"
        session_two = "22222222-2222-4222-8222-222222222222"
        observation_a = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        observation_b = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        listed = full_snapshot_json_bytes(
            (observation_a,), exported_at="2026-07-30T12:10:00Z",
            source_store_id=source_id, source_mutation_sequence=5,
            session_id=session_one,
        )
        all_sessions = multi_session_snapshot_json_bytes(
            ((session_one, observation_a, 61), (session_two, observation_b, 62)),
            exported_at="2026-07-30T12:10:01Z",
            source_store_id=source_id,
            source_mutation_sequence=5,
        )
        for body, filename in (
            (listed, "AdventureBar_SelectedSession.json"),
            (all_sessions, "AdventureBar_AllSessions_EqualGeneration.json"),
        ):
            status, _ = self.request(
                "POST", "/upload", body,
                {"Content-Type": "application/json", "Content-Length": str(len(body)),
                 receiver.FILENAME_HEADER: filename},
            )
            self.assertEqual(status, 201)
        connection = sqlite3.connect(self.server.database_path)
        try:
            states = dict(connection.execute(
                "SELECT observation_id, is_current FROM observations"
            ).fetchall())
            decisions = [row[0] for row in connection.execute(
                "SELECT membership_decision FROM uploads ORDER BY upload_id"
            ).fetchall()]
            covered_scopes = {row[0] for row in connection.execute(
                "SELECT scope_key FROM authoritative_snapshot_watermarks"
            ).fetchall()}
        finally:
            connection.close()
        self.assertEqual(states, {observation_a: 1, observation_b: 1})
        self.assertEqual(
            decisions,
            ["new_source_epoch_applied", "equal_generation_scope_extended"],
        )
        self.assertIn("all_sessions", covered_scopes)
        self.assertEqual(len(list(self.server.raw_upload_dir.iterdir())), 2)

    def test_equal_generation_disjoint_listed_sessions_each_apply(self) -> None:
        source_id = "40000000-0000-4000-8000-000000000004"
        session_one = "11111111-1111-4111-8111-111111111111"
        session_two = "22222222-2222-4222-8222-222222222222"
        observation_a = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        observation_b = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        snapshots = (
            full_snapshot_json_bytes(
                (observation_a,), exported_at="2026-07-30T12:20:00Z",
                source_store_id=source_id, source_mutation_sequence=6,
                session_id=session_one,
            ),
            full_snapshot_json_bytes(
                (observation_b,), exported_at="2026-07-30T12:20:00Z",
                source_store_id=source_id, source_mutation_sequence=6,
                session_id=session_two,
            ),
        )
        for index, body in enumerate(snapshots, start=1):
            status, _ = self.request(
                "POST", "/upload", body,
                {"Content-Type": "application/json", "Content-Length": str(len(body)),
                 receiver.FILENAME_HEADER: f"AdventureBar_SelectedSession{index}.json"},
            )
            self.assertEqual(status, 201)
        connection = sqlite3.connect(self.server.database_path)
        try:
            states = dict(connection.execute(
                "SELECT observation_id, is_current FROM observations"
            ).fetchall())
            decisions = [row[0] for row in connection.execute(
                "SELECT membership_decision FROM uploads ORDER BY upload_id"
            ).fetchall()]
        finally:
            connection.close()
        self.assertEqual(states, {observation_a: 1, observation_b: 1})
        self.assertEqual(
            decisions,
            ["new_source_epoch_applied", "equal_generation_scope_extended"],
        )

    def test_equal_generation_all_then_listed_cannot_roll_back(self) -> None:
        source_id = "50000000-0000-4000-8000-000000000005"
        session_id = "11111111-1111-4111-8111-111111111111"
        observation_a = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        observation_b = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        all_sessions = multi_session_snapshot_json_bytes(
            ((session_id, observation_a, 70),),
            exported_at="2026-07-30T12:30:00Z",
            source_store_id=source_id,
            source_mutation_sequence=7,
        )
        conflicting_listed = full_snapshot_json_bytes(
            (observation_a, observation_b), exported_at="2026-07-30T12:30:01Z",
            source_store_id=source_id, source_mutation_sequence=7,
            session_id=session_id, step_base=900,
        )
        for body, filename in (
            (all_sessions, "AdventureBar_AllSessions_First.json"),
            (conflicting_listed, "AdventureBar_SelectedSession_Later.json"),
        ):
            status, _ = self.request(
                "POST", "/upload", body,
                {"Content-Type": "application/json", "Content-Length": str(len(body)),
                 receiver.FILENAME_HEADER: filename},
            )
            self.assertEqual(status, 201)
        connection = sqlite3.connect(self.server.database_path)
        try:
            rows = connection.execute(
                """SELECT observation_id, step_count, is_current
                   FROM observations ORDER BY observation_id"""
            ).fetchall()
            decisions = [row[0] for row in connection.execute(
                "SELECT membership_decision FROM uploads ORDER BY upload_id"
            ).fetchall()]
        finally:
            connection.close()
        self.assertEqual(rows, [(observation_a, 70, 1), (observation_b, 902, 0)])
        self.assertEqual(
            decisions,
            ["new_source_epoch_applied", "equal_generation_scope_ignored"],
        )
        self.assertEqual(self.table_count("upload_observations"), 3)
        self.assertEqual(len(list(self.server.raw_upload_dir.iterdir())), 2)


class AuthenticatedHTTPTests(ReceiverHTTPTestCase):
    require_auth = True

    def test_valid_signed_upload_is_accepted(self) -> None:
        body = valid_json_bytes()
        status, response = self.request("POST", "/upload", body, signed_headers(body))
        self.assertEqual(status, 201)
        self.assertEqual(response["status"], "saved")
        self.assertEqual(self.table_count("auth_nonces"), 1)

    def test_unsigned_and_wrong_signature_are_rejected_without_storage(self) -> None:
        body = valid_json_bytes()
        unsigned = {
            "Content-Type": "application/json",
            "Content-Length": str(len(body)),
            receiver.FILENAME_HEADER: "AdventureBar_Test.json",
        }
        status, response = self.request("POST", "/upload", body, unsigned)
        self.assertEqual(status, 401)
        self.assertEqual(response, {"error": "request rejected"})

        headers = signed_headers(body)
        headers[receiver.SIGNATURE_HEADER] = "v1=" + ("0" * 64)
        status, response = self.request("POST", "/upload", body, headers)
        self.assertEqual(status, 401)
        self.assertEqual(response, {"error": "request rejected"})
        self.assertEqual(self.table_count("uploads"), 0)
        self.assertFalse(self.server.raw_upload_dir.exists())

    def test_stale_timestamp_is_rejected(self) -> None:
        body = valid_json_bytes()
        headers = signed_headers(body, timestamp=FIXED_TIME - 301)
        status, _ = self.request("POST", "/upload", body, headers)
        self.assertEqual(status, 401)
        self.assertEqual(self.table_count("auth_nonces"), 0)

    def test_nonce_replay_is_rejected_even_after_first_upload(self) -> None:
        body = valid_json_bytes()
        headers = signed_headers(body)
        first_status, _ = self.request("POST", "/upload", body, headers)
        second_status, response = self.request("POST", "/upload", body, headers)
        self.assertEqual(first_status, 201)
        self.assertEqual(second_status, 401)
        self.assertEqual(response, {"error": "request rejected"})
        self.assertEqual(self.table_count("uploads"), 1)

    def test_repeated_snapshots_upsert_observation_uuid_without_losing_raw_files(self) -> None:
        first = valid_json_bytes(step_count=68)
        second = valid_json_bytes(step_count=69)
        status, _ = self.request(
            "POST", "/upload", first, signed_headers(first, nonce="00000000-0000-4000-8000-000000000001")
        )
        self.assertEqual(status, 201)
        status, _ = self.request(
            "POST", "/upload", second, signed_headers(second, nonce="00000000-0000-4000-8000-000000000002")
        )
        self.assertEqual(status, 201)
        self.assertEqual(self.table_count("uploads"), 2)
        self.assertEqual(self.table_count("observations"), 1)
        self.assertEqual(self.table_count("upload_observations"), 2)
        self.assertEqual(len(list(self.server.raw_upload_dir.iterdir())), 2)
        connection = sqlite3.connect(self.server.database_path)
        try:
            step_count = connection.execute(
                "SELECT step_count FROM observations WHERE observation_id = ?",
                ("22222222-2222-2222-2222-222222222222",),
            ).fetchone()[0]
        finally:
            connection.close()
        self.assertEqual(step_count, 69)


if __name__ == "__main__":
    unittest.main(verbosity=2)

#!/usr/bin/env python3
"""Receive Adventure Bar Encounter Logger CSV/JSON exports.

The receiver has two explicit modes:

* trusted-LAN mode preserves the original unsigned protocol;
* ``--require-auth`` requires every upload to carry the HMAC-SHA256 protocol
  implemented by the iPhone app.

Accepted payloads are retained unchanged under ``raw_uploads`` and indexed in
SQLite.  The program uses only Python's standard library and performs no
statistical analysis.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import hmac
import io
import json
import os
import re
import secrets
import sqlite3
import sys
import time
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable, Iterator, Mapping
from urllib.parse import unquote, urlsplit


DEFAULT_PORT = 8765
DEFAULT_MAX_UPLOAD_BYTES = 25 * 1024 * 1024
DEFAULT_TIMESTAMP_SKEW_SECONDS = 300
DEFAULT_SECRET_ENV = "ADVENTUREBAR_RECEIVER_SECRET_HEX"
DEFAULT_DATABASE_FILENAME = "AdventureBarReceiver.sqlite3"
PROTOCOL_MARKER = "ABES1"
TIMESTAMP_HEADER = "X-Adventure-Timestamp"
NONCE_HEADER = "X-Adventure-Nonce"
CONTENT_SHA256_HEADER = "X-Adventure-Content-SHA256"
SIGNATURE_HEADER = "X-Adventure-Signature"
FILENAME_HEADER = "X-Filename"

REQUIRED_CSV_COLUMNS = {
    "session_id",
    "session_name",
    "observation_id",
    "encounter_number",
    "step_count",
    "movement_mode",
    "submitted_at",
    "last_edited_at",
    "measurement_uncertainty",
    "source",
    "questionable",
    "questionable_reason",
    "note",
}
ALLOWED_MOVEMENT_MODES = {
    "Walking",
    "Running",
    "Mixed/Uncertain",
    "walking",
    "running",
    "mixedUncertain",
    "mixed_uncertain",
}


class UploadValidationError(ValueError):
    """Raised when an upload is not a supported Adventure Bar export."""


class UploadAuthenticationError(ValueError):
    """Raised internally when an authenticated request cannot be accepted."""


@dataclass(frozen=True)
class ParsedExport:
    sessions: list[dict[str, Any]]
    observations: list[dict[str, Any]]
    content_kind: str | None = None
    declared_scope: str | None = None
    declared_full_snapshot: bool | None = None
    exported_at: str | None = None
    store_last_modified_at: str | None = None
    snapshot_order_us: int | None = None
    source_store_id: str | None = None
    source_mutation_sequence: int | None = None


@dataclass(frozen=True)
class UploadScope:
    """How much current app state an upload authoritatively represents."""

    kind: str
    is_full_snapshot: bool
    session_ids: tuple[str, ...] = ()


def _utc_now_text() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def _safe_filename(name: str, extension: str) -> str:
    """Return a conservative filename with the requested extension."""

    decoded = unquote(name).replace("\\", "/").split("/")[-1]
    stem = Path(decoded).stem
    stem = re.sub(r"[^A-Za-z0-9._-]+", "_", stem).strip("._-")
    if not stem:
        stem = "AdventureBar_Export"
    return f"{stem[:80]}.{extension}"


def _base_content_type(value: str) -> str:
    return value.split(";", 1)[0].strip().lower()


def _extension_for(content_type: str, requested_name: str) -> str:
    media_type = _base_content_type(content_type)
    suffix = Path(unquote(requested_name)).suffix.lower()
    if media_type in {"application/json", "text/json"}:
        expected = "json"
    elif media_type in {"text/csv", "application/csv", "application/vnd.ms-excel"}:
        expected = "csv"
    elif media_type in {"application/octet-stream", ""} and suffix in {".json", ".csv"}:
        expected = suffix[1:]
    else:
        raise UploadValidationError("Content-Type must identify a JSON or CSV file")

    if suffix and suffix != f".{expected}":
        raise UploadValidationError("Filename extension does not match Content-Type")
    return expected


def _observation_candidates(value: Any) -> list[dict[str, Any]] | None:
    if isinstance(value, list) and all(isinstance(item, dict) for item in value):
        return value
    if not isinstance(value, dict):
        return None
    direct = value.get("observations")
    if isinstance(direct, list) and all(isinstance(item, dict) for item in direct):
        return direct
    store = value.get("store")
    if isinstance(store, dict):
        nested = store.get("observations")
        if isinstance(nested, list) and all(isinstance(item, dict) for item in nested):
            return nested
    return None


def _has_any(item: Mapping[str, Any], keys: tuple[str, ...]) -> bool:
    return any(key in item for key in keys)


def _first(item: Mapping[str, Any], keys: tuple[str, ...], default: Any = None) -> Any:
    for key in keys:
        if key in item:
            return item[key]
    return default


def _decode_json(payload: bytes) -> Any:
    try:
        return json.loads(payload.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise UploadValidationError(f"Invalid UTF-8 JSON: {exc}") from exc


def _export_timestamp(value: Any, field_name: str) -> tuple[str | None, int | None]:
    if value is None:
        return None, None
    if not isinstance(value, str) or not value.strip():
        raise UploadValidationError(f"JSON {field_name} must be an ISO 8601 timestamp")
    text = value.strip()
    normalized = text[:-1] + "+00:00" if text.endswith(("Z", "z")) else text
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as exc:
        raise UploadValidationError(f"JSON {field_name} must be an ISO 8601 timestamp") from exc
    if parsed.tzinfo is None:
        raise UploadValidationError(f"JSON {field_name} must include a time zone")
    utc_value = parsed.astimezone(timezone.utc)
    epoch = datetime(1970, 1, 1, tzinfo=timezone.utc)
    delta = utc_value - epoch
    order_us = ((delta.days * 86_400 + delta.seconds) * 1_000_000) + delta.microseconds
    return text, order_us


def _parsed_json_export(payload: bytes) -> ParsedExport:
    decoded = _decode_json(payload)
    observations = _observation_candidates(decoded)
    sessions_value = decoded.get("sessions") if isinstance(decoded, dict) else None
    sessions = sessions_value if isinstance(sessions_value, list) else []
    if not all(isinstance(item, dict) for item in sessions):
        raise UploadValidationError("JSON sessions must be an array of objects")
    if observations is None and not isinstance(sessions_value, list):
        raise UploadValidationError(
            "JSON must contain an observations array, a sessions array, or be an observations array"
        )
    observations = observations or []
    for index, item in enumerate(observations, start=1):
        if not _has_any(item, ("observationID", "observationId", "observation_id", "id")):
            raise UploadValidationError(f"Observation {index} has no observation identifier")
        if not _has_any(item, ("rawStepCount", "stepCount", "step_count")):
            raise UploadValidationError(f"Observation {index} has no step count")
        if not _has_any(item, ("movementMode", "movement_mode")):
            raise UploadValidationError(f"Observation {index} has no movement mode")
        try:
            step_count = int(_first(item, ("rawStepCount", "stepCount", "step_count")))
        except (TypeError, ValueError) as exc:
            raise UploadValidationError(f"Observation {index} has an invalid step count") from exc
        if step_count < 0:
            raise UploadValidationError(f"Observation {index} has a negative step count")
        encounter = _first(item, ("encounterNumber", "encounter_number"))
        if encounter is not None:
            try:
                if int(encounter) < 1:
                    raise ValueError
            except (TypeError, ValueError) as exc:
                raise UploadValidationError(
                    f"Observation {index} has an invalid encounter number"
                ) from exc
    content_kind = decoded.get("content") if isinstance(decoded, dict) else None
    if content_kind is not None and not isinstance(content_kind, str):
        raise UploadValidationError("JSON content must be a string when present")
    declared_scope = None
    declared_full_snapshot = None
    if isinstance(decoded, dict):
        scope_value = decoded.get("exportScope", decoded.get("scope"))
        if scope_value is not None:
            if not isinstance(scope_value, str):
                raise UploadValidationError("JSON export scope must be a string when present")
            declared_scope = scope_value
        fullness_value = decoded.get("isFullSnapshot")
        if fullness_value is not None:
            if not isinstance(fullness_value, bool):
                raise UploadValidationError("JSON isFullSnapshot must be Boolean when present")
            declared_full_snapshot = fullness_value
    exported_at, exported_order = _export_timestamp(
        decoded.get("exportedAt") if isinstance(decoded, dict) else None,
        "exportedAt",
    )
    store_last_modified_at, store_order = _export_timestamp(
        decoded.get("storeLastModifiedAt") if isinstance(decoded, dict) else None,
        "storeLastModifiedAt",
    )
    source_store_id = None
    source_mutation_sequence = None
    if isinstance(decoded, dict):
        source_id_value = decoded.get("sourceStoreID")
        source_sequence_value = decoded.get("sourceMutationSequence")
        if (source_id_value is None) != (source_sequence_value is None):
            raise UploadValidationError(
                "JSON sourceStoreID and sourceMutationSequence must appear together"
            )
        if source_id_value is not None:
            if not isinstance(source_id_value, str):
                raise UploadValidationError("JSON sourceStoreID must be a UUID string")
            try:
                source_store_id = str(uuid.UUID(source_id_value.strip()))
            except (ValueError, AttributeError) as exc:
                raise UploadValidationError("JSON sourceStoreID must be a UUID string") from exc
            if isinstance(source_sequence_value, bool) or not isinstance(source_sequence_value, int):
                raise UploadValidationError(
                    "JSON sourceMutationSequence must be an unsigned integer"
                )
            if not 0 <= source_sequence_value <= 18_446_744_073_709_551_615:
                raise UploadValidationError(
                    "JSON sourceMutationSequence must be an unsigned 64-bit integer"
                )
            source_mutation_sequence = source_sequence_value
    return ParsedExport(
        sessions=list(sessions),
        observations=list(observations),
        content_kind=content_kind,
        declared_scope=declared_scope,
        declared_full_snapshot=declared_full_snapshot,
        exported_at=exported_at,
        store_last_modified_at=store_last_modified_at,
        snapshot_order_us=store_order if store_order is not None else exported_order,
        source_store_id=source_store_id,
        source_mutation_sequence=source_mutation_sequence,
    )


def _parsed_csv_export(payload: bytes) -> ParsedExport:
    try:
        text = payload.decode("utf-8-sig")
    except UnicodeDecodeError as exc:
        raise UploadValidationError(f"CSV must be UTF-8: {exc}") from exc

    sessions: dict[str, dict[str, Any]] = {}
    observations: list[dict[str, Any]] = []
    try:
        reader = csv.DictReader(io.StringIO(text, newline=""), strict=True)
        if reader.fieldnames is None:
            raise UploadValidationError("CSV has no header row")
        missing = REQUIRED_CSV_COLUMNS.difference(reader.fieldnames)
        if missing:
            raise UploadValidationError(
                "CSV is missing required columns: " + ", ".join(sorted(missing))
            )
        for row_number, row in enumerate(reader, start=2):
            if None in row:
                raise UploadValidationError(f"CSV row {row_number} has extra columns")
            if any(row.get(column) is None for column in REQUIRED_CSV_COLUMNS):
                raise UploadValidationError(f"CSV row {row_number} has missing columns")
            if not row["observation_id"].strip():
                raise UploadValidationError(f"CSV row {row_number} has no observation_id")
            try:
                steps = int(row["step_count"])
                encounter = int(row["encounter_number"])
            except ValueError as exc:
                raise UploadValidationError(
                    f"CSV row {row_number} has a non-integer count or encounter number"
                ) from exc
            if steps < 0 or encounter < 1:
                raise UploadValidationError(
                    f"CSV row {row_number} has an out-of-range count or encounter number"
                )
            if row["movement_mode"].strip() not in ALLOWED_MOVEMENT_MODES:
                raise UploadValidationError(
                    f"CSV row {row_number} has an unsupported movement mode"
                )
            normalized = dict(row)
            observations.append(normalized)
            session_id = row["session_id"].strip()
            if session_id and session_id not in sessions:
                sessions[session_id] = {
                    "id": session_id,
                    "name": row["session_name"],
                    "createdAt": row.get("session_created_at", ""),
                    "lastModifiedAt": row.get("session_last_modified_at", ""),
                    "gameVersion": row.get("game_version", ""),
                    "dungeon": row.get("dungeon", ""),
                    "mapAreaDescription": row.get("map_area_description", ""),
                    "testingConditionNotes": row.get("testing_condition_notes", ""),
                    "notes": row.get("session_notes", ""),
                    "isArchived": row.get("session_archived", ""),
                }
    except csv.Error as exc:
        raise UploadValidationError(f"Malformed CSV: {exc}") from exc
    return ParsedExport(sessions=list(sessions.values()), observations=observations)


def parse_upload(payload: bytes, extension: str) -> ParsedExport:
    if not payload:
        raise UploadValidationError("Upload body is empty")
    if extension == "json":
        return _parsed_json_export(payload)
    if extension == "csv":
        return _parsed_csv_export(payload)
    raise UploadValidationError("Unsupported file type")


def validate_json(payload: bytes) -> int:
    return len(_parsed_json_export(payload).observations)


def validate_csv(payload: bytes) -> int:
    return len(_parsed_csv_export(payload).observations)


def validate_upload(payload: bytes, extension: str) -> int:
    return len(parse_upload(payload, extension).observations)


def classify_upload_scope(
    parsed: ParsedExport,
    extension: str,
    requested_name: str,
) -> UploadScope:
    """Classify authoritative snapshots conservatively.

    CSV and compatible JSON without the app export envelope are partial.  An
    app JSON metadata export is complete for every listed session.  Complete
    backups, explicit full all-session envelopes, and the app's predictable
    ``AdventureBar_AllSessions_*.json`` snapshots are complete for the whole
    app database.
    """

    session_ids = tuple(
        sorted(
            {
                normalized["session_id"]
                for item in parsed.sessions
                if (normalized := _normalized_session(item)) is not None
            }
        )
    )
    if extension != "json":
        return UploadScope("partial", False, ())

    content = (parsed.content_kind or "").strip()
    scope = (parsed.declared_scope or "").strip().lower().replace("_", "")
    explicit_full = parsed.declared_full_snapshot is True
    explicit_partial = parsed.declared_full_snapshot is False
    all_scope = scope in {"all", "allsessions"}
    listed_scope = scope in {"session", "activesession", "selectedsession", "listedsessions"}

    if content == "completeBackup":
        return UploadScope("all_sessions", True, session_ids)
    if explicit_full and all_scope:
        return UploadScope("all_sessions", True, session_ids)
    if explicit_full and listed_scope and session_ids:
        return UploadScope("listed_sessions", True, session_ids)
    if explicit_partial:
        return UploadScope("partial", False, ())
    if content == "observationsAndSessionMetadata":
        if re.match(r"(?i)^AdventureBar_AllSessions(?:_|\.)", Path(requested_name).name):
            return UploadScope("all_sessions", True, session_ids)
        if session_ids:
            return UploadScope("listed_sessions", True, session_ids)
    return UploadScope("partial", False, ())


def save_unique(output_dir: Path, requested_name: str, extension: str, payload: bytes) -> Path:
    """Save without overwriting, using a timestamp and an exclusive create."""

    output_dir.mkdir(parents=True, exist_ok=True)
    safe = _safe_filename(requested_name, extension)
    stem = Path(safe).stem
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S_%fZ")
    for attempt in range(10_000):
        suffix = "" if attempt == 0 else f"_{attempt}"
        destination = output_dir / f"{timestamp}_{stem}{suffix}.{extension}"
        try:
            with destination.open("xb") as file_handle:
                file_handle.write(payload)
            return destination.resolve()
        except FileExistsError:
            continue
    raise OSError("Could not allocate a unique output filename")


def normalize_secret_hex(value: str) -> str:
    return value.strip().lower()


def secret_bytes(value: str) -> bytes:
    normalized = normalize_secret_hex(value)
    if not re.fullmatch(r"[0-9a-f]{64}", normalized):
        raise ValueError("The receiver secret must contain exactly 64 hexadecimal characters")
    return bytes.fromhex(normalized)


def build_canonical_request(
    method: str,
    path: str,
    timestamp: str,
    nonce: str,
    content_type: str,
    filename: str,
    body_sha256: str,
) -> str:
    normalized_type = _base_content_type(content_type)
    if normalized_type not in {"application/json", "text/csv"}:
        raise UploadAuthenticationError("unsupported signed content type")
    normalized_nonce = nonce.strip().lower()
    if not re.fullmatch(r"[a-z0-9-]{1,128}", normalized_nonce):
        raise UploadAuthenticationError("invalid nonce")
    normalized_hash = body_sha256.strip().lower()
    if not re.fullmatch(r"[0-9a-f]{64}", normalized_hash):
        raise UploadAuthenticationError("invalid content digest")
    normalized_filename = filename.strip()
    if not normalized_filename or "\r" in normalized_filename or "\n" in normalized_filename:
        raise UploadAuthenticationError("invalid filename")
    normalized_path = path if path.startswith("/") else f"/{path}"
    return "\n".join(
        [
            PROTOCOL_MARKER,
            method.upper(),
            normalized_path,
            timestamp.strip(),
            normalized_nonce,
            normalized_type,
            normalized_filename,
            normalized_hash,
        ]
    )


def verify_upload_authentication(
    headers: Mapping[str, str],
    method: str,
    path: str,
    payload: bytes,
    key: bytes,
    now_seconds: int,
    allowed_skew_seconds: int,
) -> tuple[str, int]:
    timestamp_text = (headers.get(TIMESTAMP_HEADER) or "").strip()
    nonce = (headers.get(NONCE_HEADER) or "").strip().lower()
    supplied_hash = (headers.get(CONTENT_SHA256_HEADER) or "").strip().lower()
    signature_header = (headers.get(SIGNATURE_HEADER) or "").strip().lower()
    filename = (headers.get(FILENAME_HEADER) or "").strip()
    content_type = headers.get("Content-Type") or ""
    try:
        timestamp = int(timestamp_text)
    except ValueError as exc:
        raise UploadAuthenticationError("invalid timestamp") from exc
    if abs(now_seconds - timestamp) > allowed_skew_seconds:
        raise UploadAuthenticationError("stale timestamp")
    actual_hash = hashlib.sha256(payload).hexdigest()
    if not hmac.compare_digest(actual_hash, supplied_hash):
        raise UploadAuthenticationError("content digest mismatch")
    canonical = build_canonical_request(
        method,
        path,
        timestamp_text,
        nonce,
        content_type,
        filename,
        supplied_hash,
    )
    expected = "v1=" + hmac.new(key, canonical.encode("utf-8"), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, signature_header):
        raise UploadAuthenticationError("signature mismatch")
    return nonce, timestamp


DATABASE_SCHEMA_VERSION = 4
DATABASE_SCHEMA = """
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS schema_metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS uploads (
    upload_id INTEGER PRIMARY KEY AUTOINCREMENT,
    received_at TEXT NOT NULL,
    original_filename TEXT NOT NULL,
    stored_path TEXT NOT NULL UNIQUE,
    media_type TEXT NOT NULL,
    payload_sha256 TEXT NOT NULL,
    observation_count INTEGER NOT NULL,
    remote_address TEXT NOT NULL,
    content_kind TEXT,
    snapshot_scope TEXT NOT NULL DEFAULT 'partial',
    is_full_snapshot INTEGER NOT NULL DEFAULT 0,
    scope_session_ids_json TEXT NOT NULL DEFAULT '[]',
    exported_at TEXT,
    store_last_modified_at TEXT,
    snapshot_order_us INTEGER,
    membership_decision TEXT NOT NULL DEFAULT 'not_authoritative',
    source_store_id TEXT,
    source_mutation_sequence TEXT
);
CREATE TABLE IF NOT EXISTS sessions (
    session_id TEXT PRIMARY KEY,
    session_name TEXT NOT NULL,
    metadata_json TEXT NOT NULL,
    first_upload_id INTEGER NOT NULL,
    last_upload_id INTEGER NOT NULL,
    first_seen_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS observations (
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
    last_seen_at TEXT NOT NULL,
    is_current INTEGER NOT NULL DEFAULT 1,
    managed_by_full_snapshot INTEGER NOT NULL DEFAULT 0,
    tombstoned_at TEXT,
    tombstoned_by_upload_id INTEGER
);
CREATE TABLE IF NOT EXISTS upload_observations (
    upload_id INTEGER NOT NULL,
    observation_id TEXT NOT NULL,
    PRIMARY KEY (upload_id, observation_id),
    FOREIGN KEY (upload_id) REFERENCES uploads(upload_id),
    FOREIGN KEY (observation_id) REFERENCES observations(observation_id)
);
CREATE TABLE IF NOT EXISTS auth_nonces (
    nonce TEXT PRIMARY KEY,
    request_timestamp INTEGER NOT NULL,
    received_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS observation_membership_events (
    event_id INTEGER PRIMARY KEY AUTOINCREMENT,
    observation_id TEXT NOT NULL,
    upload_id INTEGER NOT NULL,
    is_current INTEGER NOT NULL,
    changed_at TEXT NOT NULL,
    reason TEXT NOT NULL,
    FOREIGN KEY (upload_id) REFERENCES uploads(upload_id)
);
CREATE TABLE IF NOT EXISTS authoritative_snapshot_watermarks (
    scope_key TEXT PRIMARY KEY,
    snapshot_order_us INTEGER NOT NULL,
    upload_id INTEGER NOT NULL,
    payload_sha256 TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    source_store_id TEXT,
    source_mutation_sequence TEXT,
    FOREIGN KEY (upload_id) REFERENCES uploads(upload_id)
);
CREATE TABLE IF NOT EXISTS snapshot_sources (
    source_store_id TEXT PRIMARY KEY,
    is_active INTEGER NOT NULL,
    max_mutation_sequence TEXT NOT NULL,
    first_upload_id INTEGER NOT NULL,
    last_upload_id INTEGER NOT NULL,
    first_seen_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    retired_at TEXT,
    retired_by_upload_id INTEGER,
    FOREIGN KEY (first_upload_id) REFERENCES uploads(upload_id),
    FOREIGN KEY (last_upload_id) REFERENCES uploads(upload_id)
);
CREATE INDEX IF NOT EXISTS observations_session_idx
    ON observations(session_id, encounter_number);
CREATE INDEX IF NOT EXISTS membership_observation_idx
    ON observation_membership_events(observation_id, event_id);
CREATE UNIQUE INDEX IF NOT EXISTS active_snapshot_source_idx
    ON snapshot_sources(is_active) WHERE is_active = 1;
"""


def _connect_database(database_path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(database_path, timeout=10)
    connection.execute("PRAGMA busy_timeout=10000")
    connection.execute("PRAGMA foreign_keys=ON")
    return connection


@contextmanager
def _database_connection(database_path: Path) -> Iterator[sqlite3.Connection]:
    """Provide one transaction and always release its Windows file handle."""
    connection = _connect_database(database_path)
    try:
        with connection:
            yield connection
    finally:
        connection.close()


def initialize_database(database_path: Path) -> Path:
    database_path = database_path.resolve()
    database_path.parent.mkdir(parents=True, exist_ok=True)
    with _database_connection(database_path) as connection:
        connection.executescript(DATABASE_SCHEMA)
        upload_columns = {
            row[1] for row in connection.execute("PRAGMA table_info(uploads)")
        }
        observation_columns = {
            row[1] for row in connection.execute("PRAGMA table_info(observations)")
        }
        watermark_columns = {
            row[1] for row in connection.execute(
                "PRAGMA table_info(authoritative_snapshot_watermarks)"
            )
        }
        upload_migrations = {
            "content_kind": "TEXT",
            "snapshot_scope": "TEXT NOT NULL DEFAULT 'partial'",
            "is_full_snapshot": "INTEGER NOT NULL DEFAULT 0",
            "scope_session_ids_json": "TEXT NOT NULL DEFAULT '[]'",
            "exported_at": "TEXT",
            "store_last_modified_at": "TEXT",
            "snapshot_order_us": "INTEGER",
            "membership_decision": "TEXT NOT NULL DEFAULT 'not_authoritative'",
            "source_store_id": "TEXT",
            "source_mutation_sequence": "TEXT",
        }
        observation_migrations = {
            "is_current": "INTEGER NOT NULL DEFAULT 1",
            "managed_by_full_snapshot": "INTEGER NOT NULL DEFAULT 0",
            "tombstoned_at": "TEXT",
            "tombstoned_by_upload_id": "INTEGER",
        }
        for name, declaration in upload_migrations.items():
            if name not in upload_columns:
                connection.execute(f"ALTER TABLE uploads ADD COLUMN {name} {declaration}")
        for name, declaration in observation_migrations.items():
            if name not in observation_columns:
                connection.execute(f"ALTER TABLE observations ADD COLUMN {name} {declaration}")
        watermark_migrations = {
            "source_store_id": "TEXT",
            "source_mutation_sequence": "TEXT",
        }
        for name, declaration in watermark_migrations.items():
            if name not in watermark_columns:
                connection.execute(
                    f"ALTER TABLE authoritative_snapshot_watermarks "
                    f"ADD COLUMN {name} {declaration}"
                )
        connection.execute(
            "CREATE INDEX IF NOT EXISTS observations_current_idx "
            "ON observations(is_current, session_id, encounter_number)"
        )
        connection.execute(
            "INSERT INTO schema_metadata(key, value) VALUES ('schema_version', ?) "
            "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            (str(DATABASE_SCHEMA_VERSION),),
        )
    return database_path


def claim_nonce(
    database_path: Path,
    nonce: str,
    request_timestamp: int,
    now_seconds: int,
    allowed_skew_seconds: int,
) -> bool:
    cutoff = now_seconds - max(allowed_skew_seconds * 4, 3600)
    received_at = _utc_now_text()
    try:
        with _database_connection(database_path) as connection:
            connection.execute("DELETE FROM auth_nonces WHERE request_timestamp < ?", (cutoff,))
            connection.execute(
                "INSERT INTO auth_nonces(nonce, request_timestamp, received_at) VALUES (?, ?, ?)",
                (nonce, request_timestamp, received_at),
            )
        return True
    except sqlite3.IntegrityError:
        return False


def _optional_int(value: Any) -> int | None:
    if value is None or value == "":
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _optional_bool(value: Any) -> int | None:
    if value is None or value == "":
        return None
    if isinstance(value, bool):
        return int(value)
    normalized = str(value).strip().lower()
    if normalized in {"true", "1", "yes"}:
        return 1
    if normalized in {"false", "0", "no"}:
        return 0
    return None


def _normalized_session(item: Mapping[str, Any]) -> dict[str, Any] | None:
    session_id = _first(item, ("id", "sessionID", "sessionId", "session_id"))
    if session_id is None or not str(session_id).strip():
        return None
    return {
        "session_id": str(session_id).strip(),
        "session_name": str(_first(item, ("name", "sessionName", "session_name"), "")),
        "metadata_json": json.dumps(dict(item), ensure_ascii=False, sort_keys=True, separators=(",", ":")),
    }


def _normalized_observation(item: Mapping[str, Any]) -> dict[str, Any]:
    observation_id = _first(item, ("observationID", "observationId", "observation_id", "id"))
    step_count = _first(item, ("rawStepCount", "stepCount", "step_count"))
    movement_mode = _first(item, ("movementMode", "movement_mode"))
    audit = _first(item, ("auditHistory", "audit_history"), [])
    return {
        "observation_id": str(observation_id).strip(),
        "session_id": str(_first(item, ("sessionID", "sessionId", "session_id"), "")).strip() or None,
        "encounter_number": _optional_int(_first(item, ("encounterNumber", "encounter_number"))),
        "step_count": int(step_count),
        "movement_mode": str(movement_mode),
        "submitted_at": _first(item, ("submittedAt", "submitted_at")),
        "last_edited_at": _first(item, ("lastEditedAt", "last_edited_at")),
        "measurement_uncertainty": _optional_int(
            _first(item, ("measurementUncertainty", "measurement_uncertainty"))
        ),
        "source": _first(item, ("source",)),
        "questionable": _optional_bool(_first(item, ("isQuestionable", "questionable"))),
        "questionable_reason": _first(item, ("questionableReason", "questionable_reason")),
        "note": _first(item, ("note",)),
        "audit_history_json": json.dumps(audit, ensure_ascii=False, sort_keys=True, separators=(",", ":")),
        "raw_json": json.dumps(dict(item), ensure_ascii=False, sort_keys=True, separators=(",", ":")),
    }


def index_upload(
    database_path: Path,
    parsed: ParsedExport,
    destination: Path,
    requested_name: str,
    media_type: str,
    payload: bytes,
    remote_address: str,
) -> int:
    received_at = _utc_now_text()
    extension = destination.suffix.lower().lstrip(".")
    scope = classify_upload_scope(parsed, extension, requested_name)
    payload_hash = hashlib.sha256(payload).hexdigest()
    normalized_sessions = [
        session
        for item in parsed.sessions
        if (session := _normalized_session(item)) is not None
    ]
    normalized_observations = [_normalized_observation(item) for item in parsed.observations]
    with _database_connection(database_path) as connection:
        relevant_sessions = set(scope.session_ids)
        relevant_sessions.update(
            observation["session_id"]
            for observation in normalized_observations
            if observation["session_id"] is not None
        )
        if scope.kind == "all_sessions":
            relevant_sessions.update(
                str(row[0])
                for row in connection.execute(
                    """SELECT DISTINCT session_id FROM observations
                       WHERE is_current = 1 AND managed_by_full_snapshot = 1
                         AND session_id IS NOT NULL"""
                ).fetchall()
            )

        watermark_rows = connection.execute(
            """SELECT scope_key, snapshot_order_us, source_store_id,
                      source_mutation_sequence
               FROM authoritative_snapshot_watermarks"""
        ).fetchall()
        watermarks = {str(row[0]): int(row[1]) for row in watermark_rows}
        source_coverage = {
            str(row[0]): (str(row[2]), int(row[3]))
            for row in watermark_rows
            if row[2] is not None and row[3] is not None
        }
        global_watermark = watermarks.get("all_sessions")
        eligible_sessions: set[str] = set()
        allow_unscoped_projection = not scope.is_full_snapshot
        advance_global_watermark = False
        source_status: str | None = None
        if scope.is_full_snapshot and parsed.source_store_id is not None:
            source_row = connection.execute(
                """SELECT is_active, max_mutation_sequence FROM snapshot_sources
                   WHERE source_store_id = ?""",
                (parsed.source_store_id,),
            ).fetchone()
            if source_row is None:
                source_status = "new_epoch"
            elif int(source_row[0]) == 0:
                source_status = "retired"
            elif parsed.source_mutation_sequence is not None:
                prior_sequence = int(source_row[1])
                if parsed.source_mutation_sequence > prior_sequence:
                    source_status = "advance"
                elif parsed.source_mutation_sequence == prior_sequence:
                    source_status = "extend"
                else:
                    source_status = "stale"
            else:
                source_status = "stale"

        if not scope.is_full_snapshot:
            membership_decision = "not_authoritative"
        elif source_status in {"retired", "stale"}:
            membership_decision = "retired_source_ignored" if source_status == "retired" else "stale_source_ignored"
        elif source_status in {"new_epoch", "advance"}:
            eligible_sessions = set(relevant_sessions)
            allow_unscoped_projection = scope.kind == "all_sessions"
            advance_global_watermark = scope.kind == "all_sessions"
            membership_decision = "new_source_epoch_applied" if source_status == "new_epoch" else "applied"
        elif source_status == "extend":
            assert parsed.source_store_id is not None
            assert parsed.source_mutation_sequence is not None

            def is_covered(scope_key: str) -> bool:
                coverage = source_coverage.get(scope_key)
                return coverage is not None and coverage[0] == parsed.source_store_id and (
                    coverage[1] >= parsed.source_mutation_sequence
                )

            if scope.kind == "all_sessions":
                if not is_covered("all_sessions"):
                    eligible_sessions = set(relevant_sessions)
                    allow_unscoped_projection = True
                    advance_global_watermark = True
            elif not is_covered("all_sessions"):
                eligible_sessions = {
                    session_id
                    for session_id in relevant_sessions
                    if not is_covered(f"session:{session_id}")
                }
            possible_count = len(relevant_sessions) + int(scope.kind == "all_sessions")
            applicable_count = len(eligible_sessions) + int(allow_unscoped_projection)
            if applicable_count == 0:
                membership_decision = "equal_generation_scope_ignored"
            elif applicable_count < possible_count:
                membership_decision = "equal_generation_scope_partially_extended"
            else:
                membership_decision = "equal_generation_scope_extended"
        elif parsed.snapshot_order_us is None:
            global_allows = global_watermark is None
            if scope.kind == "all_sessions":
                allow_unscoped_projection = global_allows
                if global_allows:
                    eligible_sessions = {
                        session_id
                        for session_id in relevant_sessions
                        if f"session:{session_id}" not in watermarks
                    }
            else:
                eligible_sessions = {
                    session_id
                    for session_id in relevant_sessions
                    if global_allows and f"session:{session_id}" not in watermarks
                }
            applicable_count = len(eligible_sessions) + int(allow_unscoped_projection)
            possible_count = len(relevant_sessions) + int(scope.kind == "all_sessions")
            if applicable_count == 0:
                membership_decision = "unordered_ignored"
            elif applicable_count < possible_count:
                membership_decision = "unordered_partially_applied"
            else:
                membership_decision = "unordered_applied"
        else:
            order_value = parsed.snapshot_order_us
            global_allows = global_watermark is None or order_value > global_watermark
            if scope.kind == "all_sessions" and global_allows:
                allow_unscoped_projection = True
                advance_global_watermark = True
            for session_id in relevant_sessions:
                session_watermark = watermarks.get(f"session:{session_id}")
                prior_values = [value for value in (global_watermark, session_watermark) if value is not None]
                if (not prior_values or order_value > max(prior_values)) and (
                    scope.kind != "all_sessions" or global_allows
                ):
                    eligible_sessions.add(session_id)
            applicable_count = len(eligible_sessions) + int(allow_unscoped_projection)
            possible_count = len(relevant_sessions) + int(scope.kind == "all_sessions")
            if applicable_count == 0:
                membership_decision = "stale_ignored"
            elif applicable_count < possible_count:
                membership_decision = "partially_applied"
            else:
                membership_decision = "applied"

        cursor = connection.execute(
            """INSERT INTO uploads(
                   received_at, original_filename, stored_path, media_type,
                   payload_sha256, observation_count, remote_address,
                   content_kind, snapshot_scope, is_full_snapshot,
                   scope_session_ids_json, exported_at,
                   store_last_modified_at, snapshot_order_us,
                   membership_decision, source_store_id,
                   source_mutation_sequence
               ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                received_at,
                requested_name,
                str(destination.resolve()),
                media_type,
                payload_hash,
                len(parsed.observations),
                remote_address,
                parsed.content_kind,
                scope.kind,
                int(scope.is_full_snapshot),
                json.dumps(scope.session_ids, separators=(",", ":")),
                parsed.exported_at,
                parsed.store_last_modified_at,
                parsed.snapshot_order_us,
                membership_decision,
                parsed.source_store_id,
                str(parsed.source_mutation_sequence)
                if parsed.source_mutation_sequence is not None else None,
            ),
        )
        upload_id = int(cursor.lastrowid)

        if scope.is_full_snapshot and parsed.source_store_id is not None:
            sequence_text = str(parsed.source_mutation_sequence)
            if source_status == "new_epoch":
                connection.execute(
                    """UPDATE snapshot_sources
                       SET is_active = 0, retired_at = ?, retired_by_upload_id = ?
                       WHERE is_active = 1""",
                    (received_at, upload_id),
                )
                connection.execute(
                    """INSERT INTO snapshot_sources(
                           source_store_id, is_active, max_mutation_sequence,
                           first_upload_id, last_upload_id, first_seen_at, last_seen_at
                       ) VALUES (?, 1, ?, ?, ?, ?, ?)""",
                    (
                        parsed.source_store_id, sequence_text, upload_id, upload_id,
                        received_at, received_at,
                    ),
                )
            elif source_status == "advance":
                connection.execute(
                    """UPDATE snapshot_sources
                       SET max_mutation_sequence = ?, last_upload_id = ?, last_seen_at = ?
                       WHERE source_store_id = ? AND is_active = 1""",
                    (sequence_text, upload_id, received_at, parsed.source_store_id),
                )
            else:
                connection.execute(
                    """UPDATE snapshot_sources
                       SET last_upload_id = ?, last_seen_at = ?
                       WHERE source_store_id = ?""",
                    (upload_id, received_at, parsed.source_store_id),
                )

        for session in normalized_sessions:
            if scope.is_full_snapshot and session["session_id"] not in eligible_sessions:
                continue
            connection.execute(
                """INSERT INTO sessions(
                       session_id, session_name, metadata_json, first_upload_id,
                       last_upload_id, first_seen_at, last_seen_at
                   ) VALUES (?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(session_id) DO UPDATE SET
                       session_name=excluded.session_name,
                       metadata_json=excluded.metadata_json,
                       last_upload_id=excluded.last_upload_id,
                       last_seen_at=excluded.last_seen_at""",
                (
                    session["session_id"],
                    session["session_name"],
                    session["metadata_json"],
                    upload_id,
                    upload_id,
                    received_at,
                    received_at,
                ),
            )

        seen_observation_ids: set[str] = set()
        for observation in normalized_observations:
            seen_observation_ids.add(observation["observation_id"])
            previous = connection.execute(
                """SELECT is_current FROM observations
                   WHERE observation_id = ?""",
                (observation["observation_id"],),
            ).fetchone()
            applies_to_projection = not scope.is_full_snapshot or (
                observation["session_id"] in eligible_sessions
                if observation["session_id"] is not None
                else allow_unscoped_projection
            )
            if applies_to_projection:
                connection.execute(
                    """INSERT INTO observations(
                       observation_id, session_id, encounter_number, step_count,
                       movement_mode, submitted_at, last_edited_at,
                       measurement_uncertainty, source, questionable,
                       questionable_reason, note, audit_history_json, raw_json,
                       first_upload_id, last_upload_id, first_seen_at, last_seen_at,
                       is_current, managed_by_full_snapshot, tombstoned_at,
                        tombstoned_by_upload_id
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(observation_id) DO UPDATE SET
                       session_id=excluded.session_id,
                       encounter_number=excluded.encounter_number,
                       step_count=excluded.step_count,
                       movement_mode=excluded.movement_mode,
                       submitted_at=excluded.submitted_at,
                       last_edited_at=excluded.last_edited_at,
                       measurement_uncertainty=excluded.measurement_uncertainty,
                       source=excluded.source,
                       questionable=excluded.questionable,
                       questionable_reason=excluded.questionable_reason,
                       note=excluded.note,
                       audit_history_json=excluded.audit_history_json,
                       raw_json=excluded.raw_json,
                       last_upload_id=excluded.last_upload_id,
                       last_seen_at=excluded.last_seen_at,
                       is_current=1,
                       managed_by_full_snapshot=MAX(
                           observations.managed_by_full_snapshot,
                           excluded.managed_by_full_snapshot
                       ),
                       tombstoned_at=NULL,
                        tombstoned_by_upload_id=NULL""",
                    (
                        observation["observation_id"],
                        observation["session_id"],
                        observation["encounter_number"],
                        observation["step_count"],
                        observation["movement_mode"],
                        observation["submitted_at"],
                        observation["last_edited_at"],
                        observation["measurement_uncertainty"],
                        observation["source"],
                        observation["questionable"],
                        observation["questionable_reason"],
                        observation["note"],
                        observation["audit_history_json"],
                        observation["raw_json"],
                        upload_id,
                        upload_id,
                        received_at,
                        received_at,
                        1,
                        int(scope.is_full_snapshot),
                        None,
                        None,
                    ),
                )
            elif previous is None:
                connection.execute(
                    """INSERT INTO observations(
                           observation_id, session_id, encounter_number, step_count,
                           movement_mode, submitted_at, last_edited_at,
                           measurement_uncertainty, source, questionable,
                           questionable_reason, note, audit_history_json, raw_json,
                           first_upload_id, last_upload_id, first_seen_at, last_seen_at,
                           is_current, managed_by_full_snapshot, tombstoned_at,
                           tombstoned_by_upload_id
                       ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 1, ?, ?)""",
                    (
                        observation["observation_id"], observation["session_id"],
                        observation["encounter_number"], observation["step_count"],
                        observation["movement_mode"], observation["submitted_at"],
                        observation["last_edited_at"], observation["measurement_uncertainty"],
                        observation["source"], observation["questionable"],
                        observation["questionable_reason"], observation["note"],
                        observation["audit_history_json"], observation["raw_json"],
                        upload_id, upload_id, received_at, received_at,
                        received_at, upload_id,
                    ),
                )
            connection.execute(
                "INSERT INTO upload_observations(upload_id, observation_id) VALUES (?, ?)",
                (upload_id, observation["observation_id"]),
            )
            if applies_to_projection and (previous is None or int(previous[0]) == 0):
                connection.execute(
                    """INSERT INTO observation_membership_events(
                           observation_id, upload_id, is_current, changed_at, reason
                       ) VALUES (?, ?, 1, ?, ?)""",
                    (
                        observation["observation_id"],
                        upload_id,
                        received_at,
                        "first_seen" if previous is None else "seen_again",
                    ),
                )
            elif not applies_to_projection and previous is None:
                connection.execute(
                    """INSERT INTO observation_membership_events(
                           observation_id, upload_id, is_current, changed_at, reason
                       ) VALUES (?, ?, 0, ?, 'first_seen_in_stale_snapshot')""",
                    (observation["observation_id"], upload_id, received_at),
                )

        if scope.is_full_snapshot:
            if scope.kind == "all_sessions":
                candidates = connection.execute(
                    """SELECT observation_id, session_id FROM observations
                       WHERE is_current = 1 AND managed_by_full_snapshot = 1"""
                ).fetchall()
                reason = "absent_from_full_all_sessions_snapshot"
            elif scope.kind == "listed_sessions" and scope.session_ids:
                placeholders = ",".join("?" for _ in scope.session_ids)
                candidates = connection.execute(
                    f"""SELECT observation_id, session_id FROM observations
                        WHERE is_current = 1 AND managed_by_full_snapshot = 1
                          AND session_id IN ({placeholders})""",
                    scope.session_ids,
                ).fetchall()
                reason = "absent_from_full_listed_sessions_snapshot"
            else:
                candidates = []
                reason = "absent_from_full_snapshot"

            for row in candidates:
                observation_id = str(row[0])
                candidate_session_id = str(row[1]) if row[1] is not None else None
                if candidate_session_id is None:
                    if not allow_unscoped_projection:
                        continue
                elif candidate_session_id not in eligible_sessions:
                    continue
                if observation_id in seen_observation_ids:
                    continue
                connection.execute(
                    """UPDATE observations
                       SET is_current = 0, tombstoned_at = ?,
                           tombstoned_by_upload_id = ?
                       WHERE observation_id = ? AND is_current = 1""",
                    (received_at, upload_id, observation_id),
                )
                connection.execute(
                    """INSERT INTO observation_membership_events(
                           observation_id, upload_id, is_current, changed_at, reason
                       ) VALUES (?, ?, 0, ?, ?)""",
                    (observation_id, upload_id, received_at, reason),
                )

        if scope.is_full_snapshot and parsed.snapshot_order_us is not None:
            watermark_values: list[tuple[str, int, int, str, str, str | None, str | None]] = []
            if scope.kind == "all_sessions" and advance_global_watermark:
                watermark_values.append(
                    (
                        "all_sessions", parsed.snapshot_order_us, upload_id,
                        payload_hash, received_at, parsed.source_store_id,
                        str(parsed.source_mutation_sequence)
                        if parsed.source_mutation_sequence is not None else None,
                    )
                )
            watermark_values.extend(
                (
                    f"session:{session_id}", parsed.snapshot_order_us, upload_id,
                    payload_hash, received_at, parsed.source_store_id,
                    str(parsed.source_mutation_sequence)
                    if parsed.source_mutation_sequence is not None else None,
                )
                for session_id in sorted(eligible_sessions)
            )
            connection.executemany(
                """INSERT INTO authoritative_snapshot_watermarks(
                       scope_key, snapshot_order_us, upload_id, payload_sha256, updated_at,
                       source_store_id, source_mutation_sequence
                   ) VALUES (?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(scope_key) DO UPDATE SET
                       snapshot_order_us=excluded.snapshot_order_us,
                       upload_id=excluded.upload_id,
                       payload_sha256=excluded.payload_sha256,
                       updated_at=excluded.updated_at,
                       source_store_id=excluded.source_store_id,
                       source_mutation_sequence=excluded.source_mutation_sequence""",
                watermark_values,
            )
    return upload_id


def generate_secret_file(path: Path) -> Path:
    path = path.resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="ascii", newline="\n") as handle:
        handle.write(secrets.token_hex(32) + "\n")
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
    return path


class AdventureBarReceiver(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(
        self,
        server_address: tuple[str, int],
        output_dir: Path,
        max_upload_bytes: int = DEFAULT_MAX_UPLOAD_BYTES,
        *,
        database_path: Path | None = None,
        require_auth: bool = False,
        auth_secret_hex: str = "",
        timestamp_skew_seconds: int = DEFAULT_TIMESTAMP_SKEW_SECONDS,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.output_dir = output_dir.resolve()
        self.raw_upload_dir = self.output_dir / "raw_uploads"
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self.database_path = initialize_database(
            database_path or (self.output_dir / DEFAULT_DATABASE_FILENAME)
        )
        self.max_upload_bytes = max_upload_bytes
        self.require_auth = require_auth
        self.auth_key = secret_bytes(auth_secret_hex) if auth_secret_hex else None
        if require_auth and self.auth_key is None:
            raise ValueError("Authenticated mode requires a valid receiver secret")
        self.timestamp_skew_seconds = timestamp_skew_seconds
        self.clock = clock
        super().__init__(server_address, AdventureBarRequestHandler)


class AdventureBarRequestHandler(BaseHTTPRequestHandler):
    server: AdventureBarReceiver
    protocol_version = "HTTP/1.1"

    def log_message(self, format_string: str, *args: Any) -> None:
        sys.stderr.write(
            f"[{self.log_date_time_string()}] {self.client_address[0]} "
            + (format_string % args)
            + "\n"
        )

    def _json_response(self, status: HTTPStatus, body: dict[str, Any]) -> None:
        encoded = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if urlsplit(self.path).path == "/health":
            self._json_response(HTTPStatus.OK, {"status": "ok"})
        else:
            self._json_response(HTTPStatus.NOT_FOUND, {"error": "not found"})

    def do_HEAD(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        self.send_response(
            HTTPStatus.OK if urlsplit(self.path).path == "/health" else HTTPStatus.NOT_FOUND
        )
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        path = urlsplit(self.path).path
        if path != "/upload":
            self._json_response(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return

        try:
            content_length = int(self.headers.get("Content-Length") or "")
        except ValueError:
            self._json_response(HTTPStatus.LENGTH_REQUIRED, {"error": "invalid request"})
            return
        if content_length < 1:
            self._json_response(HTTPStatus.BAD_REQUEST, {"error": "invalid request"})
            return
        if content_length > self.server.max_upload_bytes:
            self._json_response(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"error": "invalid request"})
            return

        payload = self.rfile.read(content_length)
        if len(payload) != content_length:
            self._json_response(HTTPStatus.BAD_REQUEST, {"error": "invalid request"})
            return

        if self.server.require_auth:
            try:
                assert self.server.auth_key is not None
                nonce, request_timestamp = verify_upload_authentication(
                    self.headers,
                    "POST",
                    path,
                    payload,
                    self.server.auth_key,
                    int(self.server.clock()),
                    self.server.timestamp_skew_seconds,
                )
                if not claim_nonce(
                    self.server.database_path,
                    nonce,
                    request_timestamp,
                    int(self.server.clock()),
                    self.server.timestamp_skew_seconds,
                ):
                    raise UploadAuthenticationError("replayed nonce")
            except (UploadAuthenticationError, sqlite3.Error):
                self._json_response(HTTPStatus.UNAUTHORIZED, {"error": "request rejected"})
                return

        requested_name = (self.headers.get(FILENAME_HEADER) or "AdventureBar_Export").strip()
        media_type = _base_content_type(self.headers.get("Content-Type") or "")
        try:
            extension = _extension_for(self.headers.get("Content-Type", ""), requested_name)
            parsed = parse_upload(payload, extension)
            destination = save_unique(
                self.server.raw_upload_dir, requested_name, extension, payload
            )
            upload_id = index_upload(
                self.server.database_path,
                parsed,
                destination,
                requested_name,
                media_type,
                payload,
                self.client_address[0],
            )
        except UploadValidationError as exc:
            self._json_response(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
            return
        except (OSError, sqlite3.Error, ValueError) as exc:
            self._json_response(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": f"Save failed: {exc}"})
            return

        print(f"Saved upload: {destination}", flush=True)
        self._json_response(
            HTTPStatus.CREATED,
            {
                "status": "saved",
                "filename": destination.name,
                "observationCount": len(parsed.observations),
                "uploadID": upload_id,
            },
        )


def create_server(
    bind: str,
    port: int,
    output_dir: Path,
    max_upload_bytes: int = DEFAULT_MAX_UPLOAD_BYTES,
    *,
    database_path: Path | None = None,
    require_auth: bool = False,
    auth_secret_hex: str = "",
    timestamp_skew_seconds: int = DEFAULT_TIMESTAMP_SKEW_SECONDS,
    clock: Callable[[], float] = time.time,
) -> AdventureBarReceiver:
    return AdventureBarReceiver(
        (bind, port),
        output_dir,
        max_upload_bytes,
        database_path=database_path,
        require_auth=require_auth,
        auth_secret_hex=auth_secret_hex,
        timestamp_skew_seconds=timestamp_skew_seconds,
        clock=clock,
    )


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Receive Adventure Bar Encounter Logger CSV/JSON exports."
    )
    parser.add_argument("--bind", default="0.0.0.0", help="Address to listen on (default: 0.0.0.0)")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"TCP port (default: {DEFAULT_PORT})")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path.cwd() / "AdventureBarUploads",
        help="Directory containing raw_uploads and the default SQLite database",
    )
    parser.add_argument(
        "--database-path",
        type=Path,
        help=f"SQLite path (default: OUTPUT-DIR/{DEFAULT_DATABASE_FILENAME})",
    )
    parser.add_argument(
        "--max-upload-mb", type=int, default=25, help="Maximum request size in MiB (default: 25)"
    )
    parser.add_argument(
        "--require-auth", action="store_true", help="Require signed HMAC-SHA256 uploads"
    )
    parser.add_argument(
        "--auth-secret-file", type=Path, help="File containing the 64-hex upload secret"
    )
    parser.add_argument(
        "--auth-secret-env",
        default=DEFAULT_SECRET_ENV,
        help=f"Environment variable containing the secret (default: {DEFAULT_SECRET_ENV})",
    )
    parser.add_argument(
        "--generate-secret-file",
        type=Path,
        help="Create a new 256-bit secret file exclusively and exit",
    )
    parser.add_argument(
        "--timestamp-skew-seconds",
        type=int,
        default=DEFAULT_TIMESTAMP_SKEW_SECONDS,
        help="Maximum signed request clock difference (default: 300)",
    )
    args = parser.parse_args(argv)
    if not 1 <= args.port <= 65_535:
        parser.error("--port must be between 1 and 65535")
    if args.max_upload_mb < 1:
        parser.error("--max-upload-mb must be at least 1")
    if args.timestamp_skew_seconds < 1:
        parser.error("--timestamp-skew-seconds must be at least 1")
    return args


def _load_secret(args: argparse.Namespace) -> str:
    if args.auth_secret_file is not None:
        try:
            return args.auth_secret_file.read_text(encoding="ascii").strip()
        except OSError as exc:
            raise ValueError(f"Could not read secret file: {exc}") from exc
    return os.environ.get(args.auth_secret_env, "").strip()


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    if args.generate_secret_file is not None:
        try:
            path = generate_secret_file(args.generate_secret_file)
        except FileExistsError:
            print("Secret file already exists; it was not overwritten.", file=sys.stderr)
            return 1
        except OSError as exc:
            print(f"Could not create secret file: {exc}", file=sys.stderr)
            return 1
        print(f"Created receiver secret: {path}")
        return 0

    try:
        secret = _load_secret(args)
        if args.require_auth:
            secret_bytes(secret)
        server = create_server(
            args.bind,
            args.port,
            args.output_dir,
            args.max_upload_mb * 1024 * 1024,
            database_path=args.database_path,
            require_auth=args.require_auth,
            auth_secret_hex=secret if args.require_auth else "",
            timestamp_skew_seconds=args.timestamp_skew_seconds,
        )
    except (OSError, ValueError, sqlite3.Error) as exc:
        print(f"Could not start receiver: {exc}", file=sys.stderr)
        return 1

    host, port = server.server_address[:2]
    if server.require_auth:
        print("Authenticated uploads are required (HMAC-SHA256 with replay protection).")
    else:
        print("WARNING: Upload authentication is disabled; use only on a trusted LAN.")
    print("WARNING: This Python server does not provide TLS; HTTP payload contents are unencrypted.")
    print(f"Listening on http://{host}:{port}")
    print(f"Health check: http://{host}:{port}/health")
    print(f"Saving immutable payloads under: {server.raw_upload_dir}")
    print(f"SQLite database: {server.database_path}")
    try:
        server.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:
        print("\nStopping receiver.")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

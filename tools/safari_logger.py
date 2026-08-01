#!/usr/bin/env python3
"""Mobile Safari encounter counter with durable, local PC storage.

Uses only Python's standard library. The browser updates its visible/local
counter synchronously, while serialized checkpoints are persisted in SQLite.
"""

from __future__ import annotations

import argparse
import csv
import hmac
import io
import json
import secrets
import sqlite3
import threading
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlparse


DEFAULT_PORT = 8787
SESSION_NAME = "Safari Temporary Logger"
VALID_BASE_MODES = {"walking", "running"}
VALID_MODES = {"walking", "running", "mixed_uncertain"}
MAX_REQUEST_BYTES = 64 * 1024


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


class LoggerStore:
    def __init__(self, database_path: Path):
        self.database_path = database_path
        self.database_path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._initialize()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.database_path, timeout=10)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA journal_mode = WAL")
        connection.execute("PRAGMA synchronous = FULL")
        connection.execute("PRAGMA busy_timeout = 10000")
        return connection

    @contextmanager
    def _connection(self):
        connection = self._connect()
        try:
            with connection:
                yield connection
        finally:
            connection.close()

    def _initialize(self) -> None:
        with self._lock, self._connection() as connection:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS logger_state (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    session_id TEXT NOT NULL,
                    session_name TEXT NOT NULL,
                    current_count INTEGER NOT NULL CHECK (current_count >= 0),
                    base_mode TEXT NOT NULL CHECK (base_mode IN ('walking', 'running')),
                    interval_is_mixed INTEGER NOT NULL CHECK (interval_is_mixed IN (0, 1)),
                    client_revision INTEGER NOT NULL CHECK (client_revision >= 0),
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS observations (
                    observation_id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    encounter_number INTEGER NOT NULL CHECK (encounter_number > 0),
                    step_count INTEGER NOT NULL CHECK (step_count >= 0),
                    movement_mode TEXT NOT NULL CHECK (
                        movement_mode IN ('walking', 'running', 'mixed_uncertain')
                    ),
                    selector_mode TEXT NOT NULL CHECK (selector_mode IN ('walking', 'running')),
                    submitted_at TEXT NOT NULL,
                    source TEXT NOT NULL,
                    UNIQUE (session_id, encounter_number)
                );
                """
            )
            row = connection.execute(
                "SELECT singleton FROM logger_state WHERE singleton = 1"
            ).fetchone()
            if row is None:
                connection.execute(
                    """
                    INSERT INTO logger_state (
                        singleton, session_id, session_name, current_count,
                        base_mode, interval_is_mixed, client_revision, updated_at
                    ) VALUES (1, ?, ?, 0, 'walking', 0, 0, ?)
                    """,
                    (str(uuid.uuid4()), SESSION_NAME, utc_now()),
                )

    @staticmethod
    def _state_dict(row: sqlite3.Row, observation_count: int) -> dict[str, object]:
        mixed = bool(row["interval_is_mixed"])
        base_mode = row["base_mode"]
        return {
            "sessionID": row["session_id"],
            "sessionName": row["session_name"],
            "count": row["current_count"],
            "baseMode": base_mode,
            "mixed": mixed,
            "movementMode": "mixed_uncertain" if mixed else base_mode,
            "revision": row["client_revision"],
            "updatedAt": row["updated_at"],
            "observationCount": observation_count,
        }

    def state(self) -> dict[str, object]:
        with self._lock, self._connection() as connection:
            row = connection.execute("SELECT * FROM logger_state WHERE singleton = 1").fetchone()
            count = connection.execute("SELECT COUNT(*) FROM observations").fetchone()[0]
            return self._state_dict(row, count)

    def checkpoint(self, count: int, base_mode: str, mixed: bool, revision: int) -> dict[str, object]:
        if not isinstance(count, int) or isinstance(count, bool) or count < 0:
            raise ValueError("count must be a non-negative integer")
        if base_mode not in VALID_BASE_MODES:
            raise ValueError("baseMode must be walking or running")
        if not isinstance(mixed, bool):
            raise ValueError("mixed must be a Boolean")
        if not isinstance(revision, int) or isinstance(revision, bool) or revision < 0:
            raise ValueError("revision must be a non-negative integer")

        with self._lock, self._connection() as connection:
            current = connection.execute(
                "SELECT client_revision FROM logger_state WHERE singleton = 1"
            ).fetchone()[0]
            if revision >= current:
                connection.execute(
                    """
                    UPDATE logger_state
                    SET current_count = ?, base_mode = ?, interval_is_mixed = ?,
                        client_revision = ?, updated_at = ?
                    WHERE singleton = 1
                    """,
                    (count, base_mode, int(mixed), revision, utc_now()),
                )
            row = connection.execute("SELECT * FROM logger_state WHERE singleton = 1").fetchone()
            total = connection.execute("SELECT COUNT(*) FROM observations").fetchone()[0]
            result = self._state_dict(row, total)
            result["accepted"] = revision >= current
            return result

    def submit(
        self,
        observation_id: str,
        count: int,
        movement_mode: str,
        selector_mode: str,
        submitted_at: str,
        revision: int,
    ) -> dict[str, object]:
        try:
            normalized_id = str(uuid.UUID(observation_id))
        except (ValueError, TypeError, AttributeError) as error:
            raise ValueError("observationID must be a UUID") from error
        if not isinstance(count, int) or isinstance(count, bool) or count < 0:
            raise ValueError("count must be a non-negative integer")
        if movement_mode not in VALID_MODES:
            raise ValueError("movementMode is invalid")
        if selector_mode not in VALID_BASE_MODES:
            raise ValueError("selectorMode must be walking or running")
        if not isinstance(submitted_at, str) or not submitted_at.strip():
            raise ValueError("submittedAt is required")
        if not isinstance(revision, int) or isinstance(revision, bool) or revision < 0:
            raise ValueError("revision must be a non-negative integer")

        with self._lock, self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            state = connection.execute("SELECT * FROM logger_state WHERE singleton = 1").fetchone()
            existing = connection.execute(
                "SELECT * FROM observations WHERE observation_id = ?", (normalized_id,)
            ).fetchone()
            if existing is None:
                encounter_number = connection.execute(
                    "SELECT COALESCE(MAX(encounter_number), 0) + 1 FROM observations WHERE session_id = ?",
                    (state["session_id"],),
                ).fetchone()[0]
                connection.execute(
                    """
                    INSERT INTO observations (
                        observation_id, session_id, encounter_number, step_count,
                        movement_mode, selector_mode, submitted_at, source
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, 'Safari local logger')
                    """,
                    (
                        normalized_id,
                        state["session_id"],
                        encounter_number,
                        count,
                        movement_mode,
                        selector_mode,
                        submitted_at,
                    ),
                )
            else:
                if (
                    existing["step_count"] != count
                    or existing["movement_mode"] != movement_mode
                    or existing["selector_mode"] != selector_mode
                ):
                    raise ValueError("observation UUID was already submitted with different data")
                encounter_number = existing["encounter_number"]

            next_revision = max(state["client_revision"], revision) + 1
            connection.execute(
                """
                UPDATE logger_state
                SET current_count = 0, base_mode = ?, interval_is_mixed = 0,
                    client_revision = ?, updated_at = ?
                WHERE singleton = 1
                """,
                (selector_mode, next_revision, utc_now()),
            )
            connection.commit()
            result = self.state()
            result.update(
                {
                    "recorded": {
                        "observationID": normalized_id,
                        "encounterNumber": encounter_number,
                        "stepCount": count,
                        "movementMode": movement_mode,
                        "submittedAt": submitted_at,
                    }
                }
            )
            return result

    def undo(self, current_count: int, strategy: str, revision: int) -> dict[str, object]:
        if not isinstance(current_count, int) or isinstance(current_count, bool) or current_count < 0:
            raise ValueError("currentCount must be a non-negative integer")
        if strategy not in {"replace", "add"}:
            raise ValueError("strategy must be replace or add")
        if not isinstance(revision, int) or isinstance(revision, bool) or revision < 0:
            raise ValueError("revision must be a non-negative integer")

        with self._lock, self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            state = connection.execute("SELECT * FROM logger_state WHERE singleton = 1").fetchone()
            latest = connection.execute(
                "SELECT * FROM observations ORDER BY encounter_number DESC, submitted_at DESC LIMIT 1"
            ).fetchone()
            if latest is None:
                raise LookupError("there is no submitted observation to undo")
            restored = latest["step_count"] + (current_count if strategy == "add" else 0)
            restored_mode = latest["movement_mode"]
            mixed = restored_mode == "mixed_uncertain"
            selector = latest["selector_mode"]
            connection.execute(
                "DELETE FROM observations WHERE observation_id = ?", (latest["observation_id"],)
            )
            next_revision = max(state["client_revision"], revision) + 1
            connection.execute(
                """
                UPDATE logger_state
                SET current_count = ?, base_mode = ?, interval_is_mixed = ?,
                    client_revision = ?, updated_at = ?
                WHERE singleton = 1
                """,
                (restored, selector, int(mixed), next_revision, utc_now()),
            )
            connection.commit()
            result = self.state()
            result["undone"] = {
                "observationID": latest["observation_id"],
                "stepCount": latest["step_count"],
                "movementMode": restored_mode,
                "restoredCount": restored,
            }
            return result

    def observations(self) -> list[dict[str, object]]:
        with self._lock, self._connection() as connection:
            rows = connection.execute(
                "SELECT * FROM observations ORDER BY encounter_number, submitted_at"
            ).fetchall()
            return [dict(row) for row in rows]

    def export_json(self) -> bytes:
        state = self.state()
        payload = {
            "schemaVersion": 1,
            "exportedAt": utc_now(),
            "session": {
                "id": state["sessionID"],
                "name": state["sessionName"],
                "gameVersion": "Nintendo Switch",
            },
            "unfinishedCounter": {
                "count": state["count"],
                "baseMode": state["baseMode"],
                "mixed": state["mixed"],
            },
            "observations": [
                {
                    "observationID": row["observation_id"],
                    "sessionID": row["session_id"],
                    "encounterNumber": row["encounter_number"],
                    "stepCount": row["step_count"],
                    "movementMode": row["movement_mode"],
                    "submittedAt": row["submitted_at"],
                    "source": row["source"],
                }
                for row in self.observations()
            ],
        }
        return json.dumps(payload, indent=2, ensure_ascii=False).encode("utf-8")

    def export_csv(self) -> bytes:
        state = self.state()
        output = io.StringIO(newline="")
        writer = csv.writer(output, lineterminator="\r\n")
        writer.writerow(
            [
                "session_id",
                "session_name",
                "observation_id",
                "encounter_number",
                "step_count",
                "movement_mode",
                "submitted_at",
                "source",
            ]
        )
        for row in self.observations():
            writer.writerow(
                [
                    row["session_id"],
                    state["sessionName"],
                    row["observation_id"],
                    row["encounter_number"],
                    row["step_count"],
                    row["movement_mode"],
                    row["submitted_at"],
                    row["source"],
                ]
            )
        return output.getvalue().encode("utf-8")


HTML = r'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover,user-scalable=no">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="theme-color" content="#101828">
<title>Adventure Bar Logger</title>
<style>
:root{color-scheme:light dark;--bg:#f4f7fb;--card:#fff;--ink:#101828;--muted:#667085;--line:#d0d5dd;--blue:#155eef;--red:#b42318;--green:#067647}
@media(prefers-color-scheme:dark){:root{--bg:#0c111d;--card:#161b26;--ink:#f5f5f6;--muted:#98a2b3;--line:#344054;--blue:#528bff;--red:#f97066;--green:#32d583}}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}html,body{margin:0;min-height:100%;background:var(--bg);color:var(--ink);font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;touch-action:manipulation}
body{min-height:100dvh;padding:max(12px,env(safe-area-inset-top)) 14px max(14px,env(safe-area-inset-bottom));display:flex;justify-content:center}
main{width:min(100%,540px);min-height:calc(100dvh - 28px);display:grid;grid-template-rows:auto auto 1fr auto auto;gap:12px}
.session{text-align:center;color:var(--muted);font-size:.86rem;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.segment{display:grid;grid-template-columns:1fr 1fr;background:var(--line);border-radius:14px;padding:3px;gap:3px}
.segment button{min-height:48px;border:0;border-radius:11px;background:transparent;color:var(--ink);font-size:1.05rem;font-weight:700}
.segment button.active{background:var(--card);box-shadow:0 1px 4px #0003;color:var(--blue)}
.counter{display:flex;align-items:center;justify-content:center;min-height:150px;font-size:clamp(6.5rem,31vw,11rem);font-weight:800;line-height:.85;font-variant-numeric:tabular-nums;letter-spacing:-.07em;padding-right:.07em;overflow:hidden}
.controls{display:grid;grid-template-columns:1fr 2.1fr;gap:12px}
button{font:inherit;cursor:pointer}.minus,.plus,.submit,.undo{border:0;border-radius:20px;font-weight:800;min-height:78px}
.minus{background:var(--card);color:var(--ink);border:2px solid var(--line);font-size:2rem}.plus{background:var(--blue);color:#fff;font-size:3.2rem;line-height:1}
.actions{display:grid;grid-template-columns:1fr 1.65fr;gap:12px}.undo{background:var(--card);color:var(--ink);border:2px solid var(--line);font-size:1.08rem}.submit{background:var(--green);color:#fff;font-size:1.25rem}
button:disabled{opacity:.38}.footer{min-height:34px;display:flex;align-items:center;justify-content:space-between;gap:8px;color:var(--muted);font-size:.82rem}.status{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.exports{display:flex;gap:10px}.exports a{color:var(--blue);font-weight:650;text-decoration:none}
.mixed{text-align:center;color:#b54708;font-weight:700;font-size:.88rem;min-height:1.1rem}
.overlay{position:fixed;inset:0;background:#0009;display:none;align-items:flex-end;justify-content:center;padding:18px;z-index:10}.overlay.show{display:flex}.dialog{width:min(100%,520px);background:var(--card);border-radius:22px;padding:20px;box-shadow:0 20px 60px #0008}.dialog h2{font-size:1.25rem;margin:0 0 8px}.dialog p{color:var(--muted);margin:0 0 16px;line-height:1.4}.dialog button{display:block;width:100%;min-height:50px;margin-top:9px;border:0;border-radius:13px;background:var(--blue);color:white;font-weight:750}.dialog .secondary{background:var(--card);color:var(--ink);border:1px solid var(--line)}.dialog .danger{background:var(--red)}
@media(orientation:landscape) and (max-height:520px){body{padding:8px 14px}main{grid-template-columns:1fr 1fr;grid-template-rows:auto auto 1fr auto;gap:8px}.session,.segment,.mixed{grid-column:1}.counter{grid-column:1;min-height:90px;font-size:6rem}.controls,.actions{grid-column:2}.footer{grid-column:1/3}.minus,.plus,.submit,.undo{min-height:64px}}
</style>
</head>
<body><main>
  <div class="session" id="session">Safari Temporary Logger</div>
  <div><div class="segment" role="radiogroup" aria-label="Movement mode"><button id="walk" role="radio">Walking</button><button id="run" role="radio">Running</button></div><div class="mixed" id="mixed"></div></div>
  <div class="counter" id="count" aria-live="polite">0</div>
  <div class="controls"><button class="minus" id="minus" aria-label="Subtract one step">−</button><button class="plus" id="plus" aria-label="Add one successful tile movement">+</button></div>
  <div><div class="actions"><button class="undo" id="undo">Undo</button><button class="submit" id="submit">Submit</button></div><div class="footer"><span class="status" id="status">Connecting…</span><span class="exports"><a id="csv">CSV</a><a id="json">JSON</a></span></div></div>
</main>
<div class="overlay" id="modeDialog" role="dialog" aria-modal="true"><div class="dialog"><h2>Switch movement mode?</h2><p>The current interval already contains steps.</p><button id="preserveMode">Switch and preserve count</button><button class="danger" id="resetMode">Reset count and switch</button><button class="secondary" id="cancelMode">Cancel</button></div></div>
<div class="overlay" id="undoDialog" role="dialog" aria-modal="true"><div class="dialog"><h2>Replace unfinished count?</h2><p>Undo can replace the current count or add it to the restored observation.</p><button id="addUndo">Add current count</button><button class="danger" id="replaceUndo">Replace current count</button><button class="secondary" id="cancelUndo">Cancel</button></div></div>
<script>
"use strict";
const TOKEN=__ACCESS_TOKEN_JSON__, STORAGE="adventureBarSafariLogger.v1";
const $=id=>document.getElementById(id);
let state={count:0,baseMode:"walking",mixed:false,revision:0,observationCount:0}, pendingMode=null, saveChain=Promise.resolve(), busy=false;
function readLocal(){try{const x=JSON.parse(localStorage.getItem(STORAGE));return x&&Number.isInteger(x.count)&&x.count>=0?x:null}catch{return null}}
function writeLocal(){localStorage.setItem(STORAGE,JSON.stringify(state))}
function modeName(mode){return mode==="walking"?"Walking":mode==="running"?"Running":"Mixed/Uncertain"}
function newUUID(){
  if(globalThis.crypto&&typeof crypto.randomUUID==="function")return crypto.randomUUID();
  const bytes=new Uint8Array(16);if(globalThis.crypto&&crypto.getRandomValues){crypto.getRandomValues(bytes)}else{for(let i=0;i<16;i++)bytes[i]=Math.floor(Math.random()*256)}
  bytes[6]=(bytes[6]&15)|64;bytes[8]=(bytes[8]&63)|128;const hex=[...bytes].map(value=>value.toString(16).padStart(2,"0")).join("");return`${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20)}`;
}
function render(){
  $("count").textContent=state.count; $("walk").classList.toggle("active",state.baseMode==="walking"); $("run").classList.toggle("active",state.baseMode==="running");
  $("walk").setAttribute("aria-checked",state.baseMode==="walking"); $("run").setAttribute("aria-checked",state.baseMode==="running");
  $("mixed").textContent=state.mixed?"Current interval: Mixed/Uncertain":""; $("minus").disabled=state.count===0||busy; $("plus").disabled=busy; $("submit").disabled=busy; $("undo").disabled=busy||state.observationCount===0;
  writeLocal();
}
function setStatus(message,ok=true){$("status").textContent=message;$("status").style.color=ok?"var(--muted)":"var(--red)"}
async function api(path,options={}){const headers={"X-Logger-Token":TOKEN,...(options.headers||{})};const response=await fetch(path,{cache:"no-store",...options,headers});let body={};try{body=await response.json()}catch{}if(!response.ok)throw new Error(body.error||`HTTP ${response.status}`);return body}
function snapshot(){return{count:state.count,baseMode:state.baseMode,mixed:state.mixed,revision:state.revision}}
function checkpoint(){const body=snapshot();saveChain=saveChain.catch(()=>{}).then(()=>api("/api/state",{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify(body)})).then(()=>setStatus("Saved on PC")).catch(error=>setStatus(`Safari saved; PC retry needed: ${error.message}`,false));return saveChain}
function changed(){state.revision++;render();checkpoint()}
function adopt(remote){state={count:remote.count,baseMode:remote.baseMode,mixed:remote.mixed,revision:remote.revision,observationCount:remote.observationCount};render()}
async function initialize(){
  const local=readLocal();if(local)state={...state,...local};render();
  try{const remote=await api("/api/state");if(local&&local.revision>remote.revision){checkpoint();setStatus("Restoring newer Safari checkpoint…")}else{adopt(remote);setStatus("Connected — saved on PC")}}catch(error){setStatus(`Offline PC connection: ${error.message}`,false)}
}
function chooseMode(next){if(next===state.baseMode)return;if(state.count===0){state.baseMode=next;state.mixed=false;changed();return}pendingMode=next;$("modeDialog").classList.add("show")}
$("walk").onclick=()=>chooseMode("walking");$("run").onclick=()=>chooseMode("running");
$("plus").onclick=()=>{state.count++;changed()};$("minus").onclick=()=>{if(state.count>0){state.count--;changed()}};
$("cancelMode").onclick=()=>{$("modeDialog").classList.remove("show");pendingMode=null};
$("resetMode").onclick=()=>{state.count=0;state.baseMode=pendingMode;state.mixed=false;$("modeDialog").classList.remove("show");pendingMode=null;changed()};
$("preserveMode").onclick=()=>{state.baseMode=pendingMode;state.mixed=true;$("modeDialog").classList.remove("show");pendingMode=null;changed()};
async function submit(){
  if(state.count===0&&!confirm("Record a zero-step observation?"))return;
  busy=true;render();await saveChain;
  const exact={observationID:newUUID(),count:state.count,movementMode:state.mixed?"mixed_uncertain":state.baseMode,selectorMode:state.baseMode,submittedAt:new Date().toISOString(),revision:state.revision};
  try{const response=await api("/api/submit",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(exact)});adopt(response);setStatus(`Recorded: ${exact.count} ${modeName(exact.movementMode)}`)}catch(error){setStatus(`Not submitted: ${error.message}`,false)}finally{busy=false;render()}
}
$("submit").onclick=submit;
async function undo(strategy){
  $("undoDialog").classList.remove("show");busy=true;render();await saveChain;
  try{const response=await api("/api/undo",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({currentCount:state.count,strategy,revision:state.revision})});adopt(response);setStatus(`Undone — restored ${response.undone.restoredCount}`)}catch(error){setStatus(`Undo failed: ${error.message}`,false)}finally{busy=false;render()}
}
$("undo").onclick=()=>{if(state.count>0){$("undoDialog").classList.add("show")}else{undo("replace")}};$("addUndo").onclick=()=>undo("add");$("replaceUndo").onclick=()=>undo("replace");$("cancelUndo").onclick=()=>$("undoDialog").classList.remove("show");
$("csv").href=`/export.csv?token=${encodeURIComponent(TOKEN)}`;$("json").href=`/export.json?token=${encodeURIComponent(TOKEN)}`;
window.addEventListener("pagehide",()=>{const body=JSON.stringify(snapshot());navigator.sendBeacon(`/api/beacon?token=${encodeURIComponent(TOKEN)}`,new Blob([body],{type:"application/json"}))});
initialize();
</script></body></html>'''


class LoggerHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], store: LoggerStore, access_token: str):
        super().__init__(address, LoggerHandler)
        self.store = store
        self.access_token = access_token


class LoggerHandler(BaseHTTPRequestHandler):
    server: LoggerHTTPServer
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: object) -> None:
        print(f"[{self.log_date_time_string()}] {self.client_address[0]} {fmt % args}", flush=True)

    def _token_is_valid(self, query: dict[str, list[str]]) -> bool:
        supplied = self.headers.get("X-Logger-Token", "") or query.get("token", [""])[0]
        return hmac.compare_digest(supplied, self.server.access_token)

    def _common_headers(self, content_type: str, length: int) -> None:
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "no-store, max-age=0")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")

    def _send(self, status: int, data: bytes, content_type: str) -> None:
        self.send_response(status)
        self._common_headers(content_type, len(data))
        self.end_headers()
        self.wfile.write(data)

    def _json(self, status: int, payload: dict[str, object]) -> None:
        self._send(status, json.dumps(payload, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8")

    def _read_json(self) -> dict[str, object]:
        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            raise ValueError("Content-Length is required")
        try:
            length = int(raw_length)
        except ValueError as error:
            raise ValueError("Content-Length is invalid") from error
        if length < 0 or length > MAX_REQUEST_BYTES:
            raise ValueError("request body is too large")
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ValueError("request body must be valid UTF-8 JSON") from error
        if not isinstance(payload, dict):
            raise ValueError("request body must be a JSON object")
        return payload

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        if parsed.path == "/health":
            self._json(HTTPStatus.OK, {"status": "ok"})
            return
        if not self._token_is_valid(query):
            self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return
        if parsed.path == "/":
            body = HTML.replace("__ACCESS_TOKEN_JSON__", json.dumps(self.server.access_token)).encode("utf-8")
            self._send(HTTPStatus.OK, body, "text/html; charset=utf-8")
        elif parsed.path == "/api/state":
            self._json(HTTPStatus.OK, self.server.store.state())
        elif parsed.path == "/export.json":
            data = self.server.store.export_json()
            self.send_response(HTTPStatus.OK)
            self._common_headers("application/json; charset=utf-8", len(data))
            self.send_header("Content-Disposition", 'attachment; filename="AdventureBar_SafariLogger.json"')
            self.end_headers()
            self.wfile.write(data)
        elif parsed.path == "/export.csv":
            data = self.server.store.export_csv()
            self.send_response(HTTPStatus.OK)
            self._common_headers("text/csv; charset=utf-8", len(data))
            self.send_header("Content-Disposition", 'attachment; filename="AdventureBar_SafariLogger.csv"')
            self.end_headers()
            self.wfile.write(data)
        else:
            self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})

    def do_PUT(self) -> None:
        parsed = urlparse(self.path)
        if not self._token_is_valid(parse_qs(parsed.query)):
            self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return
        if parsed.path != "/api/state":
            self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return
        try:
            body = self._read_json()
            result = self.server.store.checkpoint(
                body.get("count"), body.get("baseMode"), body.get("mixed"), body.get("revision")
            )
            self._json(HTTPStatus.OK, result)
        except ValueError as error:
            self._json(HTTPStatus.BAD_REQUEST, {"error": str(error)})

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        if not self._token_is_valid(query):
            self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return
        try:
            body = self._read_json()
            if parsed.path == "/api/submit":
                result = self.server.store.submit(
                    body.get("observationID"),
                    body.get("count"),
                    body.get("movementMode"),
                    body.get("selectorMode"),
                    body.get("submittedAt"),
                    body.get("revision"),
                )
                self._json(HTTPStatus.CREATED, result)
            elif parsed.path == "/api/undo":
                result = self.server.store.undo(
                    body.get("currentCount"), body.get("strategy"), body.get("revision")
                )
                self._json(HTTPStatus.OK, result)
            elif parsed.path == "/api/beacon":
                result = self.server.store.checkpoint(
                    body.get("count"), body.get("baseMode"), body.get("mixed"), body.get("revision")
                )
                self._json(HTTPStatus.OK, result)
            else:
                self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})
        except LookupError as error:
            self._json(HTTPStatus.CONFLICT, {"error": str(error)})
        except ValueError as error:
            self._json(HTTPStatus.BAD_REQUEST, {"error": str(error)})


def load_or_create_token(path: Path) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        token = path.read_text(encoding="ascii").strip()
        if len(token) != 64 or any(character not in "0123456789abcdef" for character in token):
            raise ValueError(f"invalid token file: {path}")
        return token
    token = secrets.token_hex(32)
    try:
        path.write_text(token + "\n", encoding="ascii", errors="strict")
    except OSError:
        if path.exists():
            return load_or_create_token(path)
        raise
    return token


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Host the Adventure Bar Safari logger on this PC")
    parser.add_argument("--bind", default="0.0.0.0", help="address to bind (default: 0.0.0.0)")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--data-dir", type=Path, default=Path("SafariLoggerData"))
    parser.add_argument("--public-host", help="host/IP printed in the iPhone URL")
    return parser


def main() -> int:
    args = make_parser().parse_args()
    if not 1 <= args.port <= 65535:
        raise SystemExit("error: --port must be between 1 and 65535")
    data_dir = args.data_dir.resolve()
    token = load_or_create_token(data_dir / "access.token")
    store = LoggerStore(data_dir / "AdventureBarSafariLogger.sqlite3")
    server = LoggerHTTPServer((args.bind, args.port), store, token)
    host = args.public_host or ("127.0.0.1" if args.bind == "0.0.0.0" else args.bind)
    url = f"http://{host}:{args.port}/?token={quote(token)}"
    print("Adventure Bar Safari Logger is running.", flush=True)
    print(f"Open on iPhone: {url}", flush=True)
    print(f"SQLite data: {store.database_path}", flush=True)
    print("Press Ctrl+C in this process to stop.", flush=True)
    try:
        server.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

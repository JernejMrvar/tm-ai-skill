#!/usr/bin/env python3
"""Minimal local fixture server for tm-ai-skill's integration tests.

This is a test double, not a reimplementation of TestManagement's server. It
approximates just enough of the POV-28/POV-30 contract (`/api/v1/me`,
`/api/v1/projects`, `/api/v1/skill-release`, and
`/api/v1/skill-installations/report`) for install.sh's client-side handling
to be exercised against real HTTP round-trips, with no real deployment, no
real credentials, and no network beyond 127.0.0.1.

Token convention used only by this fixture (never a real TestManagement
format):
  tmp_<ownerId>_<generation>   -> personal key identity
  tm_<projectId>_<userId>      -> legacy key identity

Usage: fake_tm_server.py <port> <serve_dir> [<release_json_path>]

Serves static files (release artifacts) from <serve_dir> for any path that
isn't one of the API routes above. If <release_json_path> is given, its
contents are served verbatim for GET /api/v1/skill-release.
"""
import http.server
import json
import os
import sys
import hashlib
import threading

PORT = int(sys.argv[1])
SERVE_DIR = sys.argv[2]
RELEASE_JSON_PATH = sys.argv[3] if len(sys.argv) > 3 else None

_lock = threading.Lock()
_reports = {}  # installationId -> {"sequence": int, "fingerprint": str, "receipt": dict}


def _identity_from_token(token):
    if token.startswith("tmp_"):
        rest = token[len("tmp_"):]
        owner_id, _, generation = rest.rpartition("_")
        if not owner_id or not generation.isdigit():
            return None
        return {"kind": "personal", "ownerId": owner_id, "generation": int(generation)}
    if token.startswith("tm_"):
        rest = token[len("tm_"):]
        project_id, _, user_id = rest.rpartition("_")
        if not project_id:
            return None
        return {"kind": "legacy", "projectId": project_id, "userId": user_id}
    return None


def _fingerprint(body):
    stripped = {k: v for k, v in body.items() if k not in ("schemaVersion", "installationId", "sequence")}
    canonical = json.dumps(stripped, sort_keys=True)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=SERVE_DIR, **kwargs)

    def log_message(self, fmt, *args):
        pass  # keep test output quiet

    def _bearer_token(self):
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return None
        return auth[len("Bearer "):]

    def _send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/api/v1/me":
            token = self._bearer_token()
            identity = _identity_from_token(token) if token else None
            if identity is None:
                self._send_json(401, {"error": "INVALID_API_TOKEN"})
                return
            if identity["kind"] == "personal":
                self._send_json(200, {
                    "kind": "personal",
                    "ownerId": identity["ownerId"],
                    "ownerName": "Test Owner",
                    "displayName": None,
                    "generation": identity["generation"],
                })
            else:
                self._send_json(200, {
                    "kind": "legacy",
                    "projectId": identity["projectId"],
                    "userId": identity["userId"],
                    "tokenName": "test-token",
                })
            return

        if self.path == "/api/v1/projects":
            token = self._bearer_token()
            identity = _identity_from_token(token) if token else None
            if identity is None:
                self._send_json(401, {"error": "INVALID_API_TOKEN"})
                return
            self._send_json(200, {"projects": []})
            return

        if self.path == "/api/v1/skill-release":
            if RELEASE_JSON_PATH and os.path.isfile(RELEASE_JSON_PATH):
                with open(RELEASE_JSON_PATH, "r") as f:
                    payload = json.load(f)
            else:
                payload = {"schemaVersion": 1, "release": None}
            self._send_json(200, payload)
            return

        super().do_GET()

    def do_POST(self):
        if self.path == "/api/v1/skill-installations/report":
            token = self._bearer_token()
            identity = _identity_from_token(token) if token else None
            if identity is None:
                self._send_json(401, {"error": "INVALID_API_TOKEN"})
                return
            if identity["kind"] != "personal":
                self._send_json(403, {"error": "PERSONAL_KEY_REQUIRED"})
                return

            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length)
            try:
                body = json.loads(raw)
            except ValueError:
                self._send_json(400, {"error": "INVALID_REQUEST"})
                return

            forced = self.headers.get("X-Test-Force-Status")
            if forced:
                code = int(forced)
                error_map = {
                    401: "INVALID_API_TOKEN", 403: "PERSONAL_KEY_REQUIRED",
                    404: "INSTALLATION_NOT_FOUND", 409: "REPORT_CONFLICT",
                    413: "PAYLOAD_TOO_LARGE", 503: "SKILL_INSTALLATION_RETRY_EXHAUSTED",
                }
                self._send_json(code, {"error": error_map.get(code, "UNKNOWN_ERROR")})
                return

            installation_id = body.get("installationId", "").lower()
            sequence = body.get("sequence")
            fp = _fingerprint(body)

            targets = body.get("targets", [])
            if any(t.get("result") == "failed" for t in targets):
                file_result = "failure" if all(t.get("result") == "failed" for t in targets) else "partial"
            elif targets:
                file_result = "success"
            else:
                file_result = "not_observed"

            with _lock:
                prior = _reports.get(installation_id)
                if prior is not None and sequence == prior["sequence"] and fp == prior["fingerprint"]:
                    self._send_json(200, prior["receipt"])
                    return
                if prior is not None and sequence == prior["sequence"] and fp != prior["fingerprint"]:
                    self._send_json(409, {"error": "REPORT_CONFLICT"})
                    return
                if prior is not None and sequence <= prior["sequence"]:
                    self._send_json(409, {"error": "STALE_REPORT"})
                    return

                receipt = {
                    "installationId": installation_id,
                    "sequence": str(sequence),
                    "receivedAt": "2026-01-01T00:00:00.000Z",
                    "authenticatedGeneration": identity["generation"],
                    "credentialVerification": body.get("credentialVerification", {"result": "not_checked"}),
                    "fileResult": file_result,
                    "targets": [{"target": t.get("target"), "result": t.get("result")} for t in targets],
                }
                _reports[installation_id] = {"sequence": sequence, "fingerprint": fp, "receipt": receipt}
                self._send_json(201, receipt)
            return

        self._send_json(404, {"error": "NOT_FOUND"})


if __name__ == "__main__":
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.serve_forever()

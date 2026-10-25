import hashlib
import json
import secrets
import sqlite3
import threading
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import uuid4

from .models import (
    PairPuckResponse,
    PilotAlert,
    PilotAlertInput,
    PilotDecision,
    PilotHistoryRecord,
    PilotPerson,
    PilotProfile,
    PilotSession,
    PilotTranscriptLine,
    ProtectionFailure,
    ProtectionSessionSnapshot,
    RiskAssessment,
)


RISK_RANK = {"low": 0, "needs_review": 1, "high_risk": 2}


class PilotError(RuntimeError):
    pass


class AuthenticationError(PilotError):
    pass


class AuthorizationError(PilotError):
    pass


class InviteError(PilotError):
    pass


class MissingAlertError(PilotError):
    pass


class MissingProtectionSessionError(PilotError):
    pass


class ActiveProtectionSessionConflict(PilotError):
    pass


class ChunkSequenceConflict(PilotError):
    pass


class DecisionConflict(PilotError):
    def __init__(self, decision: PilotDecision) -> None:
        super().__init__("Peringatan sudah dijawab.")
        self.decision = decision


def _now() -> datetime:
    return datetime.now(UTC)


def _iso(value: datetime) -> str:
    return value.astimezone(UTC).isoformat()


def _token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


class PilotStore:
    """Small persistent store for a controlled two-phone pilot.

    Device tokens are random bearer credentials and only their hashes are stored.
    SQLite's immediate transaction provides the first-decision-wins guarantee.
    """

    def __init__(self, path: str | Path) -> None:
        self.path = str(path)
        if self.path != ":memory:":
            Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        self._connection = sqlite3.connect(self.path, check_same_thread=False)
        self._connection.row_factory = sqlite3.Row
        self._lock = threading.RLock()
        with self._connection:
            self._connection.execute("PRAGMA foreign_keys = ON")
            self._connection.execute("PRAGMA journal_mode = WAL")
            self._connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS families (
                    id TEXT PRIMARY KEY,
                    invite_code TEXT UNIQUE NOT NULL,
                    invite_expires_at TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS members (
                    id TEXT PRIMARY KEY,
                    family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
                    role TEXT NOT NULL CHECK(role IN ('parent', 'guardian')),
                    name TEXT NOT NULL,
                    relation TEXT NOT NULL,
                    token_hash TEXT UNIQUE NOT NULL,
                    created_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS alerts (
                    id TEXT PRIMARY KEY,
                    family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
                    caller_detail TEXT NOT NULL,
                    channel TEXT NOT NULL,
                    started_at TEXT NOT NULL,
                    raised_at TEXT NOT NULL,
                    level TEXT NOT NULL,
                    signals_json TEXT NOT NULL,
                    evidence_json TEXT NOT NULL,
                    decision_member_id TEXT REFERENCES members(id),
                    decision_verdict TEXT,
                    decision_at TEXT,
                    call_ended INTEGER NOT NULL DEFAULT 0,
                    updated_at TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS alerts_family_updated
                ON alerts(family_id, updated_at DESC);

                CREATE TABLE IF NOT EXISTS push_tokens (
                    token TEXT PRIMARY KEY,
                    member_id TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
                    environment TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS pucks (
                    id TEXT PRIMARY KEY,
                    family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
                    display_name TEXT NOT NULL,
                    token_hash TEXT UNIQUE NOT NULL,
                    created_at TEXT NOT NULL,
                    last_seen_at TEXT
                );

                CREATE TABLE IF NOT EXISTS protection_sessions (
                    id TEXT PRIMARY KEY,
                    family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
                    parent_id TEXT NOT NULL REFERENCES members(id),
                    call_id TEXT NOT NULL,
                    channel TEXT CHECK(channel IN ('cellular', 'whatsapp')),
                    language TEXT NOT NULL DEFAULT 'id' CHECK(language IN ('id', 'en')),
                    status TEXT NOT NULL CHECK(status IN (
                        'waiting_for_puck', 'listening', 'completed', 'error'
                    )),
                    started_at TEXT NOT NULL,
                    end_requested_at TEXT,
                    ended_at TEXT,
                    outcome TEXT CHECK(outcome IN ('analyzed', 'no_speech')),
                    masked_transcript TEXT NOT NULL DEFAULT '',
                    assessment_json TEXT,
                    failure_json TEXT,
                    next_sequence INTEGER NOT NULL DEFAULT 0,
                    last_sequence INTEGER,
                    last_digest TEXT,
                    puck_id TEXT REFERENCES pucks(id),
                    revision INTEGER NOT NULL DEFAULT 0,
                    UNIQUE(family_id, call_id)
                );

                CREATE UNIQUE INDEX IF NOT EXISTS protection_one_active_per_family
                ON protection_sessions(family_id)
                WHERE status IN ('waiting_for_puck', 'listening');
                """
            )
            self._ensure_protection_session_metadata_columns()

    def close(self) -> None:
        with self._lock:
            self._connection.close()

    def create_family(self, parent_name: str) -> PilotSession:
        name = self._required(parent_name, "Nama orang tua")
        family_id = uuid4().hex
        member_id = uuid4().hex
        token = secrets.token_urlsafe(32)
        code = self._new_code()
        now = _now()
        expires = now + timedelta(minutes=10)
        with self._lock, self._connection:
            self._connection.execute(
                "INSERT INTO families VALUES (?, ?, ?, ?)",
                (family_id, code, _iso(expires), _iso(now)),
            )
            self._connection.execute(
                "INSERT INTO members (id, family_id, role, name, relation, token_hash, created_at) VALUES (?, ?, 'parent', ?, 'Orang tua', ?, ?)",
                (member_id, family_id, name, _token_hash(token), _iso(now)),
            )
        return PilotSession(
            family_id=family_id,
            member=PilotPerson(id=member_id, name=name, relation="Orang tua", role="parent"),
            access_token=token,
            invite_code=code,
            invite_expires_at=expires,
        )

    def join_family(self, code: str, name: str, relation: str) -> PilotSession:
        normalized_code = "".join(character for character in code if character.isdigit())
        if len(normalized_code) != 6:
            raise InviteError("Kode undangan harus 6 angka.")
        name = self._required(name, "Nama pengawas")
        relation = self._required(relation, "Hubungan")
        with self._lock:
            family = self._connection.execute(
                "SELECT * FROM families WHERE invite_code = ?", (normalized_code,)
            ).fetchone()
            if family is None:
                raise InviteError("Kode undangan tidak ditemukan.")
            if datetime.fromisoformat(family["invite_expires_at"]) <= _now():
                raise InviteError("Kode undangan sudah kedaluwarsa.")
            guardian_count = self._connection.execute(
                "SELECT COUNT(*) FROM members WHERE family_id = ? AND role = 'guardian'",
                (family["id"],),
            ).fetchone()[0]
            if guardian_count >= 5:
                raise InviteError("Keluarga ini sudah memiliki terlalu banyak pengawas.")

            member_id = uuid4().hex
            token = secrets.token_urlsafe(32)
            now = _now()
            with self._connection:
                self._connection.execute(
                    "INSERT INTO members (id, family_id, role, name, relation, token_hash, created_at) VALUES (?, ?, 'guardian', ?, ?, ?, ?)",
                    (member_id, family["id"], name, relation, _token_hash(token), _iso(now)),
                )
        return PilotSession(
            family_id=family["id"],
            member=PilotPerson(id=member_id, name=name, relation=relation, role="guardian"),
            access_token=token,
        )

    def renew_invite(self, token: str) -> tuple[str, datetime]:
        member = self.authenticate(token)
        if member["role"] != "parent":
            raise AuthorizationError("Hanya orang tua yang dapat membuat undangan.")
        code = self._new_code()
        expires = _now() + timedelta(minutes=10)
        with self._lock, self._connection:
            self._connection.execute(
                "UPDATE families SET invite_code = ?, invite_expires_at = ? WHERE id = ?",
                (code, _iso(expires), member["family_id"]),
            )
        return code, expires

    def authenticate(self, token: str) -> sqlite3.Row:
        if not token:
            raise AuthenticationError("Token perangkat diperlukan.")
        with self._lock:
            member = self._connection.execute(
                "SELECT * FROM members WHERE token_hash = ?", (_token_hash(token),)
            ).fetchone()
        if member is None:
            raise AuthenticationError("Token perangkat tidak valid.")
        return member

    def pair_puck(self, code: str, display_name: str) -> PairPuckResponse:
        normalized_code = "".join(character for character in code if character.isdigit())
        if len(normalized_code) != 6:
            raise InviteError("Kode undangan harus 6 angka.")
        name = self._required(display_name, "Nama puck")
        with self._lock:
            family = self._connection.execute(
                "SELECT * FROM families WHERE invite_code = ?", (normalized_code,)
            ).fetchone()
            if family is None:
                raise InviteError("Kode undangan tidak ditemukan.")
            if datetime.fromisoformat(family["invite_expires_at"]) <= _now():
                raise InviteError("Kode undangan sudah kedaluwarsa.")
            return self._insert_puck(family["id"], name)

    def pair_puck_for_parent(self, token: str, display_name: str) -> PairPuckResponse:
        member = self.authenticate(token)
        if member["role"] != "parent":
            raise AuthorizationError("Hanya orang tua yang dapat memasangkan puck.")
        name = self._required(display_name, "Nama puck")
        with self._lock:
            return self._insert_puck(member["family_id"], name)

    def _insert_puck(self, family_id: str, name: str) -> PairPuckResponse:
        puck_id = uuid4().hex
        token = secrets.token_urlsafe(32)
        with self._connection:
            self._connection.execute(
                """
                INSERT INTO pucks (
                    id, family_id, display_name, token_hash, created_at, last_seen_at
                ) VALUES (?, ?, ?, ?, ?, NULL)
                """,
                (puck_id, family_id, name, _token_hash(token), _iso(_now())),
            )
        return PairPuckResponse(
            puck_id=puck_id,
            family_id=family_id,
            display_name=name,
            access_token=token,
        )

    def authenticate_puck(self, token: str) -> sqlite3.Row:
        if not token:
            raise AuthenticationError("Token puck diperlukan.")
        with self._lock:
            puck = self._connection.execute(
                "SELECT * FROM pucks WHERE token_hash = ?", (_token_hash(token),)
            ).fetchone()
        if puck is None:
            raise AuthenticationError("Token puck tidak valid.")
        return puck

    def create_protection_session(
        self,
        token: str,
        call_id: str,
        started_at: datetime,
        channel: str | None,
        title: str | None = None,
        caller_detail: str | None = None,
        language: str = "id",
    ) -> ProtectionSessionSnapshot:
        member = self.authenticate(token)
        if member["role"] != "parent":
            raise AuthorizationError("Hanya orang tua yang dapat memulai perlindungan.")
        if channel not in {None, "cellular", "whatsapp"}:
            raise ValueError("Kanal panggilan tidak valid.")
        if language not in {"id", "en"}:
            raise ValueError("Bahasa tidak valid.")
        normalized_call_id = str(call_id).lower()
        with self._lock:
            existing = self._connection.execute(
                "SELECT * FROM protection_sessions WHERE family_id = ? AND call_id = ?",
                (member["family_id"], normalized_call_id),
            ).fetchone()
            if existing is not None:
                return self._protection_snapshot(existing)
            active = self._connection.execute(
                """
                SELECT * FROM protection_sessions
                WHERE family_id = ? AND status IN ('waiting_for_puck', 'listening')
                ORDER BY started_at DESC LIMIT 1
                """,
                (member["family_id"],),
            ).fetchone()
            if active is not None:
                if active["status"] == "listening" and active["puck_id"] is not None:
                    return self._protection_snapshot(active)
                raise ActiveProtectionSessionConflict(
                    "Keluarga sudah memiliki sesi perlindungan aktif."
                )
            session_id = uuid4().hex
            with self._connection:
                self._connection.execute(
                    """
                    INSERT INTO protection_sessions (
                        id, family_id, parent_id, call_id, title, caller_detail,
                        channel, language, status, started_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'waiting_for_puck', ?)
                    """,
                    (
                        session_id,
                        member["family_id"],
                        member["id"],
                        normalized_call_id,
                        title or "Panggilan terdeteksi",
                        caller_detail or "Nomor tidak tersedia",
                        channel,
                        language,
                        _iso(started_at),
                    ),
                )
            row = self._connection.execute(
                "SELECT * FROM protection_sessions WHERE id = ?", (session_id,)
            ).fetchone()
        return self._protection_snapshot(row)

    def create_puck_protection_session(
        self,
        token: str,
        call_id: str,
        started_at: datetime,
        channel: str | None,
        title: str | None = None,
        caller_detail: str | None = None,
        language: str = "id",
    ) -> tuple[ProtectionSessionSnapshot, bool]:
        puck = self.authenticate_puck(token)
        if channel not in {None, "cellular", "whatsapp"}:
            raise ValueError("Kanal panggilan tidak valid.")
        if language not in {"id", "en"}:
            raise ValueError("Bahasa tidak valid.")
        normalized_call_id = str(call_id).lower()
        now = _iso(_now())
        with self._lock:
            existing = self._connection.execute(
                "SELECT * FROM protection_sessions WHERE family_id = ? AND call_id = ?",
                (puck["family_id"], normalized_call_id),
            ).fetchone()
            if existing is not None:
                return self._protection_snapshot(existing), False
            active = self._connection.execute(
                """
                SELECT 1 FROM protection_sessions
                WHERE family_id = ? AND status IN ('waiting_for_puck', 'listening')
                """,
                (puck["family_id"],),
            ).fetchone()
            if active is not None:
                raise ActiveProtectionSessionConflict(
                    "Keluarga sudah memiliki sesi perlindungan aktif."
                )
            parent = self._connection.execute(
                """
                SELECT id FROM members
                WHERE family_id = ? AND role = 'parent'
                ORDER BY created_at ASC LIMIT 1
                """,
                (puck["family_id"],),
            ).fetchone()
            if parent is None:
                raise AuthorizationError("Keluarga puck tidak memiliki akun orang tua.")
            session_id = uuid4().hex
            with self._connection:
                self._connection.execute(
                    """
                    INSERT INTO protection_sessions (
                        id, family_id, parent_id, call_id, title, caller_detail,
                        channel, language, status, started_at, puck_id
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'listening', ?, ?)
                    """,
                    (
                        session_id,
                        puck["family_id"],
                        parent["id"],
                        normalized_call_id,
                        title or "Panggilan terdeteksi",
                        caller_detail or "Nomor tidak tersedia",
                        channel,
                        language,
                        _iso(started_at),
                        puck["id"],
                    ),
                )
                self._connection.execute(
                    "UPDATE pucks SET last_seen_at = ? WHERE id = ?",
                    (now, puck["id"]),
                )
            row = self._connection.execute(
                "SELECT * FROM protection_sessions WHERE id = ?", (session_id,)
            ).fetchone()
        return self._protection_snapshot(row), True

    def get_protection_session(
        self, token: str, session_id: str
    ) -> ProtectionSessionSnapshot:
        member = self.authenticate(token)
        if member["role"] != "parent":
            raise AuthorizationError("Hanya orang tua yang dapat melihat sesi perlindungan.")
        with self._lock:
            row = self._connection.execute(
                "SELECT * FROM protection_sessions WHERE id = ?", (session_id,)
            ).fetchone()
        if row is None:
            raise MissingProtectionSessionError("Sesi perlindungan tidak ditemukan.")
        if row["family_id"] != member["family_id"]:
            raise AuthorizationError("Sesi perlindungan berasal dari keluarga lain.")
        return self._protection_snapshot(row)

    def active_protection_session(self, token: str) -> ProtectionSessionSnapshot:
        snapshot, _ = self.claim_active_protection_session(token)
        return snapshot

    def claim_active_protection_session(
        self, token: str
    ) -> tuple[ProtectionSessionSnapshot, bool]:
        puck = self.authenticate_puck(token)
        now = _iso(_now())
        with self._lock, self._connection:
            row = self._connection.execute(
                """
                SELECT * FROM protection_sessions
                WHERE family_id = ? AND status IN ('waiting_for_puck', 'listening')
                ORDER BY started_at DESC LIMIT 1
                """,
                (puck["family_id"],),
            ).fetchone()
            if row is None:
                raise MissingProtectionSessionError("Tidak ada sesi perlindungan aktif.")
            if row["puck_id"] not in {None, puck["id"]}:
                raise AuthorizationError("Sesi aktif sedang digunakan puck lain.")
            newly_claimed = row["puck_id"] is None
            self._connection.execute(
                "UPDATE pucks SET last_seen_at = ? WHERE id = ?", (now, puck["id"])
            )
            if newly_claimed:
                self._connection.execute(
                    """
                    UPDATE protection_sessions
                    SET puck_id = ?, status = 'listening', revision = revision + 1
                    WHERE id = ?
                    """,
                    (puck["id"], row["id"]),
                )
            row = self._connection.execute(
                "SELECT * FROM protection_sessions WHERE id = ?", (row["id"],)
            ).fetchone()
        return self._protection_snapshot(row), newly_claimed

    def get_puck_protection_session(
        self, token: str, session_id: str
    ) -> ProtectionSessionSnapshot:
        puck = self.authenticate_puck(token)
        with self._lock:
            row = self._connection.execute(
                "SELECT * FROM protection_sessions WHERE id = ?", (session_id,)
            ).fetchone()
        if row is None:
            raise MissingProtectionSessionError("Sesi perlindungan tidak ditemukan.")
        if row["family_id"] != puck["family_id"] or row["puck_id"] != puck["id"]:
            raise AuthorizationError("Sesi perlindungan berasal dari keluarga lain.")
        return self._protection_snapshot(row)

    def record_protection_chunk(
        self,
        token: str,
        session_id: str,
        *,
        sequence: int,
        digest: str,
        masked_transcript: str,
        assessment: RiskAssessment | None,
        final: bool,
    ) -> ProtectionSessionSnapshot:
        puck = self.authenticate_puck(token)
        with self._lock:
            self._connection.execute("BEGIN IMMEDIATE")
            try:
                row = self._connection.execute(
                    "SELECT * FROM protection_sessions WHERE id = ?", (session_id,)
                ).fetchone()
                if row is None:
                    raise MissingProtectionSessionError("Sesi perlindungan tidak ditemukan.")
                if row["family_id"] != puck["family_id"] or row["puck_id"] != puck["id"]:
                    raise AuthorizationError("Sesi perlindungan berasal dari keluarga lain.")
                if sequence == row["last_sequence"]:
                    if digest != row["last_digest"]:
                        raise ChunkSequenceConflict("Unggahan ulang memiliki audio berbeda.")
                    self._connection.rollback()
                    return self._protection_snapshot(row)
                if sequence != row["next_sequence"]:
                    raise ChunkSequenceConflict("Nomor urutan chunk tidak sesuai.")
                if row["status"] != "listening":
                    raise ActiveProtectionSessionConflict("Sesi perlindungan tidak sedang mendengar.")

                assessment_json = (
                    json.dumps(assessment.model_dump(mode="json"), ensure_ascii=False)
                    if assessment is not None
                    else None
                )
                outcome = None
                ended_at = None
                status = row["status"]
                if final:
                    status = "completed"
                    outcome = "analyzed" if assessment is not None or masked_transcript else "no_speech"
                    ended_at = _iso(_now())
                self._connection.execute(
                    """
                    UPDATE protection_sessions
                    SET masked_transcript = ?, assessment_json = ?, status = ?, outcome = ?,
                        ended_at = ?, next_sequence = next_sequence + 1,
                        last_sequence = ?, last_digest = ?, revision = revision + 1
                    WHERE id = ?
                    """,
                    (
                        masked_transcript,
                        assessment_json,
                        status,
                        outcome,
                        ended_at,
                        sequence,
                        digest,
                        session_id,
                    ),
                )
                if final:
                    self._connection.execute(
                        """
                        UPDATE alerts
                        SET call_ended = 1, updated_at = ?
                        WHERE id = ? AND family_id = ?
                        """,
                        (_iso(_now()), row["call_id"], row["family_id"]),
                    )
                self._connection.commit()
            except Exception:
                if self._connection.in_transaction:
                    self._connection.rollback()
                raise
            row = self._connection.execute(
                "SELECT * FROM protection_sessions WHERE id = ?", (session_id,)
            ).fetchone()
        return self._protection_snapshot(row)

    def update_protection_assessment(
        self, token: str, session_id: str, assessment: RiskAssessment
    ) -> ProtectionSessionSnapshot:
        puck = self.authenticate_puck(token)
        with self._lock:
            row = self._connection.execute(
                "SELECT * FROM protection_sessions WHERE id = ?", (session_id,)
            ).fetchone()
            if row is None:
                raise MissingProtectionSessionError("Sesi perlindungan tidak ditemukan.")
            if row["family_id"] != puck["family_id"] or row["puck_id"] != puck["id"]:
                raise AuthorizationError("Sesi perlindungan berasal dari keluarga lain.")
            if row["status"] != "error":
                if row["assessment_json"]:
                    stored = RiskAssessment.model_validate_json(row["assessment_json"])
                    if RISK_RANK[stored.risk_level] > RISK_RANK[assessment.risk_level]:
                        assessment = stored
                with self._connection:
                    self._connection.execute(
                        """
                        UPDATE protection_sessions
                        SET assessment_json = ?, revision = revision + 1
                        WHERE id = ?
                        """,
                        (json.dumps(assessment.model_dump(mode="json"), ensure_ascii=False), session_id),
                    )
            row = self._connection.execute(
                "SELECT * FROM protection_sessions WHERE id = ?", (session_id,)
            ).fetchone()
        return self._protection_snapshot(row)

    def inspect_protection_chunk(
        self,
        token: str,
        session_id: str,
        *,
        sequence: int,
        digest: str,
    ) -> tuple[ProtectionSessionSnapshot, bool]:
        puck = self.authenticate_puck(token)
        with self._lock:
            row = self._connection.execute(
                "SELECT * FROM protection_sessions WHERE id = ?", (session_id,)
            ).fetchone()
        if row is None:
            raise MissingProtectionSessionError("Sesi perlindungan tidak ditemukan.")
        if row["family_id"] != puck["family_id"] or row["puck_id"] != puck["id"]:
            raise AuthorizationError("Sesi perlindungan berasal dari keluarga lain.")
        if sequence == row["last_sequence"]:
            if digest != row["last_digest"]:
                raise ChunkSequenceConflict("Unggahan ulang memiliki audio berbeda.")
            return self._protection_snapshot(row), True
        if sequence != row["next_sequence"]:
            raise ChunkSequenceConflict("Nomor urutan chunk tidak sesuai.")
        if row["status"] != "listening":
            raise ActiveProtectionSessionConflict("Sesi perlindungan tidak sedang mendengar.")
        return self._protection_snapshot(row), False

    def fail_protection_session(
        self, token: str, session_id: str, failure: ProtectionFailure
    ) -> ProtectionSessionSnapshot:
        puck = self.authenticate_puck(token)
        with self._lock:
            row = self._connection.execute(
                "SELECT * FROM protection_sessions WHERE id = ?", (session_id,)
            ).fetchone()
            if row is None:
                raise MissingProtectionSessionError("Sesi perlindungan tidak ditemukan.")
            if row["family_id"] != puck["family_id"] or row["puck_id"] != puck["id"]:
                raise AuthorizationError("Sesi perlindungan berasal dari keluarga lain.")
            with self._connection:
                self._connection.execute(
                    """
                    UPDATE protection_sessions
                    SET status = 'error', outcome = NULL, assessment_json = NULL,
                        failure_json = ?, ended_at = ?, revision = revision + 1
                    WHERE id = ?
                    """,
                    (
                        json.dumps(failure.model_dump(mode="json"), ensure_ascii=False),
                        _iso(_now()),
                        session_id,
                    ),
                )
                self._connection.execute(
                    """
                    UPDATE alerts
                    SET call_ended = 1, updated_at = ?
                    WHERE id = ? AND family_id = ?
                    """,
                    (_iso(_now()), row["call_id"], row["family_id"]),
                )
            updated = self._connection.execute(
                "SELECT * FROM protection_sessions WHERE id = ?", (session_id,)
            ).fetchone()
        return self._protection_snapshot(updated)

    def request_protection_end(
        self, token: str, session_id: str
    ) -> ProtectionSessionSnapshot:
        member, row = self._parent_protection_session(token, session_id)
        del member
        if row["status"] in {"completed", "error"}:
            return self._protection_snapshot(row)
        now = _iso(_now())
        without_puck = row["puck_id"] is None
        with self._lock, self._connection:
            self._connection.execute(
                """
                UPDATE protection_sessions
                SET end_requested_at = ?,
                    status = CASE WHEN ? THEN 'completed' ELSE status END,
                    outcome = CASE WHEN ? THEN 'no_speech' ELSE outcome END,
                    ended_at = CASE WHEN ? THEN ? ELSE ended_at END,
                    revision = revision + 1
                WHERE id = ?
                """,
                (now, without_puck, without_puck, without_puck, now, session_id),
            )
            if without_puck:
                self._connection.execute(
                    """
                    UPDATE alerts
                    SET call_ended = 1, updated_at = ?
                    WHERE id = ? AND family_id = ?
                    """,
                    (now, row["call_id"], row["family_id"]),
                )
            updated = self._connection.execute(
                "SELECT * FROM protection_sessions WHERE id = ?", (session_id,)
            ).fetchone()
        return self._protection_snapshot(updated)

    def delete_protection_session(self, token: str, session_id: str) -> None:
        self._parent_protection_session(token, session_id)
        with self._lock, self._connection:
            self._connection.execute(
                "DELETE FROM protection_sessions WHERE id = ?", (session_id,)
            )

    def _parent_protection_session(
        self, token: str, session_id: str
    ) -> tuple[sqlite3.Row, sqlite3.Row]:
        member = self.authenticate(token)
        if member["role"] != "parent":
            raise AuthorizationError("Hanya orang tua yang dapat mengubah sesi perlindungan.")
        with self._lock:
            row = self._connection.execute(
                "SELECT * FROM protection_sessions WHERE id = ?", (session_id,)
            ).fetchone()
        if row is None:
            raise MissingProtectionSessionError("Sesi perlindungan tidak ditemukan.")
        if row["family_id"] != member["family_id"]:
            raise AuthorizationError("Sesi perlindungan berasal dari keluarga lain.")
        return member, row

    @staticmethod
    def _protection_snapshot(row: sqlite3.Row) -> ProtectionSessionSnapshot:
        return ProtectionSessionSnapshot(
            id=row["id"],
            call_id=row["call_id"],
            title=row["title"],
            caller_detail=row["caller_detail"],
            channel=row["channel"],
            language=row["language"],
            status=row["status"],
            puck_connected=row["puck_id"] is not None,
            masked_transcript=row["masked_transcript"],
            assessment=(
                RiskAssessment.model_validate_json(row["assessment_json"])
                if row["assessment_json"]
                else None
            ),
            outcome=row["outcome"],
            end_requested=row["end_requested_at"] is not None,
            revision=row["revision"],
            next_sequence=row["next_sequence"],
            started_at=row["started_at"],
            end_requested_at=row["end_requested_at"],
            ended_at=row["ended_at"],
            failure=(
                ProtectionFailure.model_validate_json(row["failure_json"])
                if row["failure_json"]
                else None
            ),
        )

    def _ensure_protection_session_metadata_columns(self) -> None:
        columns = {
            row["name"]
            for row in self._connection.execute("PRAGMA table_info(protection_sessions)")
        }
        if "title" not in columns:
            self._connection.execute(
                """
                ALTER TABLE protection_sessions
                ADD COLUMN title TEXT NOT NULL DEFAULT 'Panggilan terdeteksi'
                """
            )
        if "caller_detail" not in columns:
            self._connection.execute(
                """
                ALTER TABLE protection_sessions
                ADD COLUMN caller_detail TEXT NOT NULL DEFAULT 'Nomor tidak tersedia'
                """
            )
        if "language" not in columns:
            self._connection.execute(
                """
                ALTER TABLE protection_sessions
                ADD COLUMN language TEXT NOT NULL DEFAULT 'id'
                """
            )

    def profile(self, token: str) -> PilotProfile:
        member = self.authenticate(token)
        people = self._family_members(member["family_id"])
        parent = next(person for person in people if person.role == "parent")
        with self._lock:
            active = self._connection.execute(
                """SELECT status, end_requested_at FROM protection_sessions
                   WHERE family_id = ? AND status IN ('waiting_for_puck', 'listening')
                   ORDER BY started_at DESC LIMIT 1""",
                (member["family_id"],),
            ).fetchone()
        session_status = "idle" if active is None else (
            "finishing" if active["end_requested_at"] is not None else active["status"]
        )
        return PilotProfile(
            family_id=member["family_id"],
            member=self._person(member),
            parent=parent,
            guardians=[person for person in people if person.role == "guardian"],
            session_status=session_status,
        )

    def register_push_token(self, access_token: str, push_token: str, environment: str) -> None:
        member = self.authenticate(access_token)
        cleaned = push_token.strip().lower()
        if not cleaned or any(character not in "0123456789abcdef" for character in cleaned):
            raise ValueError("Token APNs tidak valid.")
        if environment not in {"sandbox", "production"}:
            raise ValueError("Lingkungan APNs tidak valid.")
        with self._lock, self._connection:
            self._connection.execute(
                """
                INSERT INTO push_tokens (token, member_id, environment, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(token) DO UPDATE SET
                    member_id = excluded.member_id,
                    environment = excluded.environment,
                    updated_at = excluded.updated_at
                """,
                (cleaned, member["id"], environment, _iso(_now())),
            )

    def notification_tokens(
        self, access_token: str, target_role: str, environment: str
    ) -> list[str]:
        member = self.authenticate(access_token)
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT push_tokens.token
                FROM push_tokens
                JOIN members ON members.id = push_tokens.member_id
                WHERE members.family_id = ? AND members.role = ?
                  AND push_tokens.environment = ?
                """,
                (member["family_id"], target_role, environment),
            ).fetchall()
        return [row["token"] for row in rows]

    def protection_notification_tokens(
        self,
        puck_token: str,
        session_id: str,
        target_role: str,
        environment: str,
    ) -> list[str]:
        if target_role not in {"parent", "guardian"}:
            raise ValueError("Peran penerima notifikasi tidak valid.")
        puck = self.authenticate_puck(puck_token)
        with self._lock:
            session = self._connection.execute(
                "SELECT family_id, puck_id FROM protection_sessions WHERE id = ?",
                (session_id,),
            ).fetchone()
            if session is None:
                raise MissingProtectionSessionError("Sesi perlindungan tidak ditemukan.")
            if session["family_id"] != puck["family_id"] or session["puck_id"] != puck["id"]:
                raise AuthorizationError("Sesi perlindungan berasal dari keluarga lain.")
            rows = self._connection.execute(
                """
                SELECT push_tokens.token
                FROM push_tokens
                JOIN members ON members.id = push_tokens.member_id
                WHERE members.family_id = ? AND members.role = ?
                  AND push_tokens.environment = ?
                """,
                (puck["family_id"], target_role, environment),
            ).fetchall()
        return [row["token"] for row in rows]

    def upsert_protection_alert(
        self, puck_token: str, session_id: str
    ) -> tuple[PilotAlert | None, bool]:
        puck = self.authenticate_puck(puck_token)
        now = _iso(_now())
        with self._lock, self._connection:
            session = self._connection.execute(
                "SELECT * FROM protection_sessions WHERE id = ?", (session_id,)
            ).fetchone()
            if session is None:
                raise MissingProtectionSessionError("Sesi perlindungan tidak ditemukan.")
            if session["family_id"] != puck["family_id"] or session["puck_id"] != puck["id"]:
                raise AuthorizationError("Sesi perlindungan berasal dari keluarga lain.")
            assessment = (
                RiskAssessment.model_validate_json(session["assessment_json"])
                if session["assessment_json"]
                else None
            )
            if assessment is None or assessment.risk_level == "low":
                return None, False

            alert_id = session["call_id"]
            existing = self._connection.execute(
                "SELECT * FROM alerts WHERE id = ?", (alert_id,)
            ).fetchone()
            if existing is not None and existing["family_id"] != session["family_id"]:
                raise AuthorizationError("Peringatan berasal dari keluarga lain.")

            level = "danger"
            signals = [self._pilot_signal(value) for value in assessment.signals]
            evidence = [
                PilotTranscriptLine(
                    id=index,
                    offset=None,
                    speaker="unknown",
                    text=item.quote,
                    flagged=[item.quote],
                    signals=[self._pilot_signal(value) for value in item.signals],
                ).model_dump(mode="json")
                for index, item in enumerate(assessment.evidence)
            ]
            if existing is not None:
                if existing["level"] == "danger":
                    level = "danger"
                old_evidence = json.loads(existing["evidence_json"])
                if len(old_evidence) > len(evidence):
                    evidence = old_evidence
                    signals = json.loads(existing["signals_json"])
            should_notify = existing is None or (
                existing["level"] != level and level == "danger"
            )
            call_ended = session["status"] in {"completed", "error"}
            self._connection.execute(
                """
                INSERT INTO alerts (
                    id, family_id, caller_detail, channel, started_at, raised_at,
                    level, signals_json, evidence_json, call_ended, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    caller_detail = excluded.caller_detail,
                    channel = excluded.channel,
                    level = excluded.level,
                    signals_json = excluded.signals_json,
                    evidence_json = excluded.evidence_json,
                    call_ended = MAX(alerts.call_ended, excluded.call_ended),
                    updated_at = excluded.updated_at
                """,
                (
                    alert_id,
                    session["family_id"],
                    session["caller_detail"],
                    session["channel"] or "cellular",
                    session["started_at"],
                    now,
                    level,
                    json.dumps(signals, ensure_ascii=False),
                    json.dumps(evidence, ensure_ascii=False),
                    int(call_ended),
                    now,
                ),
            )
        return self._alert(alert_id, session["family_id"]), should_notify

    def publish_alert(self, token: str, value: PilotAlertInput) -> PilotAlert:
        alert, _ = self.publish_alert_result(token, value)
        return alert

    def publish_alert_result(self, token: str, value: PilotAlertInput) -> tuple[PilotAlert, bool]:
        member = self.authenticate(token)
        if member["role"] != "parent":
            raise AuthorizationError("Hanya perangkat orang tua yang dapat membuat peringatan.")
        value.level = "danger"
        now = _iso(_now())
        signals = json.dumps(value.signals, ensure_ascii=False)
        evidence = json.dumps([line.model_dump(mode="json") for line in value.evidence], ensure_ascii=False)
        with self._lock, self._connection:
            existing = self._connection.execute(
                "SELECT * FROM alerts WHERE id = ?", (str(value.id),)
            ).fetchone()
            if existing is not None and existing["family_id"] != member["family_id"]:
                raise AuthorizationError("Peringatan berasal dari keluarga lain.")
            if existing is not None:
                old_evidence = json.loads(existing["evidence_json"])
                if len(old_evidence) > len(value.evidence):
                    return self._alert(str(value.id), member["family_id"]), False
                if existing["level"] == "danger":
                    value.level = "danger"
            should_notify = existing is None or (existing["level"] != value.level and value.level == "danger")
            self._connection.execute(
                """
                INSERT INTO alerts (
                    id, family_id, caller_detail, channel, started_at, raised_at,
                    level, signals_json, evidence_json, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    caller_detail = excluded.caller_detail,
                    level = excluded.level,
                    signals_json = excluded.signals_json,
                    evidence_json = excluded.evidence_json,
                    updated_at = excluded.updated_at
                """,
                (
                    str(value.id), member["family_id"], value.caller_detail, value.channel,
                    _iso(value.started_at), _iso(value.raised_at), value.level,
                    signals, evidence, now,
                ),
            )
        return self._alert(str(value.id), member["family_id"]), should_notify

    def alerts(self, token: str) -> list[PilotAlert]:
        member = self.authenticate(token)
        with self._lock:
            rows = self._connection.execute(
                "SELECT id FROM alerts WHERE family_id = ? ORDER BY updated_at DESC LIMIT 100",
                (member["family_id"],),
            ).fetchall()
        return [self._alert(row["id"], member["family_id"]) for row in rows]

    def history(self, token: str, limit: int = 100) -> list[PilotHistoryRecord]:
        member = self.authenticate(token)
        bounded_limit = max(1, min(limit, 100))
        with self._lock:
            rows = self._connection.execute(
                """
                SELECT protection_sessions.*, alerts.id AS alert_id
                FROM protection_sessions
                LEFT JOIN alerts
                  ON alerts.id = protection_sessions.call_id
                 AND alerts.family_id = protection_sessions.family_id
                WHERE protection_sessions.family_id = ?
                  AND protection_sessions.status IN ('completed', 'error')
                ORDER BY protection_sessions.started_at DESC
                LIMIT ?
                """,
                (member["family_id"], bounded_limit),
            ).fetchall()
        people = self._family_members(member["family_id"])
        parent = next(person for person in people if person.role == "parent")
        return [self._history_record(row, parent, member["family_id"]) for row in rows]

    def _history_record(
        self, row: sqlite3.Row, parent: PilotPerson, family_id: str
    ) -> PilotHistoryRecord:
        assessment = (
            RiskAssessment.model_validate_json(row["assessment_json"])
            if row["assessment_json"]
            else None
        )
        failure = (
            ProtectionFailure.model_validate_json(row["failure_json"])
            if row["failure_json"]
            else None
        )
        if row["status"] == "error":
            outcome = "error"
            presentation = "unassessed"
            signals: list[str] = []
            evidence: list[PilotTranscriptLine] = []
        elif row["outcome"] == "no_speech" or assessment is None:
            outcome = "no_speech"
            presentation = "unassessed"
            signals = []
            evidence = []
        else:
            outcome = "analyzed"
            presentation = {
                "low": "safe",
                "needs_review": "danger",
                "high_risk": "danger",
            }[assessment.risk_level]
            signals = [self._pilot_signal(value) for value in assessment.signals]
            evidence = [
                PilotTranscriptLine(
                    id=index,
                    offset=None,
                    speaker="unknown",
                    text=item.quote,
                    flagged=[item.quote],
                    signals=[self._pilot_signal(value) for value in item.signals],
                )
                for index, item in enumerate(assessment.evidence)
            ]
        started_at = datetime.fromisoformat(row["started_at"])
        ended_at = datetime.fromisoformat(row["ended_at"])
        decision = None
        if row["alert_id"] is not None:
            with self._lock:
                alert = self._connection.execute(
                    "SELECT * FROM alerts WHERE id = ? AND family_id = ?",
                    (row["alert_id"], family_id),
                ).fetchone()
            if alert is not None and alert["decision_member_id"] is not None:
                decision = self._decision(alert)
        return PilotHistoryRecord(
            id=row["call_id"],
            parent=parent,
            title=row["title"],
            caller_detail=row["caller_detail"],
            channel=row["channel"],
            started_at=started_at,
            ended_at=ended_at,
            duration_seconds=max(0.0, (ended_at - started_at).total_seconds()),
            outcome=outcome,
            presentation=presentation,
            signals=signals,
            evidence=evidence,
            decision=decision,
            failure=failure,
        )

    @staticmethod
    def _pilot_signal(value: str) -> str:
        return {
            "impersonation": "impersonation",
            "urgency": "urgency",
            "secret_code": "secretCode",
            "transfer": "transfer",
            "remote_app": "remoteApp",
        }[value]

    def decide(self, token: str, alert_id: str, verdict: str) -> PilotDecision:
        member = self.authenticate(token)
        if member["role"] != "guardian":
            raise AuthorizationError("Hanya pengawas yang dapat memberi keputusan.")
        if verdict not in {"scam", "safe"}:
            raise ValueError("Keputusan tidak valid.")
        alert_id = alert_id.lower()
        decided_at = _now()
        with self._lock:
            self._connection.execute("BEGIN IMMEDIATE")
            try:
                alert = self._connection.execute(
                    "SELECT * FROM alerts WHERE id = ? AND family_id = ?",
                    (alert_id, member["family_id"]),
                ).fetchone()
                if alert is None:
                    raise MissingAlertError("Peringatan tidak ditemukan.")
                if alert["decision_member_id"] is not None:
                    decision = self._decision(alert)
                    self._connection.rollback()
                    raise DecisionConflict(decision)
                self._connection.execute(
                    """
                    UPDATE alerts
                    SET decision_member_id = ?, decision_verdict = ?, decision_at = ?, updated_at = ?
                    WHERE id = ? AND decision_member_id IS NULL
                    """,
                    (member["id"], verdict, _iso(decided_at), _iso(decided_at), alert_id),
                )
                self._connection.commit()
            except Exception:
                if self._connection.in_transaction:
                    self._connection.rollback()
                raise
        return PilotDecision(by=self._person(member), verdict=verdict, at=decided_at)

    def end_alert(self, token: str, alert_id: str) -> PilotAlert:
        member = self.authenticate(token)
        if member["role"] != "parent":
            raise AuthorizationError("Hanya perangkat orang tua yang dapat mengakhiri panggilan.")
        alert_id = alert_id.lower()
        with self._lock, self._connection:
            cursor = self._connection.execute(
                "UPDATE alerts SET call_ended = 1, updated_at = ? WHERE id = ? AND family_id = ?",
                (_iso(_now()), alert_id, member["family_id"]),
            )
            if cursor.rowcount == 0:
                raise MissingAlertError("Peringatan tidak ditemukan.")
        return self._alert(alert_id, member["family_id"])

    def _alert(self, alert_id: str, family_id: str) -> PilotAlert:
        alert_id = alert_id.lower()
        with self._lock:
            row = self._connection.execute(
                "SELECT * FROM alerts WHERE id = ? AND family_id = ?", (alert_id, family_id)
            ).fetchone()
        if row is None:
            raise MissingAlertError("Peringatan tidak ditemukan.")
        people = self._family_members(family_id)
        parent = next(person for person in people if person.role == "parent")
        return PilotAlert(
            id=row["id"],
            parent=parent,
            caller_detail=row["caller_detail"],
            channel=row["channel"],
            started_at=row["started_at"],
            raised_at=row["raised_at"],
            level="danger",
            signals=json.loads(row["signals_json"]),
            evidence=json.loads(row["evidence_json"]),
            recipients=[person for person in people if person.role == "guardian"],
            decision=self._decision(row) if row["decision_member_id"] else None,
            call_ended=bool(row["call_ended"]),
        )

    def _decision(self, alert: sqlite3.Row) -> PilotDecision:
        with self._lock:
            member = self._connection.execute(
                "SELECT * FROM members WHERE id = ?", (alert["decision_member_id"],)
            ).fetchone()
        return PilotDecision(
            by=self._person(member), verdict=alert["decision_verdict"], at=alert["decision_at"]
        )

    def _family_members(self, family_id: str) -> list[PilotPerson]:
        with self._lock:
            members = self._connection.execute(
                "SELECT * FROM members WHERE family_id = ? ORDER BY created_at", (family_id,)
            ).fetchall()
        return [self._person(member) for member in members]

    @staticmethod
    def _person(member: sqlite3.Row) -> PilotPerson:
        return PilotPerson(
            id=member["id"], name=member["name"], relation=member["relation"], role=member["role"],
        )

    def _new_code(self) -> str:
        with self._lock:
            for _ in range(20):
                code = f"{secrets.randbelow(1_000_000):06d}"
                exists = self._connection.execute(
                    "SELECT 1 FROM families WHERE invite_code = ?", (code,)
                ).fetchone()
                if exists is None:
                    return code
        raise PilotError("Tidak dapat membuat kode undangan.")

    @staticmethod
    def _required(value: str, label: str) -> str:
        cleaned = value.strip()
        if not cleaned:
            raise ValueError(f"{label} diperlukan.")
        if len(cleaned) > 80:
            raise ValueError(f"{label} terlalu panjang.")
        return cleaned

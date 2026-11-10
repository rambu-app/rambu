import hashlib
import sqlite3
from datetime import UTC, datetime, timedelta

import pytest

from rambu_api.pilot import ChunkSequenceConflict, PilotError, PilotStore


STARTED_AT = datetime(2026, 10, 1, 10, 0, tzinfo=UTC)


def listening_session(store: PilotStore):
    parent = store.create_family("Ibu Ratna")
    puck = store.pair_puck(parent.invite_code or "", "Rambu Puck")
    session, _ = store.create_puck_protection_session(
        puck.access_token,
        "7F011753-8F09-4A45-8812-8A4591A96B3C",
        STARTED_AT,
        "whatsapp",
    )
    return parent, puck, session


def test_stream_segment_table_is_added_without_losing_existing_data(tmp_path) -> None:
    database = tmp_path / "pilot.sqlite3"
    original = PilotStore(database)
    parent = original.create_family("Ibu Ratna")
    original.close()

    migrated = PilotStore(database)
    tables = {
        row[0]
        for row in migrated._connection.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table'"
        )
    }

    assert "protection_stream_segments" in tables
    assert migrated.profile(parent.access_token).member.name == "Ibu Ratna"


def test_stream_segments_append_in_order_and_retries_are_idempotent() -> None:
    store = PilotStore(":memory:")
    _, puck, session = listening_session(store)

    first = store.record_protection_stream_segment(
        puck.access_token,
        session.id,
        sequence=0,
        digest="digest-0",
        masked_segment="Halo",
        final=False,
    )
    duplicate = store.record_protection_stream_segment(
        puck.access_token,
        session.id,
        sequence=0,
        digest="digest-0",
        masked_segment="Halo",
        final=False,
    )
    completed = store.record_protection_stream_segment(
        puck.access_token,
        session.id,
        sequence=1,
        digest="digest-1",
        masked_segment="minta [KODE]",
        final=True,
    )

    assert first.masked_transcript == "Halo"
    assert duplicate.revision == first.revision
    assert completed.masked_transcript == "Halo minta [KODE]"
    assert completed.status == "completed"
    assert completed.outcome == "analyzed"


def test_stream_segment_digest_conflict_and_out_of_order_are_rejected() -> None:
    store = PilotStore(":memory:")
    _, puck, session = listening_session(store)
    store.record_protection_stream_segment(
        puck.access_token,
        session.id,
        sequence=0,
        digest="first",
        masked_segment="Halo",
        final=False,
    )

    with pytest.raises(ChunkSequenceConflict, match="berbeda"):
        store.record_protection_stream_segment(
            puck.access_token,
            session.id,
            sequence=0,
            digest="changed",
            masked_segment="Berubah",
            final=False,
        )
    with pytest.raises(ChunkSequenceConflict, match="urutan"):
        store.record_protection_stream_segment(
            puck.access_token,
            session.id,
            sequence=2,
            digest="later",
            masked_segment="Nanti",
            final=False,
        )


def test_empty_final_stream_segment_completes_as_no_speech() -> None:
    store = PilotStore(":memory:")
    _, puck, session = listening_session(store)

    completed = store.record_protection_stream_segment(
        puck.access_token,
        session.id,
        sequence=0,
        digest=hashlib.sha256(b"").hexdigest(),
        masked_segment="",
        final=True,
    )

    assert completed.status == "completed"
    assert completed.outcome == "no_speech"


def test_stream_segment_authorization_and_restart_persistence(tmp_path) -> None:
    database = tmp_path / "pilot.sqlite3"
    store = PilotStore(database)
    parent, puck, session = listening_session(store)
    other_parent = store.create_family("Bapak Budi")
    other_puck = store.pair_puck(other_parent.invite_code or "", "Puck lain")

    with pytest.raises(PilotError, match="keluarga lain"):
        store.record_protection_stream_segment(
            other_puck.access_token,
            session.id,
            sequence=0,
            digest="digest",
            masked_segment="Halo",
            final=False,
        )

    store.record_protection_stream_segment(
        puck.access_token,
        session.id,
        sequence=0,
        digest="digest",
        masked_segment="Halo",
        final=False,
    )
    store.close()

    reopened = PilotStore(database)
    snapshot = reopened.get_protection_session(parent.access_token, session.id)
    assert snapshot.masked_transcript == "Halo"
    assert reopened._connection.execute(
        "SELECT COUNT(*) FROM protection_stream_segments WHERE session_id = ?",
        (session.id,),
    ).fetchone()[0] == 1


def test_pair_puck_returns_token_once_and_stores_only_its_hash() -> None:
    store = PilotStore(":memory:")
    parent = store.create_family("Ibu Ratna")

    paired = store.pair_puck(parent.invite_code or "", "Mac ruang tamu")

    row = store._connection.execute("SELECT * FROM pucks WHERE id = ?", (paired.puck_id,)).fetchone()
    assert paired.family_id == parent.family_id
    assert paired.display_name == "Mac ruang tamu"
    assert paired.access_token
    assert row["token_hash"] == hashlib.sha256(paired.access_token.encode()).hexdigest()
    assert paired.access_token not in tuple(row)


def test_pair_puck_rejects_invalid_and_expired_invites() -> None:
    store = PilotStore(":memory:")
    parent = store.create_family("Ibu Ratna")

    with pytest.raises(PilotError, match="tidak ditemukan"):
        store.pair_puck("000000", "Mac")

    store._connection.execute(
        "UPDATE families SET invite_expires_at = ? WHERE id = ?",
        ((datetime.now(UTC) - timedelta(seconds=1)).isoformat(), parent.family_id),
    )
    with pytest.raises(PilotError, match="kedaluwarsa"):
        store.pair_puck(parent.invite_code or "", "Mac")


def test_protection_session_is_parent_only_idempotent_and_one_active_per_family() -> None:
    store = PilotStore(":memory:")
    parent = store.create_family("Ibu Ratna")
    guardian = store.join_family(parent.invite_code or "", "Sinta", "Anak")

    created = store.create_protection_session(
        parent.access_token,
        "7F011753-8F09-4A45-8812-8A4591A96B3C",
        STARTED_AT,
        None,
        "Panggilan dari bank",
        "+62 812-••••-4417",
    )
    repeated = store.create_protection_session(
        parent.access_token,
        "7F011753-8F09-4A45-8812-8A4591A96B3C",
        STARTED_AT,
        None,
        "Judul pengganti",
        "Nomor pengganti",
    )

    assert repeated.id == created.id
    assert created.status == "waiting_for_puck"
    assert created.revision == 0
    assert repeated.title == "Panggilan dari bank"
    assert repeated.caller_detail == "+62 812-••••-4417"
    with pytest.raises(PilotError, match="aktif"):
        store.create_protection_session(
            parent.access_token, "B2546D82-9466-4015-A663-CA10CCACFFBF", STARTED_AT, None
        )
    with pytest.raises(PilotError, match="orang tua"):
        store.create_protection_session(
            guardian.access_token, "B2546D82-9466-4015-A663-CA10CCACFFBF", STARTED_AT, None
        )


def test_existing_database_migrates_history_metadata_without_data_loss(tmp_path) -> None:
    database = tmp_path / "legacy.sqlite3"
    original = PilotStore(database)
    parent = original.create_family("Ibu Ratna")
    created = original.create_protection_session(
        parent.access_token,
        "7F011753-8F09-4A45-8812-8A4591A96B3C",
        STARTED_AT,
        "cellular",
    )
    original.close()

    with sqlite3.connect(database) as connection:
        columns = {
            row[1]
            for row in connection.execute("PRAGMA table_info(protection_sessions)")
        }
        for column in ("title", "caller_detail"):
            if column in columns:
                connection.execute(f"ALTER TABLE protection_sessions DROP COLUMN {column}")

    migrated = PilotStore(database)
    snapshot = migrated.get_protection_session(parent.access_token, created.id)

    assert migrated.profile(parent.access_token).member.name == "Ibu Ratna"
    assert snapshot.call_id == created.call_id
    assert snapshot.title == "Panggilan terdeteksi"
    assert snapshot.caller_detail == "Nomor tidak tersedia"


def test_puck_can_claim_only_its_family_active_session() -> None:
    store = PilotStore(":memory:")
    first_parent = store.create_family("Ibu Ratna")
    first_puck = store.pair_puck(first_parent.invite_code or "", "Mac pertama")
    second_parent = store.create_family("Bapak Budi")
    second_puck = store.pair_puck(second_parent.invite_code or "", "Mac kedua")
    created = store.create_protection_session(
        first_parent.access_token, "7F011753-8F09-4A45-8812-8A4591A96B3C", STARTED_AT, "cellular"
    )

    claimed = store.active_protection_session(first_puck.access_token)

    assert claimed.id == created.id
    assert claimed.status == "listening"
    assert claimed.puck_connected is True
    with pytest.raises(PilotError, match="aktif"):
        store.active_protection_session(second_puck.access_token)
    with pytest.raises(PilotError, match="tidak valid"):
        store.authenticate_puck("wrong-token")


def test_puck_can_create_an_idempotent_active_session_for_its_own_family() -> None:
    store = PilotStore(":memory:")
    parent = store.create_family("Ibu Ratna")
    puck = store.pair_puck(parent.invite_code or "", "Mac")

    created, was_created = store.create_puck_protection_session(
        puck.access_token,
        "7F011753-8F09-4A45-8812-8A4591A96B3C",
        STARTED_AT,
        "whatsapp",
        "Panggilan WhatsApp terdeteksi",
        "Kontak WhatsApp",
    )
    repeated, was_repeated = store.create_puck_protection_session(
        puck.access_token,
        "7F011753-8F09-4A45-8812-8A4591A96B3C",
        STARTED_AT,
        "whatsapp",
        "Judul pengganti",
        "Detail pengganti",
    )

    assert was_created is True
    assert was_repeated is False
    assert repeated.id == created.id
    assert created.status == "listening"
    assert created.puck_connected is True
    assert created.channel == "whatsapp"
    assert repeated.title == "Panggilan WhatsApp terdeteksi"
    assert store.get_protection_session(parent.access_token, created.id).id == created.id

    with pytest.raises(PilotError, match="aktif"):
        store.create_puck_protection_session(
            puck.access_token,
            "B2546D82-9466-4015-A663-CA10CCACFFBF",
            STARTED_AT,
            "whatsapp",
        )


def test_puck_session_uses_parent_language_instead_of_newer_guardian_language() -> None:
    store = PilotStore(":memory:")
    parent = store.create_family("Ibu Ratna")
    guardian = store.join_family(parent.invite_code or "", "Zahra", "Anak")
    puck = store.pair_puck(parent.invite_code or "", "Rambu Puck")
    store.register_push_token(parent.access_token, "aa" * 32, "production", "id")
    store.register_push_token(guardian.access_token, "bb" * 32, "production", "en")

    session, _ = store.create_puck_protection_session(
        puck.access_token,
        "7F011753-8F09-4A45-8812-8A4591A96B3C",
        STARTED_AT,
        "cellular",
    )

    assert session.language == "id"


def test_puck_session_defaults_to_indonesian_when_only_guardian_has_a_language() -> None:
    store = PilotStore(":memory:")
    parent = store.create_family("Ibu Ratna")
    guardian = store.join_family(parent.invite_code or "", "Zahra", "Anak")
    puck = store.pair_puck(parent.invite_code or "", "Rambu Puck")
    store.register_push_token(guardian.access_token, "bb" * 32, "production", "en")

    session, _ = store.create_puck_protection_session(
        puck.access_token,
        "7F011753-8F09-4A45-8812-8A4591A96B3C",
        STARTED_AT,
        "cellular",
    )

    assert session.language == "id"


def test_puck_session_uses_parent_english_language() -> None:
    store = PilotStore(":memory:")
    parent = store.create_family("Ibu Ratna")
    puck = store.pair_puck(parent.invite_code or "", "Rambu Puck")
    store.register_push_token(parent.access_token, "aa" * 32, "production", "en")

    session, _ = store.create_puck_protection_session(
        puck.access_token,
        "7F011753-8F09-4A45-8812-8A4591A96B3C",
        STARTED_AT,
        "cellular",
    )

    assert session.language == "en"


def test_puck_session_creation_rejects_non_puck_and_invalid_channel() -> None:
    store = PilotStore(":memory:")
    parent = store.create_family("Ibu Ratna")
    puck = store.pair_puck(parent.invite_code or "", "Mac")

    with pytest.raises(PilotError, match="tidak valid"):
        store.create_puck_protection_session(
            parent.access_token,
            "7F011753-8F09-4A45-8812-8A4591A96B3C",
            STARTED_AT,
            "whatsapp",
        )
    with pytest.raises(ValueError, match="Kanal"):
        store.create_puck_protection_session(
            puck.access_token,
            "7F011753-8F09-4A45-8812-8A4591A96B3C",
            STARTED_AT,
            "telegram",
        )


def test_chunk_sequence_is_ordered_and_last_identical_upload_is_idempotent() -> None:
    store = PilotStore(":memory:")
    parent = store.create_family("Ibu Ratna")
    puck = store.pair_puck(parent.invite_code or "", "Mac")
    session = store.create_protection_session(
        parent.access_token, "7F011753-8F09-4A45-8812-8A4591A96B3C", STARTED_AT, None
    )
    store.active_protection_session(puck.access_token)

    first = store.record_protection_chunk(
        puck.access_token,
        session.id,
        sequence=0,
        digest="digest-zero",
        masked_transcript="Halo",
        assessment=None,
        final=False,
    )
    duplicate = store.record_protection_chunk(
        puck.access_token,
        session.id,
        sequence=0,
        digest="digest-zero",
        masked_transcript="ignored on duplicate",
        assessment=None,
        final=False,
    )

    assert first.next_sequence == 1
    assert duplicate.masked_transcript == "Halo"
    assert duplicate.revision == first.revision
    with pytest.raises(PilotError, match="urutan"):
        store.record_protection_chunk(
            puck.access_token,
            session.id,
            sequence=2,
            digest="digest-two",
            masked_transcript="Halo dunia",
            assessment=None,
            final=False,
        )
    with pytest.raises(PilotError, match="berbeda"):
        store.record_protection_chunk(
            puck.access_token,
            session.id,
            sequence=0,
            digest="different",
            masked_transcript="Halo",
            assessment=None,
            final=False,
        )


def test_parent_end_and_delete_enforce_authorization() -> None:
    store = PilotStore(":memory:")
    parent = store.create_family("Ibu Ratna")
    guardian = store.join_family(parent.invite_code or "", "Sinta", "Anak")
    session = store.create_protection_session(
        parent.access_token, "7F011753-8F09-4A45-8812-8A4591A96B3C", STARTED_AT, None
    )

    with pytest.raises(PilotError, match="orang tua"):
        store.request_protection_end(guardian.access_token, session.id)
    ended = store.request_protection_end(parent.access_token, session.id)
    assert ended.status == "completed"
    assert ended.outcome == "no_speech"
    assert ended.end_requested is True

    other_parent = store.create_family("Bapak Budi")
    with pytest.raises(PilotError, match="keluarga lain"):
        store.delete_protection_session(other_parent.access_token, session.id)
    store.delete_protection_session(parent.access_token, session.id)
    with pytest.raises(PilotError, match="tidak ditemukan"):
        store.get_protection_session(parent.access_token, session.id)


def stale_puck_session(seconds_ago: int):
    store = PilotStore(":memory:")
    parent = store.create_family("Ibu Ratna")
    puck = store.pair_puck(parent.invite_code or "", "Puck")
    session, _ = store.create_puck_protection_session(
        puck.access_token, "7F011753-8F09-4A45-8812-8A4591A96B3C", STARTED_AT, "cellular"
    )
    store._connection.execute(
        "UPDATE protection_sessions SET last_activity_at = ? WHERE id = ?",
        ((datetime.now(UTC) - timedelta(seconds=seconds_ago)).isoformat(), session.id),
    )
    store._connection.commit()
    return store, parent, puck, session


def test_puck_does_not_reclaim_abandoned_session() -> None:
    store, parent, puck, session = stale_puck_session(61)

    with pytest.raises(PilotError, match="aktif"):
        store.active_protection_session(puck.access_token)

    expired = store.get_protection_session(parent.access_token, session.id)
    assert expired.status == "error"
    assert expired.failure is not None
    assert expired.failure.code == "puck_disconnected"


def test_new_call_replaces_abandoned_session() -> None:
    store, _, puck, session = stale_puck_session(61)

    replacement, was_created = store.create_puck_protection_session(
        puck.access_token, "B2546D82-9466-4015-A663-CA10CCACFFBF", STARTED_AT, "cellular"
    )

    assert was_created is True
    assert replacement.status == "listening"
    assert replacement.id != session.id


def test_recent_session_survives_puck_reboot() -> None:
    store, _, puck, session = stale_puck_session(30)

    resumed = store.active_protection_session(puck.access_token)

    assert resumed.id == session.id
    assert resumed.status == "listening"


def test_recorded_chunk_refreshes_session_activity() -> None:
    store, _, puck, session = stale_puck_session(59)

    store.record_protection_chunk(
        puck.access_token,
        session.id,
        sequence=0,
        digest="digest-zero",
        masked_transcript="Halo",
        assessment=None,
        final=False,
    )

    (last_activity_at,) = store._connection.execute(
        "SELECT last_activity_at FROM protection_sessions WHERE id = ?", (session.id,)
    ).fetchone()
    age = datetime.now(UTC) - datetime.fromisoformat(last_activity_at)
    assert age < timedelta(seconds=5)

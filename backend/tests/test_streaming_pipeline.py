from .test_streaming import FakeBridgeStream, configured_client


def test_fake_pipeline_reaches_ready_persists_masked_final_and_completes() -> None:
    fake = FakeBridgeStream()
    client, store, _, puck, session = configured_client(fake)

    with client.websocket_connect(
        f"/api/pucks/sessions/{session.id}/stream",
        headers={"authorization": f"Bearer {puck.access_token}"},
    ) as socket:
        assert socket.receive_json() == {"type": "ready"}
        socket.send_bytes(b"\x01\x00" * 1_600)
        assert socket.receive_json() == {"type": "partial", "text": "OTP [KODE]"}
        socket.send_bytes(b"\x02\x00" * 1_600)
        assert socket.receive_json()["snapshot"]["masked_transcript"] == "OTP [KODE]"
        socket.send_json({"type": "finish"})
        assert socket.receive_json()["snapshot"]["status"] == "completed"
        assert socket.receive_json() == {"type": "complete"}

    saved = store.get_puck_protection_session(puck.access_token, session.id)
    assert saved.masked_transcript == "OTP [KODE]"
    assert fake.closed is True

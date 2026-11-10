import assert from 'node:assert/strict';
import test from 'node:test';

import { createProviderReadiness } from '../src/vercel.js';


class FakeWebSocket {
  static latest;

  constructor() {
    this.listeners = new Map();
    FakeWebSocket.latest = this;
  }

  addEventListener(type, callback) {
    const callbacks = this.listeners.get(type) || [];
    callbacks.push(callback);
    this.listeners.set(type, callbacks);
  }

  emit(type, event = {}) {
    for (const callback of this.listeners.get(type) || []) callback(event);
  }
}


test('provider readiness waits for the authenticated stream-start frame', async () => {
  const readiness = createProviderReadiness(FakeWebSocket, { timeoutMs: 1_000 });
  new readiness.WebSocket('wss://gateway.example', ['auth']);
  let settled = false;
  void readiness.ready.then(() => { settled = true; });

  FakeWebSocket.latest.emit('open');
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(settled, false);

  FakeWebSocket.latest.emit('message', {
    data: JSON.stringify({ type: 'stream-start', warnings: [] }),
  });
  await readiness.ready;
  assert.equal(settled, true);
});


test('provider readiness rejects an auth failure before stream-start', async () => {
  const readiness = createProviderReadiness(FakeWebSocket, { timeoutMs: 1_000 });
  new readiness.WebSocket('wss://gateway.example', ['bad-auth']);

  FakeWebSocket.latest.emit('close', { code: 1008 });

  await assert.rejects(readiness.ready, /before becoming ready/);
});

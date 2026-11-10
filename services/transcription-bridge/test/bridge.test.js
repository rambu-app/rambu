import assert from 'node:assert/strict';
import { once } from 'node:events';
import test from 'node:test';

import WebSocket from 'ws';

import { createBridgeServer } from '../src/bridge.js';

async function withBridge(adapter, run, options = {}) {
  const bridge = createBridgeServer({ adapter, ...options });
  bridge.listen(0, '127.0.0.1');
  await once(bridge, 'listening');
  const { port } = bridge.address();
  try {
    await run({
      http: `http://127.0.0.1:${port}`,
      ws: `ws://127.0.0.1:${port}`,
    });
  } finally {
    await new Promise((resolve) => bridge.close(resolve));
  }
}

async function connect(url) {
  const socket = new WebSocket(url);
  const messages = [];
  const waiters = [];
  socket.on('message', (data) => {
    const value = JSON.parse(data.toString());
    const waiter = waiters.shift();
    if (waiter) waiter(value);
    else messages.push(value);
  });
  await once(socket, 'open');
  return {
    socket,
    next() {
      if (messages.length) return Promise.resolve(messages.shift());
      return new Promise((resolve) => waiters.push(resolve));
    },
  };
}

test('health does not invoke the provider', async () => {
  const adapter = {
    batch: () => assert.fail('health must not bill the provider'),
    openStream: () => assert.fail('health must not bill the provider'),
  };
  await withBridge(adapter, async ({ http }) => {
    const response = await fetch(`${http}/health`);
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { status: 'ok' });
  });
});

test('batch forwards Indonesian audio and returns normalized text', async () => {
  let request;
  const adapter = {
    async batch(value) {
      request = value;
      return { text: 'Halo dari MAI' };
    },
  };
  await withBridge(adapter, async ({ http }) => {
    const response = await fetch(`${http}/v1/transcriptions`, {
      method: 'POST',
      headers: {
        'content-type': 'audio/wav',
        'x-rambu-language': 'id',
      },
      body: Buffer.from('wave'),
    });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { text: 'Halo dari MAI' });
    assert.equal(request.language, 'id');
    assert.equal(request.model, 'microsoft/mai-transcribe-2');
    assert.deepEqual(request.audio, Buffer.from('wave'));
  });
});

test('invalid language is rejected without invoking the provider', async () => {
  let called = false;
  const adapter = { batch: async () => { called = true; } };
  await withBridge(adapter, async ({ http }) => {
    const response = await fetch(`${http}/v1/transcriptions`, {
      method: 'POST',
      headers: { 'x-rambu-language': 'fr' },
      body: Buffer.from('wave'),
    });
    assert.equal(response.status, 400);
    assert.deepEqual(await response.json(), { error: 'invalid language' });
    assert.equal(called, false);
  });
});

test('stream normalizes ready, partial, final, and complete events', async () => {
  const writes = [];
  const adapter = {
    async openStream({ emit, language, model }) {
      assert.equal(language, 'id');
      assert.equal(model, 'microsoft/mai-transcribe-2-streaming');
      return {
        async start() {
          emit({ type: 'ready' });
        },
        write(audio) {
          writes.push(Buffer.from(audio));
          emit({ type: 'partial', text: 'hal' });
        },
        async finish() {
          emit({ type: 'final', text: 'halo', sequence: 0 });
          emit({ type: 'complete' });
        },
        close() {},
      };
    },
  };
  await withBridge(adapter, async ({ ws }) => {
    const connection = await connect(`${ws}/v1/stream?language=id`);
    const { socket } = connection;
    assert.deepEqual(await connection.next(), { type: 'ready' });
    socket.send(Buffer.from([1, 2, 3, 4]));
    assert.deepEqual(await connection.next(), { type: 'partial', text: 'hal' });
    socket.send(JSON.stringify({ type: 'finish' }));
    assert.deepEqual(await connection.next(), { type: 'final', text: 'halo', sequence: 0 });
    assert.deepEqual(await connection.next(), { type: 'complete' });
    assert.deepEqual(writes, [Buffer.from([1, 2, 3, 4])]);
    socket.close();
    await once(socket, 'close');
  });
});

test('stream rejects oversized audio and closes the provider session', async () => {
  let closed = false;
  const adapter = {
    async openStream({ emit }) {
      return {
        async start() { emit({ type: 'ready' }); },
        write() { assert.fail('oversized input must not be forwarded'); },
        finish() {},
        close() { closed = true; },
      };
    },
  };
  await withBridge(adapter, async ({ ws }) => {
    const connection = await connect(`${ws}/v1/stream?language=en`);
    const { socket } = connection;
    await connection.next();
    socket.send(Buffer.alloc(9));
    assert.deepEqual(await connection.next(), { type: 'error', code: 'audio_too_large' });
    await once(socket, 'close');
    assert.equal(closed, true);
  }, { maxFrameBytes: 8 });
});

test('provider failures are sanitized', async () => {
  const adapter = {
    async batch() {
      throw new Error('Authorization: Bearer secret-key upstream body');
    },
  };
  await withBridge(adapter, async ({ http }) => {
    const response = await fetch(`${http}/v1/transcriptions`, {
      method: 'POST',
      headers: { 'x-rambu-language': 'en' },
      body: Buffer.from('wave'),
    });
    assert.equal(response.status, 502);
    const body = await response.text();
    assert.equal(body.includes('secret-key'), false);
    assert.deepEqual(JSON.parse(body), { error: 'transcription provider unavailable' });
  });
});

test('empty final transcripts are ignored without consuming a sequence', async () => {
  const adapter = {
    async openStream({ emit }) {
      return {
        async start() { emit({ type: 'ready' }); },
        write() {},
        async finish() {
          emit({ type: 'final', text: '   ' });
          emit({ type: 'final', text: 'halo' });
          emit({ type: 'complete' });
        },
        close() {},
      };
    },
  };
  await withBridge(adapter, async ({ ws }) => {
    const connection = await connect(`${ws}/v1/stream?language=id`);
    assert.deepEqual(await connection.next(), { type: 'ready' });
    connection.socket.send(JSON.stringify({ type: 'finish' }));
    assert.deepEqual(await connection.next(), {
      type: 'final',
      text: 'halo',
      sequence: 0,
    });
    assert.deepEqual(await connection.next(), { type: 'complete' });
    connection.socket.close();
    await once(connection.socket, 'close');
  });
});

test('disconnect during provider startup closes the late provider session', async () => {
  let releaseProvider;
  let closed = false;
  const providerAvailable = new Promise((resolve) => { releaseProvider = resolve; });
  const adapter = {
    async openStream() {
      await providerAvailable;
      return {
        async start() {},
        write() {},
        finish() {},
        close() { closed = true; },
      };
    },
  };
  await withBridge(adapter, async ({ ws }) => {
    const socket = new WebSocket(`${ws}/v1/stream?language=en`);
    await once(socket, 'open');
    socket.close();
    await once(socket, 'close');
    releaseProvider();
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(closed, true);
  });
});

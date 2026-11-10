import http from 'node:http';

import { WebSocket, WebSocketServer } from 'ws';

const DEFAULT_BATCH_MODEL = 'microsoft/mai-transcribe-2';
const DEFAULT_STREAM_MODEL = 'microsoft/mai-transcribe-2-streaming';
const DEFAULT_MAX_BATCH_BYTES = 25 * 1024 * 1024;
const DEFAULT_MAX_FRAME_BYTES = 16 * 1024;
const LANGUAGES = new Set(['id', 'en']);

function sendJSON(response, status, value) {
  const body = JSON.stringify(value);
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
  });
  response.end(body);
}

async function readBody(request, limit) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > limit) {
      const error = new Error('request too large');
      error.code = 'BODY_TOO_LARGE';
      throw error;
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

function validLanguage(value) {
  return typeof value === 'string' && LANGUAGES.has(value);
}

function safeSocketSend(socket, value) {
  if (socket.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify(value));
  }
}

export function createBridgeServer({
  adapter,
  batchModel = process.env.RAMBU_TRANSCRIPTION_BATCH_MODEL || DEFAULT_BATCH_MODEL,
  streamModel = process.env.RAMBU_TRANSCRIPTION_STREAM_MODEL || DEFAULT_STREAM_MODEL,
  maxBatchBytes = DEFAULT_MAX_BATCH_BYTES,
  maxFrameBytes = DEFAULT_MAX_FRAME_BYTES,
} = {}) {
  if (!adapter) {
    throw new TypeError('adapter is required');
  }

  const server = http.createServer(async (request, response) => {
    if (request.method === 'GET' && request.url === '/health') {
      sendJSON(response, 200, { status: 'ok' });
      return;
    }

    if (request.method === 'POST' && request.url === '/v1/transcriptions') {
      const language = request.headers['x-rambu-language'];
      if (!validLanguage(language)) {
        sendJSON(response, 400, { error: 'invalid language' });
        return;
      }
      try {
        const audio = await readBody(request, maxBatchBytes);
        if (audio.length === 0) {
          sendJSON(response, 400, { error: 'audio is required' });
          return;
        }
        const result = await adapter.batch({ audio, language, model: batchModel });
        sendJSON(response, 200, { text: String(result.text || '') });
      } catch (error) {
        if (error?.code === 'BODY_TOO_LARGE') {
          sendJSON(response, 413, { error: 'audio too large' });
          return;
        }
        sendJSON(response, 502, { error: 'transcription provider unavailable' });
      }
      return;
    }

    sendJSON(response, 404, { error: 'not found' });
  });

  const sockets = new WebSocketServer({ noServer: true });
  server.on('upgrade', (request, socket, head) => {
    let url;
    try {
      url = new URL(request.url, 'http://bridge.internal');
    } catch {
      socket.destroy();
      return;
    }
    const language = url.searchParams.get('language');
    if (url.pathname !== '/v1/stream' || !validLanguage(language)) {
      socket.write('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }
    sockets.handleUpgrade(request, socket, head, (webSocket) => {
      sockets.emit('connection', webSocket, request, { language });
    });
  });

  sockets.on('connection', async (socket, _request, { language }) => {
    let providerSession;
    let closed = false;
    let nextSequence = 0;
    const closeProvider = () => {
      if (closed) return;
      closed = true;
      providerSession?.close?.();
    };
    const fail = (code = 'provider_unavailable') => {
      safeSocketSend(socket, { type: 'error', code });
      closeProvider();
      socket.close(1011);
    };
    socket.once('close', closeProvider);
    socket.once('error', closeProvider);

    try {
      providerSession = await adapter.openStream({
        language,
        model: streamModel,
        emit(event) {
          if (!event || !['ready', 'partial', 'final', 'complete'].includes(event.type)) {
            return;
          }
          if (event.type === 'final') {
            const text = String(event.text || '').trim();
            if (!text) return;
            safeSocketSend(socket, {
              ...event,
              text,
              sequence: nextSequence++,
            });
            return;
          }
          safeSocketSend(socket, event);
        },
        fail,
      });
      if (closed || socket.readyState !== WebSocket.OPEN) {
        providerSession.close?.();
        return;
      }
      await providerSession.start();
      if (closed || socket.readyState !== WebSocket.OPEN) {
        providerSession.close?.();
        return;
      }
    } catch {
      if (!closed) fail();
      else providerSession?.close?.();
      return;
    }

    socket.on('message', async (data, isBinary) => {
      try {
        if (isBinary) {
          if (data.length > maxFrameBytes) {
            fail('audio_too_large');
            return;
          }
          if (data.length === 0 || data.length % 2 !== 0) {
            fail('invalid_audio');
            return;
          }
          providerSession.write(data);
          return;
        }

        const message = JSON.parse(data.toString());
        if (message?.type !== 'finish') {
          fail('invalid_message');
          return;
        }
        await providerSession.finish();
      } catch {
        fail();
      }
    });
  });

  server.once('close', () => sockets.close());
  return server;
}

export { DEFAULT_BATCH_MODEL, DEFAULT_STREAM_MODEL };

import { createGateway } from '@ai-sdk/gateway';
import { experimental_streamTranscribe, transcribe } from 'ai';

function languageOptions(language) {
  return { microsoft: { language } };
}

async function messageText(data) {
  if (typeof data === 'string') return data;
  if (data instanceof ArrayBuffer) return new TextDecoder().decode(data);
  if (ArrayBuffer.isView(data)) return new TextDecoder().decode(data);
  if (typeof Blob !== 'undefined' && data instanceof Blob) return data.text();
  return String(data);
}

export function createProviderReadiness(
  WebSocketImpl = globalThis.WebSocket,
  { timeoutMs = 10_000 } = {},
) {
  if (!WebSocketImpl) throw new Error('WebSocket is unavailable');
  let resolveReady;
  let rejectReady;
  let settled = false;
  let timer;
  const ready = new Promise((resolve, reject) => {
    resolveReady = resolve;
    rejectReady = reject;
  });
  const settle = (error) => {
    if (settled) return;
    settled = true;
    if (timer) clearTimeout(timer);
    if (error) rejectReady(error);
    else resolveReady();
  };
  const fail = (error = new Error('provider stream failed before becoming ready')) => {
    settle(error);
  };

  class ReadyAwareWebSocket {
    constructor(url, protocols) {
      const socket = new WebSocketImpl(url, protocols);
      timer = setTimeout(
        () => fail(new Error('provider stream readiness timed out')),
        timeoutMs,
      );
      socket.addEventListener('message', (event) => {
        void messageText(event.data)
          .then((text) => {
            let frame;
            try {
              frame = JSON.parse(text);
            } catch {
              return;
            }
            if (frame?.type === 'stream-start') settle();
            if (frame?.type === 'error') {
              fail(new Error('provider rejected stream startup'));
            }
          })
          .catch(fail);
      });
      socket.addEventListener('error', () => fail());
      socket.addEventListener('close', () => fail());
      return socket;
    }
  }

  return { WebSocket: ReadyAwareWebSocket, ready, fail };
}

export function createVercelAdapter({ apiKey = process.env.AI_GATEWAY_API_KEY } = {}) {
  if (!apiKey) {
    throw new Error('AI_GATEWAY_API_KEY is required');
  }
  const gateway = createGateway({ apiKey });

  return {
    async batch({ audio, language, model }) {
      const result = await transcribe({
        model: gateway.experimental_transcription(model),
        audio,
        providerOptions: languageOptions(language),
      });
      return { text: result.text };
    },

    async openStream({ emit, fail, language, model }) {
      const readiness = createProviderReadiness();
      const streamGateway = createGateway({
        apiKey,
        webSocket: readiness.WebSocket,
      });
      let controller;
      let stopped = false;
      let cumulativePartial = '';
      const abortController = new AbortController();
      const audio = new ReadableStream({
        start(value) {
          controller = value;
        },
      }, { highWaterMark: 8, size: () => 1 });
      const result = experimental_streamTranscribe({
        model: streamGateway.experimental_transcription(model),
        audio,
        inputAudioFormat: { type: 'audio/pcm', rate: 16_000 },
        providerOptions: languageOptions(language),
        abortSignal: abortController.signal,
      });

      const pump = async () => {
        try {
          for await (const part of result.fullStream) {
            if (part.type === 'transcript-delta') {
              cumulativePartial += part.delta;
              emit({ type: 'partial', text: cumulativePartial });
            } else if (part.type === 'transcript-partial') {
              cumulativePartial = part.text;
              emit({ type: 'partial', text: part.text });
            } else if (part.type === 'transcript-final') {
              cumulativePartial = '';
              emit({ type: 'final', text: part.text });
            } else if (part.type === 'error') {
              throw part.error;
            }
          }
          emit({ type: 'complete' });
        } catch {
          if (!stopped) {
            readiness.fail();
            fail('provider_unavailable');
          }
        }
      };

      return {
        async start() {
          void pump();
          await readiness.ready;
          if (stopped) throw new Error('provider stream closed during startup');
          emit({ type: 'ready' });
        },
        write(chunk) {
          if (controller.desiredSize !== null && controller.desiredSize <= 0) {
            throw new Error('provider audio queue is full');
          }
          controller.enqueue(new Uint8Array(chunk));
        },
        async finish() {
          controller.close();
        },
        close() {
          if (stopped) return;
          stopped = true;
          abortController.abort();
          try {
            controller.close();
          } catch {
            // The stream may already be complete.
          }
        },
      };
    },
  };
}

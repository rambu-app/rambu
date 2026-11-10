import { createBridgeServer } from './bridge.js';
import { createVercelAdapter } from './vercel.js';

const port = Number.parseInt(process.env.PORT || '8788', 10);
const host = process.env.HOST || '0.0.0.0';
const server = createBridgeServer({ adapter: createVercelAdapter() });

server.listen(port, host, () => {
  console.log(`transcription bridge listening on ${host}:${port}`);
});

function shutdown() {
  server.close(() => process.exit(0));
}

process.once('SIGINT', shutdown);
process.once('SIGTERM', shutdown);

import assert from 'node:assert/strict';
import { afterEach, test } from 'node:test';
import IosSpeech, { BASE, credentialHeaders } from '../plugins/ios-speech/index.mjs';

/** A context with the given credential store and account, and the routes the plugin registers. */
function fakeContext({ key, token } = {}) {
  const routes = new Map();
  const services = {
    credentials: { resolve: async () => (key === undefined ? undefined : { value: key }) },
    deepseekAccount: { resolveToken: async () => token },
  };
  const ctx = {
    get: (name) => services[name],
    effect: (run) => run(),
    connection: { fetch: { register: (route) => { routes.set(route.path, route); return () => {}; } } },
  };
  return { ctx, routes };
}

const realFetch = globalThis.fetch;
afterEach(() => { globalThis.fetch = realFetch; });

test('the stored key comes first, then the account sign-in, else nothing', async () => {
  assert.deepEqual(await credentialHeaders(fakeContext({ key: ' sk-1 ', token: 't' }).ctx, BASE), { authorization: 'Bearer sk-1' });
  assert.deepEqual(await credentialHeaders(fakeContext({ key: '', token: 't' }).ctx, BASE), { 'x-dsh-auth-token': 't' });
  assert.equal(await credentialHeaders(fakeContext().ctx, BASE), undefined);
});

test('recognition forwards the WAV as a form and answers the text', async () => {
  const { ctx, routes } = fakeContext({ key: 'sk-1' });
  new IosSpeech(ctx);
  let sent;
  globalThis.fetch = async (url, init) => {
    sent = { url, init };
    return new Response(JSON.stringify({ text: '你好', duration_ms: 1000 }), { status: 200 });
  };
  const response = await routes.get('/api/ios-speech/asr').fetch(new Request('http://x/api/ios-speech/asr', { method: 'POST', body: new Uint8Array([1, 2, 3]) }));
  assert.equal(sent.url, `${BASE}/asr`);
  assert.equal(sent.init.headers.authorization, 'Bearer sk-1');
  const file = sent.init.body.get('file');
  assert.equal(file.size, 3);
  assert.deepEqual(await response.json(), { text: '你好' });
});

test('synthesis streams DeepSeek\'s PCM back and keeps only known voices', async () => {
  const { ctx, routes } = fakeContext({ key: 'sk-1' });
  new IosSpeech(ctx);
  let body;
  globalThis.fetch = async (_url, init) => {
    body = JSON.parse(init.body);
    return new Response(new Uint8Array([9, 8, 7, 6]), { status: 200 });
  };
  const response = await routes.get('/api/ios-speech/tts').fetch(new Request('http://x', { method: 'POST', body: JSON.stringify({ text: '读这句', voice: 'nobody' }) }));
  assert.deepEqual(body, { text: '读这句', voice_id: 'stella', format: 'pcm', filter_markdown: true });
  assert.equal(response.status, 200);
  assert.deepEqual([...new Uint8Array(await response.arrayBuffer())], [9, 8, 7, 6]);
});

test('failures say what kind they are', async () => {
  const none = fakeContext();
  new IosSpeech(none.ctx);
  const missing = await none.routes.get('/api/ios-speech/tts').fetch(new Request('http://x', { method: 'POST', body: '{"text":"a"}' }));
  assert.equal(missing.status, 502);
  assert.deepEqual(await missing.json(), { error: { kind: 'no-credential' } });

  const { ctx, routes } = fakeContext({ key: 'sk-bad' });
  new IosSpeech(ctx);
  globalThis.fetch = async () => new Response(JSON.stringify({ error: { message: 'Authentication Fails (request_id: abc)' } }), { status: 401 });
  const rejected = await routes.get('/api/ios-speech/tts').fetch(new Request('http://x', { method: 'POST', body: '{"text":"a"}' }));
  assert.deepEqual(await rejected.json(), { error: { kind: 'http', status: 401, credential: 'api-key', message: 'Authentication Fails' } });

  // Signed in with an account and no key: the failure says the account token was what was refused.
  const account = fakeContext({ token: 't' });
  new IosSpeech(account.ctx);
  const refused = await account.routes.get('/api/ios-speech/tts').fetch(new Request('http://x', { method: 'POST', body: '{"text":"a"}' }));
  assert.equal((await refused.json()).error.credential, 'account');

  const status = await routes.get('/api/ios-speech/status').fetch(new Request('http://x'));
  assert.deepEqual(await status.json(), { ready: true });
});

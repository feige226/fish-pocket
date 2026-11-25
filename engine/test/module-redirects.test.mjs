import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { installModuleRedirects } from '../runtime/module-redirects.mjs';

test('flock resolves to the iOS stand-in and grants the lock', async () => {
  installModuleRedirects();
  const { tryLockExclusive } = await import('@deepseek-ai/node-addon-system/flock');
  assert.match(tryLockExclusive.toString(), /invalid descriptor/);
  const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-ios-lock-')), 'session.lock');
  const handle = await fs.promises.open(file, 'w');
  await tryLockExclusive(handle.fd);
  await handle.close();
});

test('a built-in plugin resolves from the engine for code outside it, other packages do not', async () => {
  installModuleRedirects();
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-ios-profile-'));
  const probe = path.join(dir, 'probe.mjs');
  fs.writeFileSync(probe, "export const bot = import.meta.resolve('ds-bot');\nexport const sub = import.meta.resolve('ds-bot/web-search');\nexport function other() { return import.meta.resolve('yaml'); }\n");
  const { bot, sub, other } = await import(probe);
  // ds-bot's entry file is its own business (0.3.8 renamed index.js to plugin.js).
  const entry = JSON.parse(fs.readFileSync(new URL('../node_modules/ds-bot/package.json', import.meta.url), 'utf8')).main ?? 'index.js';
  assert.equal(bot, new URL(`../node_modules/ds-bot/${entry}`, import.meta.url).href);
  assert.match(sub, /\/engine\/node_modules\/ds-bot\/web-search\.js$/);
  assert.throws(other, { code: 'ERR_MODULE_NOT_FOUND' });
});

test("DSH's own packages resolve from the engine once the profile has no copy of them", async () => {
  installModuleRedirects();
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-ios-profile-'));
  const probe = path.join(dir, 'probe.mjs');
  fs.writeFileSync(probe, "export const storage = import.meta.resolve('@deepseek-ai/dsh-storage-domain');\nexport function library() { return import.meta.resolve('@deepseek-ai/schemastery'); }\n");
  const { storage, library } = await import(probe);
  assert.match(storage, /\/engine\/node_modules\/@deepseek-ai\/dsh-storage-domain\//);
  assert.throws(library, { code: 'ERR_MODULE_NOT_FOUND' });
});

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { isOfficial, removeStaleOfficial } from '../runtime/stale-official.mjs';

function pkg(dir, name, version) {
  const at = path.join(dir, name);
  fs.mkdirSync(at, { recursive: true });
  fs.writeFileSync(path.join(at, 'package.json'), JSON.stringify({ name, version }));
  return at;
}

function setup({ shipped = {}, copies = {}, manifest } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-stale-official-'));
  const engineModules = path.join(root, 'engine', 'node_modules');
  const profile = path.join(root, 'profile');
  fs.mkdirSync(engineModules, { recursive: true });
  fs.mkdirSync(profile, { recursive: true });
  for (const [name, version] of Object.entries(shipped)) pkg(engineModules, name, version);
  for (const [name, version] of Object.entries(copies)) pkg(path.join(profile, 'node_modules'), name, version);
  if (manifest !== undefined) fs.writeFileSync(path.join(profile, 'package.json'), JSON.stringify(manifest));
  return { profile, engineModules };
}
const has = (profile, name) => fs.existsSync(path.join(profile, 'node_modules', name));

test("DSH's runtime packages are official; the scope's libraries and others are not", () => {
  assert.equal(isOfficial('@deepseek-ai/dsh'), true);
  assert.equal(isOfficial('@deepseek-ai/dsh-storage-domain'), true);
  assert.equal(isOfficial('@deepseek-ai/cordis'), false);
  assert.equal(isOfficial('@deepseek-ai/schemastery'), false);
  assert.equal(isOfficial('ds-bot'), false);
  assert.equal(isOfficial('@someone/dsh-plugin'), false);
});

test('an old copy a plugin left behind goes; one at the shipped version stays', async () => {
  const dirs = setup({
    shipped: { '@deepseek-ai/dsh-storage-domain': '0.2.2-rc.4', '@deepseek-ai/dsh-storage': '0.2.2-rc.4' },
    copies: { '@deepseek-ai/dsh-storage-domain': '0.2.2-rc.1', '@deepseek-ai/dsh-storage': '0.2.2-rc.4' },
  });
  const removed = await removeStaleOfficial(dirs);
  assert.deepEqual(removed, [{ name: '@deepseek-ai/dsh-storage-domain', found: '0.2.2-rc.1', shipped: '0.2.2-rc.4' }]);
  assert.equal(has(dirs.profile, '@deepseek-ai/dsh-storage-domain'), false);
  assert.equal(has(dirs.profile, '@deepseek-ai/dsh-storage'), true);
});

test("packages the app does not ship, the scope's libraries and other plugins stay", async () => {
  const dirs = setup({
    shipped: { '@deepseek-ai/schemastery': '3.19.0' },
    copies: { '@deepseek-ai/dsh-not-shipped': '0.1.0', '@deepseek-ai/schemastery': '3.18.0', 'dsh-live-compact': '1.0.0' },
  });
  assert.deepEqual(await removeStaleOfficial(dirs), []);
  assert.equal(has(dirs.profile, '@deepseek-ai/dsh-not-shipped'), true);
  assert.equal(has(dirs.profile, '@deepseek-ai/schemastery'), true);
  assert.equal(has(dirs.profile, 'dsh-live-compact'), true);
});

test('an old official dependency leaves the manifest; the rest of it is kept as written', async () => {
  const manifest = {
    name: 'dsh-profile-web',
    dependencies: { '@deepseek-ai/dsh-web-app': '0.2.2-rc.1', '@deepseek-ai/dsh-base': '0.2.2-rc.4', 'dsh-live-compact': '1.1.5' },
    dsh: { profile: { bundles: ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app', 'dsh-live-compact'] } },
  };
  const dirs = setup({
    shipped: { '@deepseek-ai/dsh-web-app': '0.2.2-rc.4', '@deepseek-ai/dsh-base': '0.2.2-rc.4' },
    copies: { '@deepseek-ai/dsh-web-app': '0.2.2-rc.1' },
    manifest,
  });
  const removed = await removeStaleOfficial(dirs);
  assert.deepEqual(removed, [{ name: '@deepseek-ai/dsh-web-app', found: '0.2.2-rc.1', shipped: '0.2.2-rc.4' }]);
  const file = path.join(dirs.profile, 'package.json');
  const after = JSON.parse(fs.readFileSync(file, 'utf8'));
  assert.deepEqual(after.dependencies, { '@deepseek-ai/dsh-base': '0.2.2-rc.4', 'dsh-live-compact': '1.1.5' });
  assert.deepEqual(after.dsh, manifest.dsh);
  assert.equal(fs.statSync(file).mode & 0o777, 0o600);
});

test('a profile without node_modules or a manifest is left alone', async () => {
  const dirs = setup({ shipped: { '@deepseek-ai/dsh-web-app': '0.2.2-rc.4' } });
  assert.deepEqual(await removeStaleOfficial(dirs), []);
  assert.deepEqual(fs.readdirSync(dirs.profile), []);
});

test("nothing is written when the manifest's official dependencies match", async () => {
  const dirs = setup({
    shipped: { '@deepseek-ai/dsh-web-app': '0.2.2-rc.4' },
    manifest: { dependencies: { '@deepseek-ai/dsh-web-app': '0.2.2-rc.4' } },
  });
  const file = path.join(dirs.profile, 'package.json');
  const before = fs.readFileSync(file, 'utf8');
  assert.deepEqual(await removeStaleOfficial(dirs), []);
  assert.equal(fs.readFileSync(file, 'utf8'), before);
});

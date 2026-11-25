// The plugin market reads an index for a minute instead of 15 s (runtime/market-timeout.mjs).
// The value goes into the profile's own `plugin-market` row, beside the index list 设置
// writes there; these compose the real profile with the iOS overlay, as `dsh web` does.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseDocument } from 'yaml';
import { ENTRY, TIMEOUT_MS, seedMarketTimeout } from '../runtime/market-timeout.mjs';

const engine = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const bin = path.join(engine, 'node_modules/@deepseek-ai/dsh/lib/bin.js');
const installAnchor = path.join(engine, 'node_modules/@deepseek-ai/dsh/package.json');
const overlay = path.join(engine, 'ios.patch.yml');
const MARKET = '@deepseek-ai/dsh-experimental-plugin-market-bundle';
const INDEX = 'https://example.com/dsh-index.json';

function setup(t) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-market-timeout-'));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const marker = path.join(home, '.ios-market-timeout');
  const patchFile = path.join(home, 'profiles/web/cordis.patch.yml');
  return { home, marker, patchFile, seed: () => seedMarketTimeout({ home, marker, installAnchor }) };
}

/** Turn the market bundle on, as its switch in 设置 → 插件 does. */
function enableMarket(home) {
  const file = path.join(home, 'profiles/web/package.json');
  const manifest = JSON.parse(fs.readFileSync(file, 'utf8'));
  manifest.dsh.profile.bundles.push(MARKET);
  fs.writeFileSync(file, JSON.stringify(manifest, null, 2));
}

/** The market entry's composed config under `home`, with the iOS overlay; undefined while it is not mounted. */
function market(home) {
  const dump = execFileSync(process.execPath, [bin, 'web', '--patch', overlay, '--dump-config'], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore'],
    env: { ...process.env, DSH_HOME: home, DSH_IOS_DOCUMENTS: home },
  });
  return parseDocument(dump, { logLevel: 'silent' }).toJS().find((entry) => entry.id === ENTRY)?.config;
}

test('the iOS overlay leaves the market alone, so the index list stays writable', () => {
  const rows = parseDocument(fs.readFileSync(overlay, 'utf8')).toJS();
  assert.equal(rows.some((row) => row.id === ENTRY), false);
});

test('a first launch gives the market a minute, which applies once it is turned on', async (t) => {
  const { home, marker, seed } = setup(t);
  assert.equal(await seed(), 'seeded');
  assert.equal(fs.readFileSync(marker, 'utf8'), 'seeded\n');
  // Off: the row waits, and the profile still composes.
  assert.equal(market(home), undefined);
  enableMarket(home);
  assert.equal(market(home).fetchTimeoutMs, TIMEOUT_MS);
});

test('the index list the store wrote stays beside the timeout', async (t) => {
  const { home, patchFile, seed } = setup(t);
  await seed();
  fs.rmSync(path.join(home, '.ios-market-timeout'));
  fs.writeFileSync(patchFile, `- id: ${ENTRY}\n  config:\n    indexes:\n      - ${INDEX}\n`);
  assert.equal(await seed(), 'seeded');
  enableMarket(home);
  assert.deepEqual(market(home), { indexes: [INDEX], fetchTimeoutMs: TIMEOUT_MS });
});

test('a timeout the user set stays theirs, and the seed runs once', async (t) => {
  const { home, patchFile, seed } = setup(t);
  await seed();
  fs.rmSync(path.join(home, '.ios-market-timeout'));
  fs.writeFileSync(patchFile, `- id: ${ENTRY}\n  config:\n    fetchTimeoutMs: 5000\n`);
  assert.equal(await seed(), 'kept');
  // A later reset in the web settings is not undone at the next boot.
  fs.writeFileSync(patchFile, '[]\n');
  assert.equal(await seed(), 'done');
  assert.equal(fs.readFileSync(patchFile, 'utf8'), '[]\n');
});

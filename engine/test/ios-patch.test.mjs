// ios.patch.yml turns entries of the stock profile off by id. When a DSH upgrade
// renames an entry, its patch is skipped: `dsh` says so once on stderr and starts
// anyway, with the entry back on (0.2.2-rc.3 renamed `office-to-pdf`, and Office
// came on in the app unnoticed). This composes the real profile with the overlay,
// the way `dsh web` does, and fails on any id the overlay names that is not there.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const engine = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const bin = path.join(engine, 'node_modules/@deepseek-ai/dsh/lib/bin.js');
const overlay = path.join(engine, 'ios.patch.yml');

test('every entry the iOS overlay patches exists in the profile', (t) => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-ios-patch-'));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const run = spawnSync(process.execPath, [bin, 'web', '--patch', overlay, '--dump-config'], {
    encoding: 'utf8',
    env: { ...process.env, DSH_HOME: home, DSH_IOS_DOCUMENTS: home },
  });
  assert.equal(run.status, 0, run.stderr);
  const missing = [...run.stderr.matchAll(/patch: entry "([^"]+)" not found/g)].map((match) => match[1]);
  // `bot` is ds-bot's own row: the profile has it once the app has installed its
  // built-in plugin (plugins/ios-host), which a bare profile here has not.
  assert.deepEqual(missing.filter((id) => id !== 'bot'), []);
});

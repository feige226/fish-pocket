import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  backupFolder, checkpointChanges, editSetting, resetSettings, restoreCheckpoint, saveCheckpoint, settingsFiles,
} from '../runtime/recovery.mjs';

/** A `$DSH_HOME` laid out like the app's, beside a `DSH_IOS_DATA`. */
function layout() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dsh-recovery-'));
  const home = path.join(root, '.dsh');
  const data = path.join(root, '.ios');
  const files = {
    '.credentials.yaml': 'version: 1\nrefs:\n  ZHIPU_API_KEY: zk-1\n',
    '.ios-permission-default': '',
    '.anonymous-user-id': 'someone',
    'profiles/web/package.json': '{"dsh":{"profile":{"bundles":["@deepseek-ai/dsh-base"]}}}\n',
    'profiles/web/cordis.patch.yml': '[]\n',
    'profiles/web/pnpm-lock.yaml': 'lockfileVersion: 9\n',
    'profiles/web/node_modules/some-plugin/package.json': '{}',
    'sessions/a/session.jsonl': '{}\n',
    'bot/workspace/notes.md': 'hi\n',
  };
  for (const [file, text] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(home, file)), { recursive: true });
    fs.writeFileSync(path.join(home, file), text);
  }
  fs.mkdirSync(data, { recursive: true });
  fs.writeFileSync(path.join(data, 'builtins.json'), '{"ds-bot":"0.3.8"}\n');
  return { home, data, store: path.join(data, 'last-good'), backups: path.join(data, 'recovery') };
}
const read = (dir, file) => fs.readFileSync(path.join(dir, file), 'utf8');
const exists = (dir, file) => fs.existsSync(path.join(dir, file));
const broken = 'version: 1\nrecords:\n  ZHIPU_API_KEY: zk-2\n';

test('settings are the files in $DSH_HOME and the profile folder; data, packages, lockfile and the install id are not', async () => {
  const { home } = layout();
  assert.deepEqual(await settingsFiles(home), [
    '.credentials.yaml',
    '.ios-permission-default',
    'profiles/web/cordis.patch.yml',
    'profiles/web/package.json',
  ]);
});

test('nothing kept yet: no changes to offer, and restoring refuses', async () => {
  const { home, store, backups } = layout();
  assert.equal(await checkpointChanges(home, store), null);
  await assert.rejects(restoreCheckpoint(home, store, await backupFolder(backups, 'restore')), /no settings/);
});

test('a checkpoint is only rewritten when the settings changed', async () => {
  const { home, store } = layout();
  assert.equal(await saveCheckpoint(home, store, new Date('2026-11-19T12:00:00Z')), true);
  assert.equal(await saveCheckpoint(home, store, new Date('2026-11-19T13:00:00Z')), false);
  assert.deepEqual(await checkpointChanges(home, store), { at: '2026-11-19T12:00:00.000Z', changes: [] });
  fs.writeFileSync(path.join(home, 'profiles/web/cordis.patch.yml'), '- id: x\n');
  assert.equal(await saveCheckpoint(home, store, new Date('2026-11-19T14:00:00Z')), true);
  assert.equal((await checkpointChanges(home, store)).at, '2026-11-19T14:00:00.000Z');
});

test('restoring puts back what was kept, moves what is new aside, and backs up whatever it replaces', async () => {
  const { home, store, backups } = layout();
  await saveCheckpoint(home, store, new Date('2026-11-19T12:00:00Z'));
  fs.writeFileSync(path.join(home, '.credentials.yaml'), broken);
  fs.writeFileSync(path.join(home, 'settings.yaml'), 'new: 1\n');
  fs.rmSync(path.join(home, 'profiles/web/cordis.patch.yml'));
  assert.deepEqual((await checkpointChanges(home, store)).changes, [
    { path: '.credentials.yaml', kind: 'changed' },
    { path: 'profiles/web/cordis.patch.yml', kind: 'removed' },
    { path: 'settings.yaml', kind: 'added' },
  ]);

  const backup = await backupFolder(backups, 'restore');
  const { at, files } = await restoreCheckpoint(home, store, backup);
  assert.equal(at, '2026-11-19T12:00:00.000Z');
  assert.deepEqual(files, ['.credentials.yaml', 'profiles/web/cordis.patch.yml', 'settings.yaml']);
  assert.equal(read(home, '.credentials.yaml'), 'version: 1\nrefs:\n  ZHIPU_API_KEY: zk-1\n');
  assert.equal(read(home, 'profiles/web/cordis.patch.yml'), '[]\n');
  assert.equal(exists(home, 'settings.yaml'), false);
  assert.equal(read(backup, '.credentials.yaml'), broken);
  assert.equal(read(backup, 'settings.yaml'), 'new: 1\n');
  assert.equal(exists(backup, 'profiles/web/cordis.patch.yml'), false);
  assert.equal(fs.statSync(path.join(home, '.credentials.yaml')).mode & 0o777, 0o600);
  // Data and packages stay where they were.
  assert.equal(read(home, 'sessions/a/session.jsonl'), '{}\n');
  assert.equal(exists(home, 'profiles/web/node_modules/some-plugin/package.json'), true);
  assert.deepEqual((await checkpointChanges(home, store)).changes, []);
  await assert.rejects(restoreCheckpoint(home, store, await backupFolder(backups, 'restore')), /already/);
});

test('resetting moves every setting and the builtins record aside, and leaves the data', async () => {
  const { home, data, backups } = layout();
  const backup = await backupFolder(backups, 'reset');
  assert.deepEqual(await resetSettings(home, data, backup), [
    '.credentials.yaml',
    '.ios-permission-default',
    'profiles/web/cordis.patch.yml',
    'profiles/web/package.json',
  ]);
  assert.deepEqual(await settingsFiles(home), []);
  assert.equal(exists(data, 'builtins.json'), false);
  assert.equal(read(backup, 'builtins.json'), '{"ds-bot":"0.3.8"}\n');
  assert.equal(read(backup, '.credentials.yaml'), 'version: 1\nrefs:\n  ZHIPU_API_KEY: zk-1\n');
  assert.equal(read(home, 'bot/workspace/notes.md'), 'hi\n');
  assert.equal(read(home, '.anonymous-user-id'), 'someone');
  assert.equal(exists(home, 'profiles/web/pnpm-lock.yaml'), true);
});

test('editing rewrites one settings file and backs up what was there; nothing else can be written', async () => {
  const { home, backups } = layout();
  fs.writeFileSync(path.join(home, '.credentials.yaml'), broken);
  const backup = await backupFolder(backups, 'edit');
  await editSetting(home, '.credentials.yaml', 'version: 1\n', backup);
  assert.equal(read(home, '.credentials.yaml'), 'version: 1\n');
  assert.equal(read(backup, '.credentials.yaml'), broken);
  await assert.rejects(editSetting(home, 'sessions/a/session.jsonl', '', backup), /not a settings file/);
  await assert.rejects(editSetting(home, '../escape', '', backup), /not a settings file/);
});

test('backups are named for when and what, and only the last ten stay', async () => {
  const { backups } = layout();
  for (let i = 0; i < 12; i += 1) await backupFolder(backups, 'reset', new Date(Date.UTC(2026, 10, 19, 12, i)));
  const all = fs.readdirSync(backups).sort();
  assert.equal(all.length, 10);
  assert.match(all[0], /^2026-11-19T12-02-00-reset-/);
});

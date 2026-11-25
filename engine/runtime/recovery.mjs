// The way back in when the engine will not come up because of what is in its
// settings. The app has no interface until the engine prints its URL, and the
// settings outlive a reinstall, so a setting that breaks the boot — a line in
// `.credentials.yaml` DSH rejects, a patch it cannot read — keeps the app on
// its launch screen for good. main.mjs runs this on a request from that screen.
//
// It works on the settings as files, not on what is in them, so it does not need
// to know which file is broken or why:
// - every time the engine comes up, the settings are kept as they were then;
// - a launch that fails can put those back (`restoreCheckpoint`), or move every
//   setting aside so the engine starts from its defaults (`resetSettings`);
// - one file can be rewritten by hand (`editSetting`).
// What is replaced is moved into a backup, never deleted. Sessions, Bots, apps and
// files are not settings and are never touched.
import fs from 'node:fs/promises';
import path from 'node:path';

/** The profile the app runs (`dsh web`). */
const PROFILE = path.join('profiles', 'web');
/**
 * Files there that are not settings: the lockfile goes with the installed packages,
 * which are not put back; the anonymous id names the install and is no setting.
 */
const NOT_SETTINGS = new Set(['pnpm-lock.yaml', '.anonymous-user-id']);
/** Settings are small; anything larger is not one, and is not copied around. */
const MAX_SIZE = 1 << 20;
/** Backups kept; the oldest go. */
const KEEP_BACKUPS = 10;

/**
 * The settings: the files directly in `$DSH_HOME` and in the profile's folder.
 * Folders below them hold data (sessions, Bots, storages, logs) and packages.
 * @param {string} home - `$DSH_HOME`.
 * @returns {Promise<string[]>} paths relative to `home`, sorted.
 */
export async function settingsFiles(home) {
  const found = [];
  for (const dir of ['', PROFILE]) {
    let entries;
    try {
      entries = await fs.readdir(path.join(home, dir), { withFileTypes: true });
    } catch (error) {
      if (error.code === 'ENOENT') continue;
      throw error;
    }
    for (const entry of entries) {
      if (!entry.isFile() || NOT_SETTINGS.has(entry.name)) continue;
      const file = path.join(dir, entry.name);
      if ((await fs.stat(path.join(home, file))).size <= MAX_SIZE) found.push(file);
    }
  }
  return found.sort();
}

async function readFiles(root, files) {
  const contents = new Map();
  for (const file of files) {
    try {
      contents.set(file, await fs.readFile(path.join(root, file)));
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }
  return contents;
}

/** Write one file whole: a reader never sees half of it. Owner-only, as DSH keeps its own. */
async function writeWhole(file, data) {
  await fs.mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
  const temp = `${file}.recovery-${process.pid}-${Date.now()}`;
  await fs.writeFile(temp, data, { mode: 0o600 });
  await fs.rename(temp, file);
}

/**
 * The settings kept from the last time the engine came up.
 * @param {string} store - where they are kept.
 * @returns {Promise<{at: string, contents: Map<string, Buffer>} | null>}
 */
export async function loadCheckpoint(store) {
  let meta;
  try {
    meta = JSON.parse(await fs.readFile(path.join(store, 'checkpoint.json'), 'utf8'));
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
  return { at: meta.at, contents: await readFiles(path.join(store, 'files'), meta.files) };
}

const same = (a, b) => a.size === b.size && [...a].every(([file, data]) => b.get(file)?.equals(data));

/**
 * Keep the settings as they are now: the engine has just come up with them.
 * @param {string} home - `$DSH_HOME`.
 * @param {string} store - where they are kept; replaced whole.
 * @returns {Promise<boolean>} whether anything had changed since the last time.
 */
export async function saveCheckpoint(home, store, now = new Date()) {
  const files = await settingsFiles(home);
  const contents = await readFiles(home, files);
  const saved = await loadCheckpoint(store).catch(() => null);
  if (saved && same(saved.contents, contents)) return false;
  // Assembled beside the old one and swapped in, so a crash halfway leaves the old one.
  await fs.mkdir(path.dirname(store), { recursive: true });
  const staging = await fs.mkdtemp(`${store}.staging-`);
  for (const [file, data] of contents) await writeWhole(path.join(staging, 'files', file), data);
  await fs.writeFile(path.join(staging, 'checkpoint.json'), JSON.stringify({ at: now.toISOString(), files: [...contents.keys()] }), { mode: 0o600 });
  const old = `${store}.old-${process.pid}-${Date.now()}`;
  await fs.rename(store, old).catch((error) => { if (error.code !== 'ENOENT') throw error; });
  await fs.rename(staging, store);
  await fs.rm(old, { recursive: true, force: true });
  return true;
}

/**
 * What putting the kept settings back would change.
 * `changed`: differs from what was kept; `added`: new since, it would be moved
 * aside; `removed`: gone since, it would come back.
 * @param {string} home - `$DSH_HOME`.
 * @param {string} store - where the settings are kept.
 * @returns {Promise<{at: string, changes: {path: string, kind: 'changed' | 'added' | 'removed'}[]} | null>}
 *   null when nothing is kept yet.
 */
export async function checkpointChanges(home, store) {
  const saved = await loadCheckpoint(store);
  if (!saved) return null;
  const current = await readFiles(home, await settingsFiles(home));
  const changes = [];
  for (const file of new Set([...current.keys(), ...saved.contents.keys()])) {
    const now = current.get(file);
    const then = saved.contents.get(file);
    if (now && then && now.equals(then)) continue;
    changes.push({ path: file, kind: !then ? 'added' : !now ? 'removed' : 'changed' });
  }
  return { at: saved.at, changes: changes.sort((a, b) => a.path.localeCompare(b.path)) };
}

/**
 * A new folder for what one action replaces, named for when and what. The oldest
 * beyond the last few go.
 * @param {string} root - where backups live.
 * @param {string} action - what is replacing them.
 * @returns {Promise<string>} the folder.
 */
export async function backupFolder(root, action, now = new Date()) {
  await fs.mkdir(root, { recursive: true, mode: 0o700 });
  const stamp = now.toISOString().replace(/\.\d+Z$/, '').replaceAll(':', '-');
  const folder = await fs.mkdtemp(path.join(root, `${stamp}-${action}-`));
  const all = (await fs.readdir(root)).sort();
  for (const old of all.slice(0, Math.max(0, all.length - KEEP_BACKUPS))) await fs.rm(path.join(root, old), { recursive: true, force: true });
  return folder;
}

/**
 * Put back the settings kept from the last time the engine came up. What is
 * there now is moved into `backup` first.
 * @param {string} home - `$DSH_HOME`.
 * @param {string} store - where the settings are kept.
 * @param {string} backup - an empty folder (`backupFolder`).
 * @returns {Promise<{at: string, files: string[]}>} when they were kept, and the files changed.
 * @throws when nothing is kept, or nothing differs from it.
 */
export async function restoreCheckpoint(home, store, backup) {
  const saved = await loadCheckpoint(store);
  const diff = await checkpointChanges(home, store);
  if (!saved || !diff) throw new Error('no settings have been kept yet');
  if (diff.changes.length === 0) throw new Error('the settings are already as they were');
  for (const { path: file } of diff.changes) {
    const there = path.join(home, file);
    const kept = saved.contents.get(file);
    try {
      await writeWhole(path.join(backup, file), await fs.readFile(there));
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    if (kept) await writeWhole(there, kept);
    else await fs.rm(there, { force: true });
  }
  return { at: saved.at, files: diff.changes.map((change) => change.path) };
}

/**
 * Move every setting into `backup`, so the engine starts from its defaults. The
 * record of built-in plugins already switched on (`data/builtins.json`) goes too,
 * so they are switched on again in the new profile.
 * @param {string} home - `$DSH_HOME`.
 * @param {string} data - `DSH_IOS_DATA`.
 * @param {string} backup - an empty folder (`backupFolder`).
 * @returns {Promise<string[]>} the files moved, relative to `home`.
 */
export async function resetSettings(home, data, backup) {
  const files = await settingsFiles(home);
  for (const file of files) {
    await fs.mkdir(path.dirname(path.join(backup, file)), { recursive: true, mode: 0o700 });
    await fs.rename(path.join(home, file), path.join(backup, file));
  }
  await fs.rename(path.join(data, 'builtins.json'), path.join(backup, 'builtins.json')).catch((error) => {
    if (error.code !== 'ENOENT') throw error;
  });
  return files;
}

/**
 * Rewrite one setting by hand. What was there is copied into `backup` first.
 * @param {string} home - `$DSH_HOME`.
 * @param {string} file - one of `settingsFiles(home)`.
 * @param {string} text - the new contents.
 * @param {string} backup - an empty folder (`backupFolder`).
 */
export async function editSetting(home, file, text, backup) {
  if (!(await settingsFiles(home)).includes(file)) throw new Error(`${file} is not a settings file`);
  const there = path.join(home, file);
  await writeWhole(path.join(backup, file), await fs.readFile(there));
  await writeWhole(there, text);
}

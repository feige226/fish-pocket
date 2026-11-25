// Old copies of DSH's own packages in the profile, removed before the engine starts.
//
// The profile installs plugins with pnpm's hoisted linker, so a plugin that depends on
// an official package (`@deepseek-ai/dsh-*`) leaves a copy of it at the top of the
// profile's node_modules, at the version DSH had then. The profile resolves from there
// before the engine's folder, so after an app update that copy shadows the version the
// app ships. DSH then switches the row off as incompatible, and every service behind it
// stays pending: with `dsh-storage-domain` that is workspaces, sessions and Bot, and the
// app opens with nothing in it and nothing to tap.
//
// Removing such a copy hands the package back to the engine's own version: DSH finds it
// there (as in a profile that never had one), and a plugin that imports it falls back to
// the engine's folder (module-redirects.mjs). A copy at the shipped version stays, and so
// does any package the app does not ship. Nothing else in the profile is touched. pnpm may
// put a copy back on the next install; the next start removes it again.
import { readdir, readFile, rm } from 'node:fs/promises';
import path from 'node:path';
import { writeFileAtomic } from '@deepseek-ai/dsh-atomic-write';

const SCOPE = '@deepseek-ai';
/** DSH's runtime packages; other packages of the scope are libraries a plugin may pin on purpose. */
export const isOfficial = (name) => /^@deepseek-ai\/dsh(?:-|$)/.test(name);

const versionIn = async (dir) => {
  try {
    return JSON.parse(await readFile(path.join(dir, 'package.json'), 'utf8')).version;
  } catch {
    return undefined;
  }
};

/**
 * Remove the profile's copies of official packages that differ from the engine's.
 * @param {{ profile: string, engineModules: string }} dirs - the profile directory
 *   (`$DSH_HOME/profiles/web`) and the engine's node_modules.
 * @returns {Promise<{ name: string, found: string, shipped: string }[]>} what was removed:
 *   copies in node_modules, and dependencies of the profile's package.json.
 */
export async function removeStaleOfficial({ profile, engineModules }) {
  const removed = [];
  const shippedVersion = (name) => versionIn(path.join(engineModules, name));

  const scope = path.join(profile, 'node_modules', SCOPE);
  const entries = await readdir(scope).catch(() => []);
  for (const entry of entries) {
    const name = `${SCOPE}/${entry}`;
    if (!isOfficial(name)) continue;
    const shipped = await shippedVersion(name);
    if (shipped === undefined) continue;
    const found = await versionIn(path.join(scope, entry));
    if (found === shipped) continue;
    await rm(path.join(scope, entry), { recursive: true, force: true });
    removed.push({ name, found: found ?? 'unknown', shipped });
  }

  // A dependency the profile names itself would come back with the next install.
  const file = path.join(profile, 'package.json');
  let manifest;
  try {
    manifest = JSON.parse(await readFile(file, 'utf8'));
  } catch {
    return removed;
  }
  const dependencies = manifest.dependencies ?? {};
  let changed = false;
  for (const [name, spec] of Object.entries(dependencies)) {
    if (!isOfficial(name)) continue;
    const shipped = await shippedVersion(name);
    if (shipped === undefined || spec === shipped) continue;
    delete dependencies[name];
    changed = true;
    if (!removed.some((item) => item.name === name)) removed.push({ name, found: String(spec), shipped });
  }
  // The plugin manager's own form: two-space JSON, owner-only.
  if (changed) await writeFileAtomic(file, `${JSON.stringify(manifest, undefined, 2)}\n`, { mode: 0o600 });
  return removed;
}

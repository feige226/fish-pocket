// A minute, not DSH's 15 seconds, for reading a plugin index.
//
// The market reads a whole index in one request (thousands of plugins, several
// megabytes), and the stock 15 s covers the request and the body together. On a
// phone network, or an index host that is slow from where the user is, that runs
// out while the download is still going, and the store only says it cannot read
// the index.
//
// The value cannot go into ios.patch.yml: an overlay config replaces the entry's
// whole config, and the index list the user picks (`indexes`, written by 设置
// into the profile's own patch) would be hidden under it. So, like the
// permission default, it goes into the profile's own `plugin-market` row, next to
// that list: added to the row the store already wrote, or a row of its own. A
// row for an entry that is not mounted (the market bundle is off until the user
// picks a source) is skipped with a warning and applies once it is.
//
// Once per install, recorded by a marker: a value the user later sets in the web
// settings stays theirs.
import { existsSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { loadProfile } from '@deepseek-ai/dsh-app-boot';
import { writeFileAtomic } from '@deepseek-ai/dsh-atomic-write';
import { isMap, isSeq, parseDocument } from 'yaml';

export const ENTRY = 'plugin-market';
export const TIMEOUT_MS = 60_000;

/**
 * Give the `web` profile's plugin market a one-minute fetch timeout unless it has one of its own.
 * @param {object} options
 * @param {string} options.home - DSH_HOME.
 * @param {string} options.marker - the file that records this ran.
 * @param {string} options.installAnchor - the dsh package's package.json, where profile bundles resolve from.
 * @returns {Promise<'seeded' | 'kept' | 'done'>} wrote the timeout, found the user's own, or had already run.
 */
export async function seedMarketTimeout({ home, marker, installAnchor }) {
  if (existsSync(marker)) return 'done';
  // Creates the profile on a first launch, as `dsh web` would; otherwise only reads it.
  const profile = loadProfile('dsh', 'web', installAnchor, home);
  const outcome = await addTimeout(profile.patchPath);
  await writeFileAtomic(marker, `${outcome}\n`, { mode: 0o600 });
  return outcome;
}

async function addTimeout(file) {
  let text;
  try {
    text = await readFile(file, 'utf8');
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    text = '[]\n';
  }
  const document = parseDocument(text, {
    customTags: [{ tag: 'tag:yaml.org,2002:js', resolve: (value) => value }],
  });
  if (document.errors[0] !== undefined) throw document.errors[0];
  if (document.contents === null) document.contents = document.createNode([]);
  if (!isSeq(document.contents)) throw new Error(`${file}: a profile patch must be a YAML sequence`);
  // The row a 设置 write leaves: the entry's id and a config, no insert.
  const row = document.contents.items.find((item) => isMap(item) && item.get('id') === ENTRY && !item.has('insert'));
  if (row !== undefined) {
    if (row.hasIn(['config', 'fetchTimeoutMs'])) return 'kept';
    // A patch config replaces the whole config, so the row's other fields (the index list) stay as they are.
    if (!isMap(row.get('config'))) row.set('config', document.createNode({}));
    row.setIn(['config', 'fetchTimeoutMs'], TIMEOUT_MS);
  } else {
    document.contents.flow = false;
    document.add(document.createNode({ id: ENTRY, config: { fetchTimeoutMs: TIMEOUT_MS } }));
  }
  // The config editor's own form: owner-only.
  await writeFileAtomic(file, String(document), { mode: 0o600 });
  return 'seeded';
}

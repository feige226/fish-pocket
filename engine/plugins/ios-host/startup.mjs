// How start-up stands, for the launch screen. DSH prints its URL only once every
// plugin has loaded, third-party ones included, and some of those take seconds
// (one that starts a Python server, say). The launch screen keeps waiting either
// way; this only lets it say that the engine itself is up and what is left is the
// user's own plugins, so a slow launch is not taken for a slow app.
import { parentPort } from 'node:worker_threads';
import { isThirdParty } from '../../runtime/safe-mode.mjs';

/**
 * The package a loader entry's `name` loads; undefined for the app's own plugins
 * (`file:` URLs), cordis builtins (`cordis:include`) and relative paths.
 * @param {unknown} name - the entry's `name`.
 * @returns {string | undefined}
 */
export function entryPackage(name) {
  if (typeof name !== 'string' || name === '' || name.startsWith('.') || name.startsWith('/')) return undefined;
  if (/^[a-z][a-z0-9+.-]*:/i.test(name)) return undefined;
  const parts = name.split('/');
  return name.startsWith('@') ? parts.slice(0, 2).join('/') : parts[0];
}

/**
 * The third-party plugins start-up is still waiting on, when nothing else is
 * still loading; empty while anything of DSH's or the app's is.
 * @param {Iterable<{ options?: { name?: string }, _initTask?: unknown, fiber?: { inertia?: unknown } }>} entries
 * @param {(name: string) => boolean} thirdParty
 * @returns {string[]}
 */
export function waitingOnThirdParty(entries, thirdParty = isThirdParty) {
  const waiting = new Set();
  for (const entry of entries) {
    // The same test the loader's own `await()` makes (EntryTree.getTasks).
    if (!(entry._initTask || entry.fiber?.inertia)) continue;
    const name = entryPackage(entry.options?.name);
    if (name === undefined || !thirdParty(name)) return [];
    waiting.add(name);
  }
  return [...waiting];
}

/**
 * Tell main.mjs once, when start-up comes down to third-party plugins only.
 * @param {{ get(name: string): any }} ctx
 * @returns {() => void} stops watching.
 */
export function watchStartup(ctx, { post = (message) => parentPort?.postMessage(message), intervalMs = 100 } = {}) {
  let loader;
  try {
    loader = ctx.get('loader');
  } catch {}
  if (typeof loader?.entries !== 'function') return () => {};
  const timer = setInterval(() => {
    const waiting = waitingOnThirdParty(loader.entries());
    if (waiting.length > 0) {
      post({ type: 'dsh-ios/plugins-starting', plugins: waiting });
      clearInterval(timer);
    } else if (loader.getTasks().length === 0) {
      clearInterval(timer);
    }
  }, intervalMs);
  timer.unref?.();
  return () => clearInterval(timer);
}

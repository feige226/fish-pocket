// A `node` file on disk for programs that look Node up before spawning it.
// process.execPath is the app here, not a binary named node, so code that
// starts a Node child the desktop way ("is execPath node? otherwise find node
// on PATH") finds nothing and gives up: billion-context's proxy is one. The
// spawn itself already works, because child-process.mjs runs any program named
// node as a worker without reading the file, so all that is missing is a file
// to find. It goes in the real /usr/bin, which is on the engine's PATH; the
// shell mounts its own /usr/bin over it and keeps its own `node` command.
import fs from 'node:fs';
import path from 'node:path';

const CONTENT = '#!/bin/sh\n# Placeholder: Fish Pocket runs `node` in-process; this file only lets programs find it on PATH.\nexec node "$@"\n';

/** Make sure `<root>/usr/bin/node` exists and is executable. Never throws. */
export function placeNodeEntry(root = '/') {
  const file = path.join(root, 'usr', 'bin', 'node');
  try {
    if (fs.readFileSync(file, 'utf8') === CONTENT && (fs.statSync(file).mode & 0o111)) return file;
  } catch {}
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, CONTENT, { mode: 0o755 });
    fs.chmodSync(file, 0o755);
  } catch {}
  return file;
}

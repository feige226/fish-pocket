// Node entry for the iOS host (also runnable on a desktop Node for testing).
// The host starts Node with this file inside the engine's filesystem view
// (native/root) and passes DSH_IOS_HOME and DSH_IOS_DATA, a directory the two
// share. We lay out DSH_HOME/HOME/TMPDIR and run the DSH engine (boot.mjs) in a
// worker thread, publishing its web URL (it carries the access token) to a 0600
// file the host polls.
//
// The worker is what makes "restart DSH" possible: iOS starts Node once per
// process and an app cannot relaunch itself, yet some plugin changes only
// apply at startup. Replacing the worker gives the engine a new isolate and a
// fresh module cache in the same process, on the same port. The engine asks
// for it (plugins/ios-host) and we also restart it if it dies.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Worker } from 'node:worker_threads';
import { PRELOAD } from './runtime/real-paths.mjs';
import { placeNodeEntry } from './runtime/node-entry.mjs';
import { disableThirdParty } from './runtime/safe-mode.mjs';
import {
  backupFolder, checkpointChanges, editSetting, resetSettings, restoreCheckpoint, saveCheckpoint, settingsFiles,
} from './runtime/recovery.mjs';

const data = process.env.DSH_IOS_DATA;
if (!data) throw new Error('DSH_IOS_DATA is not set');
// Set by the iOS host. Without it (a desktop run) everything stays below `data`.
const home = process.env.DSH_IOS_HOME;
const dirs = home
  ? { DSH_HOME: path.join(home, '.dsh'), HOME: home, TMPDIR: '/tmp', workspace: path.join(home, 'workspace') }
  : { DSH_HOME: path.join(data, 'dsh'), HOME: path.join(data, 'home'), TMPDIR: path.join(data, 'tmp'), workspace: path.join(data, 'workspace') };
for (const dir of Object.values(dirs)) fs.mkdirSync(dir, { recursive: true });
// Only inside the app's filesystem view: on a desktop run / is the real disk.
if (home) placeNodeEntry();

// The engine's environment, not this thread's: that one is the process's, and
// the system frameworks in the process read HOME and TMPDIR, which stay real.
const env = {
  ...process.env,
  DSH_HOME: dirs.DSH_HOME,
  HOME: dirs.HOME,
  TMPDIR: dirs.TMPDIR,
  // The first-use workspace goes under this directory (see ios.patch.yml).
  DSH_IOS_DOCUMENTS: process.env.DSH_IOS_DOCUMENTS ?? path.join(data, 'documents'),
  // Skills that ship with the app, ios-environment among them (dsh-skill-filesystem's bundled root).
  DSH_BUNDLED_SKILL_DIR: path.join(path.dirname(fileURLToPath(import.meta.url)), 'skills'),
  SHELL: process.env.SHELL ?? '/bin/bash',
  // Commands resolve inside the in-process shell, whose binaries live in /bin;
  // the OS PATH (simulator runtime dirs, /usr/bin on device) means nothing there.
  PATH: '/bin:/usr/bin',
  // No terminal to answer prompts: pnpm would otherwise stop and ask before
  // purging a node_modules it wants to rebuild.
  pnpm_config_confirm_modules_purge: process.env.pnpm_config_confirm_modules_purge ?? 'false',
};
// iOS sets this to the real container, and nothing in the engine needs it.
delete env.CFFIXED_USER_HOME;
// Workers cannot chdir; the engine inherits the process working directory.
process.chdir(dirs.workspace);

const urlFile = path.join(data, 'web-url');

// Recovery (runtime/recovery.mjs and runtime/safe-mode.mjs), asked for by the launch
// screen. A stuck engine answers no HTTP and nothing else reaches this thread, so the
// app asks by file and reads how it stands from another; this thread is not the
// worker's, so a worker that hangs does not hold it up.
const recoveryRequest = path.join(data, 'recovery-request.json');
const recoveryState = path.join(data, 'recovery-state.json');
/** What was done, for the app to tell once it is in (NodeEngine.takeRecoveryReport). */
const recoveryReport = path.join(data, 'recovery-report.json');
/** The settings of the last launch that came up. */
const checkpointDir = path.join(data, 'last-good');
/** What recovery replaced: never deleted, only moved here. */
const backupRoot = path.join(data, 'recovery');
/** `starting` until the URL is out; `failed` once restarting has stopped. */
let phase = 'starting';
/** While starting: the engine is up and only third-party plugins are still loading. */
let thirdPartyStarting = false;
/** The last recovery request carried out, so the app can tell its own from an old one. */
let lastAction;
const log = fs.createWriteStream(path.join(data, 'engine.log'), { flags: 'a', mode: 0o600 });
const redact = (text) => text.replace(/token=[A-Za-z0-9_-]+/g, 'token=…');
// Each line of the log starts with the time it was written: without it a launch
// that is slow and one that is stuck read the same. Output comes in chunks that
// need not end at a line, so only a chunk's line starts get one.
const pad = (n, width = 2) => String(n).padStart(width, '0');
let lineStart = true;
function stamped(text) {
  const now = new Date();
  const time = `${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}.${pad(now.getMilliseconds(), 3)} `;
  const out = (lineStart ? time : '') + text.replace(/\n(?=[^])/g, `\n${time}`);
  lineStart = text.endsWith('\n');
  return out;
}
let published = false;
// Worker output reaches the process through these streams, so the tee sees both.
for (const name of ['stdout', 'stderr']) {
  const stream = process[name];
  const write = stream.write.bind(stream);
  stream.write = (chunk, ...rest) => {
    const text = typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString('utf8');
    if (text) log.write(stamped(redact(text)));
    const match = !published && /dsh web: (http:\/\/\S+)/.exec(text);
    if (match) {
      published = true;
      fs.writeFileSync(`${urlFile}.tmp`, match[1], { mode: 0o600 });
      fs.renameSync(`${urlFile}.tmp`, urlFile);
      // The settings it came up with are the ones a failing launch can go back to.
      phase = 'running';
      void saveCheckpoint(dirs.DSH_HOME, checkpointDir)
        .catch((error) => console.error('[dsh-ios] settings not kept', error))
        .finally(publishState);
    }
    return write(redact(text), ...rest);
  };
}
const jitless = String(process.config.variables.node_v8_options ?? '').includes('--jitless') || process.execArgv.includes('--jitless');
console.log(`[dsh-ios] node ${process.version} ${process.platform}/${process.arch} jitless=${jitless} data=${data} at ${new Date().toISOString()}`);

let engine;
let restarting = false;
let crashes = 0;
/// The start a crashed worker waits for, which a restart replaces.
let retry;
/// A boot that fails this many times running is not going to come up by trying again:
/// what keeps it down is on disk. Restarting then stops until the app asks.
const GIVE_UP_AFTER = 3;

function start() {
  fs.rmSync(urlFile, { force: true });
  published = false;
  phase = 'starting';
  thirdPartyStarting = false;
  void publishState();
  const startedAt = Date.now();
  engine = new Worker(new URL('./boot.mjs', import.meta.url), {
    env,
    // Engine boot reads Node's module loader internals (see shims/).
    execArgv: [...PRELOAD, '--expose-internals'],
    trackUnmanagedFds: false,
  });
  engine.on('message', (message) => {
    if (message?.type === 'dsh-ios/restart') void restart(message.reason);
    // plugins/ios-host/startup.mjs: what is left of start-up is the user's own plugins.
    if (message?.type === 'dsh-ios/plugins-starting' && phase === 'starting' && !published) {
      console.log(`[dsh-ios] engine up; waiting on third-party plugins: ${message.plugins.join(', ')}`);
      thirdPartyStarting = true;
      void publishState();
    }
  });
  engine.on('error', (error) => console.error('[dsh-ios] engine error', error));
  engine.on('exit', (code) => {
    if (restarting) return;
    // Unexpected exit: back off while it keeps failing early, then try again.
    crashes = Date.now() - startedAt > 60_000 ? 1 : crashes + 1;
    if (crashes >= GIVE_UP_AFTER) {
      console.error(`[dsh-ios] engine exited (${code}) ${crashes} times running; not restarting until the app asks`);
      phase = 'failed';
      void publishState();
      return;
    }
    const delay = Math.min(30_000, 1000 * 2 ** (crashes - 1));
    console.error(`[dsh-ios] engine exited (${code}); restarting in ${delay} ms`);
    retry = setTimeout(start, delay);
  });
}

async function restart(reason) {
  if (restarting) return;
  restarting = true;
  clearTimeout(retry);
  console.log(`[dsh-ios] restarting engine${reason ? ` (${reason})` : ''}`);
  await engine.terminate();
  restarting = false;
  start();
}

/// `~/…` for the paths the app shows: what the agent and the user both know them by.
const shown = (file) => (file.startsWith(`${dirs.HOME}/`) ? `~${file.slice(dirs.HOME.length)}` : file);

/// How the launch stands, for the launch screen: the phase, the last request carried
/// out, what going back to the kept settings would change, and the settings files.
/// Written whole, one at a time, so a slow one cannot overwrite a newer one.
let writing = Promise.resolve();
function publishState() {
  writing = writing.then(async () => {
    try {
      const running = phase === 'running';
      const state = {
        state: phase,
        thirdPartyStarting: phase === 'starting' && thirdPartyStarting,
        action: lastAction,
        checkpoint: running ? undefined : await checkpointChanges(dirs.DSH_HOME, checkpointDir).catch(() => null),
        files: running ? [] : await settingsFiles(dirs.DSH_HOME).catch(() => []),
      };
      fs.writeFileSync(`${recoveryState}.tmp`, JSON.stringify(state), { mode: 0o600 });
      fs.renameSync(`${recoveryState}.tmp`, recoveryState);
    } catch (error) {
      console.error('[dsh-ios] launch state not written', error);
    }
  });
  return writing;
}

/// One recovery step. Returns what the app tells about it.
async function recover(request) {
  const home = dirs.DSH_HOME;
  switch (request.action) {
    case 'safe-mode': {
      const disabled = await disableThirdParty(path.join(home, 'profiles', 'web'));
      console.log(`[dsh-ios] safe mode: switched off ${disabled.length ? disabled.join(', ') : 'nothing'}`);
      return { disabled };
    }
    case 'restore': {
      const backup = await backupFolder(backupRoot, 'restore');
      const { at, files } = await restoreCheckpoint(home, checkpointDir, backup);
      console.log(`[dsh-ios] recovery: put back the settings of ${at}: ${files.join(', ')}; what was there is in ${backup}`);
      return { files, checkpoint: at, backup: shown(backup) };
    }
    case 'reset': {
      const backup = await backupFolder(backupRoot, 'reset');
      const files = await resetSettings(home, data, backup);
      console.log(`[dsh-ios] recovery: moved every setting into ${backup}: ${files.join(', ')}`);
      return { files, backup: shown(backup) };
    }
    case 'edit': {
      const backup = await backupFolder(backupRoot, 'edit');
      await editSetting(home, request.path, String(request.text ?? ''), backup);
      console.log(`[dsh-ios] recovery: ${request.path} rewritten by hand; what was there is in ${backup}`);
      return { files: [request.path], backup: shown(backup) };
    }
    case 'restart':
      return {};
    default:
      throw new Error(`unknown recovery action ${JSON.stringify(request.action)}`);
  }
}

let recovering = false;
// Not unref'd: once restarting has stopped there is no worker left, and this is what
// keeps Node — which can start only once per process — up for the app to ask.
setInterval(async () => {
  if (recovering || restarting || !fs.existsSync(recoveryRequest)) return;
  recovering = true;
  let request;
  try {
    request = JSON.parse(fs.readFileSync(recoveryRequest, 'utf8'));
  } catch {
    request = undefined;
  }
  fs.rmSync(recoveryRequest, { force: true });
  try {
    if (typeof request?.id !== 'string') return;
    const at = new Date().toISOString();
    try {
      lastAction = { id: request.id, action: request.action, at, ok: true, ...(await recover(request)) };
    } catch (error) {
      console.error(`[dsh-ios] recovery ${request.action} failed`, error);
      lastAction = { id: request.id, action: request.action, at, ok: false, error: String(error?.message ?? error) };
      await publishState();
      return;
    }
    if (request.action !== 'restart') {
      let report = { actions: [] };
      try {
        report = JSON.parse(fs.readFileSync(recoveryReport, 'utf8'));
      } catch {}
      report.actions.push(lastAction);
      fs.writeFileSync(recoveryReport, JSON.stringify(report), { mode: 0o600 });
    }
    // A fresh run of tries for what was just changed.
    crashes = 0;
    await restart(`recovery: ${request.action}`);
  } finally {
    recovering = false;
  }
}, 1000);

start();

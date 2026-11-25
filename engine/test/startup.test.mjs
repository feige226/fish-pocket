import test from 'node:test';
import assert from 'node:assert/strict';
import { entryPackage, waitingOnThirdParty, watchStartup } from '../plugins/ios-host/startup.mjs';

const entry = (name, pending) => ({ options: { name }, ...(pending ? { fiber: { inertia: Promise.resolve() } } : {}) });

test('an entry name maps to its package; the app’s own and cordis builtins to none', () => {
  assert.equal(entryPackage('@someone/slow-plugin'), '@someone/slow-plugin');
  assert.equal(entryPackage('@deepseek-ai/dsh-workspace/server'), '@deepseek-ai/dsh-workspace');
  assert.equal(entryPackage('ds-bot/web-search'), 'ds-bot');
  assert.equal(entryPackage('some-plugin'), 'some-plugin');
  assert.equal(entryPackage('file:///opt/dsh/nodejs-project/plugins/ios-host/index.mjs'), undefined);
  assert.equal(entryPackage('cordis:include'), undefined);
  assert.equal(entryPackage('./local.mjs'), undefined);
  assert.equal(entryPackage(undefined), undefined);
});

test('waiting on third-party plugins only once nothing of DSH’s or the app’s is loading', () => {
  const thirdParty = (name) => !name.startsWith('@deepseek-ai/') && name !== 'ds-bot';
  assert.deepEqual(waitingOnThirdParty([entry('@deepseek-ai/dsh-workspace', true), entry('@someone/slow-plugin', true)], thirdParty), []);
  assert.deepEqual(waitingOnThirdParty([entry('ds-bot/web-search', true), entry('@someone/slow-plugin', true)], thirdParty), []);
  assert.deepEqual(waitingOnThirdParty([entry('file:///opt/dsh/x.mjs', true), entry('@someone/slow-plugin', true)], thirdParty), []);
  assert.deepEqual(waitingOnThirdParty([entry('@deepseek-ai/dsh-workspace', false), entry('@someone/slow-plugin', true), entry('@someone/slow-plugin', true)], thirdParty), ['@someone/slow-plugin']);
  assert.deepEqual(waitingOnThirdParty([entry('@deepseek-ai/dsh-workspace', false), entry('@someone/slow-plugin', false)], thirdParty), []);
});

test('the default rule takes the app’s built-in ds-bot for its own', () => {
  assert.deepEqual(waitingOnThirdParty([entry('ds-bot', true), entry('some-plugin', true)]), []);
  assert.deepEqual(waitingOnThirdParty([entry('ds-bot', false), entry('some-plugin', true)]), ['some-plugin']);
});

test('tells main.mjs once, and stops once the tree has settled', async () => {
  const entries = [entry('@deepseek-ai/dsh-workspace', true), entry('some-plugin', true)];
  const loader = { entries: () => entries, getTasks: () => entries.filter((e) => e.fiber?.inertia) };
  const posted = [];
  const stop = watchStartup({ get: () => loader }, { post: (m) => posted.push(m), intervalMs: 5 });
  await new Promise((done) => setTimeout(done, 20));
  assert.deepEqual(posted, []);
  entries[0] = entry('@deepseek-ai/dsh-workspace', false);
  await new Promise((done) => setTimeout(done, 20));
  entries[1] = entry('some-plugin', false);
  await new Promise((done) => setTimeout(done, 20));
  assert.deepEqual(posted, [{ type: 'dsh-ios/plugins-starting', plugins: ['some-plugin'] }]);
  stop();
});

test('nothing is said when no third-party plugin holds start-up up', async () => {
  const entries = [entry('@deepseek-ai/dsh-workspace', false)];
  const posted = [];
  const stop = watchStartup({ get: () => ({ entries: () => entries, getTasks: () => [] }) }, { post: (m) => posted.push(m), intervalMs: 5 });
  await new Promise((done) => setTimeout(done, 20));
  assert.deepEqual(posted, []);
  stop();
});

// ios.patch.yml disables the whole `harness-dev-context` plugin because its prompt tells
// the model the user is in the DSH Web GUI. Disabling a plugin also drops whatever an
// upgrade adds to it later, so this pins everything it registers today: if it starts doing
// anything else, this fails and whoever upgrades DSH decides again whether to keep it off.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import * as plugin from '@deepseek-ai/dsh-harness-dev-context';

test('ios.patch.yml still disables harness-dev-context', () => {
  const patch = readFileSync(new URL('../ios.patch.yml', import.meta.url), 'utf8');
  assert.match(patch, /- id: harness-dev-context\n\s+disabled: true/);
});

test('harness-dev-context registers only the Web GUI and checkout prompt it was disabled for', async () => {
  assert.equal(plugin.name, 'harness-dev-context');
  assert.deepEqual([...plugin.inject].sort(), ['sessionProjections', 'systemPrompt', 'webApp']);

  const calls = [];
  // Any service or method this plugin starts to use shows up in `calls`.
  const service = (svc) => new Proxy({}, {
    get: (_, method) => (arg) => {
      if (method === 'getSectionOrder' || method === 'getContextOrder') return 0;
      calls.push(`${svc}.${String(method)}(${arg?.name ?? arg?.key ?? ''})`);
      if (method === 'register') return { stateOf: () => ({ source: null, web: null }) };
      if (method === 'getAdvertisedUrl') return 'http://127.0.0.1:0';
      return () => {};
    },
  });
  const ctx = new Proxy({}, { get: (_, key) => service(String(key)) });
  await plugin.apply(ctx);

  assert.deepEqual(calls.sort(), [
    'sessionProjections.register(harnessDevLegacyPrompt)',
    'systemPrompt.context(app:web-surface)',
    'systemPrompt.context(harness:source)',
    'systemPrompt.section(app:web-surface)',
    'systemPrompt.section(harness:source)',
  ], 'harness-dev-context now registers something else: check whether iOS still wants it disabled (engine/ios.patch.yml), then update this list');
});

// plugins/ios-host/image-gen-notes.mjs drops dsh-image-gen's closed-canvas note and adds where
// the app keeps image settings after the plugin's image context. It finds both by the plugin's
// context names and wording, so an upgrade that renames one would quietly stop it: the first
// test fails then, and whoever upgrades checks what the plugin now tells the model.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { Context } from '@deepseek-ai/cordis';
import { SystemPrompt, renderContextSections } from '@deepseek-ai/dsh-system-prompt';
import { CANVAS_CLOSED, CANVAS_CONTEXT, IMAGE_CONTEXT, SETTINGS_CONTEXT, SETTINGS_NOTE, WEB_SETTINGS_PATH, addSettingsNote, dropClosedCanvas, installImageGenNotes } from '../plugins/ios-host/image-gen-notes.mjs';

test('the bundled dsh-image-gen still names its notes and words them as expected', () => {
  const require = createRequire(import.meta.url);
  const source = readFileSync(require.resolve('dsh-image-gen'), 'utf8');
  assert.ok(source.includes(`'${CANVAS_CONTEXT}'`) || source.includes(`"${CANVAS_CONTEXT}"`), `dsh-image-gen no longer registers ${CANVAS_CONTEXT}`);
  assert.ok(source.includes(CANVAS_CLOSED), 'dsh-image-gen words its closed-canvas note differently now: update CANVAS_CLOSED after reading it');
  assert.ok(source.includes(`'${IMAGE_CONTEXT}'`) || source.includes(`"${IMAGE_CONTEXT}"`), `dsh-image-gen no longer registers ${IMAGE_CONTEXT}`);
  assert.ok(source.includes(WEB_SETTINGS_PATH), 'dsh-image-gen no longer points at its web settings page this way: check what its errors say now and update SETTINGS_NOTE');
});

test('the settings line follows the plugin\'s image context, once', () => {
  const image = { name: IMAGE_CONTEXT, text: 'Image tools current default provider: google' };
  const after = addSettingsNote({ contexts: [image, { name: 'other', text: 'x' }] });
  assert.deepEqual(after.contexts.map((entry) => entry.name), [IMAGE_CONTEXT, SETTINGS_CONTEXT, 'other']);
  assert.equal(after.contexts[1].text, SETTINGS_NOTE);
  assert.equal(addSettingsNote(after).contexts.length, 3);
  assert.deepEqual(addSettingsNote({ contexts: [{ name: 'other', text: 'x' }] }).contexts.map((entry) => entry.name), ['other']);
});

test('only the closed-canvas note is dropped', () => {
  const others = [{ name: 'working-directory:current', text: 'cwd' }];
  const closed = dropClosedCanvas({ contexts: [...others, { name: CANVAS_CONTEXT, text: `${CANVAS_CLOSED} No canvas is open.` }] });
  assert.deepEqual(closed.contexts, others);

  const open = { name: CANVAS_CONTEXT, text: 'Image-gen workbench canvas: 2 shapes (2 draws), updated just now.' };
  assert.deepEqual(dropClosedCanvas({ contexts: [...others, open] }).contexts, [...others, open]);
  assert.deepEqual(dropClosedCanvas({ contexts: [...others] }).contexts, others);
});

test('the drop holds through the per-request refresh, and an opened canvas comes back on the next assembly', async () => {
  const ctx = new Context();
  await ctx.plugin(SystemPrompt, {});
  let digest = `${CANVAS_CLOSED} No canvas is open.`;
  ctx.systemPrompt.context({ name: IMAGE_CONTEXT, order: 59, text: () => 'Image tools current default provider: google.' });
  ctx.systemPrompt.context({ name: CANVAS_CONTEXT, order: 60, text: () => digest });
  installImageGenNotes(ctx);

  const assembly = await ctx.systemPrompt.assemble({});
  const names = (value) => renderContextSections(value).map((section) => section.name);
  assert.deepEqual(names(assembly), [IMAGE_CONTEXT, SETTINGS_CONTEXT]);
  // The engine re-reads registered contexts before every request: the plugin's note stays out.
  assert.deepEqual(names(ctx.systemPrompt.refreshContext(assembly, {})), [IMAGE_CONTEXT, SETTINGS_CONTEXT]);

  digest = 'Image-gen workbench canvas: 1 shape (1 draw), updated just now.';
  const opened = await ctx.systemPrompt.assemble({});
  assert.deepEqual(names(opened), [IMAGE_CONTEXT, SETTINGS_CONTEXT, CANVAS_CONTEXT]);
  assert.equal(renderContextSections(opened).at(-1).text, digest);
});

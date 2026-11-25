// What dsh-image-gen tells the model that is not so in the app, and one fact the model
// cannot know on its own. Both ride in the runtime context, a user-role snapshot appended only
// when its text changes, so a fixed note costs nothing after a session's first snapshot.
//
// The plugin's canvas note, with no canvas open, says to send the user to the workbench
// whenever they mention a drawing. In the app a markup is drawn on a picture in the
// conversation and arrives as an image on the message, which the model sees for itself, so
// that note is dropped and nothing is said in its place. A canvas really open in the web
// version keeps the plugin's note, which then describes it. Before each request the engine
// re-reads every registered context by name, which would undo an edit to the plugin's text;
// a dropped entry stays dropped.

/** The plugin's canvas context, and how its text starts while no canvas is open. */
export const CANVAS_CONTEXT = 'dsh-image-gen:canvas';
export const CANVAS_CLOSED = 'Image-gen workbench canvas: not connected.';

/**
 * The plugin's errors send the user to "Settings > Plugins > Image generation", its page in
 * the web version. In the app the page is Settings → 生图, so a line saying so follows the
 * plugin's own image context, whenever the plugin is there to add it.
 */
export const IMAGE_CONTEXT = 'dsh-image-gen:image-defaults';
export const WEB_SETTINGS_PATH = 'Settings > Plugins > Image generation';
export const SETTINGS_CONTEXT = 'fish-pocket:image-settings';
export const SETTINGS_NOTE = [
  'In the Fish Pocket app, image generation is set up in the app\'s Settings → Image Generation (the top row of the Explore tab; at the bottom of the sidebar on an iPad before iOS 18): the default provider, API keys, subscription sign-in and ComfyUI workflows.',
  `Image tool errors that say "${WEB_SETTINGS_PATH}" mean that page.`,
].join(' ');

/**
 * Drop the plugin's closed-canvas note from an assembly.
 * @param {{ contexts: { name: string, text: string, interpolate?: boolean }[] }} assembly
 * @returns the same assembly, changed in place.
 */
export function dropClosedCanvas(assembly) {
  const index = assembly.contexts.findIndex((entry) => entry.name === CANVAS_CONTEXT);
  if (index !== -1 && assembly.contexts[index].text.startsWith(CANVAS_CLOSED)) assembly.contexts.splice(index, 1);
  return assembly;
}

/**
 * Add the app's settings line after the plugin's image context, when there is one.
 * @param {{ contexts: { name: string, text: string, interpolate?: boolean }[] }} assembly
 * @returns the same assembly, changed in place.
 */
export function addSettingsNote(assembly) {
  const index = assembly.contexts.findIndex((entry) => entry.name === IMAGE_CONTEXT);
  if (index !== -1 && !assembly.contexts.some((entry) => entry.name === SETTINGS_CONTEXT)) {
    assembly.contexts.splice(index + 1, 0, { name: SETTINGS_CONTEXT, text: SETTINGS_NOTE, interpolate: false });
  }
  return assembly;
}

/** Apply both to every assembly on a context that has `systemPrompt`. */
export function installImageGenNotes(ctx) {
  ctx.on('system-prompt/assemble', async (_assembly, _context, next) => addSettingsNote(dropClosedCanvas(await next())));
}

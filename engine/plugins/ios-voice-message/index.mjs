// Voice messages: the agent answers with a voice bubble instead of text, the way a person
// sends one in a chat app. The engine makes no audio. The tool call carries the words, the
// app draws the call as a voice bubble and reads the words aloud when the user taps it, with
// the speech service the user set up (Volcengine or DeepSeek).
//
//   POST /api/ios-voice-message/settings
//     { allowSessions, allowBots, ready, guidance, bots: [sessionId], groups: [sessionId] }
//     → { ok: true }
//
// The user decides where voice messages are allowed (ordinary sessions and Bot chats apart);
// the agent decides, within that, when one fits, by `guidance`, which the user can edit. The
// app sends all of it when it connects and again whenever any of it changes. Until it has,
// and wherever it is not allowed, the tool is not offered at all, so the model never sees it.
// What the app sent is kept in `<DSH_IOS_DATA>/voice-message.json`: the engine restarts on its
// own (a plugin change, a crash), and the app, which sent it already, does not send it again.
//
// Never offered:
// - in a group: what members say there is read from ds-bot's group book, which a member's
//   tool call never reaches, so the group would see the member say nothing;
// - to a subagent: what it says goes to its parent, not to the user;
// - on a voice call: everything is spoken already;
// - in a turn an IM chat started (WeChat, Telegram…): ds-bot relays the reply's text there,
//   and a voice message has none.
// - when the app has no speech service to read it with (`ready`).
import fs from 'node:fs';
import path from 'node:path';
import { defineTool } from '@deepseek-ai/dsh-tools';
import { onCall } from '../ios-call/index.mjs';

export const ROUTE = '/api/ios-voice-message';
export const TOOL = 'send_voice_message';
/** Longer than a voice message should ever be; the description asks for far less. */
export const MAX_CHARACTERS = 1_000;

/** Used when the app sends no guidance of its own. */
export const DEFAULT_GUIDANCE = 'Only while chatting casually (greetings, small talk, comfort, a joke), and '
  + 'only now and then, when a voice fits better than text. Never for work: tasks, code, research, '
  + 'data, steps or anything the user may want to read again. Always when the user asks for one.';

/** What the model is told, the user's rule last. */
export function describe(guidance) {
  return 'Send the user a voice message instead of a text reply. The app shows it as a voice bubble in '
    + 'this conversation and reads `text` aloud when the user taps it. Sending it ends your turn, so put '
    + 'the whole reply in it and do not write the same thing as text. Write `text` the way it will be '
    + 'heard: short, natural spoken sentences in the language the user speaks, without Markdown, lists, '
    + 'tables, code, links or emoji. Keep it under about a minute of speech (roughly 250 Chinese '
    + 'characters or 150 English words). Anything the user needs to read, copy or keep (code, links, '
    + 'addresses, long numbers) does not belong in a voice message: answer in text instead. When the '
    + 'user wants to hear you (asks for a voice message, or to say something by voice), this is how.\n\n'
    + 'When to send one, as the user set it:\n'
    + (guidance?.trim() || DEFAULT_GUIDANCE);
}

/** The app's last word; undefined until it has spoken. */
let settings;

/** Replace the settings with what the app sent, or say what is wrong with it. */
export function applySettings(body) {
  const ids = (value) => Array.isArray(value) && value.every((id) => typeof id === 'string');
  if (body === null || typeof body !== 'object'
    || typeof body.allowSessions !== 'boolean' || typeof body.allowBots !== 'boolean'
    || typeof body.ready !== 'boolean' || (body.guidance !== undefined && typeof body.guidance !== 'string')
    || !ids(body.bots ?? []) || !ids(body.groups ?? [])) {
    return 'expected { allowSessions, allowBots, ready, guidance?, bots?, groups? }';
  }
  settings = {
    allowSessions: body.allowSessions,
    allowBots: body.allowBots,
    ready: body.ready,
    guidance: body.guidance ?? '',
    bots: new Set(body.bots ?? []),
    groups: new Set(body.groups ?? []),
  };
  return undefined;
}

export function resetSettings() { settings = undefined; }

/** Where the app's last settings are kept, or undefined off the phone (no data directory). */
export function settingsFile(data = process.env.DSH_IOS_DATA) {
  return data ? path.join(data, 'voice-message.json') : undefined;
}

/** The settings the app sent before a restart, or nothing when there are none or they are unreadable. */
export function restoreSettings(file = settingsFile()) {
  if (settings !== undefined || file === undefined) return;
  let body;
  try { body = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return; }
  applySettings(body);
}

function keepSettings(body, file = settingsFile()) {
  if (file === undefined) return;
  try {
    fs.writeFileSync(`${file}.tmp`, JSON.stringify(body));
    fs.renameSync(`${file}.tmp`, file);
  } catch { /* kept in memory; the app sends it again when it next changes */ }
}

/** Per session: how far its log was read, and whether its latest user message came from an IM chat. */
const lastAsker = new WeakMap();

/**
 * Whether the user message the session is answering came in from an IM chat. ds-bot sends
 * those with a request id of `im:<platform>:…`, which DSH keeps on the message's source.
 * Read incrementally: only the events since the last look.
 */
export function fromIm(session) {
  let entry = lastAsker.get(session);
  if (entry === undefined) {
    entry = { offset: 0, im: false };
    lastAsker.set(session, entry);
  }
  if (typeof session.snapshotEvents !== 'function' || entry.offset === session.seq) return entry.im;
  for (const event of session.snapshotEvents(entry.offset)) {
    const messages = event.type === 'user/message' ? [event.data]
      : event.type === 'agent/inbox/spliced' ? event.data?.inserted ?? [] : [];
    for (const message of messages) {
      if (message?.source?.kind !== 'user') continue;
      const rpcId = message.source.rpcId;
      entry.im = typeof rpcId === 'string' && rpcId.startsWith('im:');
    }
  }
  entry.offset = session.seq;
  return entry.im;
}

/** Whether the agent of this step may send a voice message. */
export function allowed(agent) {
  const session = agent?.session;
  if (settings === undefined || !settings.ready || session === undefined) return false;
  if (session.header?.origin === 'subagent') return false;
  const id = session.id;
  if (settings.groups.has(id) || onCall(id)) return false;
  if (!(settings.bots.has(id) ? settings.allowBots : settings.allowSessions)) return false;
  return !fromIm(session);
}

export function voiceTool(guidance) {
  return defineTool({
    name: TOOL,
    description: describe(guidance),
    parameters: {
      text: { type: 'string', description: 'what the voice message says, written to be heard', required: true },
    },
    output: {
      schema: { type: 'json' },
      render: (_args, value) => [{ type: 'text', text: `Voice message sent (${value.characters} characters). Your turn is over.` }],
    },
    execute: async (args, exec) => {
      const text = args.text.trim();
      if (!text) throw new Error(`${TOOL}: \`text\` is empty`);
      const characters = [...text].length;
      if (characters > MAX_CHARACTERS) {
        throw new Error(`${TOOL}: ${characters} characters is far too long for a voice message; `
          + 'say it in a few spoken sentences, or answer in text.');
      }
      exec?.concludeTurn?.();
      return { sent: true, characters };
    },
  });
}

const json = (value, status = 200) =>
  new Response(JSON.stringify(value), { status, headers: { 'content-type': 'application/json' } });

export default class IosVoiceMessage {
  static inject = ['connection', 'tools'];

  constructor(ctx) {
    // The description carries the user's rule, so a new rule registers the tool again.
    let registered;
    let disposeTool;
    const install = (guidance) => {
      if (registered === guidance) return;
      disposeTool?.();
      registered = guidance;
      disposeTool = ctx.tools.register(voiceTool(guidance), { when: ({ agent }) => allowed(agent) });
    };
    restoreSettings();
    install(settings?.guidance ?? '');

    ctx.effect(() => ctx.connection.fetch.register({
      path: `${ROUTE}/settings`,
      methods: ['POST'],
      requestBody: 'buffered',
      fetch: async (request) => {
        let body;
        try { body = await request.json(); } catch { body = undefined; }
        const problem = applySettings(body);
        if (problem !== undefined) return json({ error: { kind: 'invalid', message: problem } }, 400);
        keepSettings(body);
        install(settings.guidance);
        return json({ ok: true });
      },
    }), 'ios-voice-message: settings');

    ctx.effect(() => () => {
      disposeTool?.();
      disposeTool = undefined;
      registered = undefined;
      resetSettings();
    }, 'ios-voice-message: tool');
  }
}

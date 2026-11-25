// Voice calls from the app's call screen. The app does the listening and the speaking
// (Volcengine streaming recognition and synthesis, on the user's own key); the engine only
// needs to know that a session is on a call, so the model answers the way a call needs.
//
//   POST /api/ios-call/state  { sessionId, active }  → { ok: true }
//
// While a session is on a call, each turn's first step gets one note for the model, recorded
// like the time context: a user message of its own source kind, which the app's timeline never
// shows. The app renews the call every `RENEW_MS` and ends it on hang-up; a call the app stopped
// renewing (a crash, a lost connection) lapses after `LEASE_MS`, so no later turn is told it is
// on a call that is over.
import { createUserMessage } from '@deepseek-ai/dsh-llm';

export const ROUTE = '/api/ios-call';
/** The source kind of the note: the app's timeline shows only `user` messages. */
export const SOURCE = 'voice-call';
/** How long a call stays on without word from the app; the app renews it every 30 s. */
export const LEASE_MS = 90_000;

export const NOTE = 'The user is talking with you on a live voice call. Their words reach you through speech '
  + 'recognition, which can mishear a word or split one sentence into two messages: read them '
  + 'charitably, and ask when you cannot tell what they meant. Everything you write is read aloud '
  + 'as you write it, so answer in short, natural spoken sentences in the language the user speaks, '
  + 'without Markdown, lists, tables, code blocks, links or emoji. When something is better seen than '
  + 'heard (code, a long list, a '
  + 'table), say so in a sentence and keep it out of the answer. Say briefly what you are about to '
  + 'do before a long piece of work, so the user is not left in silence. The user can cut in at any '
  + 'time, which stops your answer where they started talking.';

/** Session id → the time its call lapses. */
const calls = new Map();

/** Whether `sessionId` is on a call at `now`. A lapsed call is forgotten. */
export function onCall(sessionId, now = Date.now()) {
  const until = calls.get(sessionId);
  if (until === undefined) return false;
  if (until > now) return true;
  calls.delete(sessionId);
  return false;
}

/** Start or renew (`active`) or end a session's call. */
export function setCall(sessionId, active, now = Date.now()) {
  if (active) calls.set(sessionId, now + LEASE_MS);
  else calls.delete(sessionId);
}

/** The note as a message of its own source kind. */
export function noteMessage() {
  return createUserMessage({
    content: [{ type: 'text', text: NOTE }],
    source: { kind: SOURCE, form: 'snapshot', sections: [{ name: SOURCE, text: NOTE }] },
  });
}

const json = (value, status = 200) =>
  new Response(JSON.stringify(value), { status, headers: { 'content-type': 'application/json' } });

export default class IosCall {
  static inject = ['connection', 'agents'];

  constructor(ctx) {
    ctx.effect(() => ctx.connection.fetch.register({
      path: `${ROUTE}/state`,
      methods: ['POST'],
      requestBody: 'buffered',
      fetch: async (request) => {
        let body;
        try { body = await request.json(); } catch { body = undefined; }
        const sessionId = typeof body?.sessionId === 'string' ? body.sessionId.trim() : '';
        if (!sessionId || typeof body?.active !== 'boolean') {
          return json({ error: { kind: 'invalid', message: 'expected { sessionId, active }' } }, 400);
        }
        setCall(sessionId, body.active);
        return json({ ok: true });
      },
    }), 'ios-call: state');

    // Only a turn's first step, and only one that brings new messages: the note is in the
    // history from then on, and a retry (no messages) already has it.
    ctx.on('agent/pre-step', async ({ agent, step, signal }, next) => {
      const decision = await next();
      if (decision.kind === 'reject' || signal?.aborted || step !== 1 || decision.messages.length === 0) return decision;
      if (!onCall(agent.session.id)) return decision;
      return { ...decision, messages: [...decision.messages, noteMessage()] };
    });

    ctx.effect(() => () => calls.clear(), 'ios-call: calls');
  }
}

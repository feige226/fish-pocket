// reminders.list beyond one page (#245): the addon returns at most 200, so the
// tool has to pass through what lets the caller choose which 200 and read on.
//
// A stand-in for the addon is installed before the tools are imported, so what
// the tool hands the addon can be read back. This file runs in its own process
// under `node --test`, so the stand-in never leaks into ios-native.test.mjs,
// which pins the no-addon case.
import test from 'node:test';
import assert from 'node:assert/strict';

const calls = [];
process._linkedBinding = (name) => {
  if (name !== 'dsh_ios_native') throw new Error(`no binding ${name}`);
  return {
    capabilities: () => JSON.stringify({ reminders: ['list'] }),
    invoke: async (capability, op, args) => {
      calls.push({ capability, op, args: JSON.parse(args) });
      return JSON.stringify({ reminders: [], total: 0, offset: 0, truncated: false });
    },
  };
};
const { TOOLS, toEpochSeconds } = await import('../plugins/ios-native/tools.mjs');

const list = async (args) => {
  calls.length = 0;
  await TOOLS.reminders.execute({ action: 'list', ...args }, {});
  assert.equal(calls.length, 1);
  return calls[0].args;
};

test('list passes order, due range and paging through to the addon', async () => {
  assert.deepEqual(await list({}), {});
  assert.deepEqual(
    await list({ includeCompleted: true, order: 'desc', from: '2026-01-01', to: '2027-01-01', limit: 50, offset: 200 }),
    {
      includeCompleted: true,
      order: 'desc',
      from: toEpochSeconds('2026-01-01'),
      to: toEpochSeconds('2027-01-01'),
      limit: 50,
      offset: 200,
    },
  );
  // When something was finished is its own date to order and filter by.
  assert.deepEqual(
    await list({ sort: 'completed', order: 'desc', completedFrom: '2026-11-01', completedTo: '2026-11-08T12:00:00Z' }),
    {
      sort: 'completed',
      order: 'desc',
      completedFrom: toEpochSeconds('2026-11-01'),
      completedTo: Date.parse('2026-11-08T12:00:00Z') / 1000,
    },
  );
  // Asking for more than a page gets a page, not an error: the rest is a nextOffset away.
  assert.equal((await list({ limit: 1000 })).limit, 200);
});

test('list refuses paging and ranges the addon could only misread', async () => {
  const refused = (args, pattern) => assert.rejects(TOOLS.reminders.execute({ action: 'list', ...args }, {}), pattern);
  await refused({ offset: -1 }, /`offset` must be a whole number/);
  await refused({ offset: 1.5 }, /`offset` must be a whole number/);
  await refused({ limit: 0 }, /`limit` must be a whole number/);
  await refused({ from: '2026-02-01', to: '2026-01-01' }, /'to' must be after 'from'/);
  await refused({ from: 'soon' }, /could not read the date/);
  await refused({ completedFrom: '2026-11-08', completedTo: '2026-11-01' }, /'completedTo' must be after 'completedFrom'/);
});

test('a truncated list says where the next page starts', () => {
  const render = (value) => TOOLS.reminders.output.render({ action: 'list' }, value)[0].text;
  const page = (offset, count) => Array.from({ length: count }, (_, index) => ({
    id: `R-${offset + index}`, title: `第 ${offset + index} 条`, completed: false, list: '家',
  }));

  const first = render({ reminders: page(0, 200), total: 433, offset: 0, truncated: true, nextOffset: 200 });
  assert.match(first, /showing 1–200 of 433; pass offset 200 for the next page/);
  const second = render({ reminders: page(200, 200), total: 433, offset: 200, truncated: true, nextOffset: 400 });
  assert.match(second, /showing 201–400 of 433; pass offset 400/);
  const last = render({ reminders: page(400, 33), total: 433, offset: 400, truncated: false });
  assert.doesNotMatch(last, /showing/);
  // Reading past the end must not read as "they have no reminders".
  assert.match(render({ reminders: [], total: 433, offset: 500, truncated: false }), /Nothing from offset 500: there are 433 in all/);
  assert.match(render({ reminders: [], total: 0, offset: 0, truncated: false }), /Nothing on their reminders/);
  // Nor must an empty range: they have reminders, just none in it.
  const ranged = TOOLS.reminders.output.render(
    { action: 'list', from: '2026-08-05', to: '2027-01-01' },
    { reminders: [], total: 0, offset: 0, truncated: false },
  )[0].text;
  assert.equal(ranged, 'No reminders match that.');
});

test('a finished reminder says when it was finished', () => {
  const text = TOOLS.reminders.output.render({ action: 'list' }, {
    reminders: [
      { id: 'R-1', title: '交房租', completed: true, completedAt: '2026-11-02T20:15:00+08:00', due: '2026-11-01T09:00:00+08:00' },
      { id: 'R-2', title: '旧事', completed: true },
    ],
  })[0].text;
  assert.match(text, /\[done 2026-11-02 20:15\] 2026-11-01 09:00 {2}交房租/);
  // Reminders finished before iOS kept a completion date still read as done.
  assert.match(text, /\[done\] no due date {2}旧事/);
});

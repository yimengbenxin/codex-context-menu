import test from 'node:test';
import assert from 'node:assert/strict';
import {CompactionObserver} from '../Resources/adaptive/compaction-observer.mjs';

function fixture() {
  const context = {root: '/project', bounds: {model: 'fixture', tiers: [272000]},
    budget: 272000, effective_percent: 95, expected: 258400, scope: 'body_after_prefix'};
  const session = {model: 'fixture', provider: 'openai', context, manual: false};
  const controller = {sessions: new Map([['first', session], ['second', {...session}]])};
  const rows = [];
  const observer = new CompactionObserver(controller, async row => rows.push(row), () => 1000);
  const event = (method, values = {}, threadId = 'first') => observer.observe({method, params: {threadId, turnId: 'turn', ...values}});
  const usage = (total, window = 258400, thread = 'first') => event('thread/tokenUsage/updated',
    {tokenUsage: {modelContextWindow: window, last: {inputTokens: total - 5, totalTokens: total}}}, thread);
  const item = {id: 'sample', type: 'contextCompaction'};
  return {observer, event, usage, item, rows, session};
}

test('captures pre/post values once and separates simultaneous threads', async () => {
  const {observer, event, usage, item, rows} = fixture();
  usage(263405);
  usage(170005, 258400, 'second');
  event('item/started', {item});
  event('item/started', {item});
  usage(90005);
  event('item/completed', {item});
  event('item/completed', {item});
  await observer.writes;
  assert.equal(rows.length, 1);
  assert.equal(rows[0].before_total, 263405);
  assert.equal(rows[0].before_input, 263400);
  assert.equal(rows[0].after_total, 90005);
  assert.equal(rows[0].target, 258400);
  assert.equal(rows[0].status, 'completed');
  assert.equal(rows[0].project.length, 64);
  assert.equal(JSON.stringify(rows).includes('/project'), false);
});

test('missing or stale runtime values remain unknown', async () => {
  const {observer, event, usage, item, rows} = fixture();
  usage(270000, 460750);
  event('item/started', {item});
  event('item/completed', {item});
  await observer.writes;
  assert.equal(rows[0].before_total, null);
  assert.equal(rows[0].target, null);
  assert.equal(rows[0].after_total, null);
});

test('manual, failed and shutdown attempts retain their classification', async () => {
  const {observer, event, usage, item, rows, session} = fixture();
  session.manual = true;
  usage(250000);
  event('item/started', {item});
  event('turn/completed', {turn: {status: 'failed'}});
  event('item/started', {item: {...item, id: 'unfinished'}});
  await observer.close();
  assert.equal(rows[0].manual, true);
  assert.equal(rows[0].status, 'failed');
  assert.equal(rows[1].status, 'incomplete');
});

test('persistence failure does not alter the conversation or lose the next observation', async () => {
  const {observer, event, item, rows, session} = fixture();
  const snapshot = JSON.stringify(session);
  observer.write = async () => { throw new Error('fixture storage failure'); };
  event('item/started', {item});
  event('item/completed', {item});
  await observer.writes;
  observer.write = async row => rows.push(row);
  event('item/started', {item: {...item, id: 'next'}});
  event('item/completed', {item: {...item, id: 'next'}});
  await observer.writes;
  assert.equal(rows.length, 1);
  assert.equal(JSON.stringify(session), snapshot);
});

test('malformed notifications never throw into the native transport', async () => {
  const {observer, event, item, rows, session} = fixture();
  event('item/started', {item: {type: 'contextCompaction'}});
  assert.equal(observer.pending.size, 0);
  session.context.root = undefined;
  assert.doesNotThrow(() => event('item/started', {item}));
  session.context.root = '/project';
  event('item/started', {item});
  event('item/completed', {item});
  await observer.writes;
  assert.equal(rows.length, 1);
});

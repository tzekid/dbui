import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import { spawn, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { createServer, createConnection } from 'node:net';
import { chromium } from 'playwright-core';
import { enroll } from './passkey-helper.mjs';

const binary = resolve(process.argv[2] || 'zig-out/bin/dbui');
const scratchKey = 'dbui:scratch:fixture';
const temp = await mkdtemp(join(tmpdir(), 'dbui-browser-'));
let server, browser;
let serverLog = '';
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(check, label) {
  const deadline = Date.now() + 10000;
  let last;
  do {
    try { last = await check(); if (last) return; } catch (error) { last = error.message; }
    await sleep(25);
  } while (Date.now() < deadline);
  throw new Error(`Timed out: ${label} (${last})`);
}
const deferred = () => {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  const signal = { promise, done: false, resolve: () => { signal.done = true; resolve(); } };
  return signal;
};
try {
  const reservation = createServer();
  reservation.listen(0, '127.0.0.1');
  await once(reservation, 'listening');
  const port = reservation.address().port;
  await new Promise(done => reservation.close(done));
  const origin = `http://localhost:${port}`;
  const queries = join(temp, 'queries');
  const database = join(temp, 'fixture.db');
  await mkdir(queries);
  execFileSync('sqlite3', [database], { input: 'CREATE TABLE items (value TEXT); INSERT INTO items VALUES (\'fixture\');' });
  const scratch = join(queries, '.dbui-scratch.sql');
  await writeFile(scratch, "SELECT 'initial';");
  await writeFile(join(queries, 'named.sql'), "SELECT 'named';\r\n");
  // Read-only mode needs its own file because duplicate configured paths are rejected.
  const roDatabase = join(temp, 'readonly.db');
  await writeFile(roDatabase, await readFile(database));
  const config = join(temp, 'config.json');
  await writeFile(config, JSON.stringify({ listen: `127.0.0.1:${port}`, auth: { origin, state_path: join(temp, 'auth.db') }, databases: [
    { id: 'fixture', label: 'Fixture', path: database, mode: 'read-write', queries_path: queries },
    { id: 'readonly', label: 'Read only', path: roDatabase, mode: 'read-only' },
  ] }));
  server = spawn(binary, ['--config', config], { stdio: ['ignore', 'pipe', 'pipe'] });
  server.stdout.on('data', data => { serverLog += data; });
  server.stderr.on('data', data => { serverLog += data; });
  server.on('error', error => { serverLog += error.message; });
  await until(async () => {
    if (server.exitCode !== null) throw new Error(`Server exited: ${serverLog}`);
    return (await fetch(`${origin}/healthz`)).ok;
  }, 'fixture listener');
  const executablePath = process.env.CHROMIUM || ['/usr/bin/chromium', '/usr/bin/chromium-browser', '/usr/bin/google-chrome'].find(existsSync);
  assert.ok(executablePath, 'Set CHROMIUM to a system Chromium executable');
  browser = await chromium.launch({ executablePath, headless: true, args: ['--no-sandbox'] });
  const enrolled = await enroll(binary, config, origin, browser);
  const sessionCookies = enrolled.cookies;
  await enrolled.context.close();
  const saveURL = `${origin}/db/fixture/query/scratch/save`;
  const scratchURL = `${origin}/db/fixture/query?scratch=1`;
  async function pageFor(options = {}, init) {
    const context = await browser.newContext(options);
    await context.addCookies(sessionCookies);
    if (init) await context.addInitScript(init);
    const page = await context.newPage();
    page.setDefaultTimeout(10000);
    page.on('dialog', dialog => dialog.accept());
    await page.goto(scratchURL);
    return { page, context };
  }
  const editor = page => page.locator('[data-sql]');
  const state = page => page.locator('[data-save-state]');
  const recovery = page => page.evaluate(key => JSON.parse(localStorage.getItem(key)), scratchKey);
  const saved = page => until(async () => await state(page).textContent() === 'Saved on server', 'server acknowledgement');

  // A late acknowledgement must retain a newer edit and advance its base revision.
  {
    const { page, context } = await pageFor();
    const committed = deferred(), release = deferred();
    let count = 0;
    let pendingRoutes = 0;
    await context.route(saveURL, async route => {
      pendingRoutes += 1;
      try {
        // Keep the failed-save fixture explicit; the next group separately
        // exercises a committed save whose network response is lost.
        if (++count !== 1) return await route.fulfill({ status: 503, contentType: 'text/plain', body: 'unavailable' });
        const response = await route.fetch();
        committed.resolve();
        await release.promise;
        await route.fulfill({ response });
      } finally {
        pendingRoutes -= 1;
      }
    });
    await editor(page).fill("SELECT 'acknowledged';");
    await until(() => committed.done, 'request committed before delayed acknowledgement');
    await editor(page).fill("SELECT 'newer π';");
    const oldRevision = (await recovery(page)).revision;
    release.resolve();
    await until(async () => (await recovery(page))?.revision !== oldRevision, 'late acknowledgement updates recovery revision');
    assert.equal((await recovery(page)).source, "SELECT 'newer π';");
    assert.equal(await readFile(scratch, 'utf8'), "SELECT 'acknowledged';");
    await until(async () => await state(page).textContent() === 'Autosave failed', 'failed newer save');
    await page.reload();
    assert.equal(await editor(page).inputValue(), "SELECT 'newer π';");
    await until(async () => await state(page).textContent() === 'Autosave failed', 'recovered draft still blocked by network fixture');
    await until(() => pendingRoutes === 0, 'blocked autosave routes settled');
    assert.equal(await readFile(scratch, 'utf8'), "SELECT 'acknowledged';");
    await context.unroute(saveURL);
    await page.locator('[data-save-button]').click();
    await saved(page);
    assert.equal(await recovery(page), null);
    assert.equal(await readFile(scratch, 'utf8'), "SELECT 'newer π';");
    await context.unrouteAll({ behavior: 'wait' });
    await context.close();
  }
  console.log('browser: late save acknowledgement and failed-save reload passed');

  // The server commits, but the client loses the response; reload reconciles equal bytes.
  {
    const { page, context } = await pageFor();
    await context.route(saveURL, async route => { await route.fetch(); await route.abort(); });
    await editor(page).fill("SELECT 'response lost';");
    await until(async () => await state(page).textContent() === 'Autosave failed', 'lost response');
    assert.equal(await readFile(scratch, 'utf8'), "SELECT 'response lost';");
    assert.equal((await recovery(page)).source, "SELECT 'response lost';");
    // The committed/lost response has been observed. Finish its interceptor
    // before navigation can cancel a later keepalive request from this page.
    await context.unrouteAll({ behavior: 'wait' });
    await page.reload();
    assert.equal(await editor(page).inputValue(), "SELECT 'response lost';");
    assert.equal(await recovery(page), null);
    await context.unrouteAll({ behavior: 'wait' });
    await context.close();
  }
  console.log('browser: lost response reconciliation passed');

  // An acknowledgement in one tab cannot clear another tab's newer recovery record.
  {
    const { page, context } = await pageFor();
    const other = await context.newPage();
    await other.goto(scratchURL);
    const committed = deferred(), release = deferred();
    let count = 0;
    await context.route(saveURL, async route => {
      if (++count !== 1) return route.abort();
      const response = await route.fetch();
      committed.resolve();
      await release.promise;
      await route.fulfill({ response });
    });
    await editor(page).fill("SELECT 'first tab saved';");
    await until(() => committed.done, 'first tab save');
    await editor(other).fill("SELECT 'second tab draft';");
    release.resolve();
    await saved(page);
    assert.equal((await recovery(other))?.source, "SELECT 'second tab draft';", 'first tab must not clear another tab recovery');
    await other.reload();
    assert.equal(await editor(other).inputValue(), "SELECT 'second tab draft';");
    assert.equal(await other.locator('[data-run-button]').isDisabled(), true);
    await context.unrouteAll({ behavior: 'wait' });
    await context.close();
  }
  console.log('browser: recovery ownership across tabs passed');


  {
    const { page, context } = await pageFor();
    await writeFile(scratch, "SELECT 'external edit';");
    await editor(page).fill("SELECT 'browser draft';");
    await until(async () => await state(page).textContent() === 'Conflict', 'concurrent server edit');
    await page.reload();
    assert.equal(await editor(page).inputValue(), "SELECT 'browser draft';");
    assert.equal(await page.locator('[data-run-button]').isDisabled(), true);
    assert.equal(await readFile(scratch, 'utf8'), "SELECT 'external edit';");
    await page.getByRole('link', { name: 'Use server Scratch' }).click();
    assert.equal(await editor(page).inputValue(), "SELECT 'external edit';");
    assert.equal(await recovery(page), null);
    await context.unrouteAll({ behavior: 'wait' });
    await context.close();
  }
  console.log('browser: explicit recovery conflict choice passed');

  // Disabled browser storage still exposes failure and permits an explicit server save.
  {
    const { page, context } = await pageFor({}, () => {
      for (const method of ['getItem', 'setItem', 'removeItem']) {
        Storage.prototype[method] = () => { throw new DOMException('Storage disabled', 'SecurityError'); };
      }
    });
    await context.route(saveURL, route => route.abort());
    await editor(page).fill("SELECT 'storage unavailable';");
    await until(async () => await state(page).textContent() === 'Autosave failed', 'visible failure without storage');
    assert.equal(await editor(page).inputValue(), "SELECT 'storage unavailable';");
    await context.unroute(saveURL);
    await page.locator('[data-save-button]').click();
    await saved(page);
    assert.equal(await readFile(scratch, 'utf8'), "SELECT 'storage unavailable';");
    await context.unrouteAll({ behavior: 'wait' });
    await context.close();
  }
  console.log('browser: disabled storage and explicit save passed');

  // Running a query also persists Scratch: its acknowledgement has the same race.
  {
    const { page, context } = await pageFor();
    await editor(page).fill("-- π 😀\nSELECT 'query response';");
    await saved(page);
    const committed = deferred(), release = deferred();
    let queryRequests = 0;
    await page.route(`${origin}/db/fixture/query`, async route => {
      queryRequests += 1;
      const response = await route.fetch();
      committed.resolve();
      await release.promise;
      await route.fulfill({ response });
    });
    await context.route(saveURL, route => route.abort());
    await page.evaluate(() => {
      const form = document.querySelector('[data-query-form]');
      form.requestSubmit();
      form.requestSubmit();
    });
    await until(() => committed.done, 'request committed before delayed acknowledgement');
    await editor(page).fill("SELECT 'edited during query';");
    release.resolve();
    await until(async () => (await page.locator('[data-query-response]').textContent()).includes('query response'), 'query result');
    assert.equal((await recovery(page))?.source, "SELECT 'edited during query';", 'query acknowledgement must not clear a newer recovery generation');
    assert.notEqual(await state(page).textContent(), 'Saved on server');
    assert.equal(queryRequests, 1, 'rapid submissions must produce one in-flight query');
    await page.reload();
    assert.equal(await editor(page).inputValue(), "SELECT 'edited during query';");
    await context.unrouteAll({ behavior: 'wait' });
    await context.close();
  }
  console.log('browser: editing while a query is in flight passed');

  // Named-file acknowledgements and conflict pages cannot discard edits made in flight.
  {
    const { page, context } = await pageFor();
    await page.goto(`${origin}/db/fixture/query?file=named.sql`);
    const fileURL = `${origin}/db/fixture/query/file/save`;
    let committed = deferred(), release = deferred();
    await page.route(fileURL, async route => {
      const response = await route.fetch();
      committed.resolve();
      await release.promise;
      await route.fulfill({ response });
    });
    await editor(page).fill("SELECT 'named acknowledged';\n");
    await page.locator('[data-save-button]').click();
    await until(() => committed.done, 'named save committed');
    await editor(page).fill("SELECT 'named newer';\n");
    release.resolve();
    await until(async () => await state(page).textContent() === 'Unsaved changes', 'named acknowledgement preserves dirty state');
    assert.equal(await readFile(join(queries, 'named.sql'), 'utf8'), "SELECT 'named acknowledged';\r\n");
    await page.unroute(fileURL);
    await page.locator('[data-save-button]').click();
    await until(async () => await state(page).textContent() === 'Saved', 'newer named save');
    assert.equal(await readFile(join(queries, 'named.sql'), 'utf8'), "SELECT 'named newer';\r\n");

    await writeFile(join(queries, 'named.sql'), "SELECT 'external named';\r\n");
    committed = deferred(); release = deferred();
    await page.route(fileURL, async route => {
      const response = await route.fetch();
      assert.equal(response.status(), 409);
      committed.resolve();
      await release.promise;
      await route.fulfill({ response });
    });
    await editor(page).fill("SELECT 'conflicting edit';\n");
    await page.locator('[data-save-button]').click();
    await until(() => committed.done, 'named conflict response');
    await editor(page).fill("SELECT 'typed during conflict';\n");
    release.resolve();
    await until(async () => await state(page).textContent() === 'Conflict', 'conflict response received');
    assert.equal(await editor(page).inputValue(), "SELECT 'typed during conflict';\n");
    assert.equal(await readFile(join(queries, 'named.sql'), 'utf8'), "SELECT 'external named';\r\n");
    assert.match(await page.locator('[data-query-response]').textContent(), /Copy this buffer before reloading/);
    const copied = await editor(page).inputValue();
    await page.unroute(fileURL);
    await page.reload();
    await editor(page).fill(copied);
    await page.locator('[data-save-button]').click();
    await until(async () => await state(page).textContent() === 'Saved', 'explicitly reapplied conflict buffer');
    assert.equal(await readFile(join(queries, 'named.sql'), 'utf8'), "SELECT 'typed during conflict';\r\n");
    await context.unrouteAll({ behavior: 'wait' });
    await context.close();
  }
  console.log('browser: named-file late acknowledgements and conflict buffers passed');


  {
    const { page, context } = await pageFor({ javaScriptEnabled: false });
    await editor(page).fill("SELECT 'native ✓';");
    await page.locator('[data-save-button]').click();
    assert.equal(await readFile(scratch, 'utf8'), "SELECT 'native ✓';");
    await page.locator('[data-run-button]').click();
    assert.match(await page.locator('[data-query-response]').textContent(), /native ✓/);
    await page.goto(`${origin}/db/fixture/query?file=named.sql`);
    await editor(page).fill("SELECT 'native CRLF';\n");
    await page.locator('[data-save-button]').click();
    assert.equal(await readFile(join(queries, 'named.sql'), 'utf8'), "SELECT 'native CRLF';\r\n");
    await page.goto(`${origin}/db/readonly/query`);
    await editor(page).fill("INSERT INTO items VALUES ('forbidden');");
    await page.locator('[data-run-button]').click();
    assert.equal(execFileSync('sqlite3', [roDatabase, 'SELECT count(*) FROM items;'], { encoding: 'utf8' }).trim(), '1');
    assert.match(await page.getByRole('alert').textContent(), /read.only|not authorized/i);
    await context.unrouteAll({ behavior: 'wait' });
    await context.close();
  }
  console.log('browser: native SQL, CRLF saves, and read-only protection passed');

  // Exercise the real single-worker application's partial-request boundary.
  // More bytes must not extend the frozen App's 15-second request deadline.
  const sessionCookie = sessionCookies.find(item => item.name === 'dbui_session');
  const partialHead = `POST /db/fixture/query HTTP/1.1\r\nHost: localhost:${port}\r\nOrigin: ${origin}\r\nCookie: ${sessionCookie.name}=${sessionCookie.value}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 100\r\n`;
  for (const kind of ['head', 'body', 'trickle']) {
    const socket = createConnection({ host: '127.0.0.1', port });
    socket.on('error', () => {}); // Closing incomplete input may reset the peer.
    const closed = new Promise(done => socket.once('close', done));
    let timeout, trickle;
    try {
      await once(socket, 'connect');
      socket.write(kind === 'body' ? `${partialHead}\r\nsql=` : partialHead);
      if (kind === 'trickle') {
        socket.write('X-Progress: ');
        trickle = setInterval(() => socket.write('x'), 200);
      }
      await Promise.race([closed, new Promise((_, reject) => {
        timeout = setTimeout(() => reject(new Error(`${kind}: partial request exceeded its deadline`)), 18000);
      })]);
      const health = await fetch(`${origin}/healthz`, { signal: AbortSignal.timeout(2000) });
      assert.equal(health.status, 200);
      assert.equal(await health.text(), 'ok\n');
    } finally {
      clearTimeout(timeout);
      clearInterval(trickle);
      socket.destroy();
    }
  }
  const stopped = once(server, 'exit');
  let stopTimeout;
  try {
    server.kill('SIGTERM');
    const [code, signal] = await Promise.race([stopped, new Promise((_, reject) => {
      stopTimeout = setTimeout(() => reject(new Error('graceful shutdown exceeded the service window')), 12000);
    })]);
    assert.equal(code, 0);
    assert.equal(signal, null);
  } finally {
    clearTimeout(stopTimeout);
  }
  console.log('http: partial heads/bodies and trickled input expire; health recovers; shutdown is clean');
} catch (error) {
  console.error(serverLog);
  throw error;
} finally {
  if (browser) await browser.close();
  if (server && server.exitCode === null) {
    const stopped = once(server, 'exit');
    server.kill('SIGTERM');
    const force = setTimeout(() => server.kill('SIGKILL'), 3000);
    await stopped;
    clearTimeout(force);
  }
  await rm(temp, { recursive: true, force: true });
}

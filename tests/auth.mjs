import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import { spawn, execFileSync } from 'node:child_process';
import { createServer } from 'node:net';
import { once } from 'node:events';
import { createHash, createPrivateKey, sign } from 'node:crypto';
import { chromium } from 'playwright-core';
import { authenticator, enroll } from './passkey-helper.mjs';

const binary = resolve(process.argv[2] || 'zig-out/bin/dbui');
const temp = await mkdtemp(join(tmpdir(), 'dbui-passkeys-'));
let server, browser;
let log = '';
const wait = ms => new Promise(done => setTimeout(done, ms));
async function until(fn) {
  for (let n = 0; n < 200; n++) { try { if (await fn()) return; } catch {} await wait(30); }
  throw new Error('Authentication journey timed out');
}
try {
  const socket = createServer().listen(0, '127.0.0.1');
  await once(socket, 'listening');
  const port = socket.address().port;
  await new Promise(done => socket.close(done));
  const origin = `http://localhost:${port}`;
  const db = join(temp, 'fixture.db');
  const state = join(temp, 'auth.db');
  const config = join(temp, 'config.json');
  const queries = join(temp, 'queries');
  await mkdir(queries);
  execFileSync('sqlite3', [db], { input: 'CREATE TABLE items(value TEXT); INSERT INTO items VALUES (\'private fixture\');' });
  await writeFile(config, JSON.stringify({ listen: `127.0.0.1:${port}`, auth: { origin, state_path: state }, databases: [{ id: 'fixture', label: 'Private fixture', path: db, mode: 'read-only', queries_path: queries }] }));
  const start = async () => {
    server = spawn(binary, ['--config', config], { stdio: ['ignore', 'pipe', 'pipe'] });
    server.stdout.on('data', data => { log += data; });
    server.stderr.on('data', data => { log += data; });
    await until(async () => server.exitCode == null && (await fetch(`${origin}/healthz`)).ok);
  };
  const stop = async () => { const ended = once(server, 'exit'); server.kill('SIGTERM'); assert.equal((await ended)[0], 0); server = null; };
  await start();
  const request = (path, options = {}) => fetch(`${origin}${path}`, { redirect: 'manual', ...options });
  for (const path of ['/', '/db/fixture', '/db/fixture/schema', '/private-unknown']) {
    const response = await request(path);
    assert.equal(response.status, 303);
    assert.ok(response.headers.get('location').startsWith('/login?next='));
    assert.ok(!(await response.text()).includes('Private fixture'));
  }
  for (const path of ['/db/fixture/query', '/auth/passkeys/options', '/unknown']) assert.equal((await request(path, { method: 'POST' })).status, 401);
  assert.equal((await request('/auth/session')).status, 401);
  assert.equal((await request('/auth/login/options', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' })).status, 403);
  assert.equal((await request('/auth/login/options', { method: 'POST', headers: { 'Content-Type': 'application/json', Origin: 'https://evil.example' }, body: '{}' })).status, 403);
  console.log('auth: anonymous database access, same-origin enforcement and safe return destinations passed');

  const executablePath = process.env.CHROMIUM || ['/usr/bin/chromium', '/usr/bin/chromium-browser', '/usr/bin/google-chrome'].find(existsSync);
  browser = await chromium.launch({ executablePath, headless: true, args: ['--no-sandbox'] });
  const first = await enroll(binary, config, origin, browser, { viewport: { width: 390, height: 844 }, colorScheme: 'dark' });
  const { page, context } = first;
  const hostile = await request('/login?next=%2F%2Fevil.example');
  assert.match(await hostile.text(), /data-next="\/"/);
  const token = first.setupURL.split('#')[1];
  const firstCookie = first.cookies.find(item => item.name === 'dbui_session');
  const cookieHeader = `${firstCookie.name}=${firstCookie.value}`;
  const setupRetry = await request('/auth/setup/options', { method: 'POST', headers: { Origin: origin, 'Content-Type': 'application/json', 'X-dbui-Setup': token }, body: '{}' });
  assert.equal(setupRetry.status, 403);
  assert.equal(execFileSync('sqlite3', [state, 'SELECT count(*) FROM passkeys; SELECT count(*) FROM bootstrap;'], { encoding: 'utf8' }).trim(), '1\n0');
  assert.ok(!execFileSync('sqlite3', [state, '.dump'], { encoding: 'utf8' }).includes(firstCookie.value));
  assert.equal((await request('/auth/session', { headers: { Cookie: cookieHeader } })).status, 200);
  const csrf = (await (await request('/auth/session', { headers: { Cookie: cookieHeader } })).json()).csrf_token;
  assert.match(csrf, /^[a-f0-9]{64}$/);
  const form = (path, values, cookie = cookieHeader) => request(path, { method: 'POST', headers: { Origin: origin, Cookie: cookie, 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(values) });
  assert.equal((await form('/auth/passkey/remove', { csrf_token: csrf, id: '1' })).status, 409);
  assert.equal((await form('/auth/logout', { csrf_token: 'wrong' })).status, 403);
  assert.equal((await request('/db/fixture/query', { method: 'POST', headers: { Cookie: cookieHeader }, body: 'csrf_token=' + csrf })).status, 403);
  assert.equal((await request('/auth/passkeys/options', { method: 'POST', headers: { Origin: origin, Cookie: cookieHeader, 'Content-Type': 'application/json' }, body: '{}' })).status, 403);
  await page.screenshot({ path: join(temp, 'security-phone-dark.png'), fullPage: true });
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
  console.log('auth: real discoverable credential enrollment, one-use setup, hashed sessions, CSRF and last-passkey protection passed');

  // Restart preserves the registered public key and browser session.
  await stop();
  await start();
  assert.equal((await request('/db/fixture', { headers: { Cookie: cookieHeader } })).status, 200);
  await page.reload();
  const oldCookie = cookieHeader;
  await page.getByRole('button', { name: 'Sign out', exact: true }).click();
  await page.waitForURL(`${origin}/login`);
  assert.equal((await request('/db/fixture', { headers: { Cookie: oldCookie } })).status, 303);
  let assertion;
  page.on('request', req => { if (new URL(req.url()).pathname === '/auth/login/verify') assertion = req.postDataJSON(); });
  await page.goto(`${origin}/login?next=%2Fdb%2Ffixture%2Fquery%3Fscratch%3D1`);
  await page.getByRole('button', { name: 'Sign in with passkey' }).click();
  await page.waitForURL(`${origin}/db/fixture/query?scratch=1`);
  assert.ok(assertion?.signature);
  const replay = await context.request.post(`${origin}/auth/login/verify`, { headers: { Origin: origin }, data: assertion });
  assert.equal(replay.status(), 403);
  // Use the real enrolled authenticator's key to sign deliberately invalid
  // ceremonies. A valid signature alone must never bypass origin/RP/UV checks.
  const signingKey = createPrivateKey({ key: Buffer.from(first.credential.privateKey, 'base64'), format: 'der', type: 'pkcs8' });
  const sha = value => createHash('sha256').update(value).digest();
  function signedAssertion(challenge, changes = {}) {
    const client = Buffer.from(JSON.stringify({ type: 'webauthn.get', challenge, origin, crossOrigin: false, ...changes.client }));
    const auth = Buffer.alloc(37);
    sha(changes.rp || 'localhost').copy(auth);
    auth[32] = changes.flags ?? 5;
    return {
      challenge_id: challenge, credential_id: assertion.credential_id,
      user_handle: Buffer.from(first.credential.userHandle, 'base64').toString('base64url'),
      client_data_json: client.toString('base64url'), authenticator_data: auth.toString('base64url'),
      signature: sign('sha256', Buffer.concat([auth, sha(client)]), signingKey).toString('base64url'),
    };
  }
  async function loginChallenge() {
    const response = await context.request.post(`${origin}/auth/login/options`, { headers: { Origin: origin }, data: {} });
    assert.equal(response.status(), 200);
    return (await response.json()).challenge_id;
  }
  for (const changes of [{ client: { origin: 'https://evil.example' } }, { client: { crossOrigin: true } }, { rp: 'evil.example' }, { flags: 1 }, { flags: 4 }, { flags: 0x15 }]) {
    const challenge = await loginChallenge();
    const rejected = await context.request.post(`${origin}/auth/login/verify`, { headers: { Origin: origin }, data: signedAssertion(challenge, changes) });
    assert.equal(rejected.status(), 403);
  }
  let challenge = await loginChallenge();
  execFileSync('sqlite3', [state, 'UPDATE challenges SET expires=0;']);
  assert.equal((await context.request.post(`${origin}/auth/login/verify`, { headers: { Origin: origin }, data: signedAssertion(challenge) })).status(), 403);
  challenge = await loginChallenge();
  const signed = signedAssertion(challenge);
  assert.equal((await request('/auth/login/verify', { method: 'POST', headers: { Origin: origin, 'Content-Type': 'application/json' }, body: JSON.stringify(signed) })).status, 403);
  assert.equal((await context.request.post(`${origin}/auth/login/verify`, { headers: { Origin: origin }, data: signed })).status(), 200);
  const primaryCookie = (await context.cookies()).find(item => item.name === 'dbui_session');
  const primaryHeader = `${primaryCookie.name}=${primaryCookie.value}`;
  console.log('auth: restart, logout, return destinations, signed origin/RP/verification failures, browser binding, expiry, replay and synced counters passed');

  // A second session signs in through WebAuthn using the same synced key.
  const other = await browser.newContext();
  const otherPage = await other.newPage();
  await authenticator(other, otherPage, first.credential);
  await otherPage.goto(`${origin}/login`);
  await otherPage.getByRole('button', { name: 'Sign in with passkey' }).click();
  await otherPage.waitForURL(`${origin}/db/fixture`);
  const otherCookie = (await other.cookies()).find(item => item.name === 'dbui_session');
  await page.goto(`${origin}/security`);
  await page.getByRole('button', { name: 'Sign out other sessions' }).click();
  await page.waitForURL(`${origin}/security?revoked=1`);
  assert.equal((await request('/auth/session', { headers: { Cookie: `${otherCookie.name}=${otherCookie.value}` } })).status, 401);
  await other.close();

  // A new authenticator creates a backup key without an unrestricted signup.
  await first.cdp.send('WebAuthn.removeVirtualAuthenticator', { authenticatorId: first.authenticatorId });
  const backup = await authenticator(context, page);
  await page.getByLabel('New passkey name').fill('Backup key');
  await page.getByRole('button', { name: 'Add a passkey', exact: true }).click();
  await page.waitForURL(`${origin}/security?added=1`);
  assert.equal(await page.locator('.passkey-row').count(), 2);
  const backupRow = page.locator('.passkey-row').filter({ has: page.getByRole('heading', { name: 'Backup key', exact: true }) });
  await backupRow.locator('summary').click();
  await backupRow.getByRole('textbox', { name: 'Passkey name' }).fill('Renamed backup');
  await backupRow.getByRole('button', { name: 'Save name' }).click();
  await page.waitForURL(`${origin}/security?saved=1`);
  assert.ok(await page.getByRole('heading', { name: 'Renamed backup' }).isVisible());
  const renamed = page.locator('.passkey-row').filter({ has: page.getByRole('heading', { name: 'Renamed backup', exact: true }) });
  await renamed.locator('summary').click();
  page.once('dialog', dialog => dialog.accept());
  await renamed.getByRole('button', { name: 'Remove passkey' }).click();
  await page.waitForURL(`${origin}/security?removed=1`);
  assert.equal(await page.locator('.passkey-row').count(), 1);
  console.log('auth: additional passkey, rename, removal and revoking other sessions passed');

  // Expiry keeps the original editor tab alive, then accepts a new session CSRF.
  await page.goto(`${origin}/db/fixture/query?scratch=1`);
  execFileSync('sqlite3', [state, "UPDATE sessions SET expires=0;"]);
  await page.locator('[data-sql]').fill("SELECT 'keep unsaved';");
  await page.locator('[data-session-expired]').waitFor();
  assert.equal(await page.locator('[data-sql]').inputValue(), "SELECT 'keep unsaved';");
  const loginPage = await context.newPage();
  const originalDevice = await authenticator(context, loginPage, first.credential);
  await loginPage.goto(`${origin}/login`);
  await loginPage.getByRole('button', { name: 'Sign in with passkey' }).click();
  await loginPage.waitForURL(`${origin}/db/fixture`);
  await page.bringToFront();
  await page.evaluate(() => window.dispatchEvent(new Event('focus')));
  await until(async () => await page.locator('[data-session-expired]').count() === 0);
  await page.locator('[data-save-button]').click();
  await until(async () => await page.locator('[data-save-state]').textContent() === 'Saved on server');
  assert.equal(await readFile(join(queries, '.dbui-scratch.sql'), 'utf8'), "SELECT 'keep unsaved';");
  await loginPage.close();
  console.log('auth: session-expiry query preservation, reauthentication and continued saves passed');

  // Sensitive changes require recent device verification; ordinary use remains.
  execFileSync('sqlite3', [state, 'UPDATE sessions SET created=created-1000;']);
  const currentCookies = await context.cookies();
  const currentCookie = currentCookies.find(item => item.name === 'dbui_session');
  const currentHeader = `${currentCookie.name}=${currentCookie.value}`;
  const currentCsrf = (await (await request('/auth/session', { headers: { Cookie: currentHeader } })).json()).csrf_token;
  const stale = await request('/auth/passkeys/options', { method: 'POST', headers: { Cookie: currentHeader, Origin: origin, 'X-dbui-CSRF': currentCsrf, 'Content-Type': 'application/json' }, body: '{}' });
  assert.equal(stale.status, 401);

  // Recovery is a host-only command, refuses overwrite, backs up before reset.
  const backupPath = join(temp, 'before-reset.db');
  assert.throws(() => execFileSync(binary, ['--config', config, 'auth', 'recover'], { stdio: 'pipe' }));
  const recoveryURL = execFileSync(binary, ['--config', config, 'auth', 'recover', '--backup', backupPath, '--confirm'], { encoding: 'utf8' }).trim();
  assert.ok(recoveryURL.startsWith(`${origin}/setup#`));
  assert.equal(execFileSync('sqlite3', [backupPath, 'PRAGMA integrity_check; SELECT count(*) FROM passkeys;'], { encoding: 'utf8' }).trim(), 'ok\n1');
  assert.equal(execFileSync('sqlite3', [state, 'SELECT count(*) FROM passkeys; SELECT count(*) FROM sessions;'], { encoding: 'utf8' }).trim(), '0\n0');
  assert.throws(() => execFileSync(binary, ['--config', config, 'auth', 'recover', '--backup', backupPath, '--confirm'], { stdio: 'pipe' }));
  assert.equal((await request('/auth/session', { headers: { Cookie: currentHeader } })).status, 401);
  await page.goto(recoveryURL);
  await page.getByRole('button', { name: 'Create a passkey', exact: true }).click();
  await page.waitForURL(`${origin}/security?added=1`);
  assert.equal(execFileSync('sqlite3', [state, 'PRAGMA integrity_check; SELECT count(*) FROM passkeys;'], { encoding: 'utf8' }).trim(), 'ok\n1');
  console.log('auth: recent verification and full backed-up lost-passkey recovery passed');
  const active = await context.request.get(`${origin}/auth/session`);
  const activeCsrf = (await active.json()).csrf_token;
  const protectedHeaders = { Origin: origin, 'X-dbui-CSRF': activeCsrf };
  const badOptions = await context.request.post(`${origin}/auth/passkeys/options`, { headers: protectedHeaders, data: {} });
  assert.equal(badOptions.status(), 200);
  const badChallenge = (await badOptions.json()).challenge_id;
  const deepCbor = Buffer.concat([Buffer.alloc(1000, 0x81), Buffer.from([0])]).toString('base64url');
  const malformed = await context.request.post(`${origin}/auth/passkeys/verify`, { headers: protectedHeaders, data: {
    challenge_id: badChallenge, credential_id: 'AA', label: 'Malformed key', attestation_object: deepCbor,
    client_data_json: Buffer.from(JSON.stringify({ type: 'webauthn.create', challenge: badChallenge, origin, crossOrigin: false })).toString('base64url'),
  } });
  assert.equal(malformed.status(), 403);
  const oversized = await context.request.post(`${origin}/auth/passkeys/options`, { headers: { ...protectedHeaders, 'Content-Type': 'application/json' }, data: ' '.repeat(256 * 1024 + 1) });
  assert.equal(oversized.status(), 413);
  assert.equal((await request('/healthz')).status, 200);
  console.log('auth: malformed CBOR depth and oversized bodies are rejected without interrupting service');
  assert.ok(!log.includes(token));
  assert.ok(!log.includes(firstCookie.value));
  for (const width of [375, 768, 1440]) {
    await page.setViewportSize({ width, height: 900 });
    await page.goto(`${origin}/security`);
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
  }
  await stop();
  console.log('auth: phone, tablet and desktop overflow checks, secret-free logs and graceful shutdown passed');
} catch (error) {
  console.error(log);
  throw error;
} finally {
  await browser?.close();
  if (server && server.exitCode == null) { const done = once(server, 'exit'); server.kill('SIGTERM'); await done; }
  await rm(temp, { recursive: true, force: true });
}

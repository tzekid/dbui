import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';

export async function authenticator(context, page, credential) {
  const cdp = await context.newCDPSession(page);
  await cdp.send('WebAuthn.enable');
  const { authenticatorId } = await cdp.send('WebAuthn.addVirtualAuthenticator', {
    options: {
      protocol: 'ctap2', ctap2Version: 'ctap2_1', transport: 'internal',
      hasResidentKey: true, hasUserVerification: true,
      isUserVerified: true, automaticPresenceSimulation: true,
    },
  });
  if (credential) await cdp.send('WebAuthn.addCredential', { authenticatorId, credential });
  return { cdp, authenticatorId };
}

export async function enroll(binary, config, origin, browser, options = {}) {
  const setupURL = execFileSync(binary, ['--config', config, 'auth', 'setup'], { encoding: 'utf8' }).trim();
  assert.ok(setupURL.startsWith(`${origin}/setup#`));
  const context = await browser.newContext(options);
  context.setDefaultTimeout(10000);
  context.setDefaultNavigationTimeout(10000);
  const page = await context.newPage();
  await page.addInitScript(() => {
    const create = navigator.credentials.create.bind(navigator.credentials);
    navigator.credentials.create = options => create(options).catch(error => {
      window.passkeyFailure = { name: error.name, message: error.message };
      throw error;
    });
  });
  const device = await authenticator(context, page);
  await page.goto(setupURL);
  await page.waitForFunction(() => !location.hash);
  await page.getByRole('button', { name: 'Create a passkey', exact: true }).click();
  try {
    await page.waitForURL(`${origin}/security?added=1`, { timeout: 10000 });
  } catch (error) {
    throw new Error(`Enrollment failed: ${await page.locator('[data-auth-error]').textContent()} ${JSON.stringify(await page.evaluate(() => window.passkeyFailure))}`, { cause: error });
  }
  assert.ok(await page.getByRole('heading', { name: 'Sign-in & security' }).isVisible());
  const { credentials } = await device.cdp.send('WebAuthn.getCredentials', { authenticatorId: device.authenticatorId });
  assert.equal(credentials.length, 1);
  return { context, page, ...device, credential: credentials[0], setupURL, cookies: await context.cookies() };
}

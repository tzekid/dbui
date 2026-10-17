import { chromium } from 'playwright-core';
import { existsSync } from 'node:fs';
import { writeFile } from 'node:fs/promises';
import { enroll } from './passkey-helper.mjs';

const [binary, config, origin, output] = process.argv.slice(2);
const executablePath = process.env.CHROMIUM || ['/usr/bin/chromium', '/usr/bin/chromium-browser', '/usr/bin/google-chrome'].find(existsSync);
const browser = await chromium.launch({ executablePath, headless: true, args: ['--no-sandbox'] });
try {
  const enrolled = await enroll(binary, config, origin, browser);
  const cookie = enrolled.cookies.find(item => item.name === 'dbui_session');
  await writeFile(output, `# Netscape HTTP Cookie File\n${new URL(origin).hostname}\tFALSE\t/\tFALSE\t0\t${cookie.name}\t${cookie.value}\n`, { mode: 0o600 });
} finally {
  await browser.close();
}

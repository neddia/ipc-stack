#!/usr/bin/env node
// Persistent browser for exploratory e2e UI checks (development only).
// One Chromium page, reached through connect-proxy.py, driven over local HTTP:
//   POST http://127.0.0.1:9333 {"action":"goto","url":"http://172.22.x.y:8000/ui"}
//   actions: goto, click, fill, select, check, press, mouse, type, frameFill, eval, text, shot, wait, cookie, html, newpage
// Uses the shared Playwright install in ~/codex-tools/browser-checks.
const http = require('http');
const path = require('path');
const { createRequire } = require('module');
const req = createRequire(path.join(process.env.HOME, 'codex-tools/browser-checks/package.json'));
const { chromium } = req('playwright');

const PORT = Number(process.env.UI_DRIVER_PORT || 9333);
const SHOTS = process.env.UI_DRIVER_SHOTS || path.join(process.env.HOME, '.cache/toops-e2e/run/shots');
require('fs').mkdirSync(SHOTS, { recursive: true });

(async () => {
  const browser = await chromium.launch({
    args: ['--proxy-server=http://127.0.0.1:13128', '--proxy-bypass-list=<-loopback>', '--ignore-certificate-errors-spki-list'],
  });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, ignoreHTTPSErrors: true });
  let page = await context.newPage();
  const consoleLog = [];
  const watch = (p) => {
    p.on('console', (m) => { if (['error', 'warning'].includes(m.type())) consoleLog.push(`${m.type()}: ${m.text()}`.slice(0, 500)); });
    p.on('pageerror', (e) => consoleLog.push(`pageerror: ${e.message}`.slice(0, 500)));
    p.on('response', (r) => { if (r.status() >= 400) consoleLog.push(`http ${r.status()} ${r.request().method()} ${r.url()}`.slice(0, 300)); });
  };
  watch(page);
  let n = 0;

  async function run(cmd) {
    const t = cmd.timeout || 15000;
    switch (cmd.action) {
      case 'goto': await page.goto(cmd.url, { waitUntil: cmd.until || 'networkidle', timeout: t }); return { url: page.url(), title: await page.title() };
      case 'newpage': page = await context.newPage(); watch(page); return { ok: true };
      case 'click': await page.locator(cmd.selector).first().click({ timeout: t }); break;
      case 'fill': await page.locator(cmd.selector).first().fill(String(cmd.value), { timeout: t }); break;
      case 'select': await page.locator(cmd.selector).first().selectOption(cmd.value, { timeout: t }); break;
      case 'check': await page.locator(cmd.selector).first().setChecked(cmd.value !== false, { timeout: t }); break;
      case 'press': await page.keyboard.press(cmd.key); break;
      case 'mouse': await page.mouse.click(cmd.x, cmd.y); break;
      case 'type': await page.keyboard.type(String(cmd.text), { delay: cmd.delay || 40 }); break;
      case 'frameFill': await page.frameLocator(cmd.frame).locator(cmd.selector).first().fill(String(cmd.value), { timeout: t }); break;
      case 'wait': await page.locator(cmd.selector).first().waitFor({ state: cmd.state || 'visible', timeout: t }); break;
      case 'eval': return { value: await page.evaluate(cmd.js) };
      case 'html': return { html: (await page.locator(cmd.selector || 'body').first().innerHTML()).slice(0, cmd.max || 20000) };
      case 'cookie': await context.addCookies([cmd.cookie]); return { ok: true };
      case 'text': {
        const text = await page.locator(cmd.selector || 'body').first().innerText({ timeout: t });
        return { text: text.slice(0, cmd.max || 12000) };
      }
      case 'shot': {
        const file = path.join(SHOTS, `${String(++n).padStart(3, '0')}-${(cmd.name || 'shot').replace(/[^a-z0-9_-]+/gi, '_')}.png`);
        if (cmd.selector) await page.locator(cmd.selector).first().screenshot({ path: file });
        else await page.screenshot({ path: file, fullPage: !!cmd.full });
        return { file };
      }
      default: throw new Error(`unknown action ${cmd.action}`);
    }
    if (cmd.settle !== false) await page.waitForTimeout(cmd.settle || 600);
    return { ok: true, url: page.url() };
  }

  http.createServer((request, response) => {
    let body = '';
    request.on('data', (c) => { body += c; });
    request.on('end', async () => {
      let result;
      try {
        const cmds = JSON.parse(body || '{}');
        result = [];
        for (const cmd of Array.isArray(cmds) ? cmds : [cmds]) result.push(await run(cmd));
        if (!Array.isArray(cmds)) result = result[0];
      } catch (error) {
        result = { error: String(error.message || error).slice(0, 2000) };
      }
      const out = { ...(Array.isArray(result) ? { results: result } : result), console: consoleLog.splice(0) };
      response.writeHead(200, { 'Content-Type': 'application/json' });
      response.end(JSON.stringify(out));
    });
  }).listen(PORT, '127.0.0.1', () => console.log(`ui-driver on 127.0.0.1:${PORT}`));
})();

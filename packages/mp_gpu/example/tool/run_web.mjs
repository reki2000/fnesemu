// Opens the probe page in headless Chrome over the DevTools protocol and
// prints the probe lines of the console until the probe is done.
// Usage: node tool/run_web.mjs URL [chrome flags...]
import { spawn } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [url, ...flags] = process.argv.slice(2);
const chrome = spawn(process.env.CHROME ?? 'google-chrome', [
  '--headless=new', '--no-sandbox', '--remote-debugging-port=9333',
  '--user-data-dir=' + mkdtempSync(join(tmpdir(), 'probe-')), ...flags, 'about:blank',
], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let targets;
for (let i = 0; i < 100 && !targets; i++) {
  try { targets = await (await fetch('http://127.0.0.1:9333/json')).json(); } catch { await sleep(200); }
}
const ws = new WebSocket(targets.find((t) => t.type === 'page').webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener('open', r));
let id = 0;
let done = false;
ws.addEventListener('message', (e) => {
  const m = JSON.parse(e.data);
  if (m.method === 'Runtime.consoleAPICalled') {
    const text = m.params.args.map((a) => a.value ?? a.description).join(' ');
    if (text.startsWith('MP_GPU_PROBE')) console.log(text);
    if (text === 'MP_GPU_PROBE_DONE') done = true;
  }
  if (m.method === 'Runtime.exceptionThrown') console.log('EXCEPTION ' + JSON.stringify(m.params.exceptionDetails).slice(0, 500));
});
const send = (method, params = {}) => ws.send(JSON.stringify({ id: ++id, method, params }));
send('Runtime.enable');
send('Page.navigate', { url });
for (let i = 0; i < 1200 && !done; i++) await sleep(500);
ws.close();
chrome.kill();
process.exit(done ? 0 : 1);

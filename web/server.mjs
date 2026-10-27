// server.mjs —— GUI Agent 控制台服务
// 职责：托管页面、发起 agent 运行、把日志/用量/历史推给浏览器、清理临时文件
// 注意：沙盒里 Node 用管道捕获子进程会 EPERM，所以 agent 输出直接写文件，这里 tail 文件

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const IPC_REQ = path.join(ROOT, 'ipc', 'req');
const IPC_RES = path.join(ROOT, 'ipc', 'res');
const HIST = path.join(__dirname, 'history');

// 日志写文件（启动器不再重定向 stdout）
const LOGFILE = path.join(__dirname, 'console.log');
function logLine(s) { try { fs.appendFileSync(LOGFILE, s + '\n'); } catch {} }
console.log = (...a) => logLine(a.join(' '));
console.error = (...a) => logLine('ERR ' + a.join(' '));
const TMP = process.env.TEMP || 'C:\\Windows\\Temp';
// 端口优先级：环境变量 PORT > 应用根目录 config.json 的 port > 6360
let PORT = 6360;
try {
  const cfgPath = path.join(ROOT, 'config.json');
  if (fs.existsSync(cfgPath)) {
    const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8').replace(/^\uFEFF/, ''));
    if (cfg.port) PORT = Number(cfg.port);
  }
} catch {}
if (process.env.PORT) PORT = Number(process.env.PORT);

fs.mkdirSync(HIST, { recursive: true });
fs.mkdirSync(IPC_REQ, { recursive: true });
fs.mkdirSync(IPC_RES, { recursive: true });

// ── 临时文件清理 ─────────────────────────────────────────────
function sweepTemp() {
  const now = Date.now();
  try {
    for (const f of fs.readdirSync(TMP)) {
      const p = path.join(TMP, f);
      let st;
      try { st = fs.statSync(p); } catch { continue; }
      const age = now - st.mtimeMs;
      if (/^(shot-|agent-state|llm-.*\.(req|res)\.json)/.test(f) && age > 10 * 60 * 1000) {
        try { fs.unlinkSync(p); } catch {}
      }
      if (/^agent-run-.*\.log$/.test(f) && age > 2 * 24 * 3600 * 1000) {
        try { fs.unlinkSync(p); } catch {}
      }
    }
  } catch {}
}
sweepTemp();
setInterval(sweepTemp, 5 * 60 * 1000);

// ── 配置（API 设置）────────────────────────────────────────
const CONFIG_FILE = path.join(ROOT, 'config.json');
const KEYS_FILE = path.join(ROOT, 'agent', 'keys.json');
const RUN_DIR = path.join(ROOT, 'agent', 'run');
const PY = (() => {
  const p = 'C:\\Users\\18790\\.dsh\\dsh-runtimes\\dsh-primary-runtime\\dependencies\\python\\python.exe';
  return fs.existsSync(p) ? p : 'python';
})();

function readJsonFile(p, dflt) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8').replace(/^\uFEFF/, '')); } catch { return dflt; }
}
function writeJsonFile(p, obj) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, JSON.stringify(obj, null, 2), 'utf8');
}
function maskKey(k) {
  if (!k) return '';
  if (k.length <= 8) return '****';
  return k.slice(0, 3) + '****' + k.slice(-4);
}

const PRESETS = {
  deepseek:    { baseUrl: 'https://api.deepseek.com/v1', model: 'deepseek-chat', needKey: true, label: 'DeepSeek' },
  openai:      { baseUrl: 'https://api.openai.com/v1', model: 'gpt-4o', needKey: true, label: 'OpenAI' },
  moonshot:    { baseUrl: 'https://api.moonshot.cn/v1', model: 'moonshot-v1-8k', needKey: true, label: 'Moonshot / Kimi' },
  dashscope:   { baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1', model: 'qwen-vl-max', needKey: true, label: '阿里通义 (DashScope)' },
  zhipu:       { baseUrl: 'https://open.bigmodel.cn/api/paas/v4', model: 'glm-4v-plus', needKey: true, label: '智谱 GLM' },
  siliconflow: { baseUrl: 'https://api.siliconflow.cn/v1', model: 'Qwen/Qwen2.5-VL-7B-Instruct', needKey: true, label: '硅基流动' },
  groq:        { baseUrl: 'https://api.groq.com/openai/v1', model: 'llama-3.2-11b-vision-preview', needKey: true, label: 'Groq' },
  anthropic:   { baseUrl: 'https://api.anthropic.com', model: 'claude-sonnet-4-20250514', needKey: true, label: 'Anthropic Claude' },
  ollama:      { baseUrl: 'http://127.0.0.1:11434', model: 'gemma4:e4b', needKey: false, label: '本地 Ollama' },
  custom:      { baseUrl: '', model: '', needKey: false, label: '自定义（OpenAI 兼容）' }
};

// 用 llm_call.py 发一条极小请求，验证 key / 地址 / 模型是否可用
function testProvider(opts) {
  return new Promise((resolve) => {
    try {
      fs.mkdirSync(RUN_DIR, { recursive: true });
      const id = Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
      const reqFile = path.join(RUN_DIR, `test-${id}.req.json`);
      const resFile = path.join(RUN_DIR, `test-${id}.res.json`);
      const style = opts.style || (opts.provider === 'anthropic' ? 'anthropic' : (opts.provider === 'ollama' ? 'ollama' : 'openai'));
      const req = {
        style,
        baseUrl: opts.baseUrl || (PRESETS[opts.provider] || {}).baseUrl || '',
        model: opts.model || (PRESETS[opts.provider] || {}).model || '',
        apiKey: opts.apiKey || '',
        messages: [{ role: 'user', content: '只输出 JSON：{"ok":true}' }],
        image: '',
        timeout: 40
      };
      fs.writeFileSync(reqFile, JSON.stringify(req), 'utf8');
      const started = Date.now();
      const child = spawn(PY, [path.join(ROOT, 'agent', 'llm_call.py'), reqFile, resFile],
        { stdio: 'ignore', windowsHide: true });
      child.on('exit', () => {
        let out = { ok: false, error: '进程没有输出' };
        try { out = JSON.parse(fs.readFileSync(resFile, 'utf8').replace(/^\uFEFF/, '')); } catch {}
        try { fs.unlinkSync(reqFile); } catch {}
        try { fs.unlinkSync(resFile); } catch {}
        out.latencyMs = Date.now() - started;
        resolve(out);
      });
      setTimeout(() => { try { child.kill(); } catch {} }, 45000);
    } catch (e) {
      resolve({ ok: false, error: String(e && e.message || e) });
    }
  });
}
// ── 与 worker 的文件 IPC ────────────────────────────────────
async function ipc(req, timeoutMs = 25000) {
  const id = Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
  fs.writeFileSync(path.join(IPC_REQ, id + '.json'), JSON.stringify(req), 'utf8');
  const resFile = path.join(IPC_RES, id + '.json');
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (fs.existsSync(resFile)) {
      await new Promise(r => setTimeout(r, 40));
      let txt = '';
      try { txt = fs.readFileSync(resFile, 'utf8').replace(/^\uFEFF/, ''); } catch {}
      try { fs.unlinkSync(resFile); } catch {}
      try { return JSON.parse(txt); } catch { return { ok: false, error: 'bad json' }; }
    }
    await new Promise(r => setTimeout(r, 60));
  }
  return { ok: false, error: 'worker timeout' };
}

function workerOnline() {
  try {
    const s = fs.readFileSync(path.join(ROOT, 'ipc', 'heartbeat.txt'), 'utf8').trim();
    const iso = s.split('|')[1];
    return (Date.now() - new Date(iso).getTime()) < 15000;
  } catch { return false; }
}

// ── 运行状态 ────────────────────────────────────────────────
let run = null;

function parseTokens(text) {
  let prompt = 0, completion = 0, total = 0, last = null;
  for (const line of text.split(/\r?\n/)) {
    if (line.startsWith('__USAGE__ ')) {
      try {
        const u = JSON.parse(line.slice(10));
        prompt = u.cumPrompt ?? prompt + (u.prompt || 0);
        completion = u.cumCompletion ?? completion + (u.completion || 0);
        total = u.cumTotal ?? total + (u.total || 0);
        last = u;
      } catch {}
    }
    if (line.startsWith('__TOKENS__ ')) {
      try { const t = JSON.parse(line.slice(11)); prompt = t.prompt; completion = t.completion; total = t.total; } catch {}
    }
  }
  return { prompt, completion, total, last };
}

function readRunLog() {
  if (!run) return '';
  try { return fs.readFileSync(run.logPath, 'utf8'); } catch { return ''; }
}

function historyList() {
  try {
    return fs.readdirSync(HIST)
      .filter(f => f.endsWith('.json'))
      .map(f => { try { return JSON.parse(fs.readFileSync(path.join(HIST, f), 'utf8')); } catch { return null; } })
      .filter(Boolean)
      .sort((a, b) => (b.startedAt || 0) - (a.startedAt || 0))
      .slice(0, 30);
  } catch { return []; }
}

function saveMeta(meta) {
  try { fs.writeFileSync(path.join(HIST, meta.id + '.json'), JSON.stringify(meta, null, 2), 'utf8'); } catch {}
}

function startRun(opts) {
  if (run && !run.done) return { ok: false, error: '已有任务在跑' };
  const id = Date.now().toString(36);
  const logPath = path.join(HIST, id + '.log');
  fs.writeFileSync(logPath, '', 'utf8');

  const meta = {
    id,
    task: String(opts.task || ''),
    provider: String(opts.provider || (readJsonFile(CONFIG_FILE, {}).agent || {}).provider || 'deepseek'),
    model: String(opts.model || (readJsonFile(CONFIG_FILE, {}).agent || {}).model || ''),
    maxSteps: Number(opts.maxSteps || 8),
    plan: !!opts.plan,
    screenshot: !!opts.screenshot,
    startedAt: Date.now(),
    endedAt: 0,
    status: 'running',
    tokens: { prompt: 0, completion: 0, total: 0 }
  };
  saveMeta(meta);

  const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(ROOT, 'agent', 'agent.ps1'),
    '-Task', meta.task, '-Provider', meta.provider, '-MaxSteps', String(meta.maxSteps), '-LogFile', logPath];
  if (meta.model) args.push('-Model', meta.model);
  if (meta.plan) args.push('-Plan');
  if (meta.screenshot) args.push('-WithScreenshot');

  const fd = fs.openSync(logPath, 'a');
  const proc = spawn('powershell.exe', args, { stdio: ['ignore', fd, fd], windowsHide: true });
  proc.on('exit', () => {
    try { fs.closeSync(fd); } catch {}
    if (!run) return;
    run.done = true;
    const text = readRunLog();
    const t = parseTokens(text);
    const m = { ...meta, endedAt: Date.now(), tokens: { prompt: t.prompt, completion: t.completion, total: t.total } };
    m.status = text.includes('完成:') ? 'done' : 'stopped';
    saveMeta(m);
  });

  run = { id, proc, logPath, done: false, startedAt: Date.now(), meta };
  return { ok: true, id };
}

// ── HTTP ────────────────────────────────────────────────────
const MIME = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.png': 'image/png' };

function json(res, obj, code = 200) {
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(obj));
}

function readBody(req) {
  return new Promise(resolve => {
    let data = '';
    req.on('data', c => data += c);
    req.on('end', () => { try { resolve(JSON.parse(data || '{}')); } catch { resolve({}); } });
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${PORT}`);
  const p = url.pathname;

  try {
    if (p === '/' || p === '/index.html') {
      const html = fs.readFileSync(path.join(__dirname, 'index.html'));
      res.writeHead(200, { 'Content-Type': MIME['.html'], 'Cache-Control': 'no-store' });
      return res.end(html);
    }

    if (p === '/api/state') {
      const online = workerOnline();
      const wins = online ? await ipc({ cmd: 'windows' }) : { ok: false, data: [] };
      const fg = online ? await ipc({ cmd: 'foreground' }) : { ok: false, data: null };
      const text = readRunLog();
      return json(res, {
        worker: online,
        windows: (wins.data || []).filter(w => w && w.Title).slice(0, 16),
        foreground: fg.data || null,
        running: !!(run && !run.done),
        runId: run ? run.id : null,
        tokens: parseTokens(text),
        history: historyList()
      });
    }

    if (p === '/api/log') {
      if (!run) return json(res, { ok: true, text: '', running: false, tokens: { prompt: 0, completion: 0, total: 0 } });
      const text = readRunLog();
      return json(res, { ok: true, text, running: !!(run && !run.done), id: run.id, tokens: parseTokens(text) });
    }

    if (p === '/api/shot') {
      if (!workerOnline()) return json(res, { ok: false, error: 'worker offline' }, 503);
      const file = path.join(TMP, 'shot-live.png');
      try {
        const r = await ipc({ cmd: 'shot', path: file });
        if (!r.ok) return json(res, r, 500);
        if (!fs.existsSync(file)) return json(res, { ok: false, error: 'no file' }, 500);
        const buf = fs.readFileSync(file);
        res.writeHead(200, { 'Content-Type': 'image/png', 'Cache-Control': 'no-store' });
        return res.end(buf);
      } finally {
        try { fs.unlinkSync(file); } catch {}
      }
    }

    if (p === '/api/run' && req.method === 'POST') {
      const body = await readBody(req);
      if (!body.task) return json(res, { ok: false, error: '缺少任务描述' }, 400);
      return json(res, startRun(body));
    }

    if (p === '/api/stop' && req.method === 'POST') {
      if (run && run.proc && !run.done) {
        try { run.proc.kill(); } catch {}
        return json(res, { ok: true });
      }
      return json(res, { ok: false, error: '没有在跑的任务' });
    }

    if (p === '/api/history' && req.method === 'GET') {
      return json(res, { ok: true, items: historyList() });
    }

    if (p === '/api/history/clear' && req.method === 'POST') {
      for (const f of fs.readdirSync(HIST)) {
        try { fs.unlinkSync(path.join(HIST, f)); } catch {}
      }
      return json(res, { ok: true });
    }

    if (p.startsWith('/api/history/') && req.method === 'GET') {
      const id = p.split('/').pop();
      if (!/^[a-z0-9]+$/i.test(id)) return json(res, { ok: false, error: 'bad id' }, 400);
      const metaFile = path.join(HIST, id + '.json');
      const logFile = path.join(HIST, id + '.log');
      if (!fs.existsSync(metaFile)) return json(res, { ok: false, error: 'not found' }, 404);
      let text = '';
      try { text = fs.readFileSync(logFile, 'utf8'); } catch {}
      return json(res, { ok: true, meta: JSON.parse(fs.readFileSync(metaFile, 'utf8')), text });
    }

    if (p === '/api/health') {
      return json(res, {
        ok: true,
        version: (() => { try { return fs.readFileSync(path.join(ROOT, 'VERSION'), 'utf8').trim(); } catch { return '?'; } })(),
        port: PORT,
        worker: workerOnline(),
        uptimeSec: Math.floor(process.uptime()),
        running: !!(run && !run.done)
      });
    }

    if (p === '/api/settings' && req.method === 'GET') {
      const cfg = readJsonFile(CONFIG_FILE, {});
      const keys = readJsonFile(KEYS_FILE, {});
      const keyInfo = {};
      for (const k of Object.keys(keys)) {
        if (typeof keys[k] === 'string' && keys[k]) keyInfo[k] = maskKey(keys[k]);
      }
      return json(res, {
        presets: PRESETS,
        agent: (() => {
          const a = cfg.agent || {};
          return {
            provider: a.provider || a.defaultProvider || 'deepseek',
            model: a.model || a.defaultModel || 'deepseek-chat',
            baseUrl: a.baseUrl || '',
            maxSteps: a.maxSteps || 8
          };
        })(),
        keys: keyInfo,
        env: {
          DEEPSEEK_API_KEY: !!process.env.DEEPSEEK_API_KEY,
          OPENAI_API_KEY: !!process.env.OPENAI_API_KEY,
          ANTHROPIC_API_KEY: !!process.env.ANTHROPIC_API_KEY
        }
      });
    }

    if (p === '/api/settings' && req.method === 'POST') {
      const body = await readBody(req);
      const cfg = readJsonFile(CONFIG_FILE, {});
      if (body.agent) {
        cfg.agent = Object.assign({}, cfg.agent || {}, body.agent);
      }
      writeJsonFile(CONFIG_FILE, cfg);

      if (body.keys && typeof body.keys === 'object') {
        const keys = readJsonFile(KEYS_FILE, {});
        for (const [k, v] of Object.entries(body.keys)) {
          if (v === null) { delete keys[k]; continue; }
          if (typeof v === 'string' && v.trim() && !/^\*+$/.test(v)) keys[k] = v.trim();
        }
        writeJsonFile(KEYS_FILE, keys);
      }
      return json(res, { ok: true, agent: cfg.agent });
    }

    if (p === '/api/settings/test' && req.method === 'POST') {
      const body = await readBody(req);
      const keys = readJsonFile(KEYS_FILE, {});
      const provider = body.provider || 'deepseek';
      const preset = PRESETS[provider] || {};
      const apiKey = (body.apiKey && String(body.apiKey).trim()) || keys[provider] || '';
      const r = await testProvider({
        provider,
        style: body.style,
        baseUrl: body.baseUrl || preset.baseUrl || '',
        model: body.model || preset.model || '',
        apiKey
      });
      return json(res, r);
    }
    res.writeHead(404); res.end('not found');
  } catch (e) {
    try { json(res, { ok: false, error: String((e && e.message) || e) }, 500); } catch {}
  }
});

server.listen(PORT, '127.0.0.1', () => {
  try { fs.writeFileSync(path.join(__dirname, 'console.pid'), String(process.pid), 'utf8'); } catch {}
  console.log(`GUI Agent 控制台: http://127.0.0.1:${PORT}`);
});

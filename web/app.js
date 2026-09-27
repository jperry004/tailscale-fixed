/* Tailscale Doctor - browser UI.
 * Plain JavaScript, no dependencies. All real work happens in TailscaleDoctor.ps1;
 * this page only calls its local API (127.0.0.1) with the session token. */
(function () {
  'use strict';

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  const STATUS_ICON = { ok: '✓', warn: '!', fail: '✕', error: '✕', info: 'i', skip: '–', running: '…', pending: '' };
  // After these fixes, everything must be re-checked before trying more fixes.
  const STRUCTURAL = new Set(['install', 'repair', 'update', 'start-service', 'restart-service', 'reset-state', 'reset-winhttp-proxy', 'tpm-recover', 'dns-repair', 'fix-dependencies']);
  const CHECK_TIMEOUT_MS = 3 * 60 * 1000;
  const ACTION_TIMEOUT_MS = 30 * 60 * 1000;

  const state = {
    token: null,
    info: null,
    checks: [],          // [{id,title}]
    results: {},         // id -> result
    actions: [],         // history of action results
    busy: false,
    serverDown: false,
    logSeq: 0,
    logLines: [],
    loginTab: 'key',
    loginPoll: null,
  };

  const $ = (id) => document.getElementById(id);
  const el = (tag, attrs, ...children) => {
    const n = document.createElement(tag);
    if (attrs) {
      for (const [k, v] of Object.entries(attrs)) {
        if (v === undefined || v === null || v === false) continue;
        if (k === 'class') n.className = v;
        else if (k === 'text') n.textContent = v;
        else if (k.startsWith('on')) n.addEventListener(k.slice(2), v);
        else n.setAttribute(k, v === true ? '' : String(v));
      }
    }
    for (const c of children.flat()) {
      if (c === null || c === undefined || c === false) continue;
      n.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
    }
    return n;
  };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  // Turns plain text into nodes, with http(s) links clickable (safely, no innerHTML).
  function linkify(text) {
    const frag = document.createDocumentFragment();
    const re = /https?:\/\/[^\s"'<>)]+/g;
    let last = 0; let m;
    const s = String(text ?? '');
    while ((m = re.exec(s))) {
      if (m.index > last) frag.appendChild(document.createTextNode(s.slice(last, m.index)));
      frag.appendChild(el('a', { href: m[0], target: '_blank', rel: 'noopener noreferrer' }, m[0]));
      last = m.index + m[0].length;
    }
    if (last < s.length) frag.appendChild(document.createTextNode(s.slice(last)));
    return frag;
  }

  // ---------------------------------------------------------------------------
  // API
  // ---------------------------------------------------------------------------
  async function api(path, body, timeoutMs = 60000) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeoutMs);
    let res;
    try {
      res = await fetch(path, {
        method: body === undefined ? 'GET' : 'POST',
        headers: { 'X-Doctor-Token': state.token || '', 'Content-Type': 'application/json' },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: ctrl.signal,
        cache: 'no-store',
      });
    } catch (e) {
      if (e && e.name === 'AbortError') throw new Error(`No answer after ${Math.round(timeoutMs / 1000)} s. The doctor may still be working - check the console window.`);
      setServerDown(true);
      throw new Error('Cannot reach Tailscale Doctor. Is its console window still open? Start TailscaleDoctor.cmd again if you closed it.');
    } finally {
      clearTimeout(timer);
    }
    setServerDown(false);
    let j;
    try { j = await res.json(); } catch (_) { throw new Error(`Unexpected response from the doctor (HTTP ${res.status}).`); }
    if (!j || !j.ok) throw new Error((j && j.error) || `Request failed (HTTP ${res.status}).`);
    return j.data;
  }

  function setServerDown(down) {
    if (down === state.serverDown) return;
    state.serverDown = down;
    if (down) showBanner('Lost connection to the Tailscale Doctor console window. If you closed it, run TailscaleDoctor.cmd again.');
    else hideBanner();
  }
  function showBanner(msg, kind) {
    const b = $('banner');
    b.textContent = '';
    b.appendChild(linkify(msg));
    b.className = 'banner' + (kind === 'warn' ? ' warn' : '');
  }
  function hideBanner() { $('banner').className = 'banner hidden'; }

  // ---------------------------------------------------------------------------
  // Busy handling: one operation at a time (the backend is single-threaded).
  // ---------------------------------------------------------------------------
  function setBusy(b) {
    state.busy = b;
    document.querySelectorAll('button[data-lock], #btn-autofix, #btn-check, #btn-login-go, #btn-login-open').forEach((x) => { x.disabled = b; });
    if (b) $('verdict').dataset.state = 'busy';
  }
  async function exclusive(fn) {
    if (state.busy) return;
    setBusy(true);
    const logTimer = setInterval(pollLog, 1500);
    try { return await fn(); }
    catch (e) { showBanner(e.message || String(e)); }
    finally {
      clearInterval(logTimer);
      setBusy(false);
      $('verdict').dataset.state = 'idle';
      pollLog();
      renderVerdict();
      setProgress(null);
    }
  }

  function setProgress(frac, label) {
    const p = $('progress');
    if (frac === null) { p.classList.add('hidden'); $('progress-label').textContent = ''; return; }
    p.classList.remove('hidden');
    $('progress-bar').style.width = Math.max(2, Math.min(100, frac * 100)) + '%';
    $('progress-label').textContent = label || '';
  }

  // ---------------------------------------------------------------------------
  // Checks
  // ---------------------------------------------------------------------------
  async function runAllChecks(labelPrefix) {
    const ids = state.checks.map((c) => c.id);
    for (const id of ids) { state.results[id] = { id, title: titleOf(id), status: 'pending', summary: 'Waiting…', details: [], advice: [], fixes: [] }; }
    renderChecks();
    for (let i = 0; i < ids.length; i++) {
      const id = ids[i];
      setProgress(i / ids.length, `${labelPrefix || 'Checking'}: ${titleOf(id)} (${i + 1}/${ids.length})`);
      state.results[id] = { ...state.results[id], status: 'running', summary: 'Checking…' };
      renderCheck(id);
      try {
        try {
          state.results[id] = await api('/api/check', { id, fresh: i === 0 }, CHECK_TIMEOUT_MS);
        } catch (first) {
          if (state.serverDown) throw first;
          await sleep(1500);   // one retry for transient hiccups
          state.results[id] = await api('/api/check', { id }, CHECK_TIMEOUT_MS);
        }
      } catch (e) {
        state.results[id] = { id, title: titleOf(id), status: 'error', summary: e.message, details: [], advice: [], fixes: [] };
        if (state.serverDown) { renderCheck(id); throw e; }
      }
      renderCheck(id);
      renderVerdict(true);
    }
    setProgress(1, 'Done');
    $('checks-meta').textContent = 'Last run ' + new Date().toLocaleTimeString();
    maybeOpenLogin();
  }

  const titleOf = (id) => (state.checks.find((c) => c.id === id) || { title: id }).title;
  const ordered = () => state.checks.map((c) => state.results[c.id]).filter(Boolean);

  function renderChecks() {
    const list = $('checks');
    list.textContent = '';
    for (const c of state.checks) {
      list.appendChild(el('li', { class: 'check-item', id: 'check-' + c.id }));
      renderCheck(c.id);
    }
  }

  function renderCheck(id) {
    const r = state.results[id] || { id, title: titleOf(id), status: 'pending', summary: 'Not checked yet', details: [], advice: [], fixes: [] };
    const li = $('check-' + id);
    if (!li) return;
    li.className = 'check-item s-' + r.status;
    li.textContent = '';
    const fixes = (r.fixes || []).map((f) => el('button', {
      class: 'btn small' + (f.primary && ['fail', 'error', 'warn'].includes(r.status) ? ' primary' : '') + (f.confirm ? ' danger' : ''),
      type: 'button', 'data-lock': true, disabled: state.busy,
      onclick: () => onFix(f),
    }, f.label));
    li.appendChild(el('div', { class: 'check-row' },
      el('div', { class: 'status ' + r.status, title: r.status }, STATUS_ICON[r.status] ?? '?'),
      el('div', null,
        el('div', { class: 'check-title' }, r.title || id, r.durationMs ? el('span', { class: 'dur' }, (r.durationMs / 1000).toFixed(1) + ' s') : null),
        el('div', { class: 'check-summary' }, linkify(r.summary || ''))),
      el('div', { class: 'check-fixes' }, fixes)));

    const hasDetails = (r.details && r.details.length) || (r.advice && r.advice.length) || (r.data && r.data.tail);
    if (hasDetails) {
      const d = el('details', { class: 'check-more' });
      if (['fail', 'error'].includes(r.status)) d.open = true;
      d.appendChild(el('summary', null, (r.advice && r.advice.length) ? 'What to do & details' : 'Details'));
      if (r.advice && r.advice.length) d.appendChild(el('ul', { class: 'advice' }, r.advice.map((a) => el('li', null, linkify(a)))));
      if (r.details && r.details.length) d.appendChild(el('pre', null, r.details.join('\n')));
      if (r.data && r.data.tail) {
        const t = el('details', null, el('summary', null, 'Last log lines'), el('pre', null, r.data.tail));
        d.appendChild(t);
      }
      li.appendChild(d);
    }
  }

  // ---------------------------------------------------------------------------
  // Verdict
  // ---------------------------------------------------------------------------
  function renderVerdict(partial) {
    const v = $('verdict');
    const results = ordered().filter((r) => !['pending', 'running'].includes(r.status));
    if (state.busy && partial !== true) return;
    if (!results.length) return;
    const bad = results.find((r) => r.status === 'fail' || r.status === 'error');
    const warn = results.find((r) => r.status === 'warn');
    const backend = state.results.backend;
    const connected = backend && backend.data && backend.data.backendState === 'Running';

    const title = $('verdict-title');
    const text = $('verdict-text');
    text.textContent = '';
    if (state.busy) {
      v.dataset.state = 'busy';
      $('verdict-icon').textContent = '…';
      title.textContent = bad ? `Found a problem: ${bad.title}` : 'Checking…';
      if (bad) text.appendChild(linkify(bad.summary));
      return;
    }
    if (bad) {
      v.dataset.state = 'fail';
      $('verdict-icon').textContent = '✕';
      title.textContent = `Problem: ${bad.title}`;
      text.appendChild(linkify(bad.summary));
      const advice = (bad.advice || []).slice(0, 4);
      if (advice.length) text.appendChild(el('ul', { class: 'advice-list' }, advice.map((a) => el('li', null, linkify(a)))));
      const others = results.filter((r) => (r.status === 'fail' || r.status === 'error') && r !== bad).length;
      if (others) text.appendChild(el('p', { class: 'muted small' }, `${others} more problem(s) below. Fix the first one first: later ones are often caused by it.`));
    } else if (warn) {
      v.dataset.state = connected ? 'ok' : 'warn';
      $('verdict-icon').textContent = connected ? '✓' : '!';
      title.textContent = connected ? 'Tailscale is connected (with warnings)' : `Warning: ${warn.title}`;
      text.appendChild(linkify(warn.summary));
    } else {
      v.dataset.state = connected ? 'ok' : 'warn';
      $('verdict-icon').textContent = connected ? '✓' : '!';
      title.textContent = connected ? 'Tailscale is working' : 'No problems found';
      const ips = backend && backend.data && backend.data.ips;
      text.textContent = connected ? `This PC is connected to your tailnet${ips && ips.length ? ' as ' + ips[0] : ''}.` : 'All checks passed.';
    }
  }

  function maybeOpenLogin() {
    const b = state.results.backend;
    if (!b || !b.data) return;
    const needs = b.data.backendState === 'NeedsLogin' || (b.fixes || []).some((f) => f.action === 'show-login');
    // Only push the login form when nothing more fundamental is broken.
    const blocking = ordered().find((r) => (r.status === 'fail' || r.status === 'error') && r.id !== 'backend' && r.id !== 'security' && r.id !== 'tls' && r.id !== 'ts2021');
    if (needs && !blocking) openLogin();
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------
  function onFix(f) {
    if (f.action === 'show-login') { openLogin(); return; }
    if (f.confirm && !window.confirm(f.confirm)) return;
    exclusive(async () => {
      await runAction(f.action, f.params || {}, f.label);
      await runAllChecks('Re-checking');
    });
  }

  async function runAction(action, params, label) {
    const entry = { action, label: label || action, status: 'running', steps: [], hints: [], started: new Date() };
    state.actions.unshift(entry);
    renderActions();
    $('verdict-title').textContent = `Working: ${entry.label}…`;
    $('verdict-text').textContent = 'This can take a few minutes for installs and restarts. Follow along in the log below.';
    setProgress(0.5, entry.label);
    try {
      const r = await api('/api/action', { action, params }, ACTION_TIMEOUT_MS);
      entry.status = r.ok ? 'ok' : 'fail';
      entry.steps = r.steps || [];
      entry.hints = r.hints || [];
      entry.data = r.data || {};
      return r;
    } catch (e) {
      entry.status = 'fail';
      entry.steps.push(e.message);
      return { ok: false, steps: [e.message], hints: [], data: {} };
    } finally {
      entry.finished = new Date();
      renderActions();
    }
  }

  function renderActions() {
    const box = $('actions');
    box.textContent = '';
    if (!state.actions.length) { box.appendChild(el('p', { class: 'muted' }, 'Nothing yet.')); return; }
    for (const a of state.actions) {
      const icon = a.status === 'ok' ? '✓ ' : a.status === 'fail' ? '✕ ' : '… ';
      const node = el('div', { class: 'action-entry ' + a.status },
        el('h3', null, icon + a.label, el('span', { class: 'muted small' }, '  ' + a.started.toLocaleTimeString())),
        a.steps.length ? el('ul', null, a.steps.map((s) => el('li', null, linkify(s)))) : null,
        a.hints.length ? el('ul', { class: 'hints' }, a.hints.map((s) => el('li', null, linkify(s)))) : null);
      box.appendChild(node);
    }
  }

  async function autoFix() {
    await exclusive(async () => {
      const tried = new Set();
      for (let round = 1; round <= 6; round++) {
        await runAllChecks(round === 1 ? 'Checking' : `Re-checking (round ${round})`);
        const candidates = [];
        for (const r of ordered()) {
          if (!['fail', 'error', 'warn'].includes(r.status)) continue;
          for (const f of r.fixes || []) if (f.auto && !tried.has(f.action) && !candidates.some((c) => c.action === f.action)) candidates.push(f);
        }
        if (!candidates.length) break;
        for (const f of candidates) {
          tried.add(f.action);
          if (f.confirm && !window.confirm(f.confirm)) continue;
          await runAction(f.action, f.params || {}, f.label);
          if (STRUCTURAL.has(f.action)) break;
        }
      }
      const b = state.results.backend;
      const remaining = ordered().filter((r) => r.status === 'fail' || r.status === 'error');
      if (remaining.length) {
        showBanner('Automatic repair did everything it safely can. What is left needs you: follow the steps under "Problem" above (for example, a change in your antivirus), then click "Fix everything automatically" again.', 'warn');
      } else if (b && b.data && b.data.backendState === 'Running') {
        hideBanner();
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Login
  // ---------------------------------------------------------------------------
  function openLogin() {
    const c = $('login-card');
    if (!c.classList.contains('hidden')) return;
    c.classList.remove('hidden');
    c.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }
  function closeLogin() {
    $('login-card').classList.add('hidden');
    stopLoginPoll();
  }
  function setLoginTab(tab) {
    state.loginTab = tab;
    document.querySelectorAll('.tab').forEach((t) => t.classList.toggle('active', t.dataset.tab === tab));
    document.querySelectorAll('.tab-panel').forEach((p) => p.classList.toggle('hidden', p.dataset.panel !== tab));
    $('btn-login-go').textContent = tab === 'key' ? 'Log in with key' : 'Get sign-in link';
  }
  function loginOptions() {
    return {
      unattended: $('opt-unattended').checked,
      acceptRoutes: $('opt-routes').checked,
      hostname: $('opt-hostname').value.trim(),
      tags: $('opt-tags').value.trim(),
    };
  }
  function showLoginResult(r) {
    const box = $('login-result');
    box.textContent = '';
    const cls = 'action-entry ' + (r.ok ? 'ok' : 'fail');
    box.appendChild(el('div', { class: cls },
      el('h3', null, r.ok ? '✓ Done' : '✕ Did not work'),
      el('ul', null, (r.steps || []).map((s) => el('li', null, linkify(s)))),
      (r.hints || []).length ? el('ul', { class: 'hints' }, r.hints.map((s) => el('li', null, linkify(s)))) : null));
  }

  function onLoginGo() {
    const opts = loginOptions();
    if (opts.hostname && !/^[A-Za-z0-9][A-Za-z0-9-]{0,62}$/.test(opts.hostname)) { window.alert('Device name: letters, digits and dashes only.'); return; }
    if (state.loginTab === 'key') {
      const key = $('authkey').value.trim();
      if (!key) { window.alert('Paste an auth key first.'); $('authkey').focus(); return; }
      exclusive(async () => {
        const r = await runAction('login-key', { ...opts, authKey: key }, 'Log in with auth key');
        showLoginResult(r);
        if (r.ok) { $('authkey').value = ''; }
        await runAllChecks('Re-checking');
        if (r.ok) closeLogin();
      });
    } else {
      exclusive(async () => {
        const r = await runAction('login-browser', opts, 'Browser sign-in');
        showLoginResult(r);
        const url = r.data && r.data.url;
        if (r.ok && url) {
          $('login-link-box').classList.remove('hidden');
          const a = $('login-link');
          a.href = url; a.textContent = url;
          try { window.open(url, '_blank', 'noopener'); } catch (_) { /* popup blocked: link is shown */ }
          startLoginPoll();
        } else if (r.ok) {
          await runAllChecks('Re-checking');
        }
      });
    }
  }

  function startLoginPoll() {
    stopLoginPoll();
    const started = Date.now();
    $('login-wait').textContent = 'Waiting for you to finish signing in…';
    state.loginPoll = setInterval(async () => {
      if (state.busy) return;
      if (Date.now() - started > 15 * 60 * 1000) {
        stopLoginPoll();
        $('login-wait').textContent = 'Stopped waiting after 15 minutes. Click "Get sign-in link" to try again.';
        return;
      }
      try {
        const r = await api('/api/action', { action: 'login-poll', params: {} }, 30000);
        const s = r.data && r.data.backendState;
        if (s === 'Running' || s === 'NeedsMachineAuth') {
          stopLoginPoll();
          $('login-wait').textContent = s === 'Running' ? 'Signed in and connected!' : 'Signed in. An admin must approve this device in the admin console.';
          exclusive(async () => {
            if (loginOptions().unattended) await runAction('enable-unattended', {}, 'Turn on unattended mode');
            await runAllChecks('Re-checking');
          });
        }
      } catch (_) { /* transient; keep polling */ }
    }, 3000);
  }
  function stopLoginPoll() { if (state.loginPoll) { clearInterval(state.loginPoll); state.loginPoll = null; } }

  // ---------------------------------------------------------------------------
  // Log, report, quit
  // ---------------------------------------------------------------------------
  let logPending = false;
  async function pollLog() {
    if (logPending) return;
    logPending = true;
    try {
      const items = await api('/api/log?since=' + state.logSeq, undefined, 15000);
      if (items && items.length) {
        for (const it of items) {
          state.logSeq = Math.max(state.logSeq, it.seq);
          state.logLines.push(`[${it.time}] ${it.level === 'info' ? '' : it.level.toUpperCase() + ' '}${it.message}`);
        }
        if (state.logLines.length > 3000) state.logLines = state.logLines.slice(-3000);
        const pre = $('log');
        const atBottom = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 20;
        pre.textContent = state.logLines.join('\n');
        if (atBottom) pre.scrollTop = pre.scrollHeight;
      }
    } catch (_) { /* surfaced via banner */ }
    finally { logPending = false; }
  }

  function buildReport() {
    return {
      tool: 'Tailscale Doctor',
      version: state.info && state.info.version,
      computer: state.info && state.info.computer,
      created: new Date().toISOString(),
      results: ordered(),
      actions: state.actions.map((a) => ({ action: a.action, label: a.label, status: a.status, steps: a.steps, hints: a.hints, started: a.started, finished: a.finished })),
      log: state.logLines.slice(-1500),
    };
  }
  function redact(s) { return s.replace(/tskey-[A-Za-z0-9_-]+/g, 'tskey-***REDACTED***'); }

  function exportReport() {
    const blob = new Blob([redact(JSON.stringify(buildReport(), null, 2))], { type: 'application/json' });
    const a = el('a', { href: URL.createObjectURL(blob), download: `tailscale-doctor-${(state.info && state.info.computer) || 'pc'}-${new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-')}.json` });
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 10000);
  }

  function summaryText() {
    const lines = [`Tailscale Doctor report - ${(state.info && state.info.computer) || ''} - ${new Date().toLocaleString()}`, ''];
    for (const r of ordered()) {
      lines.push(`[${(r.status || '').toUpperCase()}] ${r.title}: ${r.summary || ''}`);
      if (['fail', 'error', 'warn'].includes(r.status)) for (const a of r.advice || []) lines.push(`    - ${a}`);
    }
    if (state.actions.length) {
      lines.push('', 'Actions:');
      for (const a of state.actions.slice().reverse()) lines.push(`  ${a.status === 'ok' ? 'OK  ' : 'FAIL'} ${a.label}`);
    }
    return redact(lines.join('\n'));
  }
  async function copySummary() {
    const text = summaryText();
    try { await navigator.clipboard.writeText(text); flash($('btn-copy'), 'Copied!'); }
    catch (_) {
      const ta = el('textarea'); ta.value = text; document.body.appendChild(ta); ta.select();
      try { document.execCommand('copy'); flash($('btn-copy'), 'Copied!'); } catch (__) { window.alert(text); }
      ta.remove();
    }
  }
  function flash(btn, text) { const o = btn.textContent; btn.textContent = text; setTimeout(() => { btn.textContent = o; }, 1500); }

  async function quit() {
    if (state.busy && !window.confirm('Work is in progress. Quit anyway?')) return;
    try { await api('/api/shutdown', {}, 5000); } catch (_) { /* already gone */ }
    stopLoginPoll();
    document.body.textContent = '';
    document.body.appendChild(el('main', null, el('section', { class: 'card' }, el('h2', null, 'Tailscale Doctor has stopped.'), el('p', { class: 'muted' }, 'You can close this tab. Run TailscaleDoctor.cmd to start it again.'))));
  }

  // ---------------------------------------------------------------------------
  // Init
  // ---------------------------------------------------------------------------
  async function init() {
    const params = new URLSearchParams(location.search);
    const t = params.get('t');
    if (t) {
      state.token = t;
      try { sessionStorage.setItem('tsdoctor-token', t); } catch (_) { /* storage blocked */ }
      try { history.replaceState(null, '', location.pathname); } catch (_) { /* ignore */ }
    } else {
      try { state.token = sessionStorage.getItem('tsdoctor-token'); } catch (_) { state.token = null; }
    }

    $('btn-check').addEventListener('click', () => exclusive(() => runAllChecks()));
    $('btn-autofix').addEventListener('click', autoFix);
    $('btn-login-open').addEventListener('click', openLogin);
    $('btn-login-close').addEventListener('click', closeLogin);
    $('btn-login-go').addEventListener('click', onLoginGo);
    $('btn-showkey').addEventListener('click', () => {
      const k = $('authkey');
      k.type = k.type === 'password' ? 'text' : 'password';
      $('btn-showkey').textContent = k.type === 'password' ? 'Show' : 'Hide';
    });
    document.querySelectorAll('.tab').forEach((tb) => tb.addEventListener('click', () => setLoginTab(tb.dataset.tab)));
    $('btn-export').addEventListener('click', exportReport);
    $('btn-copy').addEventListener('click', copySummary);
    $('btn-quit').addEventListener('click', quit);
    $('btn-clear-actions').addEventListener('click', () => { state.actions = []; renderActions(); });
    setLoginTab('key');

    if (!state.token) {
      showBanner('Missing access token. Open the full link shown in the Tailscale Doctor console window (it ends in ?t=...).');
      setBusy(true);
      return;
    }
    try {
      state.info = await api('/api/info', undefined, 20000);
    } catch (e) {
      showBanner(e.message);
      setBusy(true);
      return;
    }
    state.checks = state.info.checks || [];
    $('machine').textContent = `${state.info.computer || 'This PC'} · v${state.info.version}` + (state.info.admin ? ' · Administrator' : ' · NOT administrator');
    $('log-path').textContent = state.info.logFile ? '— also saved to ' + state.info.logFile : '';
    if (!state.info.admin) showBanner('Not running as Administrator: checks work, but most fixes will fail. Close the console window, right-click TailscaleDoctor.cmd and choose "Run as administrator".', 'warn');
    if (!state.info.windows) showBanner('This is not Windows: most checks will be skipped. Tailscale Doctor is built for Windows.', 'warn');
    renderChecks();
    pollLog();
    setInterval(() => { if (!state.busy) pollLog(); }, 5000);
    // Kick off a first read-only check so the page is immediately useful.
    exclusive(() => runAllChecks());
  }

  document.addEventListener('DOMContentLoaded', init);
})();

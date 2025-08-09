// dashboard.js - dark neon interactive frontend
// Queries endpoints:
//  - GET /data         -> latest report
//  - POST /start-scan  -> {"mode":"partial"|"full"}
//  - GET /history      -> array of history entries
//  - GET /stream       -> SSE for live logs
//  - POST /action/*    -> kill/suspend/clear_temp/boost (see backend)

const state = {
    cpuChart: null,
    memChart: null,
    diskChart: null,
    historyChart: null
};

function el(id) { return document.getElementById(id); }

function nice(n, suffix = '%') { return (n === undefined || n === null) ? '—' : (Math.round(n * 10) / 10) + suffix; }

async function fetchData() {
    try {
        const res = await fetch('/data');
        if (!res.ok) return null;
        const json = await res.json();
        return json;
    } catch (e) {
        console.error('fetchData error', e);
        return null;
    }
}

async function fetchHistory() {
    try {
        const r = await fetch('/history');
        if (!r.ok) return [];
        return await r.json();
    } catch (e) { return []; }
}

function createDoughnut(ctx, color) {
    return new Chart(ctx, {
        type: 'doughnut',
        data: { labels: ['Used', 'Free'], datasets: [{ data: [0, 100], backgroundColor: [color, 'rgba(255,255,255,0.05)'], hoverOffset: 6 }] },
        options: { cutout: '70%', plugins: { legend: { display: false } }, animation: { duration: 500 } }
    });
}

function createBar(ctx) {
    return new Chart(ctx, {
        type: 'bar',
        data: { labels: [], datasets: [{ data: [], backgroundColor: '#4be3ff' }] },
        options: { plugins: { legend: { display: false } }, scales: { y: { beginAtZero: true, max: 100 } }, animation: { duration: 500 } }
    });
}

async function initCharts() {
    // history top line chart
    const hctx = el('historyChart').getContext('2d');
    state.historyChart = new Chart(hctx, {
        type: 'line',
        data: {
            labels: [], datasets: [
                { label: 'Score', data: [], borderColor: '#8a5bff', backgroundColor: 'rgba(138,91,255,0.08)', tension: 0.3, pointRadius: 4, pointBackgroundColor: '#8a5bff' },
                { label: 'CPU%', data: [], borderColor: '#4be3ff', backgroundColor: 'rgba(75,227,255,0.06)', tension: 0.3, pointRadius: 4, pointBackgroundColor: '#4be3ff' }
            ]
        },
        options: { plugins: { legend: { labels: { color: '#9fb6bf' } } }, scales: { x: { ticks: { color: '#9fb6bf' } }, y: { ticks: { color: '#9fb6bf' } } }, animation: { duration: 700 } }
    });

    state.cpuChart = createDoughnut(el('cpuChart').getContext('2d'), '#4be3ff');
    state.memChart = createDoughnut(el('memChart').getContext('2d'), '#9bff8b');
    state.diskChart = createBar(el('diskChart').getContext('2d'));
}

function updateHistoryChart(history) {
    // history is array of entries (last N). We'll show last 4 (or more)
    const labels = history.map(it => it.time.split(' ')[1] || it.time);
    const scores = history.map(it => it.score || 0);
    const cpus = history.map(it => it.cpu || 0);
    state.historyChart.data.labels = labels;
    state.historyChart.data.datasets[0].data = scores;
    state.historyChart.data.datasets[1].data = cpus;
    state.historyChart.update();
}

function updateKPIs(r) {
    el('hostName').innerText = r.host || r.hostname || 'localhost';
    el('hostIP').innerText = r.ip || '—';
    el('hostOS').innerText = r.platform || r.os || '—';
    el('scoreVal').innerText = (r.score !== undefined) ? r.score : '—';
    el('cpuText').innerText = nice(r.cpu_percent || r.cpu && r.cpu.percent || 0);
    el('memText').innerText = nice(r.memory_percent || (r.memory && r.memory.used_percent) || 0);
}

function updateCharts(r) {
    // CPU
    const cpuVal = Number(r.cpu_percent || (r.cpu && r.cpu.percent) || 0);
    state.cpuChart.data.datasets[0].data = [cpuVal, Math.max(0, 100 - cpuVal)];
    state.cpuChart.update();

    const memVal = Number(r.memory_percent || (r.memory && r.memory.used_percent) || 0);
    state.memChart.data.datasets[0].data = [memVal, Math.max(0, 100 - memVal)];
    state.memChart.update();

    // disks
    const disks = r.disks || [];
    state.diskChart.data.labels = disks.map(d => d.mount || d.device || 'disk');
    state.diskChart.data.datasets[0].data = disks.map(d => d.percent || 0);
    state.diskChart.update();
}

function renderRemediations(r) {
    const remList = el('remList');
    remList.innerHTML = '';
    const rems = r.remediations || [];
    if (rems.length === 0) {
        const div = document.createElement('div'); div.className = 'remItem muted'; div.innerHTML = "No remediation suggestions — system looks healthy.";
        remList.appendChild(div);
    } else {
        rems.forEach(it => {
            const div = document.createElement('div'); div.className = 'remItem';
            div.innerHTML = `<div><div class="title">${it.title}</div><div class="muted tiny">${it.action || it.note || ''}</div></div>
                       <div><button class="btn ghost" onclick="copyText('${(it.action || '').replace(/'/g, '\\\'')}')">Copy</button></div>`;
            remList.appendChild(div);
        });
    }
    // top processes
    const top = r.top_processes || [];
    top.forEach(p => {
        const div = document.createElement('div'); div.className = 'remItem';
        div.innerHTML = `<div><strong>${p.name}</strong> <span class="muted tiny">PID ${p.pid} • CPU ${p.cpu}% • ${p.mem_mb}MB</span></div>
                     <div>
                       <button class="btn tiny" onclick="killPid(${p.pid})">Kill</button>
                       <button class="btn tiny" onclick="suspendPid(${p.pid})">Suspend</button>
                       <button class="btn tiny" onclick="resumePid(${p.pid})">Resume</button>
                     </div>`;
        el('remList').appendChild(div);
    });
}

function appendLog(line) {
    const area = el('logArea');
    const d = document.createElement('div');
    d.textContent = line;
    area.appendChild(d);
    area.scrollTop = area.scrollHeight;
}

// SSE
function startSSE() {
    if (typeof (EventSource) === 'undefined') { console.warn('SSE not supported'); return; }
    const es = new EventSource('/stream');
    es.onmessage = function (e) {
        try {
            const line = JSON.parse(e.data);
            appendLog(line);
        } catch (err) {
            appendLog(e.data);
        }
    };
    es.onerror = function () { appendLog('[SSE] connection lost (will retry)'); };
}

async function refreshAll() {
    const r = await fetchData();
    if (!r) return;
    updateKPIs(r);
    updateCharts(r);
    renderRemediations(r);
    // update history chart
    const history = await fetchHistory();
    updateHistoryChart(history.slice(-8)); // send last up to 8
}

function copyText(t) {
    navigator.clipboard?.writeText(t);
}

async function killPid(pid) {
    const res = await fetch('/action/kill', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ pid }) });
    const json = await res.json();
    if (json.status === 'ok') appendLog(`Killed PID ${pid}`);
    else appendLog(`Kill error: ${JSON.stringify(json)}`);
}

async function suspendPid(pid) {
    const res = await fetch('/action/suspend', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ pid }) });
    const json = await res.json();
    if (json.status === 'ok') appendLog(`Suspended PID ${pid}`);
    else appendLog(`Suspend error: ${JSON.stringify(json)}`);
}

async function resumePid(pid) {
    const res = await fetch('/action/resume', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ pid }) });
    const json = await res.json();
    if (json.status === 'ok') appendLog(`Resumed PID ${pid}`);
    else appendLog(`Resume error: ${JSON.stringify(json)}`);
}

async function startScan(mode) {
    try {
        el('statusBadge').innerText = `Starting ${mode}...`;
        const res = await fetch('/start-scan', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ mode }) });
        if (res.ok) {
            el('statusBadge').innerText = 'Running';
            appendLog(`Scan started (${mode})`);
        } else {
            const json = await res.json();
            appendLog(`Scan start failed: ${JSON.stringify(json)}`);
        }
    } catch (e) { appendLog('Start scan error: ' + e.message); }
}

async function clearTemp() {
    const res = await fetch('/action/clear_temp', { method: 'POST' });
    const json = await res.json();
    if (json.status === 'ok') appendLog(`Cleared temp: removed ${json.removed || 'n/a'} files`);
    else appendLog(`Clear temp error: ${JSON.stringify(json)}`);
}

async function boostSystem() {
    const mode = el('boostMode').value || 'soft';
    const res = await fetch('/action/boost', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ mode }) });
    const json = await res.json();
    appendLog(`Boost result: ${JSON.stringify(json)}`);
}

document.addEventListener('DOMContentLoaded', async () => {
    await initCharts();
    startSSE();
    // attach buttons
    el('fullBtn').addEventListener('click', () => startScan('full'));
    el('partialBtn').addEventListener('click', () => startScan('partial'));
    el('boostBtn').addEventListener('click', () => boostSystem());
    el('clearTempBtn').addEventListener('click', () => clearTemp());
    el('refreshBtn').addEventListener('click', () => refreshAll());
    el('clearLogs').addEventListener('click', () => { el('logArea').innerHTML = ''; });
    // initial refresh & poll
    await refreshAll();
    setInterval(refreshAll, 4000);
});
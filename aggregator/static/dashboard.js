let cpuChart, memChart, diskChart;
const hostNameEl = document.getElementById('hostName');
const hostIPEl = document.getElementById('hostIP');
const scoreEl = document.getElementById('healthScore');
const netEl = document.getElementById('netState');
const remList = document.getElementById('remList');
const logArea = document.getElementById('logArea');
const statusBadge = document.getElementById('statusBadge');

function makeChart(ctx, type, labels, data, color){
    return new Chart(ctx, {
        type,
        data: { labels, datasets: [{ label: '', data, backgroundColor: color, borderColor: color, fill:false }]},
        options:{responsive:true, animation:{duration:500}}
    });
}

async function fetchReport(){
    try{
        const res = await fetch('/data');
        if(!res.ok){ console.warn('No data'); return null; }
        const json = await res.json();
        return json;
    }catch(e){ console.error(e); return null; }
}

function safeNumber(v){ return (v===null||v===undefined)?0:Math.round(v*100)/100; }

async function refreshUI(){
    const data = await fetchReport();
    if(!data) return;
    // if full report returned
    const isFull = data && data.cpu_percent !== undefined || data.cpu !== undefined;
    const host = data.host || data.hostname || (data.reports && data.reports[0] && data.reports[0].host) || '—';
    hostNameEl.innerText = host;
    hostIPEl.innerText = data.ip || '—';
    scoreEl.innerText = (data.score !== undefined)? data.score : '—';
    netEl.innerText = (data.network_online!==undefined)? (data.network_online ? 'Online' : 'Offline') : (data.network_interfaces ? 'Connected' : '—');

    // CPU
    const cpuVal = safeNumber(data.cpu_percent || data.cpu || (data.cpu && data.cpu.percent) || 0);
    const memVal = safeNumber(data.memory_percent || data.memory || data.memory_percent || 0);

    // update charts
    if(!cpuChart){
        cpuChart = makeChart(document.getElementById('cpuChart').getContext('2d'), 'doughnut', ['Used','Free'], [cpuVal, Math.max(0,100-cpuVal)], ['#00e6e6','#06333a']);
    } else {
        cpuChart.data.datasets[0].data = [cpuVal, Math.max(0,100-cpuVal)];
        cpuChart.update();
    }

    if(!memChart){
        memChart = makeChart(document.getElementById('memChart').getContext('2d'), 'doughnut', ['Used','Free'], [memVal, Math.max(0,100-memVal)], ['#ff6b6b','#3a2424']);
    } else {
        memChart.data.datasets[0].data = [memVal, Math.max(0,100-memVal)];
        memChart.update();
    }

    // Disks: collect mount labels and percents
    const disks = data.disks || (data.reports && data.reports[0] && data.reports[0].disks) || [];
    const labels = disks.map(d=>d.mount || d.device || 'disk');
    const vals = disks.map(d=>d.percent || 0);
    if(!diskChart){
        diskChart = makeChart(document.getElementById('diskChart').getContext('2d'),'bar',labels,vals,['#00aaff']);
    } else {
        diskChart.data.labels = labels;
        diskChart.data.datasets[0].data = vals;
        diskChart.update();
    }

    // remediations
    remList.innerHTML = '';
    const rems = data.remediations || data.rems || [];
    rems.forEach(r=>{ const li=document.createElement('li'); li.innerHTML=`<strong>${r.title}:</strong> ${r.action}`; remList.appendChild(li); });

    // status
    fetch('/status').then(r=>r.json()).then(s=>{
        statusBadge.innerText = s.running ? `Running (${s.mode})` : 'Idle';
    }).catch(()=>{});
}

// SSE logs
function startSSE(){
    const es = new EventSource('/stream');
    es.onmessage = function(e){
        try{
            const line = JSON.parse(e.data);
            logArea.textContent += line + "\n";
            logArea.scrollTop = logArea.scrollHeight;
        } catch(err){}
    };
    es.onerror = function(){ console.warn('SSE connection error'); };
}

// buttons
document.addEventListener('DOMContentLoaded', ()=>{
    document.getElementById('btnPartial').addEventListener('click', ()=> {
        fetch('/start-scan', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({mode:'partial'})});
    });
    document.getElementById('btnFull').addEventListener('click', ()=> {
        fetch('/start-scan', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({mode:'full'})});
    });
    // initial load
    refreshUI();
    startSSE();
    // refresh every 4s
    setInterval(refreshUI, 4000);
});
// Initial setup for charts
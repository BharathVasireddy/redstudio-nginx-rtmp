import { API_BASE } from './constants.js';
import { dom } from './dom.js';
import { formatNumber } from './utils.js';

function renderMetrics(data) {
    if (!dom.metricsStatus || !dom.cpuValue || !dom.cpuSub || !dom.memValue || !dom.memSub || !dom.diskValue || !dom.diskSub || !dom.netValue || !dom.netSub) {
        return;
    }
    if (!data || data.supported === false) {
        dom.metricsStatus.textContent = 'Metrics not available on this server.';
        dom.metricsStatus.className = 'status error';
        return;
    }

    if (data.cpu) {
        dom.cpuValue.textContent = data.cpu.usage_pct === null ? '--' : `${formatNumber(data.cpu.usage_pct)}%`;
        if (Array.isArray(data.loadavg)) {
            dom.cpuSub.textContent = `Load ${data.loadavg.join(', ')}`;
        } else {
            dom.cpuSub.textContent = 'Load --';
        }
    }

    if (data.memory) {
        const used = data.memory.used_mb;
        const total = data.memory.total_mb;
        const pct = data.memory.used_pct;
        dom.memValue.textContent = (used === null || total === null) ? '--' : `${formatNumber(used)} / ${formatNumber(total)} MB`;
        dom.memSub.textContent = pct === null ? '--' : `${formatNumber(pct)}% used`;
    }

    if (data.disk) {
        const used = data.disk.used_gb;
        const total = data.disk.total_gb;
        const pct = data.disk.used_pct;
        dom.diskValue.textContent = (used === null || total === null) ? '--' : `${formatNumber(used)} / ${formatNumber(total)} GB`;
        dom.diskSub.textContent = pct === null ? '--' : `${formatNumber(pct)}% used`;
    }

    if (data.network) {
        const rx = data.network.rx_mbps;
        const tx = data.network.tx_mbps;
        dom.netValue.textContent = (rx === null || tx === null) ? '--' : `${rx.toFixed(2)} down / ${tx.toFixed(2)} up Mbps`;
        dom.netSub.textContent = data.uptime_sec ? `Uptime ${Math.floor(data.uptime_sec / 3600)}h` : 'Uptime --';
    }

    dom.metricsStatus.textContent = '';
    dom.metricsStatus.className = 'status';
}

export async function loadMetrics() {
    if (!dom.metricsStatus) {
        return;
    }
    try {
        const res = await fetch(`${API_BASE}/metrics`, { cache: 'no-store' });
        if (res.status === 401) {
            return;
        }
        if (!res.ok) {
            dom.metricsStatus.textContent = 'Metrics unavailable';
            dom.metricsStatus.className = 'status error';
            return;
        }
        const data = await res.json();
        renderMetrics(data);
    } catch (err) {
        dom.metricsStatus.textContent = 'Metrics unavailable';
        dom.metricsStatus.className = 'status error';
    }
}

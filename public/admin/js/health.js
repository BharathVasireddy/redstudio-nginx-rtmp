import { API_BASE } from './constants.js';
import { dom } from './dom.js';

function renderHealth(report) {
    if (!dom.healthList || !dom.healthStatus || !dom.healthMeta) {
        return;
    }
    dom.healthList.innerHTML = '';
    if (!report || report.supported === false) {
        const message = report && report.error ? `Health checks unavailable: ${report.error}` : 'Health checks unavailable';
        dom.healthStatus.textContent = message;
        dom.healthStatus.className = 'status error';
        dom.healthMeta.textContent = '';
        return;
    }

    const warnings = Array.isArray(report.warnings) ? report.warnings : [];
    if (warnings.length === 0) {
        dom.healthStatus.textContent = 'All checks look good.';
        dom.healthStatus.className = 'status success';
    } else {
        const hasCritical = warnings.some((warning) => warning.level === 'critical');
        dom.healthStatus.textContent = hasCritical ? 'Critical issues detected.' : 'Warnings detected.';
        dom.healthStatus.className = 'status error';
    }

    warnings.forEach((warning) => {
        const level = warning.level || 'warning';
        const item = document.createElement('li');
        item.className = 'health-item';
        item.innerHTML = `
            <span class="health-badge ${level}">${level}</span>
            <span>${warning.message || 'Check recommended settings.'}</span>
        `;
        dom.healthList.appendChild(item);
    });

    const ingest = report.ingest || {};
    const live = report.live || {};
    const overlays = report.overlays || {};
    const parts = [];
    if (ingest.active) {
        const video = ingest.video || {};
        const audio = ingest.audio || {};
        const size = (video.width && video.height) ? `${video.width}x${video.height}` : 'unknown size';
        const fps = video.frame_rate ? `${video.frame_rate} fps` : 'fps --';
        const audioRate = audio.sample_rate ? `${audio.sample_rate} Hz` : 'audio --';
        parts.push(`Ingest: ${size} @ ${fps}, audio ${audioRate}`);
    } else {
        parts.push('Ingest: idle');
    }
    if (live.active) {
        parts.push(`Live: ${live.clients || 0} viewer(s)`);
    } else {
        parts.push('Live: idle');
    }
    if (overlays.enabled) {
        parts.push(`Overlays: ${overlays.count || 0} enabled`);
    } else {
        parts.push('Overlays: disabled');
    }
    dom.healthMeta.textContent = parts.join(' | ');
}

export async function loadHealth() {
    if (!dom.healthStatus) {
        return;
    }
    try {
        const res = await fetch(`${API_BASE}/health`, { cache: 'no-store' });
        if (res.status === 401) {
            return;
        }
        if (!res.ok) {
            dom.healthStatus.textContent = 'Health checks unavailable';
            dom.healthStatus.className = 'status error';
            return;
        }
        const report = await res.json();
        renderHealth(report);
    } catch (err) {
        dom.healthStatus.textContent = 'Health checks unavailable';
        dom.healthStatus.className = 'status error';
    }
}

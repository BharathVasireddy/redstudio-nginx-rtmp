import { API_BASE } from './constants.js';
import { dom } from './dom.js';
import { state } from './state.js';
import { showToast, getErrorMessage, copyToClipboard, generateKey } from './utils.js';
import { normalizeOverlayItem, normalizeOverlays, renderOverlays, bindOverlayEvents } from './overlays.js';
import { mergeDefaults, renderDestinations, bindDestinationEvents } from './destinations.js';
import { updateEmbedUi, bindEmbedEvents, setEmbedStatus } from './embed.js';
import { loadMetrics } from './metrics.js';
import { loadHealth } from './health.js';
import { initPreviewPlayer } from './preview.js';
import { normalizeTicker, renderTicker, bindTickerEvents } from './ticker.js';

function getIngestUrl() {
    const host = window.location.hostname;
    if (host === 'localhost' || host === '127.0.0.1') {
        return 'rtmp://localhost/ingest';
    }
    if (host.startsWith('live.')) {
        return `rtmp://ingest.${host.slice(5)}/ingest`;
    }
    if (host.startsWith('ingest.')) {
        return `rtmp://${host}/ingest`;
    }
    return `rtmp://ingest.${host}/ingest`;
}

function render() {
    if (dom.ingestUrlInput) {
        dom.ingestUrlInput.value = getIngestUrl();
    }
    if (dom.ingestKeyInput) {
        dom.ingestKeyInput.value = state.ingest_key || '';
    }
    if (dom.publicLiveToggle) {
        dom.publicLiveToggle.checked = state.public_live !== false;
    }
    if (dom.publicLiveLabel) {
        dom.publicLiveLabel.textContent = state.public_live !== false
            ? 'Visible on website'
            : 'Hidden on website';
    }
    if (dom.publicHlsToggle) {
        dom.publicHlsToggle.checked = state.public_hls !== false;
    }
    if (dom.publicHlsLabel) {
        dom.publicHlsLabel.textContent = state.public_hls !== false
            ? 'Allow HLS access'
            : 'Block HLS access';
    }
    state.overlays = normalizeOverlays(state.overlays, { allowEmpty: true });
    renderOverlays();
    state.ticker = normalizeTicker(state.ticker);
    renderTicker();
    renderDestinations();
}

async function waitForOrigin(timeoutMs = 12000) {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
        try {
            const res = await fetch(`${API_BASE}/restream`, { cache: 'no-store' });
            if (res.ok) {
                return true;
            }
        } catch (err) {
            // ignore transient network errors during restart
        }
        await new Promise((resolve) => setTimeout(resolve, 1000));
    }
    return false;
}

async function waitForStreamHealth(timeoutMs = 15000) {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
        try {
            const res = await fetch(`${API_BASE}/health`, { cache: 'no-store' });
            if (!res.ok) {
                await new Promise((resolve) => setTimeout(resolve, 1500));
                continue;
            }
            const report = await res.json();
            if (report && report.supported && report.ingest && report.ingest.active) {
                if (report.live && report.live.active) {
                    return 'live';
                }
                return 'ingest';
            }
        } catch (err) {
            // ignore and retry
        }
        await new Promise((resolve) => setTimeout(resolve, 1500));
    }
    return null;
}

async function confirmTickerSaved() {
    if (!state.ticker) {
        return;
    }
    const desired = normalizeTicker(state.ticker);
    if (!desired.enabled && !desired.text) {
        return;
    }
    try {
        const res = await fetch('/public-config.json', { cache: 'no-store' });
        if (!res.ok) {
            return;
        }
        const data = await res.json();
        const saved = normalizeTicker(data.ticker);
        const desiredItems = Array.isArray(desired.items) ? desired.items : [];
        const savedItems = Array.isArray(saved.items) ? saved.items : [];
        const mismatch = saved.enabled !== desired.enabled
            || saved.speed !== desired.speed
            || saved.font_size !== desired.font_size
            || saved.height !== desired.height
            || saved.background !== desired.background
            || saved.separator !== desired.separator
            || JSON.stringify(savedItems) !== JSON.stringify(desiredItems);
        if (mismatch) {
            showToast('Ticker did not persist. Restart the admin API and save again.', 'error');
        }
    } catch (err) {
        // Ignore ticker confirmation errors
    }
}

async function ensureSession() {
    try {
        const res = await fetch(`${API_BASE}/session`, { cache: 'no-store' });
        if (res.status === 401) {
            window.location.href = '/admin/login.html';
            return false;
        }
        return res.ok;
    } catch (err) {
        window.location.href = '/admin/login.html';
        return false;
    }
}

async function loadConfig() {
    try {
        const res = await fetch(`${API_BASE}/restream`);
        if (res.status === 401) {
            window.location.href = '/admin/login.html';
            return;
        }
        const payload = await res.json();
        state.ingest_key = payload.ingest_key || '';
        state.public_live = typeof payload.public_live === 'boolean' ? payload.public_live : true;
        state.public_hls = typeof payload.public_hls === 'boolean' ? payload.public_hls : true;
        const overlaysSource = payload.overlays || payload.overlay || [];
        state.overlays = normalizeOverlays(overlaysSource, { allowEmpty: true });
        state.ticker = normalizeTicker(payload.ticker);
        state.destinations = mergeDefaults(payload.destinations);
        render();
    } catch (err) {
        if (dom.status) {
            dom.status.textContent = 'Using default configuration';
            dom.status.className = 'status error';
        }
        state.destinations = mergeDefaults([]);
        state.ingest_key = '';
        state.public_live = true;
        state.public_hls = true;
        state.overlays = [normalizeOverlayItem({})];
        state.ticker = normalizeTicker({});
        render();
        showToast('Admin API not reachable. Showing defaults.', 'error');
    }
}

async function saveConfig(apply) {
    if (dom.status) {
        dom.status.textContent = 'Saving...';
        dom.status.className = 'status';
    }
    showToast('Saving...', 'info');

    try {
        const payload = { ...state, overlays: normalizeOverlays(state.overlays, { allowEmpty: true }) };
        const res = await fetch(`${API_BASE}/restream`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });

        if (res.status === 401) {
            window.location.href = '/admin/login.html';
            return;
        }

        if (!res.ok) {
            const errorMessage = await getErrorMessage(res);
            if (dom.status) {
                dom.status.textContent = 'Save failed';
                dom.status.className = 'status error';
            }
            showToast(`Save failed: ${errorMessage}`, 'error');
            return;
        }

        await confirmTickerSaved();

        if (apply) {
            if (dom.status) {
                dom.status.textContent = 'Applying changes...';
            }
            showToast('Applying changes...', 'info');
            const reconnecting = dom.reconnectToggle && dom.reconnectToggle.checked;
            const query = new URLSearchParams();
            if (reconnecting) {
                query.set('reconnect', '1');
            }
            const applyUrl = query.toString()
                ? `${API_BASE}/restream/apply?${query.toString()}`
                : `${API_BASE}/restream/apply`;
            try {
                const applyRes = await fetch(applyUrl, { method: 'POST' });
                if (applyRes.status === 401) {
                    window.location.href = '/admin/login.html';
                    return;
                }
                if (!applyRes.ok) {
                    if (reconnecting && [520, 521, 522, 523, 524].includes(applyRes.status)) {
                        if (dom.status) {
                            dom.status.textContent = 'Waiting for server...';
                        }
                        showToast('Waiting for server...', 'info');
                        const recovered = await waitForOrigin();
                        if (recovered) {
                            if (dom.status) {
                                dom.status.textContent = 'Saved and applied successfully';
                                dom.status.className = 'status success';
                            }
                            showToast('Saved and applied successfully', 'success');
                            return;
                        }
                    }
                    const errorMessage = await getErrorMessage(applyRes);
                    if (dom.status) {
                        dom.status.textContent = 'Apply failed';
                        dom.status.className = 'status error';
                    }
                    showToast(`Apply failed: ${errorMessage}`, 'error');
                    return;
                }
                let applyPayload = {};
                try {
                    applyPayload = await applyRes.json();
                } catch (err) {
                    applyPayload = {};
                }
                if (applyPayload.reconnect === 'failed') {
                    if (dom.status) {
                        dom.status.textContent = 'Saved, reconnect failed';
                        dom.status.className = 'status error';
                    }
                    showToast(`Reconnect failed: ${applyPayload.reconnect_error || 'unknown error'}`, 'error');
                } else if (applyPayload.reconnect === 'ok') {
                    if (dom.status) {
                        dom.status.textContent = 'Saved and applied successfully';
                        dom.status.className = 'status success';
                    }
                    showToast('Saved, reconnecting stream...', 'success');
                    if (reconnecting) {
                        const health = await waitForStreamHealth();
                        if (health === 'live') {
                            showToast('Stream reconnected successfully.', 'success');
                        } else if (health === 'ingest') {
                            showToast('Reconnect pending: ingest seen, live output not yet active.', 'info');
                        } else {
                            showToast('Reconnect pending. Check OBS and server health.', 'info');
                        }
                    }
                } else {
                    if (dom.status) {
                        dom.status.textContent = 'Saved and applied successfully';
                        dom.status.className = 'status success';
                    }
                    showToast('Saved and applied successfully', 'success');
                }
            } catch (err) {
                if (reconnecting) {
                    if (dom.status) {
                        dom.status.textContent = 'Waiting for server...';
                    }
                    showToast('Waiting for server...', 'info');
                    const recovered = await waitForOrigin();
                    if (recovered) {
                        if (dom.status) {
                            dom.status.textContent = 'Saved and applied successfully';
                            dom.status.className = 'status success';
                        }
                        showToast('Saved and applied successfully', 'success');
                        return;
                    }
                }
                if (dom.status) {
                    dom.status.textContent = 'Network error';
                    dom.status.className = 'status error';
                }
                showToast('Network error', 'error');
            }
            return;
        }

        if (dom.status) {
            dom.status.textContent = 'Saved successfully';
            dom.status.className = 'status success';
        }
        showToast('Saved successfully', 'success');
    } catch (err) {
        if (dom.status) {
            dom.status.textContent = 'Network error';
            dom.status.className = 'status error';
        }
        showToast('Network error', 'error');
    }
}

function bindEvents() {
    if (dom.addBtn) {
        dom.addBtn.addEventListener('click', () => {
            state.destinations.push({
                id: `custom-${Date.now()}`,
                name: 'Custom Platform',
                enabled: false,
                rtmp_url: 'rtmp://',
                stream_key: ''
            });
            render();
        });
    }

    if (dom.saveBtn) {
        dom.saveBtn.addEventListener('click', () => saveConfig(false));
    }
    if (dom.applyBtn) {
        dom.applyBtn.addEventListener('click', () => saveConfig(true));
    }

    if (dom.ingestKeyInput) {
        dom.ingestKeyInput.addEventListener('input', (event) => {
            state.ingest_key = event.target.value;
        });
    }

    if (dom.publicLiveToggle) {
        dom.publicLiveToggle.addEventListener('change', () => {
            state.public_live = dom.publicLiveToggle.checked;
            if (dom.publicLiveLabel) {
                dom.publicLiveLabel.textContent = state.public_live
                    ? 'Visible on website'
                    : 'Hidden on website';
            }
        });
    }

    if (dom.publicHlsToggle) {
        dom.publicHlsToggle.addEventListener('change', () => {
            state.public_hls = dom.publicHlsToggle.checked;
            if (dom.publicHlsLabel) {
                dom.publicHlsLabel.textContent = state.public_hls
                    ? 'Allow HLS access'
                    : 'Block HLS access';
            }
        });
    }

    if (dom.generateKeyBtn) {
        dom.generateKeyBtn.addEventListener('click', () => {
            const key = generateKey();
            state.ingest_key = key;
            if (dom.ingestKeyInput) {
                dom.ingestKeyInput.value = key;
            }
            showToast('New stream key generated', 'success');
        });
    }

    if (dom.copyKeyBtn) {
        dom.copyKeyBtn.addEventListener('click', () => {
            if (dom.ingestKeyInput) {
                copyToClipboard(dom.ingestKeyInput.value);
            }
        });
    }

    if (dom.toggleIngestKey && dom.ingestKeyInput) {
        dom.toggleIngestKey.addEventListener('click', () => {
            const isPassword = dom.ingestKeyInput.type === 'password';
            dom.ingestKeyInput.type = isPassword ? 'text' : 'password';
            const eyeIcon = dom.toggleIngestKey.querySelector('.eye-icon');
            const eyeOffIcon = dom.toggleIngestKey.querySelector('.eye-off-icon');
            if (eyeIcon && eyeOffIcon) {
                eyeIcon.style.display = isPassword ? 'none' : 'block';
                eyeOffIcon.style.display = isPassword ? 'block' : 'none';
            }
        });
    }

    if (dom.logoutBtn) {
        dom.logoutBtn.addEventListener('click', async () => {
            try {
                await fetch(`${API_BASE}/logout`, { method: 'POST' });
            } finally {
                window.location.href = '/admin/login.html';
            }
        });
    }

    bindDestinationEvents(render);
    bindOverlayEvents();
    bindEmbedEvents();
    bindTickerEvents();
}

bindEvents();

ensureSession().then((ok) => {
    if (ok) {
        loadConfig();
        loadMetrics();
        setInterval(loadMetrics, 5000);
        loadHealth();
        setInterval(loadHealth, 5000);
        updateEmbedUi();
        setEmbedStatus('', 'info');
        initPreviewPlayer();
    }
});

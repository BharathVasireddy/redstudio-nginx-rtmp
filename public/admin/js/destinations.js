import { defaultDestinations } from './constants.js';
import { dom } from './dom.js';
import { state } from './state.js';

export function mergeDefaults(destinations) {
    const merged = [];
    const seen = new Set();
    if (Array.isArray(destinations)) {
        destinations.forEach((dest) => {
            merged.push(dest);
            if (dest && dest.id) {
                seen.add(dest.id);
            }
        });
    }
    defaultDestinations.forEach((dest) => {
        if (!seen.has(dest.id)) {
            merged.push({ ...dest });
        }
    });
    return merged;
}

export function renderDestinations() {
    if (!dom.list) {
        return;
    }
    dom.list.innerHTML = '';
    state.destinations.forEach((dest, index) => {
        const row = document.createElement('div');
        row.className = `platform-row${dest.enabled ? ' is-enabled' : ''}`;
        row.innerHTML = `
            <div class="platform-header">
                <div class="platform-name">${dest.name || 'Unnamed Platform'}</div>
                <div class="platform-controls">
                    <div class="toggle-group">
                        <label class="toggle-switch">
                            <input type="checkbox" data-index="${index}" data-field="enabled" ${dest.enabled ? 'checked' : ''}>
                            <span class="slider"></span>
                        </label>
                        <span class="toggle-label">${dest.enabled ? 'Enabled' : 'Disabled'}</span>
                    </div>
                    <button class="delete-btn" data-index="${index}" data-name="${dest.name || 'this platform'}" title="Delete platform">
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                            <polyline points="3 6 5 6 21 6"></polyline>
                            <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"></path>
                            <line x1="10" y1="11" x2="10" y2="17"></line>
                            <line x1="14" y1="11" x2="14" y2="17"></line>
                        </svg>
                    </button>
                </div>
            </div>
            <div class="platform-fields">
                <div class="field">
                    <label>RTMP Server URL</label>
                    <input data-index="${index}" data-field="rtmp_url" value="${dest.rtmp_url || ''}" placeholder="rtmp://example.com/live">
                </div>
                <div class="field">
                    <label>Stream Key</label>
                    <div class="field-input-wrapper">
                        <input type="password" data-index="${index}" data-field="stream_key" value="${dest.stream_key || ''}" placeholder="Enter your stream key" class="platform-stream-key">
                        <button type="button" class="eye-toggle" data-toggle-index="${index}" aria-label="Toggle stream key visibility">
                            <svg class="eye-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                                <path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"></path>
                                <circle cx="12" cy="12" r="3"></circle>
                            </svg>
                            <svg class="eye-off-icon" style="display: none;" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                                <path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19m-6.72-1.07a3 3 0 1 1-4.24-4.24"></path>
                                <line x1="1" y1="1" x2="23" y2="23"></line>
                            </svg>
                        </button>
                    </div>
                </div>
            </div>
        `;
        dom.list.appendChild(row);
    });
}

export function updateFromInputs(event, onRender) {
    const target = event.target;
    const index = Number(target.dataset.index);
    const field = target.dataset.field;
    if (Number.isNaN(index) || !field) {
        return;
    }
    if (field === 'enabled') {
        state.destinations[index][field] = target.checked;
        if (onRender) {
            onRender();
        }
        return;
    }
    state.destinations[index][field] = target.value;
}

export function removeItem(event, onRender) {
    if (!event.target.closest('.delete-btn')) {
        return;
    }
    const btn = event.target.closest('.delete-btn');
    const label = btn.dataset.name || 'this platform';
    if (!confirm(`Delete ${label}?`)) {
        return;
    }
    const index = Number(btn.dataset.index);
    state.destinations.splice(index, 1);
    if (onRender) {
        onRender();
    }
}

function handleStreamKeyToggle(event) {
    const toggleBtn = event.target.closest('.eye-toggle[data-toggle-index]');
    if (!toggleBtn || !dom.list) {
        return;
    }
    const index = toggleBtn.dataset.toggleIndex;
    const input = dom.list.querySelector(`input[data-index="${index}"][data-field="stream_key"]`);
    if (!input) {
        return;
    }
    const isPassword = input.type === 'password';
    input.type = isPassword ? 'text' : 'password';
    const eyeIcon = toggleBtn.querySelector('.eye-icon');
    const eyeOffIcon = toggleBtn.querySelector('.eye-off-icon');
    if (eyeIcon && eyeOffIcon) {
        eyeIcon.style.display = isPassword ? 'none' : 'block';
        eyeOffIcon.style.display = isPassword ? 'block' : 'none';
    }
}

export function bindDestinationEvents(onRender) {
    if (!dom.list) {
        return;
    }
    dom.list.addEventListener('input', (event) => updateFromInputs(event, onRender));
    dom.list.addEventListener('change', (event) => updateFromInputs(event, onRender));
    dom.list.addEventListener('click', (event) => removeItem(event, onRender));
    dom.list.addEventListener('click', handleStreamKeyToggle);
}

import { API_BASE, overlayDefaults, overlayMaxCount } from './constants.js';
import { dom } from './dom.js';
import { state } from './state.js';
import { getErrorMessage, showToast } from './utils.js';

const accordionState = new Map();

function showConfirmModal(title, message, onConfirm) {
    const modalOverlay = document.createElement('div');
    modalOverlay.className = 'modal-overlay';
    modalOverlay.innerHTML = `
        <div class="modal-content">
            <div class="modal-icon">
                <svg fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"/>
                </svg>
            </div>
            <div class="modal-title">${title}</div>
            <div class="modal-message">${message}</div>
            <div class="modal-actions">
                <button class="btn btn-secondary modal-cancel">Cancel</button>
                <button class="btn btn-primary modal-confirm">Delete</button>
            </div>
        </div>
    `;
    document.body.appendChild(modalOverlay);

    const handleConfirm = () => {
        modalOverlay.remove();
        if (onConfirm) {
            onConfirm();
        }
    };

    const handleCancel = () => {
        modalOverlay.remove();
    };

    modalOverlay.querySelector('.modal-confirm').addEventListener('click', handleConfirm);
    modalOverlay.querySelector('.modal-cancel').addEventListener('click', handleCancel);
    modalOverlay.addEventListener('click', (e) => {
        if (e.target === modalOverlay) {
            handleCancel();
        }
    });
    setTimeout(() => modalOverlay.classList.remove('hidden'), 10);
}

function cleanupAccordionState(overlayIds) {
    for (const key of accordionState.keys()) {
        if (!overlayIds.has(key)) {
            accordionState.delete(key);
        }
    }
}

function getCollapsedState(overlayId, index) {
    if (accordionState.has(overlayId)) {
        return accordionState.get(overlayId);
    }
    return true;
}

function setCollapsed(item, overlayId, collapsed) {
    if (!item || !overlayId) {
        return;
    }
    item.classList.toggle('overlay-collapsed', collapsed);
    accordionState.set(overlayId, collapsed);
    const toggleBtn = item.querySelector('[data-action="toggle-overlay"]');
    if (toggleBtn) {
        toggleBtn.setAttribute('aria-expanded', collapsed ? 'false' : 'true');
        toggleBtn.setAttribute('aria-label', collapsed ? 'Expand overlay' : 'Collapse overlay');
    }
}

function collapseOtherOverlays(activeId) {
    if (!dom.overlayList) {
        return;
    }
    dom.overlayList.querySelectorAll('.overlay-item').forEach((item) => {
        const id = item.dataset.overlayId;
        if (id && id !== activeId) {
            setCollapsed(item, id, true);
        }
    });
}

function generateOverlayId() {
    const bytes = new Uint8Array(4);
    window.crypto.getRandomValues(bytes);
    return Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
}

export function normalizeOverlayItem(raw) {
    const overlay = { ...overlayDefaults, ...(raw || {}) };
    const positions = [
        'top-left',
        'top-right',
        'bottom-left',
        'bottom-right',
        'center',
        'top-center',
        'bottom-center',
        'center-left',
        'center-right',
        'custom'
    ];

    if (!overlay.id || typeof overlay.id !== 'string') {
        overlay.id = generateOverlayId();
    }
    overlay.position = positions.includes(overlay.position) ? overlay.position : overlayDefaults.position;
    overlay.size_mode = overlay.size_mode === 'px' ? 'px' : 'percent';

    const offsetX = Number(overlay.offset_x);
    const offsetY = Number(overlay.offset_y);
    overlay.offset_x = Number.isFinite(offsetX) ? Math.min(2000, Math.max(0, offsetX)) : overlayDefaults.offset_x;
    overlay.offset_y = Number.isFinite(offsetY) ? Math.min(2000, Math.max(0, offsetY)) : overlayDefaults.offset_y;

    const sizeValue = Number(overlay.size_value);
    if (Number.isFinite(sizeValue)) {
        if (overlay.size_mode === 'px') {
            overlay.size_value = Math.min(2000, Math.max(16, sizeValue));
        } else {
            overlay.size_value = Math.min(100, Math.max(1, sizeValue));
        }
    } else {
        overlay.size_value = overlayDefaults.size_value;
    }

    const opacityValue = Number(overlay.opacity);
    overlay.opacity = Number.isFinite(opacityValue) ? Math.min(1, Math.max(0, opacityValue)) : overlayDefaults.opacity;

    const rotateValue = Number(overlay.rotate);
    overlay.rotate = Number.isFinite(rotateValue) ? Math.min(180, Math.max(-180, rotateValue)) : overlayDefaults.rotate;
    overlay.image_file = typeof overlay.image_file === 'string' ? overlay.image_file : '';
    overlay.enabled = Boolean(overlay.enabled);

    return overlay;
}

export function normalizeOverlays(raw, options = {}) {
    let overlays = [];
    if (Array.isArray(raw)) {
        overlays = raw;
    } else if (raw && typeof raw === 'object') {
        overlays = [raw];
    }
    overlays = overlays.map(normalizeOverlayItem);
    if (overlays.length === 0) {
        if (options.allowEmpty) {
            return [];
        }
        overlays = [normalizeOverlayItem({})];
    }
    return overlays.slice(0, overlayMaxCount);
}

function setOverlayStatus(item, message, type = 'info') {
    const status = item ? item.querySelector('[data-field="status"]') : null;
    if (!status) {
        return;
    }
    status.textContent = message;
    status.className = `status ${type}`;
}

function updateOverlayToggleLabel(item, overlay) {
    const labels = item ? item.querySelectorAll('[data-field="toggle-label"]') : [];
    labels.forEach((label) => {
        label.textContent = overlay.enabled ? 'Overlay enabled' : 'Overlay disabled';
    });

    if (item) {
        item.classList.toggle('overlay-enabled', overlay.enabled);
        item.classList.toggle('overlay-disabled', !overlay.enabled);
    }
}

function updateOverlaySizeLabel(item, overlay) {
    const label = item ? item.querySelector('[data-field="size-label"]') : null;
    const sizeInput = item ? item.querySelector('[data-field="size-value"]') : null;
    if (!label || !sizeInput) {
        return;
    }
    if (overlay.size_mode === 'px') {
        label.textContent = 'Width (px)';
        sizeInput.min = '16';
        sizeInput.max = '2000';
    } else {
        label.textContent = 'Size (% of width)';
        sizeInput.min = '1';
        sizeInput.max = '100';
    }
}

function updateOverlayFileName(item, overlay) {
    const label = item ? item.querySelector('[data-field="file-name"]') : null;
    if (!label) {
        return;
    }
    const input = item.querySelector('[data-field="image-input"]');
    const selected = input && input.files && input.files[0] ? input.files[0].name : '';
    const current = overlay.image_file ? `Current: ${overlay.image_file}` : 'No image uploaded';
    label.textContent = selected ? `${current} | Selected: ${selected}` : current;

    const pathLabel = item ? item.querySelector('[data-field="public-path"]') : null;
    if (pathLabel) {
        pathLabel.textContent = overlay.image_file
            ? `Public path: ${buildOverlayUrl(overlay.image_file)}`
            : 'Public path: --';
    }
}

function updateOverlaySummary(item, overlay) {
    const summary = item ? item.querySelector('[data-field="summary"]') : null;
    if (!summary) {
        return;
    }
    summary.innerHTML = '';
    const sizeText = overlay.size_mode === 'px'
        ? `${overlay.size_value}px`
        : `${overlay.size_value}%`;
    const imageText = overlay.image_file ? overlay.image_file : 'none';
    const parts = [
        `Image: ${imageText}`,
        `Size: ${sizeText}`,
        `Position: ${overlay.position}`,
        `Offset: ${overlay.offset_x}x${overlay.offset_y}`,
        `Opacity: ${Math.round(overlay.opacity * 100)}%`,
        `Rotate: ${overlay.rotate}deg`
    ];
    parts.forEach((text) => {
        const chip = document.createElement('span');
        chip.className = 'overlay-chip';
        chip.textContent = text;
        summary.appendChild(chip);
    });
}

function setPreviewSource(preview, placeholder, src, container, onDone) {
    if (!preview || !placeholder) {
        return;
    }
    if (!src) {
        preview.style.display = 'none';
        placeholder.style.display = 'flex';
        if (container) {
            container.classList.remove('has-image');
        }
        if (onDone) {
            onDone();
        }
        return;
    }
    preview.onload = () => {
        preview.style.display = 'block';
        placeholder.style.display = 'none';
        if (container) {
            container.classList.add('has-image');
        }
        if (onDone) {
            onDone();
        }
    };
    preview.onerror = () => {
        preview.style.display = 'none';
        placeholder.style.display = 'flex';
        if (container) {
            container.classList.remove('has-image');
        }
        if (onDone) {
            onDone();
        }
    };
    preview.src = src;
}

function buildOverlayUrl(filename) {
    return `/admin/overlays/${encodeURIComponent(filename)}`;
}

function refreshOverlayPreview(item, overlay) {
    const preview = item ? item.querySelector('[data-field="preview"]') : null;
    const placeholder = item ? item.querySelector('[data-field="preview-placeholder"]') : null;
    const thumb = item ? item.querySelector('[data-field="preview-thumb"]') : null;
    const thumbPlaceholder = item ? item.querySelector('[data-field="preview-thumb-placeholder"]') : null;
    const previewContainer = preview ? preview.closest('.overlay-preview') : null;
    const thumbContainer = thumb ? thumb.closest('.overlay-thumb') : null;
    if (!overlay.image_file) {
        setPreviewSource(preview, placeholder, '', previewContainer);
        setPreviewSource(thumb, thumbPlaceholder, '', thumbContainer);
        return;
    }
    const src = `${buildOverlayUrl(overlay.image_file)}?v=${Date.now()}`;
    setPreviewSource(preview, placeholder, src, previewContainer);
    setPreviewSource(thumb, thumbPlaceholder, src, thumbContainer);
}

export function renderOverlays() {
    if (!dom.overlayList) {
        return;
    }
    state.overlays = normalizeOverlays(state.overlays, { allowEmpty: true });
    const overlayIds = new Set(state.overlays.map((overlay) => overlay.id));
    cleanupAccordionState(overlayIds);
    dom.overlayList.innerHTML = '';
    if (state.overlays.length === 0) {
        const empty = document.createElement('div');
        empty.className = 'overlay-empty';
        empty.innerHTML = `
            <div class="overlay-empty-title">No overlays yet</div>
            <div class="overlay-empty-subtitle">Add an overlay to brand your stream output.</div>
        `;
        dom.overlayList.appendChild(empty);
    }
    state.overlays.forEach((overlay, index) => {
        const item = document.createElement('div');
        item.className = `overlay-item ${overlay.enabled ? 'overlay-enabled' : 'overlay-disabled'}`;
        item.dataset.overlayId = overlay.id;
        const opacityValue = Math.round(overlay.opacity * 100);
        item.innerHTML = `
            <div class="overlay-item-header" data-action="header-click">
                <div class="overlay-item-title">
                    <span class="overlay-item-badge">${index + 1}</span>
                    <div class="overlay-thumb">
                        <img data-field="preview-thumb" alt="Overlay thumbnail" style="display: none;">
                        <span class="overlay-thumb-placeholder" data-field="preview-thumb-placeholder">No image</span>
                    </div>
                    <div class="overlay-title-stack">
                        <div class="overlay-title">Overlay ${index + 1}</div>
                        <div class="overlay-status-label" data-field="toggle-label"></div>
                    </div>
                </div>
                <div class="overlay-item-actions">
                    <div class="overlay-header-toggle" data-action="toggle-enabled">
                        <label class="toggle-switch">
                            <input type="checkbox" data-field="enabled" ${overlay.enabled ? 'checked' : ''}>
                            <span class="slider"></span>
                        </label>
                        <span class="overlay-header-toggle-label">Enabled</span>
                    </div>
                    <button class="accordion-toggle-btn" type="button" data-action="toggle-overlay" aria-expanded="true" aria-label="Collapse overlay">
                        <svg fill="none" stroke="currentColor" viewBox="0 0 24 24">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"/>
                        </svg>
                    </button>
                    <button class="delete-btn" type="button" data-action="remove-overlay" aria-label="Delete overlay">
                        <svg fill="none" stroke="currentColor" viewBox="0 0 24 24">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/>
                        </svg>
                    </button>
                </div>
            </div>
            <div class="overlay-summary" data-field="summary"></div>
            <div class="overlay-body">
                <div class="overlay-grid">
                <div class="overlay-left-panel">
                    <div class="overlay-field-group">
                        <div class="overlay-section-title">Image & Upload</div>
                        <div class="overlay-preview">
                            <img data-field="preview" alt="Overlay preview" style="display: none;">
                            <span class="overlay-preview-placeholder" data-field="preview-placeholder">No image uploaded</span>
                        </div>
                        <div class="overlay-file-row">
                            <label class="overlay-file-pill">
                                <input type="file" data-field="image-input" accept="image/png,image/jpeg,image/webp">
                                <span>Choose image</span>
                            </label>
                            <div class="overlay-file-meta">
                                <div class="overlay-file-name" data-field="file-name"></div>
                                <div class="overlay-public-path" data-field="public-path"></div>
                            </div>
                        </div>
                        <div class="overlay-actions">
                            <button class="btn btn-primary" type="button" data-action="upload-image">Upload</button>
                            <button class="btn btn-secondary" type="button" data-action="clear-image">Remove</button>
                        </div>
                        <div class="status" data-field="status" style="margin-top: 0.75rem;"></div>
                    </div>
                </div>
                <div class="overlay-config-section">
                    <div class="overlay-field-group">
                        <div class="overlay-section-title">Position & Transform</div>
                        <div class="field">
                            <label>Position</label>
                            <select data-field="position">
                                <option value="top-left" ${overlay.position === 'top-left' ? 'selected' : ''}>Top Left</option>
                                <option value="top-center" ${overlay.position === 'top-center' ? 'selected' : ''}>Top Center</option>
                                <option value="top-right" ${overlay.position === 'top-right' ? 'selected' : ''}>Top Right</option>
                                <option value="center-left" ${overlay.position === 'center-left' ? 'selected' : ''}>Center Left</option>
                                <option value="center" ${overlay.position === 'center' ? 'selected' : ''}>Center</option>
                                <option value="center-right" ${overlay.position === 'center-right' ? 'selected' : ''}>Center Right</option>
                                <option value="bottom-left" ${overlay.position === 'bottom-left' ? 'selected' : ''}>Bottom Left</option>
                                <option value="bottom-center" ${overlay.position === 'bottom-center' ? 'selected' : ''}>Bottom Center</option>
                                <option value="bottom-right" ${overlay.position === 'bottom-right' ? 'selected' : ''}>Bottom Right</option>
                                <option value="custom" ${overlay.position === 'custom' ? 'selected' : ''}>Custom (X/Y)</option>
                            </select>
                        </div>
                        <div class="platform-fields" style="grid-template-columns: 1fr 1fr; margin-top: 1rem;">
                            <div class="field">
                                <label>Offset X (px)</label>
                                <input data-field="offset_x" type="number" min="0" max="2000" value="${overlay.offset_x}">
                            </div>
                            <div class="field">
                                <label>Offset Y (px)</label>
                                <input data-field="offset_y" type="number" min="0" max="2000" value="${overlay.offset_y}">
                            </div>
                        </div>
                        <div class="field" style="margin-top: 1rem;">
                            <label>Rotate (deg)</label>
                            <input data-field="rotate" type="number" min="-180" max="180" value="${overlay.rotate}">
                        </div>
                    </div>
                    <div class="overlay-field-group">
                        <div class="overlay-section-title">Size & Appearance</div>
                        <div class="field">
                            <label>Size Mode</label>
                            <select data-field="size_mode">
                                <option value="percent" ${overlay.size_mode === 'percent' ? 'selected' : ''}>Percent of Video Width</option>
                                <option value="px" ${overlay.size_mode === 'px' ? 'selected' : ''}>Fixed Width (px)</option>
                            </select>
                        </div>
                        <div class="field" style="margin-top: 1rem;">
                            <label data-field="size-label">Size (% of width)</label>
                            <input data-field="size-value" type="number" min="1" max="100" step="1" value="${overlay.size_value}">
                        </div>
                        <div class="field" style="margin-top: 1rem;">
                            <label>Opacity</label>
                            <div class="overlay-slider">
                                <input data-field="opacity" type="range" min="0" max="100" step="1" value="${opacityValue}">
                                <span data-field="opacity-value">${opacityValue}%</span>
                            </div>
                        </div>
                    </div>
                </div>
                </div>
            </div>
        `;
        dom.overlayList.appendChild(item);
        updateOverlayToggleLabel(item, overlay);
        updateOverlaySizeLabel(item, overlay);
        updateOverlayFileName(item, overlay);
        updateOverlaySummary(item, overlay);
        refreshOverlayPreview(item, overlay);
        setCollapsed(item, overlay.id, getCollapsedState(overlay.id, index));
    });

    if (dom.overlayAddBtn) {
        dom.overlayAddBtn.disabled = state.overlays.length >= overlayMaxCount;
    }
    if (dom.overlayLimitNote) {
        const limitText = state.overlays.length >= overlayMaxCount
            ? `Maximum of ${overlayMaxCount} overlays reached.`
            : `You can add up to ${overlayMaxCount} overlays.`;
        dom.overlayLimitNote.textContent = limitText;
    }
}

async function uploadOverlayImage(overlayId, item) {
    const input = item.querySelector('[data-field="image-input"]');
    if (!input || !input.files || input.files.length === 0) {
        setOverlayStatus(item, 'Choose an image first', 'error');
        return;
    }
    const file = input.files[0];
    if (file.size > 5 * 1024 * 1024) {
        setOverlayStatus(item, 'Image too large (max 5MB)', 'error');
        return;
    }

    setOverlayStatus(item, 'Uploading...', 'info');
    const reader = new FileReader();
    reader.onload = async () => {
        try {
            const res = await fetch(`${API_BASE}/overlay/image`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    data_url: reader.result,
                    overlay_id: overlayId,
                    original_name: file.name
                })
            });

            if (res.status === 401) {
                window.location.href = '/admin/login.html';
                return;
            }
            if (!res.ok) {
                const errorMessage = await getErrorMessage(res);
                setOverlayStatus(item, `Upload failed: ${errorMessage}`, 'error');
                return;
            }

            const payload = await res.json();
            if (payload.image_file) {
                const overlay = state.overlays.find((entry) => entry.id === overlayId);
                if (overlay) {
                    overlay.image_file = payload.image_file;
                }
            }
            setOverlayStatus(item, 'Image uploaded', 'success');
            showToast('Overlay image uploaded', 'success');
            updateOverlayFileName(item, state.overlays.find((entry) => entry.id === overlayId) || overlayDefaults);
            updateOverlaySummary(item, state.overlays.find((entry) => entry.id === overlayId) || overlayDefaults);
            refreshOverlayPreview(item, state.overlays.find((entry) => entry.id === overlayId) || overlayDefaults);
        } catch (err) {
            setOverlayStatus(item, 'Upload failed', 'error');
        }
    };
    reader.readAsDataURL(file);
}

async function clearOverlayImage(overlayId, item) {
    setOverlayStatus(item, 'Removing...', 'info');
    try {
        const res = await fetch(`${API_BASE}/overlay/image`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ action: 'clear', overlay_id: overlayId })
        });
        if (res.status === 401) {
            window.location.href = '/admin/login.html';
            return;
        }
        if (!res.ok) {
            const errorMessage = await getErrorMessage(res);
            setOverlayStatus(item, `Remove failed: ${errorMessage}`, 'error');
            return;
        }
        const overlay = state.overlays.find((entry) => entry.id === overlayId);
        if (overlay) {
            overlay.image_file = '';
            overlay.enabled = false;
        }
        const input = item.querySelector('[data-field="image-input"]');
        if (input) {
            input.value = '';
        }
        setOverlayStatus(item, 'Image removed', 'success');
        showToast('Overlay image removed', 'success');
        updateOverlayToggleLabel(item, overlay || overlayDefaults);
        updateOverlayFileName(item, overlay || overlayDefaults);
        updateOverlaySummary(item, overlay || overlayDefaults);
        refreshOverlayPreview(item, overlay || overlayDefaults);
    } catch (err) {
        setOverlayStatus(item, 'Remove failed', 'error');
    }
}

async function removeOverlayItem(overlayId, item) {
    const index = state.overlays.findIndex((entry) => entry.id === overlayId);
    if (index === -1) {
        return;
    }

    showConfirmModal(
        'Remove Overlay?',
        `Are you sure you want to remove Overlay ${index + 1}? This action cannot be undone.`,
        async () => {
            state.overlays.splice(index, 1);
            accordionState.delete(overlayId);

            try {
                const res = await fetch(`${API_BASE}/overlay/image`, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ action: 'delete', overlay_id: overlayId })
                });
                if (res.status === 401) {
                    window.location.href = '/admin/login.html';
                    return;
                }
            } catch (err) {
                // ignore delete errors
            }

            renderOverlays();
            showToast('Overlay removed', 'success');
        }
    );
}

async function clearAllOverlays() {
    if (!confirm('Clear all overlays?')) {
        return;
    }
    try {
        const res = await fetch(`${API_BASE}/overlay/image`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ action: 'clear' })
        });
        if (res.status === 401) {
            window.location.href = '/admin/login.html';
            return;
        }
        if (!res.ok) {
            const errorMessage = await getErrorMessage(res);
            showToast(`Clear failed: ${errorMessage}`, 'error');
            return;
        }
        state.overlays = [];
        accordionState.clear();
        renderOverlays();
        showToast('All overlays cleared', 'success');
    } catch (err) {
        showToast('Clear failed', 'error');
    }
}

function findOverlayById(id) {
    return state.overlays.find((overlay) => overlay.id === id);
}

function handleOverlayInput(event) {
    const target = event.target;
    const item = target.closest('.overlay-item');
    if (!item) {
        return;
    }
    const overlayId = item.dataset.overlayId;
    const overlay = findOverlayById(overlayId);
    if (!overlay) {
        return;
    }

    const field = target.dataset.field;
    if (!field) {
        return;
    }

    if (field === 'enabled') {
        overlay.enabled = target.checked;
        updateOverlayToggleLabel(item, overlay);
        updateOverlaySummary(item, overlay);
        return;
    }
    if (field === 'position') {
        overlay.position = target.value;
        updateOverlaySummary(item, overlay);
        return;
    }
    if (field === 'offset_x') {
        overlay.offset_x = Number(target.value);
        updateOverlaySummary(item, overlay);
        return;
    }
    if (field === 'offset_y') {
        overlay.offset_y = Number(target.value);
        updateOverlaySummary(item, overlay);
        return;
    }
    if (field === 'rotate') {
        overlay.rotate = Number(target.value);
        updateOverlaySummary(item, overlay);
        return;
    }
    if (field === 'size_mode') {
        overlay.size_mode = target.value;
        updateOverlaySizeLabel(item, overlay);
        updateOverlaySummary(item, overlay);
        return;
    }
    if (field === 'size-value') {
        overlay.size_value = Number(target.value);
        updateOverlaySummary(item, overlay);
        return;
    }
    if (field === 'opacity') {
        const value = Number(target.value);
        overlay.opacity = Number.isFinite(value) ? value / 100 : overlay.opacity;
        const label = item.querySelector('[data-field="opacity-value"]');
        if (label) {
            label.textContent = `${target.value}%`;
        }
        updateOverlaySummary(item, overlay);
        return;
    }
    if (field === 'image-input') {
        const preview = item.querySelector('[data-field="preview"]');
        const placeholder = item.querySelector('[data-field="preview-placeholder"]');
        const thumb = item.querySelector('[data-field="preview-thumb"]');
        const thumbPlaceholder = item.querySelector('[data-field="preview-thumb-placeholder"]');
        const previewContainer = preview ? preview.closest('.overlay-preview') : null;
        const thumbContainer = thumb ? thumb.closest('.overlay-thumb') : null;
        if (target.files && target.files[0]) {
            const objectUrl = URL.createObjectURL(target.files[0]);
            let pending = 0;
            const done = () => {
                pending -= 1;
                if (pending <= 0) {
                    URL.revokeObjectURL(objectUrl);
                }
            };
            const targets = [
                [preview, placeholder, previewContainer],
                [thumb, thumbPlaceholder, thumbContainer]
            ];
            targets.forEach(([img, placeholderEl, container]) => {
                if (!img || !placeholderEl) {
                    return;
                }
                pending += 1;
                setPreviewSource(img, placeholderEl, objectUrl, container, done);
            });
            if (pending === 0) {
                URL.revokeObjectURL(objectUrl);
            }
        } else {
            setPreviewSource(preview, placeholder, '', previewContainer);
            setPreviewSource(thumb, thumbPlaceholder, '', thumbContainer);
        }
        updateOverlayFileName(item, overlay);
        updateOverlaySummary(item, overlay);
    }
}

function handleOverlayAction(event) {
    const actionBtn = event.target.closest('[data-action]');
    if (!actionBtn) {
        return;
    }
    const item = actionBtn.closest('.overlay-item');
    if (!item) {
        return;
    }
    const overlayId = item.dataset.overlayId;
    const action = actionBtn.dataset.action;
    if (action === 'upload-image') {
        uploadOverlayImage(overlayId, item);
    } else if (action === 'clear-image') {
        clearOverlayImage(overlayId, item);
    } else if (action === 'toggle-overlay') {
        event.stopPropagation();
        const collapsed = item.classList.contains('overlay-collapsed');
        setCollapsed(item, overlayId, !collapsed);
        if (collapsed) {
            collapseOtherOverlays(overlayId);
        }
    } else if (action === 'toggle-enabled') {
        event.stopPropagation();
    } else if (action === 'header-click') {
        const collapsed = item.classList.contains('overlay-collapsed');
        setCollapsed(item, overlayId, !collapsed);
        if (collapsed) {
            collapseOtherOverlays(overlayId);
        }
    } else if (action === 'remove-overlay') {
        event.stopPropagation();
        removeOverlayItem(overlayId, item);
    }
}

export function bindOverlayEvents() {
    if (dom.overlayAddBtn) {
        dom.overlayAddBtn.addEventListener('click', () => {
            if (state.overlays.length >= overlayMaxCount) {
                showToast(`Maximum of ${overlayMaxCount} overlays reached`, 'error');
                return;
            }
            const newOverlay = normalizeOverlayItem({});
            state.overlays.push(newOverlay);
            accordionState.set(newOverlay.id, false);
            renderOverlays();
            collapseOtherOverlays(newOverlay.id);
        });
    }
    if (dom.overlayClearBtn) {
        dom.overlayClearBtn.addEventListener('click', () => {
            clearAllOverlays();
        });
    }
    if (dom.overlayList) {
        dom.overlayList.addEventListener('input', handleOverlayInput);
        dom.overlayList.addEventListener('change', handleOverlayInput);
        dom.overlayList.addEventListener('click', handleOverlayAction);
    }
}

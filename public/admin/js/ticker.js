import {
    tickerDefaults,
    tickerSpeedRange,
    tickerFontRange,
    tickerHeightRange,
    tickerMaxItems,
    tickerTextLimit
} from './constants.js';
import { dom } from './dom.js';
import { state } from './state.js';
import { showToast } from './utils.js';

const PREVIEW_EMPTY = 'Add a message to preview the scrolling ticker.';
const COLOR_RE = /^#(?:[0-9a-f]{3}|[0-9a-f]{6})$/i;
const SEPARATOR_PRESETS = ['•', '.', '|', '//', '-', 'custom'];
const BLOCK_TAGS = new Set(['DIV', 'P', 'BR', 'LI']);

let activeItemId = null;

function clampSpeed(value) {
    const number = Number(value);
    if (!Number.isFinite(number)) {
        return tickerDefaults.speed;
    }
    return Math.min(tickerSpeedRange.max, Math.max(tickerSpeedRange.min, Math.round(number)));
}

function clampFontSize(value) {
    const number = Number(value);
    if (!Number.isFinite(number)) {
        return tickerDefaults.font_size;
    }
    return Math.min(tickerFontRange.max, Math.max(tickerFontRange.min, Math.round(number)));
}

function clampHeight(value) {
    const number = Number(value);
    if (!Number.isFinite(number)) {
        return tickerDefaults.height;
    }
    return Math.min(tickerHeightRange.max, Math.max(tickerHeightRange.min, Math.round(number)));
}

function generateTickerId() {
    const bytes = new Uint8Array(4);
    window.crypto.getRandomValues(bytes);
    return Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
}

function sanitizeColor(value) {
    if (!value) {
        return '';
    }
    const cleaned = String(value).trim();
    if (!cleaned) {
        return '';
    }
    return COLOR_RE.test(cleaned) ? cleaned : '';
}

function sanitizeSeparator(value) {
    if (value === null || value === undefined) {
        return '';
    }
    let cleaned = String(value).replace(/\s+/g, ' ').trim();
    if (!cleaned) {
        return '';
    }
    if (cleaned.length > 6) {
        cleaned = cleaned.slice(0, 6).trim();
    }
    return cleaned;
}

function escapeHtml(value) {
    return String(value)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

function sanitizeHtmlInput(html) {
    const container = document.createElement('div');
    container.innerHTML = html;
    const parts = [];

    function walk(node) {
        if (node.nodeType === Node.TEXT_NODE) {
            parts.push(escapeHtml(node.textContent));
            return;
        }
        if (node.nodeType !== Node.ELEMENT_NODE) {
            return;
        }
        const tag = node.tagName;
        if (tag === 'BR') {
            parts.push(' ');
            return;
        }
        const normalized = tag === 'B' ? 'strong' : tag === 'I' ? 'em' : tag.toLowerCase();
        const isAllowed = normalized === 'strong' || normalized === 'em';
        if (isAllowed) {
            parts.push(`<${normalized}>`);
        }
        node.childNodes.forEach(walk);
        if (isAllowed) {
            parts.push(`</${normalized}>`);
        }
        if (!isAllowed && BLOCK_TAGS.has(tag)) {
            parts.push(' ');
        }
    }

    container.childNodes.forEach(walk);
    const htmlOut = parts.join('').replace(/\s{2,}/g, ' ').trim();
    const text = container.textContent.replace(/\s+/g, ' ').trim();
    return { html: htmlOut, text };
}

function normalizeTickerItem(raw, fallbackId) {
    const item = raw && typeof raw === 'object' ? raw : {};
    const id = typeof item.id === 'string' && item.id ? item.id : fallbackId;
    const htmlRaw = typeof item.html === 'string' ? item.html : '';
    const textRaw = typeof item.text === 'string' ? item.text : '';
    const bold = Boolean(item.bold);
    let html = '';
    let text = '';

    if (htmlRaw) {
        const sanitized = sanitizeHtmlInput(htmlRaw);
        html = sanitized.html;
        text = sanitized.text;
    }

    if (!text && textRaw) {
        text = textRaw.replace(/\r?\n/g, ' ').trim();
    }

    if (!html && text) {
        const safeText = escapeHtml(text);
        html = bold ? `<strong>${safeText}</strong>` : safeText;
    }

    return { id, text, html };
}

export function normalizeTicker(raw) {
    const source = raw && typeof raw === 'object' ? raw : {};
    const enabled = Boolean(source.enabled);
    let text = typeof source.text === 'string' ? source.text : '';
    text = text.replace(/\r?\n/g, ' ').trim();
    const speed = clampSpeed(source.speed);
    const fontSize = clampFontSize(source.font_size ?? source.fontSize);
    const height = clampHeight(source.height);
    const background = sanitizeColor(source.background);
    const separator = sanitizeSeparator(source.separator) || tickerDefaults.separator;
    let items = [];
    if (Array.isArray(source.items)) {
        items = source.items;
    } else if (text) {
        items = [{ text, bold: false }];
    }
    items = items
        .map((item) => normalizeTickerItem(item, generateTickerId()))
        .filter((item) => item.text);

    if (!text && items.length) {
        text = items.map((item) => item.text).join(` ${separator} `);
    }

    return {
        enabled,
        text,
        speed,
        font_size: fontSize,
        height,
        background,
        separator,
        items
    };
}

function updateTickerSpeedLabel() {
    if (!dom.tickerSpeedValue) {
        return;
    }
    dom.tickerSpeedValue.textContent = `${state.ticker.speed}s`;
}

function updateTickerFontSizeLabel() {
    if (!dom.tickerFontSizeValue) {
        return;
    }
    dom.tickerFontSizeValue.textContent = `${state.ticker.font_size}px`;
}

function updateTickerHeightLabel() {
    if (!dom.tickerHeightValue) {
        return;
    }
    dom.tickerHeightValue.textContent = `${state.ticker.height}px`;
}

function updateTickerToggleLabel() {
    if (!dom.tickerLabel) {
        return;
    }
    dom.tickerLabel.textContent = state.ticker.enabled ? 'Ticker enabled' : 'Ticker disabled';
}

function syncBackgroundInputs() {
    if (!dom.tickerBgColor && !dom.tickerBgInput) {
        return;
    }
    const color = state.ticker.background || '#0f172a';
    if (dom.tickerBgColor) {
        dom.tickerBgColor.value = color;
    }
    if (dom.tickerBgInput) {
        dom.tickerBgInput.value = state.ticker.background || '';
    }
}

function syncSeparatorInputs() {
    if (!dom.tickerSeparatorSelect || !dom.tickerSeparatorInput) {
        return;
    }
    const current = state.ticker.separator || tickerDefaults.separator;
    const presetValues = SEPARATOR_PRESETS.filter((value) => value !== 'custom');
    const preset = presetValues.includes(current) ? current : 'custom';
    dom.tickerSeparatorSelect.value = preset;
    const isCustom = preset === 'custom';
    dom.tickerSeparatorInput.disabled = !isCustom;
    dom.tickerSeparatorInput.value = isCustom ? current : '';
}

function updateCharCount() {
    if (!dom.tickerCharCount || !dom.tickerEditor) {
        return;
    }
    const length = dom.tickerEditor.textContent.replace(/\s+/g, ' ').trim().length;
    dom.tickerCharCount.textContent = `${length} chars (recommended ${tickerTextLimit})`;
    const meta = dom.tickerCharCount.parentElement;
    if (meta) {
        meta.classList.toggle('is-over', length > tickerTextLimit);
    }
}

function updateTickerOffset() {
    if (!dom.tickerPreviewBar || !dom.tickerPreviewTrack || !dom.tickerPreviewPrimary) {
        return;
    }
    const itemWidth = dom.tickerPreviewPrimary.getBoundingClientRect().width;
    const containerWidth = dom.tickerPreviewBar.getBoundingClientRect().width;
    const computed = window.getComputedStyle(dom.tickerPreviewTrack);
    const gap = parseFloat(computed.columnGap || computed.gap || '32') || 32;
    const offset = Math.max(itemWidth + gap, containerWidth + gap);
    dom.tickerPreviewTrack.style.setProperty('--ticker-offset', `${offset}px`);
}

function updateTickerPreviewVisibility(enabled, hasContent) {
    if (!dom.tickerPreview) {
        return;
    }
    dom.tickerPreview.classList.toggle('is-empty', !hasContent);
    dom.tickerPreview.classList.toggle('is-disabled', !enabled);
    if (!hasContent && dom.tickerPreviewPlaceholder) {
        dom.tickerPreviewPlaceholder.textContent = PREVIEW_EMPTY;
    }
}

function buildTickerMarkup(items, separator) {
    const parts = [];
    items.forEach((item) => {
        if (!item || (!item.text && !item.html)) {
            return;
        }
        if (item.html) {
            const sanitized = sanitizeHtmlInput(item.html);
            if (sanitized.html) {
                parts.push(sanitized.html);
            }
            return;
        }
        const text = item.text || '';
        const safeText = escapeHtml(text);
        if (item.bold) {
            parts.push(`<strong class="ticker-preview-strong">${safeText}</strong>`);
        } else {
            parts.push(`<span class="ticker-preview-text">${safeText}</span>`);
        }
    });
    if (!parts.length) {
        return '';
    }
    const safeSep = escapeHtml(separator || tickerDefaults.separator);
    const sepMarkup = `<span class="ticker-preview-sep">${safeSep}</span>`;
    return parts.join(sepMarkup) + sepMarkup;
}

function formatMetaLabel(html) {
    const hasBold = /<strong|<b/i.test(html);
    const hasItalic = /<em|<i/i.test(html);
    if (hasBold && hasItalic) {
        return 'Bold + Italic';
    }
    if (hasBold) {
        return 'Bold';
    }
    if (hasItalic) {
        return 'Italic';
    }
    return 'Regular';
}

function renderTickerItems() {
    if (!dom.tickerItems) {
        return;
    }
    dom.tickerItems.innerHTML = '';
    if (!state.ticker.items || state.ticker.items.length === 0) {
        const empty = document.createElement('div');
        empty.className = 'ticker-items-empty';
        empty.textContent = 'No ticker messages yet. Add a message to start scrolling.';
        dom.tickerItems.appendChild(empty);
        return;
    }

    state.ticker.items.forEach((item, index) => {
        const row = document.createElement('div');
        row.className = 'ticker-item-row';
        row.dataset.id = item.id;

        const head = document.createElement('div');
        head.className = 'ticker-item-head';

        const label = document.createElement('div');
        label.className = 'ticker-item-label';
        label.textContent = `Message ${index + 1}`;

        const actions = document.createElement('div');
        actions.className = 'ticker-item-actions';

        const formatTag = document.createElement('span');
        formatTag.className = 'ticker-item-meta';
        formatTag.textContent = formatMetaLabel(item.html || '');

        const editBtn = document.createElement('button');
        editBtn.type = 'button';
        editBtn.className = 'btn btn-secondary btn-small';
        editBtn.dataset.action = 'edit';
        editBtn.textContent = 'Edit';

        const removeBtn = document.createElement('button');
        removeBtn.type = 'button';
        removeBtn.className = 'btn btn-secondary btn-small';
        removeBtn.dataset.action = 'remove';
        removeBtn.textContent = 'Remove';

        actions.appendChild(formatTag);
        actions.appendChild(editBtn);
        actions.appendChild(removeBtn);
        head.appendChild(label);
        head.appendChild(actions);

        const body = document.createElement('div');
        body.className = 'ticker-item-body';
        body.textContent = item.text || '';

        row.appendChild(head);
        row.appendChild(body);
        dom.tickerItems.appendChild(row);
    });
}

function openModal(item) {
    if (!dom.tickerModal || !dom.tickerEditor) {
        return;
    }
    activeItemId = item ? item.id : null;
    if (dom.tickerModalTitle) {
        dom.tickerModalTitle.textContent = item ? 'Edit ticker message' : 'Add ticker message';
    }
    dom.tickerEditor.innerHTML = '';
    if (item && item.html) {
        dom.tickerEditor.innerHTML = item.html;
    } else if (item && item.text) {
        dom.tickerEditor.textContent = item.text;
    }
    updateCharCount();
    dom.tickerModal.classList.remove('hidden');
    dom.tickerModal.setAttribute('aria-hidden', 'false');
    dom.tickerEditor.focus();
}

function closeModal() {
    if (!dom.tickerModal) {
        return;
    }
    dom.tickerModal.classList.add('hidden');
    dom.tickerModal.setAttribute('aria-hidden', 'true');
    activeItemId = null;
}

function insertEmoji(emoji) {
    if (!dom.tickerEditor) {
        return;
    }
    const selection = window.getSelection();
    if (!selection || selection.rangeCount === 0) {
        dom.tickerEditor.textContent += emoji;
        return;
    }
    const range = selection.getRangeAt(0);
    range.deleteContents();
    const node = document.createTextNode(emoji);
    range.insertNode(node);
    range.setStartAfter(node);
    range.setEndAfter(node);
    selection.removeAllRanges();
    selection.addRange(range);
    dom.tickerEditor.focus();
}

function applyFormat(command) {
    if (!dom.tickerEditor) {
        return;
    }
    document.execCommand(command);
    dom.tickerEditor.focus();
}

function saveModal() {
    if (!dom.tickerEditor) {
        return;
    }
    const sanitized = sanitizeHtmlInput(dom.tickerEditor.innerHTML);
    if (!sanitized.text) {
        showToast('Ticker message cannot be empty.', 'error');
        return;
    }
    if (!state.ticker.items) {
        state.ticker.items = [];
    }
    if (activeItemId) {
        const item = state.ticker.items.find((entry) => entry.id === activeItemId);
        if (item) {
            item.text = sanitized.text;
            item.html = sanitized.html;
        }
    } else {
        state.ticker.items.push({
            id: generateTickerId(),
            text: sanitized.text,
            html: sanitized.html
        });
        if (state.ticker.items.length > tickerMaxItems) {
            showToast(`Recommended: keep ticker to ${tickerMaxItems} messages or fewer.`, 'info');
        }
    }
    renderTickerItems();
    updateTickerPreview();
    closeModal();
}

export function renderTicker() {
    if (!state.ticker) {
        state.ticker = { ...tickerDefaults };
    }

    if (dom.tickerToggle) {
        dom.tickerToggle.checked = state.ticker.enabled;
    }
    if (dom.tickerSpeed) {
        dom.tickerSpeed.value = String(state.ticker.speed);
    }
    if (dom.tickerFontSize) {
        dom.tickerFontSize.value = String(state.ticker.font_size);
    }
    if (dom.tickerHeight) {
        dom.tickerHeight.value = String(state.ticker.height);
    }
    syncBackgroundInputs();
    syncSeparatorInputs();
    renderTickerItems();
    updateTickerSpeedLabel();
    updateTickerFontSizeLabel();
    updateTickerHeightLabel();
    updateTickerToggleLabel();
    updateTickerPreview();
}

export function updateTickerPreview() {
    const markup = buildTickerMarkup(state.ticker.items || [], state.ticker.separator);
    updateTickerPreviewVisibility(state.ticker.enabled, Boolean(markup));
    if (dom.tickerPreviewPrimary) {
        dom.tickerPreviewPrimary.innerHTML = markup;
    }
    if (dom.tickerPreviewClone) {
        dom.tickerPreviewClone.innerHTML = markup;
    }
    if (dom.tickerPreviewTrack) {
        dom.tickerPreviewTrack.style.setProperty('--ticker-duration', `${state.ticker.speed}s`);
    }
    if (dom.tickerPreviewBar) {
        if (state.ticker.background) {
            dom.tickerPreviewBar.style.setProperty('--ticker-preview-bg', state.ticker.background);
        } else {
            dom.tickerPreviewBar.style.removeProperty('--ticker-preview-bg');
        }
        if (state.ticker.font_size) {
            dom.tickerPreviewBar.style.setProperty('--ticker-preview-font-size', `${state.ticker.font_size}px`);
        } else {
            dom.tickerPreviewBar.style.removeProperty('--ticker-preview-font-size');
        }
        if (state.ticker.height) {
            dom.tickerPreviewBar.style.setProperty('--ticker-preview-height', `${state.ticker.height}px`);
        } else {
            dom.tickerPreviewBar.style.removeProperty('--ticker-preview-height');
        }
    }
    requestAnimationFrame(updateTickerOffset);
}

export function bindTickerEvents() {
    if (dom.tickerToggle) {
        dom.tickerToggle.addEventListener('change', () => {
            state.ticker.enabled = dom.tickerToggle.checked;
            updateTickerToggleLabel();
            updateTickerPreview();
        });
    }

    if (dom.tickerSpeed) {
        dom.tickerSpeed.addEventListener('input', (event) => {
            state.ticker.speed = clampSpeed(event.target.value);
            updateTickerSpeedLabel();
            updateTickerPreview();
        });
    }

    if (dom.tickerFontSize) {
        dom.tickerFontSize.addEventListener('input', (event) => {
            state.ticker.font_size = clampFontSize(event.target.value);
            updateTickerFontSizeLabel();
            updateTickerPreview();
        });
    }

    if (dom.tickerHeight) {
        dom.tickerHeight.addEventListener('input', (event) => {
            state.ticker.height = clampHeight(event.target.value);
            updateTickerHeightLabel();
            updateTickerPreview();
        });
    }

    if (dom.tickerBgColor) {
        dom.tickerBgColor.addEventListener('input', (event) => {
            state.ticker.background = sanitizeColor(event.target.value);
            syncBackgroundInputs();
            updateTickerPreview();
        });
    }

    if (dom.tickerBgInput) {
        dom.tickerBgInput.addEventListener('input', (event) => {
            state.ticker.background = sanitizeColor(event.target.value);
            syncBackgroundInputs();
            updateTickerPreview();
        });
    }

    if (dom.tickerBgReset) {
        dom.tickerBgReset.addEventListener('click', () => {
            state.ticker.background = '';
            syncBackgroundInputs();
            updateTickerPreview();
        });
    }

    if (dom.tickerSeparatorSelect && dom.tickerSeparatorInput) {
        dom.tickerSeparatorSelect.addEventListener('change', () => {
            const value = dom.tickerSeparatorSelect.value;
            if (value === 'custom') {
                dom.tickerSeparatorInput.disabled = false;
                state.ticker.separator = sanitizeSeparator(dom.tickerSeparatorInput.value) || tickerDefaults.separator;
            } else {
                dom.tickerSeparatorInput.disabled = true;
                dom.tickerSeparatorInput.value = '';
                state.ticker.separator = sanitizeSeparator(value) || tickerDefaults.separator;
            }
            updateTickerPreview();
        });

        dom.tickerSeparatorInput.addEventListener('input', () => {
            dom.tickerSeparatorSelect.value = 'custom';
            dom.tickerSeparatorInput.disabled = false;
            state.ticker.separator = sanitizeSeparator(dom.tickerSeparatorInput.value) || tickerDefaults.separator;
            updateTickerPreview();
        });
    }

    if (dom.tickerAddBtn) {
        dom.tickerAddBtn.addEventListener('click', () => {
            openModal(null);
        });
    }

    if (dom.tickerItems) {
        dom.tickerItems.addEventListener('click', (event) => {
            const target = event.target;
            if (!(target instanceof HTMLButtonElement)) {
                return;
            }
            const row = target.closest('.ticker-item-row');
            if (!row) {
                return;
            }
            const item = state.ticker.items.find((entry) => entry.id === row.dataset.id);
            if (!item) {
                return;
            }
            if (target.dataset.action === 'edit') {
                openModal(item);
            }
            if (target.dataset.action === 'remove') {
                state.ticker.items = state.ticker.items.filter((entry) => entry.id !== row.dataset.id);
                renderTickerItems();
                updateTickerPreview();
            }
        });
    }

    if (dom.tickerModalClose) {
        dom.tickerModalClose.addEventListener('click', closeModal);
    }
    if (dom.tickerModalCancel) {
        dom.tickerModalCancel.addEventListener('click', closeModal);
    }
    if (dom.tickerModalSave) {
        dom.tickerModalSave.addEventListener('click', saveModal);
    }
    if (dom.tickerModal) {
        dom.tickerModal.addEventListener('click', (event) => {
            if (event.target === dom.tickerModal) {
                closeModal();
            }
        });
        dom.tickerModal.addEventListener('click', (event) => {
            const target = event.target;
            if (!(target instanceof HTMLElement)) {
                return;
            }
            const action = target.closest('.ticker-format-btn')?.dataset.action;
            if (!action) {
                return;
            }
            if (action === 'bold') {
                applyFormat('bold');
            }
            if (action === 'italic') {
                applyFormat('italic');
            }
        });
    }

    if (dom.tickerEditor) {
        dom.tickerEditor.addEventListener('input', () => {
            updateCharCount();
        });
        dom.tickerEditor.addEventListener('keydown', (event) => {
            if (!(event.ctrlKey || event.metaKey) || event.altKey) {
                return;
            }
            const key = event.key.toLowerCase();
            if (key === 'b') {
                event.preventDefault();
                applyFormat('bold');
            }
            if (key === 'i') {
                event.preventDefault();
                applyFormat('italic');
            }
        });
    }

    if (dom.tickerEmojiRow) {
        dom.tickerEmojiRow.addEventListener('click', (event) => {
            const target = event.target;
            if (!(target instanceof HTMLButtonElement)) {
                return;
            }
            const emoji = target.dataset.emoji;
            if (!emoji) {
                return;
            }
            insertEmoji(emoji);
            updateCharCount();
        });
    }

    window.addEventListener('resize', () => {
        updateTickerOffset();
    });
}

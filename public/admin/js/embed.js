import { dom } from './dom.js';
import { copyToClipboard } from './utils.js';

function getEmbedBase() {
    return window.location.origin;
}

export function buildEmbedUrl() {
    const type = dom.embedType ? dom.embedType.value : 'full';
    const origin = getEmbedBase();
    if (type === 'hls') {
        return `${origin}/hls/master.m3u8`;
    }
    if (type === 'embed') {
        const params = new URLSearchParams();
        params.set('controls', dom.embedControls && dom.embedControls.checked ? '1' : '0');
        params.set('badge', dom.embedBadge && dom.embedBadge.checked ? '1' : '0');
        params.set('stats', dom.embedStats && dom.embedStats.checked ? '1' : '0');
        params.set('muted', dom.embedMuted && dom.embedMuted.checked ? '1' : '0');
        return `${origin}/embed.html?${params.toString()}`;
    }
    return `${origin}/`;
}

function buildEmbedCode() {
    if (!dom.embedCode) {
        return;
    }
    const type = dom.embedType ? dom.embedType.value : 'full';
    const url = buildEmbedUrl();
    if (type === 'hls') {
        dom.embedCode.textContent = url;
        return;
    }

    const width = dom.embedWidth && dom.embedWidth.value ? dom.embedWidth.value : '100%';
    const height = dom.embedHeight && dom.embedHeight.value ? dom.embedHeight.value : '560';
    const responsive = dom.embedResponsive && dom.embedResponsive.checked;

    if (responsive) {
        dom.embedCode.textContent = `<div style="position:relative;padding-top:56.25%;">\n  <iframe\n    src="${url}"\n    style="position:absolute;inset:0;width:100%;height:100%;border:0;"\n    allow="autoplay; fullscreen; picture-in-picture"\n    allowfullscreen\n  ></iframe>\n</div>`;
        return;
    }

    dom.embedCode.textContent = `<iframe\n  src="${url}"\n  width="${width}"\n  height="${height}"\n  style="border:0;"\n  allow="autoplay; fullscreen; picture-in-picture"\n  allowfullscreen\n></iframe>`;
}

export function setEmbedStatus(message, type = 'info') {
    if (!dom.embedStatus) {
        return;
    }
    dom.embedStatus.textContent = message;
    dom.embedStatus.className = `status ${type}`;
}

export function updateEmbedUi() {
    if (!dom.embedType) {
        return;
    }

    const isHls = dom.embedType.value === 'hls';
    const isResponsive = dom.embedResponsive && dom.embedResponsive.checked;
    const disableSizing = isHls || isResponsive;

    if (dom.embedWidth) {
        dom.embedWidth.disabled = disableSizing;
    }
    if (dom.embedHeight) {
        dom.embedHeight.disabled = disableSizing;
    }
    if (dom.embedControls) {
        dom.embedControls.disabled = isHls;
    }
    if (dom.embedBadge) {
        dom.embedBadge.disabled = isHls;
    }
    if (dom.embedStats) {
        dom.embedStats.disabled = isHls;
    }
    if (dom.embedMuted) {
        dom.embedMuted.disabled = isHls;
    }
    if (dom.copyEmbedBtn) {
        dom.copyEmbedBtn.textContent = isHls ? 'Copy HLS URL' : 'Copy Embed Code';
    }
    buildEmbedCode();
}

export function bindEmbedEvents() {
    const embedInputs = [
        dom.embedType,
        dom.embedWidth,
        dom.embedHeight,
        dom.embedResponsive,
        dom.embedControls,
        dom.embedBadge,
        dom.embedStats,
        dom.embedMuted
    ];

    embedInputs.forEach((input) => {
        if (!input) {
            return;
        }
        const eventName = input.tagName === 'SELECT' || input.type === 'checkbox' ? 'change' : 'input';
        input.addEventListener(eventName, () => {
            updateEmbedUi();
            setEmbedStatus('', 'info');
        });
    });

    if (dom.copyEmbedBtn) {
        dom.copyEmbedBtn.addEventListener('click', () => {
            if (!dom.embedCode || !dom.embedCode.textContent) {
                return;
            }
            copyToClipboard(dom.embedCode.textContent);
            setEmbedStatus('Copied.', 'success');
        });
    }
}

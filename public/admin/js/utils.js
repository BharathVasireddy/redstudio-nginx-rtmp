import { dom } from './dom.js';

export function showToast(message, type = 'info') {
    if (!dom.toastContainer) {
        return;
    }
    const toast = document.createElement('div');
    toast.className = `toast ${type}`;
    toast.textContent = message;
    dom.toastContainer.appendChild(toast);
    setTimeout(() => {
        toast.style.animation = 'toastSlideIn 0.3s ease-out reverse';
        setTimeout(() => toast.remove(), 300);
    }, 4000);
}

export async function getErrorMessage(res) {
    try {
        const payload = await res.json();
        if (payload && payload.error) {
            return payload.error;
        }
    } catch (err) {
        // ignore JSON parse errors
    }
    return `HTTP ${res.status}`;
}

export async function copyToClipboard(value) {
    try {
        await navigator.clipboard.writeText(value);
        showToast('Copied to clipboard', 'success');
    } catch (err) {
        showToast('Copy failed', 'error');
    }
}

export function formatNumber(value) {
    if (value === null || value === undefined || Number.isNaN(value)) {
        return '--';
    }
    return value.toFixed(1);
}

export function generateKey() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
    const bytes = new Uint8Array(24);
    window.crypto.getRandomValues(bytes);
    return Array.from(bytes, (byte) => alphabet[byte % alphabet.length]).join('');
}

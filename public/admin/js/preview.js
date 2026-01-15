import { STREAM_URL } from './constants.js';
import { dom } from './dom.js';

let previewPlayer = null;
const FALLBACK_STREAM_URL = '/hls/stream.m3u8';

async function resolvePreviewUrl() {
    try {
        const res = await fetch(STREAM_URL, { method: 'HEAD', cache: 'no-store' });
        if (res.ok) {
            return STREAM_URL;
        }
    } catch (err) {
        // Ignore and fall back
    }
    return FALLBACK_STREAM_URL;
}

export function initPreviewPlayer() {
    const videoElement = dom.previewPlayer;
    if (!videoElement) {
        return;
    }
    if (typeof Plyr === 'undefined') {
        return;
    }

    previewPlayer = new Plyr(videoElement, {
        controls: ['play', 'mute', 'volume', 'fullscreen'],
        autoplay: true,
        muted: false,
        hideControls: true,
        resetOnEnd: false,
        keyboard: { focused: false, global: false }
    });

    resolvePreviewUrl().then((url) => {
        if (typeof Hls !== 'undefined' && Hls.isSupported()) {
            const hls = new Hls({
                enableWorker: true,
                lowLatencyMode: false,
                maxBufferLength: 180,
                maxMaxBufferLength: 600,
                backBufferLength: 180,
                liveSyncDurationCount: 12,
                liveMaxLatencyDurationCount: 30,
                maxLiveSyncPlaybackRate: 1
            });
            hls.loadSource(url);
            hls.attachMedia(videoElement);
            hls.on(Hls.Events.ERROR, function (event, data) {
                if (data.fatal) {
                    if (dom.previewOffline) {
                        dom.previewOffline.classList.remove('hidden');
                    }
                }
            });
            hls.on(Hls.Events.MANIFEST_PARSED, function () {
                if (dom.previewOffline) {
                    dom.previewOffline.classList.add('hidden');
                }
            });
        } else if (videoElement.canPlayType('application/vnd.apple.mpegurl')) {
            videoElement.src = url;
        }
    });

    previewPlayer.on('playing', () => {
        if (dom.previewOffline) {
            dom.previewOffline.classList.add('hidden');
        }
    });

    previewPlayer.on('error', () => {
        if (dom.previewOffline) {
            dom.previewOffline.classList.remove('hidden');
        }
    });
}

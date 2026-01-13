import { STREAM_URL } from './constants.js';
import { dom } from './dom.js';

let previewPlayer = null;

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

    if (typeof Hls !== 'undefined' && Hls.isSupported()) {
        const hls = new Hls({
            enableWorker: true,
            lowLatencyMode: false,
            maxBufferLength: 30,
            backBufferLength: 30,
            liveSyncDurationCount: 2,
            liveMaxLatencyDurationCount: 6,
            maxLiveSyncPlaybackRate: 1
        });
        hls.loadSource(STREAM_URL);
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
        videoElement.src = STREAM_URL;
    }

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

export const API_BASE = '/admin/api';
export const STREAM_URL = '/hls/master.m3u8';

export const defaultDestinations = [
    {
        id: 'youtube',
        name: 'YouTube',
        enabled: false,
        rtmp_url: 'rtmp://a.rtmp.youtube.com/live2',
        stream_key: ''
    },
    {
        id: 'facebook',
        name: 'Facebook',
        enabled: false,
        rtmp_url: 'rtmp://live-api-s.facebook.com:80/rtmp',
        stream_key: ''
    },
    {
        id: 'twitch',
        name: 'Twitch',
        enabled: false,
        rtmp_url: 'rtmp://live.twitch.tv/app',
        stream_key: ''
    },
    {
        id: 'instagram',
        name: 'Instagram',
        enabled: false,
        rtmp_url: 'rtmps://live-upload.instagram.com:443/rtmp/',
        stream_key: ''
    },
    {
        id: 'custom',
        name: 'Custom',
        enabled: false,
        rtmp_url: 'rtmp://',
        stream_key: ''
    }
];

export const overlayDefaults = {
    id: '',
    enabled: false,
    image_file: '',
    position: 'top-right',
    offset_x: 24,
    offset_y: 24,
    size_mode: 'percent',
    size_value: 18,
    opacity: 1,
    rotate: 0
};

export const overlayMaxCount = 8;

export const tickerDefaults = {
    enabled: false,
    text: '',
    speed: 32,
    font_size: 14,
    height: 40,
    background: '',
    separator: '•',
    items: []
};

export const tickerSpeedRange = {
    min: 10,
    max: 120
};

export const tickerFontRange = {
    min: 10,
    max: 28
};

export const tickerHeightRange = {
    min: 28,
    max: 80
};

export const tickerMaxItems = 10;
export const tickerTextLimit = 140;

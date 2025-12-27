/**
 * NGINX-RTMP Admin API Server - Enterprise Edition
 * Manages streaming with real viewer counts, session persistence, and server-side tokens
 */

const express = require('express');
const cors = require('cors');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const http = require('http');
const { exec } = require('child_process');

const app = express();
const PORT = 3000;

// Paths
const CONFIG_PATH = path.join(__dirname, 'config.json');
const SESSION_PATH = path.join(__dirname, 'session.json');
const ANALYTICS_PATH = path.join(__dirname, 'analytics.json');
const DEFAULT_NGINX_CONF_PATH = path.join(__dirname, '..', 'conf', 'nginx.conf');
const SYSTEM_NGINX_CONF_PATH = '/usr/local/nginx/conf/nginx.conf';

const PUSH_BLOCK_START = '# === Managed Push Targets (auto-generated; do not edit) ===';
const PUSH_BLOCK_END = '# === End Managed Push Targets ===';
const HLS_BLOCK_START = '# === Managed HLS Pipeline (auto-generated; do not edit) ===';
const HLS_BLOCK_END = '# === End Managed HLS Pipeline ===';

const HLS_PROFILE_SCRIPTS = {
    lowcpu: 'ffmpeg-abr-lowcpu.sh',
    high: 'ffmpeg-abr.sh'
};

// Detect OS
const isWindows = process.platform === 'win32';
const NGINX_EXE_PATH = isWindows
    ? path.join(__dirname, '..', 'nginx.exe')
    : '/usr/local/nginx/sbin/nginx';

// Middleware
app.use(cors());
app.use(express.json());
app.use(express.urlencoded({ extended: false }));

// ========================================
// Session Management with Persistence
// ========================================

const RECONNECT_GRACE_PERIOD = 120; // seconds

// Default session state
let streamSession = {
    isLive: false,
    startTime: null,
    publisher: null,
    disconnectTime: null,
    peakViewers: 0,
    totalViews: 0
};

// Load persisted session on startup
function loadSession() {
    try {
        if (fs.existsSync(SESSION_PATH)) {
            const data = JSON.parse(fs.readFileSync(SESSION_PATH, 'utf8'));
            // Restore session if within grace period
            const now = Date.now();
            if (data.startTime && data.disconnectTime) {
                if ((now - data.disconnectTime) < (RECONNECT_GRACE_PERIOD * 1000)) {
                    streamSession = { ...data, isLive: false };
                    console.log('[Session] Restored session from disk, waiting for reconnect');
                } else {
                    console.log('[Session] Previous session expired, starting fresh');
                }
            } else if (data.startTime && data.isLive) {
                // Server crashed while live - treat as disconnected
                streamSession = { ...data, isLive: false, disconnectTime: now };
                console.log('[Session] Recovered crashed live session');
            }
        }
    } catch (err) {
        console.error('[Session] Error loading session:', err.message);
    }
}

// Save session to disk
function saveSession() {
    try {
        fs.writeFileSync(SESSION_PATH, JSON.stringify(streamSession, null, 2));
    } catch (err) {
        console.error('[Session] Error saving session:', err.message);
    }
}

// Analytics logging
function logAnalytics(event, data) {
    try {
        let analytics = [];
        if (fs.existsSync(ANALYTICS_PATH)) {
            analytics = JSON.parse(fs.readFileSync(ANALYTICS_PATH, 'utf8'));
        }
        analytics.push({
            timestamp: new Date().toISOString(),
            event,
            ...data
        });
        // Keep last 1000 entries to prevent unbounded growth
        if (analytics.length > 1000) {
            analytics = analytics.slice(-1000);
        }
        fs.writeFileSync(ANALYTICS_PATH, JSON.stringify(analytics, null, 2));
    } catch (err) {
        console.error('[Analytics] Error logging:', err.message);
    }
}

// Load session on startup
loadSession();
warnIfSecretMismatch();

// ========================================
// Viewer Count from NGINX /stat
// ========================================

let cachedViewerCount = 0;
let lastViewerCheck = 0;
const VIEWER_CACHE_MS = 2000; // Cache for 2 seconds

async function getViewerCount() {
    const now = Date.now();
    if (now - lastViewerCheck < VIEWER_CACHE_MS) {
        return cachedViewerCount;
    }

    return new Promise((resolve) => {
        const config = readConfig();
        const httpPort = config?.server?.httpPort || 8080;

        const req = http.get(`http://127.0.0.1:${httpPort}/stat`, (res) => {
            let data = '';
            res.on('data', chunk => data += chunk);
            res.on('end', () => {
                try {
                    // Parse XML to get nclients (number of HLS clients)
                    // Look for <live><stream><nclients>X</nclients>
                    const nclientsMatch = data.match(/<application>\s*<name>live<\/name>[\s\S]*?<stream>[\s\S]*?<nclients>(\d+)<\/nclients>/);
                    const hlsMatch = data.match(/<hls>[\s\S]*?<nclients>(\d+)<\/nclients>/);

                    let viewers = 0;
                    if (nclientsMatch) {
                        viewers = parseInt(nclientsMatch[1], 10) || 0;
                    }
                    // Some NGINX builds report HLS separately
                    if (hlsMatch) {
                        viewers = Math.max(viewers, parseInt(hlsMatch[1], 10) || 0);
                    }

                    cachedViewerCount = viewers;
                    lastViewerCheck = now;

                    // Track peak viewers
                    if (streamSession.isLive && viewers > streamSession.peakViewers) {
                        streamSession.peakViewers = viewers;
                        saveSession();
                    }

                    resolve(viewers);
                } catch (e) {
                    resolve(cachedViewerCount);
                }
            });
        });

        req.on('error', () => {
            resolve(cachedViewerCount);
        });

        req.setTimeout(2000, () => {
            req.destroy();
            resolve(cachedViewerCount);
        });
    });
}

// ========================================
// HLS Token Generation (Server-Side)
// ========================================

function generateHlsToken(uri, secret, validitySeconds = 604800) {
    const expires = Math.floor(Date.now() / 1000) + validitySeconds;
    const toHash = `${expires}${uri} ${secret}`;
    const md5Hash = crypto.createHash('md5').update(toHash).digest('base64');
    // Convert to Base64URL
    const base64Url = md5Hash.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    return { md5: base64Url, expires };
}

// ========================================
// Helper Functions
// ========================================

function readConfig() {
    try {
        return JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
    } catch (err) {
        console.error('Error reading config:', err);
        return null;
    }
}

function resolveNginxConfPath() {
    if (isWindows) return DEFAULT_NGINX_CONF_PATH;
    try {
        if (fs.existsSync(SYSTEM_NGINX_CONF_PATH)) return SYSTEM_NGINX_CONF_PATH;
    } catch (err) {
        console.warn('[NGINX] Failed to resolve system config path:', err.message);
    }
    return DEFAULT_NGINX_CONF_PATH;
}

function escapeRegExp(value) {
    return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function isValidHlsProfile(profile) {
    if (!profile) return false;
    const normalized = String(profile).toLowerCase();
    return normalized in HLS_PROFILE_SCRIPTS || normalized === 'highcpu' || normalized === 'full';
}

function normalizeHlsProfile(profile) {
    if (!profile) return 'lowcpu';
    const normalized = String(profile).toLowerCase();
    if (normalized === 'highcpu' || normalized === 'full') return 'high';
    return HLS_PROFILE_SCRIPTS[normalized] ? normalized : 'lowcpu';
}

function buildPushUrl(platform) {
    const baseUrl = (platform?.url || '').trim();
    const key = (platform?.key || '').trim();
    if (!baseUrl || !key) return null;
    if (baseUrl.endsWith('/')) return `${baseUrl}${key}`;
    return `${baseUrl}/${key}`;
}

function collectPushTargets(config) {
    const targets = [];
    const seen = new Set();
    const platforms = [
        ...(config?.platforms || []),
        ...(config?.customPlatforms || [])
    ];

    platforms.forEach((platform) => {
        if (!platform?.enabled) return;
        const url = buildPushUrl(platform);
        if (!url || seen.has(url)) return;
        seen.add(url);
        targets.push(url);
    });

    return targets;
}

function updateNginxPushTargets(config) {
    try {
        const nginxConfPath = resolveNginxConfPath();
        const nginxConf = fs.readFileSync(nginxConfPath, 'utf8');
        if (!nginxConf.includes(PUSH_BLOCK_START) || !nginxConf.includes(PUSH_BLOCK_END)) {
            return { success: false, error: 'Managed push block not found in nginx.conf' };
        }

        const targets = collectPushTargets(config);
        const pushLines = targets.length
            ? targets.map((url) => `push ${url};`).join('\n')
            : '# (no push targets enabled)';

        const block = `${PUSH_BLOCK_START}\n${pushLines}\n${PUSH_BLOCK_END}`;
        const pattern = new RegExp(`${escapeRegExp(PUSH_BLOCK_START)}[\\s\\S]*?${escapeRegExp(PUSH_BLOCK_END)}`);
        const updated = nginxConf.replace(pattern, block);

        if (updated === nginxConf) {
            return { success: false, error: 'Failed to update push targets' };
        }

        fs.writeFileSync(nginxConfPath, updated);
        return { success: true, targets };
    } catch (err) {
        return { success: false, error: err.message };
    }
}

function buildExecPublishLine(nginxConf, scriptName) {
    const execMatch = nginxConf.match(/exec_publish\s+([^\s;]+)\s+([^\s;]+\/)ffmpeg-abr(?:-lowcpu)?\.sh\b/);
    const execCommand = execMatch ? execMatch[1] : '/bin/bash';
    const scriptDir = execMatch ? execMatch[2] : '/var/www/nginx-rtmp-module/scripts/';
    return `exec_publish ${execCommand} ${scriptDir}${scriptName} $name;`;
}

function updateNginxHlsPipeline(config) {
    try {
        const nginxConfPath = resolveNginxConfPath();
        const nginxConf = fs.readFileSync(nginxConfPath, 'utf8');
        if (!nginxConf.includes(HLS_BLOCK_START) || !nginxConf.includes(HLS_BLOCK_END)) {
            return { success: false, error: 'Managed HLS block not found in nginx.conf' };
        }

        const profile = normalizeHlsProfile(config?.hls?.profile);
        const scriptName = HLS_PROFILE_SCRIPTS[profile];
        const execLine = buildExecPublishLine(nginxConf, scriptName);
        const block = `${HLS_BLOCK_START}\n${execLine}\n${HLS_BLOCK_END}`;
        const pattern = new RegExp(`${escapeRegExp(HLS_BLOCK_START)}[\\s\\S]*?${escapeRegExp(HLS_BLOCK_END)}`);
        const updated = nginxConf.replace(pattern, block);

        if (updated === nginxConf) {
            return { success: false, error: 'Failed to update HLS pipeline' };
        }

        fs.writeFileSync(nginxConfPath, updated);
        return { success: true, profile };
    } catch (err) {
        return { success: false, error: err.message };
    }
}

function syncNginxConfig(config) {
    const hlsResult = updateNginxHlsPipeline(config);
    if (!hlsResult.success) return hlsResult;

    const pushResult = updateNginxPushTargets(config);
    if (!pushResult.success) return pushResult;

    return { success: true };
}

function getAdminKey(config) {
    return process.env.ADMIN_API_KEY || config?.adminApiKey || config?.auth?.adminApiKey || null;
}

function requireAdmin(req, res, next) {
    const config = readConfig();
    const adminKey = getAdminKey(config);
    if (!adminKey) {
        return res.status(500).json({ error: 'Admin API key not configured' });
    }

    const providedKey = req.get('x-admin-key') || req.query.adminKey;
    if (!providedKey || providedKey !== adminKey) {
        return res.status(401).json({ error: 'Unauthorized' });
    }

    return next();
}

function isValidHlsSecret(secret) {
    return typeof secret === 'string' && /^[A-Za-z0-9!@#%_+\-=:.,]+$/.test(secret);
}

function updateNginxHlsSecret(secret) {
    try {
        const nginxConfPath = resolveNginxConfPath();
        const nginxConf = fs.readFileSync(nginxConfPath, 'utf8');
        const updated = nginxConf.replace(
            /secure_link_md5\s+"[^"]*";/,
            `secure_link_md5 "$arg_expires$uri ${secret}";`
        );

        if (updated === nginxConf) {
            return { success: false, error: 'secure_link_md5 directive not found' };
        }

        fs.writeFileSync(nginxConfPath, updated);
        return { success: true };
    } catch (err) {
        return { success: false, error: err.message };
    }
}

function getNginxHlsSecret() {
    try {
        const nginxConfPath = resolveNginxConfPath();
        const nginxConf = fs.readFileSync(nginxConfPath, 'utf8');
        const match = nginxConf.match(/secure_link_md5\s+"\\$arg_expires\\$uri\\s+([^"]+)";/);
        return match ? match[1] : null;
    } catch (err) {
        return null;
    }
}

function warnIfSecretMismatch() {
    const config = readConfig();
    if (!config?.auth?.hlsSecret) return;
    const nginxSecret = getNginxHlsSecret();
    if (nginxSecret && nginxSecret !== config.auth.hlsSecret) {
        console.warn('[HLS] Secret mismatch between config.json and nginx.conf');
    }
}

function writeConfig(config) {
    try {
        fs.writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2));
        return true;
    } catch (err) {
        console.error('Error writing config:', err);
        return false;
    }
}

function generateRandomKey(length = 16) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    let result = '';
    for (let i = 0; i < length; i++) {
        result += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return result;
}

function reloadNginx() {
    return new Promise((resolve, reject) => {
        const rootDir = path.join(__dirname, '..');
        const cmdPrefix = isWindows ? '' : 'sudo ';
        const reloadCmd = `${cmdPrefix}"${NGINX_EXE_PATH}" -s reload`;

        exec(reloadCmd, { cwd: rootDir }, (error) => {
            if (error) {
                reject({ error: error.message });
            } else {
                resolve({ success: true, message: 'NGINX reloaded successfully' });
            }
        });
    });
}

// ========================================
// API Endpoints
// ========================================

// Get configuration
app.get('/api/config', requireAdmin, (req, res) => {
    const config = readConfig();
    if (config) {
        res.json(config);
    } else {
        res.status(500).json({ error: 'Failed to read configuration' });
    }
});

// Update platforms
app.post('/api/platforms', requireAdmin, (req, res) => {
    const config = readConfig();
    if (!config) {
        return res.status(500).json({ error: 'Failed to read configuration' });
    }

    const { platforms, customPlatforms } = req.body;
    if (platforms) config.platforms = platforms;
    if (customPlatforms !== undefined) config.customPlatforms = customPlatforms;

    if (writeConfig(config)) {
        res.json({ success: true, message: 'Platforms updated' });
    } else {
        res.status(500).json({ error: 'Failed to save configuration' });
    }
});

// Update HLS settings
app.post('/api/hls', requireAdmin, (req, res) => {
    const config = readConfig();
    if (!config) {
        return res.status(500).json({ error: 'Failed to read configuration' });
    }

    const { fragmentDuration, playlistLength, cleanup, profile } = req.body;
    if (fragmentDuration !== undefined) config.hls.fragmentDuration = fragmentDuration;
    if (playlistLength !== undefined) config.hls.playlistLength = playlistLength;
    if (cleanup !== undefined) config.hls.cleanup = cleanup;
    if (profile !== undefined) {
        if (!isValidHlsProfile(profile)) {
            return res.status(400).json({ error: 'Invalid HLS profile' });
        }
        config.hls.profile = normalizeHlsProfile(profile);
    }

    if (writeConfig(config)) {
        res.json({ success: true, message: 'HLS settings updated' });
    } else {
        res.status(500).json({ error: 'Failed to save configuration' });
    }
});

// Update auth
app.post('/api/auth', requireAdmin, (req, res) => {
    const config = readConfig();
    if (!config) {
        return res.status(500).json({ error: 'Failed to read configuration' });
    }

    const { users, hlsSecret } = req.body;
    if (users) config.auth.users = users;
    if (hlsSecret) {
        if (!isValidHlsSecret(hlsSecret)) {
            return res.status(400).json({ error: 'Invalid HLS secret format' });
        }

        const updateResult = updateNginxHlsSecret(hlsSecret);
        if (!updateResult.success) {
            return res.status(500).json({ error: 'Failed to update NGINX HLS secret', details: updateResult.error });
        }

        config.auth.hlsSecret = hlsSecret;
    }

    if (writeConfig(config)) {
        res.json({ success: true, message: 'Auth settings updated' });
    } else {
        res.status(500).json({ error: 'Failed to save configuration' });
    }
});

// Rotate stream key
app.post('/api/key/rotate', requireAdmin, (req, res) => {
    const config = readConfig();
    if (!config) return res.status(500).json({ error: 'Failed to read configuration' });

    const { username } = req.body;
    const userIndex = config.auth.users.findIndex(u => u.username === username);
    if (userIndex === -1) return res.status(404).json({ error: 'User not found' });

    const newKey = generateRandomKey(16);
    config.auth.users[userIndex].key = newKey;

    if (writeConfig(config)) {
        res.json({ success: true, newKey, message: 'Stream key rotated' });
    } else {
        res.status(500).json({ error: 'Failed to save configuration' });
    }
});

// Add user
app.post('/api/auth/user', requireAdmin, (req, res) => {
    const config = readConfig();
    if (!config) return res.status(500).json({ error: 'Failed to read configuration' });

    const { username } = req.body;
    if (!username) return res.status(400).json({ error: 'Username required' });
    if (config.auth.users.find(u => u.username === username)) {
        return res.status(400).json({ error: 'Username already exists' });
    }

    const newUser = { username, key: generateRandomKey(16) };
    config.auth.users.push(newUser);

    if (writeConfig(config)) {
        res.json({ success: true, user: newUser, message: 'User added' });
    } else {
        res.status(500).json({ error: 'Failed to save configuration' });
    }
});

// Delete user
app.delete('/api/auth/user/:username', requireAdmin, (req, res) => {
    const config = readConfig();
    if (!config) return res.status(500).json({ error: 'Failed to read configuration' });

    const { username } = req.params;
    const userIndex = config.auth.users.findIndex(u => u.username === username);
    if (userIndex === -1) return res.status(404).json({ error: 'User not found' });
    if (config.auth.users.length === 1) return res.status(400).json({ error: 'Cannot delete the last user' });

    config.auth.users.splice(userIndex, 1);

    if (writeConfig(config)) {
        res.json({ success: true, message: 'User deleted' });
    } else {
        res.status(500).json({ error: 'Failed to save configuration' });
    }
});

// Apply configuration
app.post('/api/apply', requireAdmin, async (req, res) => {
    try {
        const config = readConfig();
        if (!config) {
            return res.status(500).json({ error: 'Failed to read configuration' });
        }

        const syncResult = syncNginxConfig(config);
        if (!syncResult.success) {
            return res.status(500).json({ error: 'Failed to sync NGINX configuration', details: syncResult.error });
        }

        await reloadNginx();
        res.json({ success: true, message: 'Configuration applied' });
    } catch (err) {
        res.status(500).json({ error: 'Failed to apply configuration', details: err.error || err.message });
    }
});

// Reload NGINX
app.post('/api/reload', requireAdmin, async (req, res) => {
    try {
        const result = await reloadNginx();
        res.json(result);
    } catch (err) {
        res.status(500).json({ error: 'Failed to reload NGINX', details: err.error || err.message });
    }
});

// ========================================
// HLS Token Endpoint (Server-Side Generation)
// ========================================

app.get('/api/token/hls', (req, res) => {
    const { stream = 'master' } = req.query;
    const config = readConfig();
    if (!config) return res.status(500).json({ error: 'Config error' });

    const uri = `/hls/${stream}.m3u8`;
    const token = generateHlsToken(uri, config.auth.hlsSecret);

    res.header('Cache-Control', 'no-store');
    res.json({
        url: `${uri}?md5=${token.md5}&expires=${token.expires}`,
        expires: token.expires,
        expiresIn: 604800 // 7 days
    });
});

// ========================================
// RTMP Callbacks (Source of Truth)
// ========================================

app.all('/api/callback/on_publish', (req, res) => {
    const payload = Object.keys(req.body || {}).length ? req.body : req.query;
    const { user, pass, name } = payload;
    console.log(`[RTMP] on_publish attempt: app=${payload.app} name=${name} user=${user}`);

    const config = readConfig();
    const validUser = config.auth.users.find(u => u.username === user && u.key === pass);

    if (!validUser) {
        console.log(`[RTMP] Auth failed for user: ${user}`);
        return res.status(403).send('Unauthorized');
    }

    const now = Date.now();

    // Resume or start new session
    if (streamSession.startTime && streamSession.disconnectTime &&
        (now - streamSession.disconnectTime) < (RECONNECT_GRACE_PERIOD * 1000)) {
        console.log(`[RTMP] Stream resumed. Start time preserved: ${new Date(streamSession.startTime).toISOString()}`);
        streamSession.isLive = true;
        streamSession.disconnectTime = null;
        streamSession.publisher = user;
    } else {
        console.log(`[RTMP] New stream session started.`);
        streamSession = {
            isLive: true,
            startTime: now,
            publisher: user,
            disconnectTime: null,
            peakViewers: 0,
            totalViews: (streamSession.totalViews || 0) + 1
        };
        logAnalytics('stream_start', { publisher: user });
    }

    saveSession();
    res.status(200).send('OK');
});

app.all('/api/callback/on_done', (req, res) => {
    const payload = Object.keys(req.body || {}).length ? req.body : req.query;
    console.log(`[RTMP] on_done: app=${payload.app} name=${payload.name}`);

    if (streamSession.isLive) {
        const duration = streamSession.startTime ? Math.floor((Date.now() - streamSession.startTime) / 1000) : 0;
        logAnalytics('stream_stop', {
            publisher: streamSession.publisher,
            duration,
            peakViewers: streamSession.peakViewers
        });

        streamSession.isLive = false;
        streamSession.disconnectTime = Date.now();
        saveSession();
    }

    res.status(200).send('OK');
});

// ========================================
// Stream Status API (Public)
// ========================================

app.get('/api/stream/status', async (req, res) => {
    const now = Date.now();

    // Expire session if beyond grace period
    if (!streamSession.isLive && streamSession.disconnectTime &&
        (now - streamSession.disconnectTime) > (RECONNECT_GRACE_PERIOD * 1000)) {
        streamSession.startTime = null;
        streamSession.disconnectTime = null;
        streamSession.peakViewers = 0;
    }

    // Get real viewer count from NGINX
    const viewers = await getViewerCount();

    const response = {
        isLive: streamSession.isLive,
        startTime: streamSession.startTime,
        uptime: streamSession.isLive && streamSession.startTime
            ? Math.floor((now - streamSession.startTime) / 1000) : 0,
        viewers: viewers,
        peakViewers: streamSession.peakViewers,
        publisher: streamSession.publisher,
        serverTime: now
    };

    res.header('Cache-Control', 'no-store, no-cache, must-revalidate');
    res.header('Pragma', 'no-cache');
    res.json(response);
});

// Health check
app.get('/api/health', (req, res) => {
    res.json({
        status: 'ok',
        timestamp: new Date().toISOString(),
        uptime: process.uptime(),
        streamLive: streamSession.isLive
    });
});

// Analytics endpoint
app.get('/api/analytics', (req, res) => {
    try {
        if (fs.existsSync(ANALYTICS_PATH)) {
            const analytics = JSON.parse(fs.readFileSync(ANALYTICS_PATH, 'utf8'));
            res.json(analytics.slice(-100)); // Last 100 entries
        } else {
            res.json([]);
        }
    } catch (err) {
        res.status(500).json({ error: 'Failed to read analytics' });
    }
});

// Start server
app.listen(PORT, () => {
    console.log(`
╔════════════════════════════════════════════════════════════╗
║         NGINX-RTMP Admin API Server (Enterprise)           ║
║         Running on http://localhost:${PORT}                    ║
╠════════════════════════════════════════════════════════════╣
║  NEW Features:                                             ║
║  GET  /api/stream/status  - Real viewer count + uptime     ║
║  GET  /api/token/hls      - Server-side HLS tokens         ║
║  GET  /api/analytics      - Stream analytics               ║
║  GET  /api/health         - Health check                   ║
╚════════════════════════════════════════════════════════════╝
    `);
});

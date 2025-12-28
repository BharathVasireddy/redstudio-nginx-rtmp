# Oracle Cloud (Production)

## 1) Provision and open ports

- Open ports `1935`, `80`, `443`, `8080` in your Oracle Security List/NSG.

## 2) SSH into the VM

```bash
ssh -i /path/to/key ubuntu@<server-ip>
```

## 3) Install base dependencies

```bash
sudo apt-get update
sudo apt-get install -y git python3 curl unzip
```

## 4) Clone and install

```bash
cd /var/www
git clone https://github.com/BharathVasireddy/redstudio-nginx-rtmp.git
cd redstudio-nginx-rtmp
sudo ./setup-oracle.sh
sudo ./deploy.sh
```

`setup-oracle.sh` installs build dependencies, compiles nginx with RTMP, and configures the firewall.

## 5) Admin login and ingest key

- Admin UI: `https://live.<your-domain>/admin/`
- Credentials: `data/admin.credentials` on the server (or set `ADMIN_USER`/`ADMIN_PASSWORD` in GitHub Secrets).
- In **Ingest Settings**, generate a stream key and click **Save & Apply**.

## 6) OBS settings (production)

- Server: `rtmp://ingest.<your-domain>/ingest`
- Stream Key: the key shown in `/admin` -> Ingest Settings

## 7) Player URLs

- Website: `https://live.<your-domain>/`
- HLS: `https://live.<your-domain>/hls/stream.m3u8`

## 8) GitHub Actions (optional)

If you want auto-deploy on every push to `main`, set these GitHub Secrets:

- `ORACLE_HOST` (server IP)
- `ORACLE_USER` (usually `ubuntu`)
- `ORACLE_SSH_KEY` (private key content)
- `ORACLE_SSH_KEY_PASSPHRASE` (optional)
- `ADMIN_USER`, `ADMIN_PASSWORD` (optional)

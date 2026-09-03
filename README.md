🇬🇧 English | [🇪🇸 Español](README-ES.md)

# jellypi

Media center for Raspberry Pi 4 with automatic TV show and movie downloading.

**Stack:** Jellyfin · Sonarr · Radarr · Prowlarr · qBittorrent · Seerr · Gluetun · Tailscale · FlareSolverr  
**Watch on TV:** Jellyfin app on Chromecast with Google TV  
**Add content:** Seerr from your phone or laptop  
**Remote access:** Tailscale — no open ports required  
**VPN:** Gluetun + PIA (OpenVPN) — all qBittorrent traffic goes through the VPN

---

## Required hardware

- Raspberry Pi 4 (4GB or 8GB)
- 32GB microSD — High Endurance recommended (Samsung PRO Endurance or SanDisk High Endurance)
- 2TB external USB HDD formatted as ext4
- Ethernet cable to router (recommended) or WiFi
- Powered USB hub if the HDD has no external power supply

---

## 1. Prepare the microSD

Use **Raspberry Pi Imager**: [raspberrypi.com/software](https://raspberrypi.com/software)

- **Device:** Raspberry Pi 4
- **OS:** Raspberry Pi OS Lite (64-bit) — under "Raspberry Pi OS (other)"
- **Storage:** your microSD

Open **Edit Settings** (⚙️) before flashing:

```
Hostname:   jellypi
Username:   pi
SSH:        Enable — Use password authentication
WiFi:       leave empty (use ethernet)
```

---

## 2. First SSH access

```bash
ssh pi@jellypi.local
```

If `jellypi.local` doesn't resolve, find the Pi's IP in your router.

---

## 3. System setup

```bash
sudo apt install -y git
git clone https://github.com/serginator/jellyPi ~/jellypi
cd ~/jellypi
cp env.example .env
nano .env
```

Run the setup script as root — it formats the HDD, installs Docker and log2ram, configures qBittorrent, and sets up the download schedule. Use `lsblk` to identify your HDD device when prompted.

> ⚠️ Setup formats the HDD. Select the correct device.

```bash
sudo bash setup.sh
sudo reboot
```

---

## 4. Start the services

```bash
cd ~/jellypi
docker compose up -d
docker compose ps
```

First run downloads ~1.5GB of images.

---

## 5. Configure the services

Replace `jellypi.local` with the Pi's IP if the hostname doesn't resolve.

### qBittorrent — `http://jellypi.local:8080`

Default credentials: `admin` / `adminadmin`  
(Check the log if they don't work: `docker compose logs qbittorrent | grep password`)

`setup.sh` applies all settings automatically. To edit manually:

```bash
nano /mnt/storage/config/qbittorrent/qBittorrent/qBittorrent.conf
docker compose restart qbittorrent
```

**Applied limits:**

| Setting | Value |
|---------|-------|
| Global connections | 50 |
| Connections per torrent | 10 |
| Active downloads | 1 |
| Active seeds | 2 |
| DHT | enabled |
| LSD | disabled |
| Max ratio | 1.0 (pause on completion) |

**Download schedule** (via `qbt.sh`, installed by `setup.sh`):

- `01:00` — resume all torrents
- `08:00` — pause all torrents

> `qbt.sh` authenticates via API on each call — qBittorrent 5.x ignores the localhost auth bypass. Update the password in the script if you change it in qBittorrent.

In **Tools → Options → Downloads**, set Default Save Path to `/data/torrents`.

The `tv` and `movies` categories are created automatically by Sonarr/Radarr. For anime, add category `sonarr-anime` manually with save path `/data/torrents/anime`.

### Sonarr — `http://jellypi.local:8989`

On first access: **Authentication Required → Disabled for Local Addresses**.

1. **Settings → Media Management → Root Folders:** add `/data/media/tv` and `/data/media/anime`
2. **Settings → Download Clients → + → qBittorrent:** Host `gluetun`, Port `8080`, Category `tv`
3. Copy the **API Key** from Settings → General

**Anime:**

- Set **Series Type = Anime** before saving — enables absolute numbering and correct Nyaa.si searches
- Use `/data/media/anime` as Root Folder
- If a series shows "No results found", use **Interactive Search** to diagnose
- Set **Monitored = No** on already-watched episodes to avoid re-downloading

**Custom Formats** (Settings → Custom Formats → +, Release Title condition, regex, case insensitive):

| Custom Format | Regex | Score |
|---|---|---|
| `Dub` | `english.?dub\|\[dub\]\|dubbed` | `-10000` |
| `Hardcoded Subs` | `dubbed\|hardcoded\|hard.?sub\|hcsub\|\bhs\b` | `-10000` |
| `Trusted Anime Groups` | `subsplease\|erai.raws\|kawaiika.raws` | `+100` |

Bazarr adds Spanish subtitles automatically — don't filter by "spanish" on Nyaa.

**Quality Definitions** (Settings → Quality) — set size limits for `Bluray-1080p`:

| Field | Value |
|---|---|
| Preferred | `50` MB/min |
| Max | `70` MB/min |

This keeps episodes under ~4 GB even for 60-minute episodes (70 MB/min × 60 min = 4.2 GB).

**Quality Profile** — enable `Bluray-1080p`, order from best to worst:

| Quality | Status |
|---|---|
| `Bluray-1080p` | ✅ |
| `WEB-DL-1080p` | ✅ |
| `WEBRip-1080p` | ✅ |
| `Remux-1080p` | ❌ |
| `Remux-2160p` | ❌ |
| `Bluray-2160p` | ❌ |

### Radarr — `http://jellypi.local:7878`

1. **Settings → Media Management → Root Folders:** add `/data/media/movies`
2. **Settings → Download Clients → + → qBittorrent:** Host `gluetun`, Port `8080`, Category `movies`
3. Copy the **API Key** from Settings → General

**Quality Definitions** (Settings → Quality) — set size limits for `Bluray-1080p`:

| Field | Value |
|---|---|
| Preferred | `80` MB/min |
| Max | `100` MB/min |

This caps BluRay encodes at ~12 GB for a 2-hour movie. Remux files (200+ MB/min) are rejected automatically.

**Quality Profile** — enable `Bluray-1080p`, disable oversized formats, order from best to worst:

| Quality | Status | Typical size |
|---|---|---|
| `Bluray-1080p` | ✅ | 4-12GB |
| `WEB-DL-1080p` | ✅ | 2-8GB |
| `WEBRip-1080p` | ✅ | 2-8GB |
| `Remux-1080p` | ❌ | 20-50GB |
| `Remux-2160p` | ❌ | 40-80GB |
| `Bluray-2160p` | ❌ | 40-80GB |

Radarr picks `Bluray-1080p` first when available; falls back to `WEB-DL-1080p`.

### Prowlarr — `http://jellypi.local:9696`

1. **Settings → Apps → + → Sonarr:** Prowlarr `http://prowlarr:9696`, Sonarr `http://sonarr:8989`, API Key
2. **Settings → Apps → + → Radarr:** Prowlarr `http://prowlarr:9696`, Radarr `http://radarr:7878`, API Key
3. **Indexers → + → Add Indexer**

Recommended indexers:

| Indexer | URL | For |
|---------|-----|-----|
| YTS | `https://yts.gg/` | Movies |
| The Pirate Bay | (first URL in list) | General |
| EZTV | (first URL in list) | TV Shows |
| Nyaa.si | `https://nyaa.si` | Anime |
| AnimeTosho | `https://animetosho.org` | Anime |

> 1337x is blocked at TCP level from Pi IPs — FlareSolverr cannot help. Nyaa.si and AnimeTosho have no aggressive Cloudflare.

**FlareSolverr** bypasses Cloudflare browser challenges for indexers that need it (e.g. EZTV):

1. **Settings → Indexers → Proxies → +** → FlareSolverr → Host `http://flaresolverr:8191` → tag `flaresolverr`
2. On each affected indexer, set the same tag `flaresolverr` in the **Tags** field

When adding Nyaa.si, verify **Settings → Apps → Sonarr → Sync Categories** includes anime categories (`Anime - English Translated`, `Anime - Raw`, etc.).

### Jellyfin — `http://jellypi.local:8096`

Add libraries in the first-run wizard:
- **Movies** → `/data/media/movies`
- **TV Shows** → `/data/media/tv`
- **Anime** → `/data/media/anime`

Hardware acceleration (Pi 4): **Dashboard → Playback → Transcoding → Video4Linux2 (V4L2)**

### Bazarr — `http://jellypi.local:6767`

1. **Settings → Providers → + → OpenSubtitles.com**
2. **Settings → Languages → + Add New Profile:** Spanish, Always — set as default for Series and Movies
3. **Settings → Sonarr:** host `sonarr`, port `8989`, API Key
4. **Settings → Radarr:** host `radarr`, port `7878`, API Key
5. **Settings → Jellyfin:** host `jellyfin`, port `8096`, API Key (Dashboard → API Keys → +)

### Seerr — `http://jellypi.local:5055`

1. Sign in with Jellyfin
2. Connect Sonarr (`http://sonarr:8989`) and Radarr (`http://radarr:7878`) with their API Keys

**Anime profile:** add a second Sonarr server in **Settings → Services → Sonarr → Add Sonarr Server** with the same config but Root Folder `/data/media/anime`, **Anime Series Type** on, and **Is Default for Anime** on.

> If you see ⚠️ on aired episodes after adding a series, click 🔍 on each to force a search — indexers may not be synced yet.

### Uptime Kuma — `http://jellypi.local:3001`

Choose SQLite on first run. Add one HTTP(s) monitor per service:

| Service | URL |
|---------|-----|
| Jellyfin | `http://jellyfin:8096` |
| Seerr | `http://seerr:5055` |
| Sonarr | `http://sonarr:8989` |
| Radarr | `http://radarr:7878` |
| Prowlarr | `http://prowlarr:9696` |
| qBittorrent | `http://gluetun:8080` |
| Bazarr | `http://bazarr:6767` |

### Gluetun (VPN)

Routes all qBittorrent traffic through PIA. Tailscale and the rest of the stack are unaffected.

Add to `.env`:

```
PIA_USER=your_pia_username
PIA_PASSWORD=your_pia_password
PIA_SERVER_REGION=Netherlands
```

```bash
docker compose up -d gluetun
docker compose up -d qbittorrent
```

> Always restart qBittorrent after restarting Gluetun — it shares Gluetun's network namespace.  
> PIA only supports OpenVPN in Gluetun (not WireGuard).

Verify the VPN is active:

```bash
docker exec gluetun wget -qO- https://ipinfo.io/ip
```

Measure VPN speed:

```bash
docker exec gluetun wget -O /dev/null https://speed.cloudflare.com/__down?bytes=10000000 2>&1 | tail -1
```

Benchmark all configured regions and apply the fastest:

```bash
chmod +x ~/jellypi/pia-benchmark.sh && ~/jellypi/pia-benchmark.sh
```

### Tailscale (remote access)

Add to `.env`:

```
TS_AUTHKEY=tskey-auth-xxxxxxxxxxxx
```

Generate the key at [tailscale.com/admin/settings/keys](https://tailscale.com/admin/settings/keys) — mark as **Reusable**.

```bash
docker compose up -d tailscale
docker exec tailscale tailscale status
```

The Pi appears as `jellypi` in [tailscale.com/admin/machines](https://tailscale.com/admin/machines) with a `100.x.x.x` IP. Use `http://100.x.x.x:<port>` to access services remotely.

### Decluttarr and Unpackerr (no UI)

Require these variables in `.env`:

```
SONARR_API_KEY=        # Settings → General → API Key in Sonarr
RADARR_API_KEY=        # Settings → General → API Key in Radarr
QBITTORRENT_PASSWORD=  # your qBittorrent password
PIA_USER=              # Private Internet Access username
PIA_PASSWORD=          # Private Internet Access password
```

Restrict `.env` permissions:

```bash
chmod 600 ~/jellypi/.env
```

- **Decluttarr** — removes stalled torrents and blocklists them in Sonarr/Radarr
- **Unpackerr** — extracts `.rar` files and notifies Sonarr/Radarr to import

---

## 6. Watch on Chromecast

Install the **Jellyfin** app from Google Play and add server `http://jellypi.local:8096`.

---

## Port reference

| Service      | Port |
|--------------|------|
| Jellyfin     | 8096 |
| Seerr        | 5055 |
| Sonarr       | 8989 |
| Radarr       | 7878 |
| Prowlarr     | 9696 |
| qBittorrent  | 8080 |
| Bazarr       | 6767 |
| Uptime Kuma  | 3001 |
| Gluetun      | exposes qBittorrent's 8080 and 6881 |
| Tailscale    | access via `100.x.x.x` |
| FlareSolverr | 8191 |

---

## Backup & restore

`backup.sh` stops all containers, tars the config dirs (excluding Jellyfin cache and metadata), then restarts. Run from `~/jellypi` on the Pi:

```bash
./backup.sh
# → backups/config-YYYYMMDD-HHMMSS.tar.gz
```

Copy the file off the Pi before reinstalling (scp, USB drive, etc.).

**Restore on a fresh install:**

```bash
git clone git@github.com:serginator/jellyPi.git ~/jellypi
cd ~/jellypi
cp /path/to/your/.env .env          # copy your real .env, not env.example
sudo bash setup.sh                  # formats HDD, installs Docker, system deps
docker compose up -d && sleep 30 && docker compose down   # let services initialize once
./restore.sh /path/to/backup.tar.gz # extracts config, wipes series/movie lists, starts up
```

After restore: Sonarr/Radarr have all your settings (quality profiles, custom formats, indexers, download clients) but no library. Re-add content via Seerr and scan libraries in Jellyfin.

---

## Clone the microSD

```bash
# On Mac, SD inserted as disk4:
sudo dd if=/dev/disk4 of=~/jellypi-backup.img bs=4m status=progress
# Restore:
sudo dd if=~/jellypi-backup.img of=/dev/disk4 bs=4m status=progress
```

---

## HDD structure

```
/mnt/storage/
├── data/
│   ├── torrents/
│   │   ├── movies/
│   │   ├── tv/
│   │   └── anime/          ← sonarr-anime category
│   └── media/
│       ├── movies/         ← Radarr (hardlink)
│       ├── tv/             ← Sonarr
│       └── anime/          ← Sonarr anime profile
├── config/
└── docker/
```

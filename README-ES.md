[🇬🇧 English](README.md) | 🇪🇸 Español

# jellypi

Media center para Raspberry Pi 4 con descarga automática de series y películas.

**Stack:** Jellyfin · Sonarr · Radarr · Prowlarr · qBittorrent · Seerr · Gluetun · Tailscale · FlareSolverr  
**Acceso en la tele:** App Jellyfin en Chromecast con Google TV  
**Añadir contenido:** Seerr desde el móvil o portátil  
**Acceso remoto:** Tailscale — sin abrir puertos en el router  
**VPN:** Gluetun + PIA (OpenVPN) — todo el tráfico de qBittorrent sale por la VPN

---

## Hardware necesario

- Raspberry Pi 4 (4GB o 8GB)
- microSD 32GB — High Endurance recomendada (Samsung PRO Endurance o SanDisk High Endurance)
- HDD externo USB de 2TB formateado en ext4
- Cable ethernet al router (recomendado) o WiFi
- Hub USB con alimentación propia si el HDD no tiene fuente propia

---

## 1. Preparar la microSD

Usa **Raspberry Pi Imager**: [raspberrypi.com/software](https://raspberrypi.com/software)

- **Device:** Raspberry Pi 4
- **OS:** Raspberry Pi OS Lite (64-bit) — en "Raspberry Pi OS (other)"
- **Storage:** tu microSD

Abre **Edit Settings** (⚙️) antes de flashear:

```
Hostname:   jellypi
Username:   pi
SSH:        Enable — Use password authentication
WiFi:       dejar vacío (usa ethernet)
```

---

## 2. Primer acceso por SSH

```bash
ssh pi@jellypi.local
```

Si `jellypi.local` no resuelve, busca la IP del Pi en tu router.

---

## 3. Setup del sistema

```bash
sudo apt install -y git
git clone https://github.com/serginator/jellyPi ~/jellypi
cd ~/jellypi
cp env.example .env
nano .env
```

Ejecuta el script de setup como root — formatea el HDD, instala Docker y log2ram, configura qBittorrent e instala el horario de descargas. El script preguntará qué dispositivo es el HDD (`lsblk` para verlos).

> ⚠️ El setup formatea el HDD. Selecciona el dispositivo correcto.

```bash
sudo bash setup.sh
sudo reboot
```

---

## 4. Levantar los servicios

```bash
cd ~/jellypi
docker compose up -d
docker compose ps
```

La primera vez descarga ~1.5GB de imágenes.

---

## 5. Configurar los servicios

Sustituye `jellypi.local` por la IP del Pi si el hostname no resuelve.

### qBittorrent — `http://jellypi.local:8080`

Credenciales por defecto: `admin` / `adminadmin`  
(Si no funcionan: `docker compose logs qbittorrent | grep password`)

`setup.sh` aplica toda la configuración automáticamente. Para editar manualmente:

```bash
nano /mnt/storage/config/qbittorrent/qBittorrent/qBittorrent.conf
docker compose restart qbittorrent
```

**Límites aplicados:**

| Parámetro | Valor |
|-----------|-------|
| Conexiones globales | 50 |
| Conexiones por torrent | 10 |
| Descargas activas | 1 |
| Seeds activos | 2 |
| DHT | activado |
| LSD | desactivado |
| Ratio máx | 1.0 (pausa al completar) |

**Horario de descarga** (via `qbt.sh`, instalado por `setup.sh`):

- `01:00` — reanuda todos los torrents
- `08:00` — pausa todos los torrents

> `qbt.sh` hace login en la API en cada llamada — qBittorrent 5.x ignora el bypass de auth para localhost. Actualiza la contraseña en el script si la cambias en qBittorrent.

En **Tools → Options → Downloads**, pon Default Save Path a `/data/torrents`.

Las categorías `tv` y `movies` las crea Sonarr/Radarr automáticamente. Para anime añade manualmente la categoría `sonarr-anime` con save path `/data/torrents/anime`.

### Sonarr — `http://jellypi.local:8989`

En el primer acceso: **Authentication Required → Disabled for Local Addresses**.

1. **Settings → Media Management → Root Folders:** añade `/data/media/tv` y `/data/media/anime`
2. **Settings → Download Clients → + → qBittorrent:** Host `gluetun`, Port `8080`, Category `tv`
3. Copia la **API Key** de Settings → General

**Anime:**

- Pon **Series Type = Anime** antes de guardar — activa numeración absoluta y búsqueda correcta en Nyaa.si
- Usa `/data/media/anime` como Root Folder
- Si una serie muestra "No results found", usa **Interactive Search** para diagnosticar
- Pon **Monitored = No** en episodios ya vistos para no volver a descargarlos

**Custom Formats** (Settings → Custom Formats → +, condición Release Title, regex, case insensitive):

| Custom Format | Regex | Score |
|---|---|---|
| `Dub` | `english.?dub\|\[dub\]\|dubbed` | `-10000` |
| `Hardcoded Subs` | `dubbed\|hardcoded\|hard.?sub\|hcsub\|\bhs\b` | `-10000` |
| `Trusted Anime Groups` | `subsplease\|erai.raws\|kawaiika.raws` | `+100` |

Bazarr añade subtítulos en español automáticamente — no filtres por "spanish" en Nyaa.

### Radarr — `http://jellypi.local:7878`

1. **Settings → Media Management → Root Folders:** añade `/data/media/movies`
2. **Settings → Download Clients → + → qBittorrent:** Host `gluetun`, Port `8080`, Category `movies`
3. Copia la **API Key** de Settings → General

**Quality Profile** — desactiva los formatos de mayor tamaño:

| Calidad | Estado | Tamaño típico |
|---------|--------|---------------|
| `Remux-1080p` | ❌ | 20-50GB |
| `Remux-2160p` | ❌ | 40-80GB |
| `Bluray-2160p` | ❌ | 40-80GB |
| `WEB-DL-1080p` | ✅ | 2-8GB |
| `WEBRip-1080p` | ✅ | 2-8GB |

### Prowlarr — `http://jellypi.local:9696`

1. **Settings → Apps → + → Sonarr:** Prowlarr `http://prowlarr:9696`, Sonarr `http://sonarr:8989`, API Key
2. **Settings → Apps → + → Radarr:** Prowlarr `http://prowlarr:9696`, Radarr `http://radarr:7878`, API Key
3. **Indexers → + → Add Indexer**

Indexers recomendados:

| Indexer | URL | Para |
|---------|-----|------|
| YTS | `https://yts.gg/` | Películas |
| The Pirate Bay | (primera URL de la lista) | General |
| EZTV | (primera URL de la lista) | Series |
| Nyaa.si | `https://nyaa.si` | Anime |
| AnimeTosho | `https://animetosho.org` | Anime |

> 1337x está bloqueado a nivel TCP desde IPs del Pi — FlareSolverr no ayuda. Nyaa.si y AnimeTosho no tienen Cloudflare agresivo.

**FlareSolverr** bypasea los Cloudflare browser challenges en indexers que lo necesitan (ej. EZTV):

1. **Settings → Indexers → Proxies → +** → FlareSolverr → Host `http://flaresolverr:8191` → tag `flaresolverr`
2. En cada indexer afectado, añade el mismo tag `flaresolverr` en el campo **Tags**

Al añadir Nyaa.si, verifica que **Settings → Apps → Sonarr → Sync Categories** incluye categorías de anime (`Anime - English Translated`, `Anime - Raw`, etc.).

### Jellyfin — `http://jellypi.local:8096`

Añade las bibliotecas en el asistente de primer arranque:
- **Movies** → `/data/media/movies`
- **TV Shows** → `/data/media/tv`
- **Anime** → `/data/media/anime`

Hardware acceleration (Pi 4): **Dashboard → Playback → Transcoding → Video4Linux2 (V4L2)**

### Bazarr — `http://jellypi.local:6767`

1. **Settings → Providers → + → OpenSubtitles.com**
2. **Settings → Languages → + Add New Profile:** Spanish, Always — márcalo como perfil por defecto en Series y Películas
3. **Settings → Sonarr:** host `sonarr`, port `8989`, API Key
4. **Settings → Radarr:** host `radarr`, port `7878`, API Key
5. **Settings → Jellyfin:** host `jellyfin`, port `8096`, API Key (Dashboard → API Keys → +)

### Seerr — `http://jellypi.local:5055`

1. Sign in with Jellyfin
2. Conecta Sonarr (`http://sonarr:8989`) y Radarr (`http://radarr:7878`) con sus API Keys

**Perfil de anime:** añade un segundo servidor de Sonarr en **Settings → Services → Sonarr → Add Sonarr Server** con la misma config pero Root Folder `/data/media/anime`, **Anime Series Type** activado e **Is Default for Anime** activado.

> Si ves ⚠️ en episodios ya emitidos al añadir una serie, pulsa 🔍 en cada uno para forzar la búsqueda — los indexers pueden no estar sincronizados aún.

### Uptime Kuma — `http://jellypi.local:3001`

Elige SQLite en el primer arranque. Añade un monitor HTTP(s) por servicio:

| Servicio | URL |
|---------|-----|
| Jellyfin | `http://jellyfin:8096` |
| Seerr | `http://seerr:5055` |
| Sonarr | `http://sonarr:8989` |
| Radarr | `http://radarr:7878` |
| Prowlarr | `http://prowlarr:9696` |
| qBittorrent | `http://gluetun:8080` |
| Bazarr | `http://bazarr:6767` |

### Gluetun (VPN)

Enruta todo el tráfico de qBittorrent por PIA. Tailscale y el resto del stack no se ven afectados.

Añade en `.env`:

```
PIA_USER=tu_usuario_pia
PIA_PASSWORD=tu_contraseña_pia
PIA_SERVER_REGION=Netherlands
```

```bash
docker compose up -d gluetun
docker compose up -d qbittorrent
```

> Reinicia siempre qBittorrent después de reiniciar Gluetun — comparte su namespace de red.  
> PIA solo soporta OpenVPN en Gluetun (no WireGuard).

Verifica que la VPN está activa:

```bash
docker exec gluetun wget -qO- https://ipinfo.io/ip
```

Mide la velocidad de la VPN:

```bash
docker exec gluetun wget -O /dev/null https://speed.cloudflare.com/__down?bytes=10000000 2>&1 | tail -1
```

Benchmark de regiones — prueba todas y aplica la más rápida:

```bash
chmod +x ~/jellypi/pia-benchmark.sh && ~/jellypi/pia-benchmark.sh
```

### Tailscale (acceso remoto)

Añade en `.env`:

```
TS_AUTHKEY=tskey-auth-xxxxxxxxxxxx
```

Genera la key en [tailscale.com/admin/settings/keys](https://tailscale.com/admin/settings/keys) — marca **Reusable**.

```bash
docker compose up -d tailscale
docker exec tailscale tailscale status
```

El Pi aparece como `jellypi` en [tailscale.com/admin/machines](https://tailscale.com/admin/machines) con una IP `100.x.x.x`. Accede a los servicios con `http://100.x.x.x:<puerto>`.

### Decluttarr y Unpackerr (sin UI)

Requieren estas variables en `.env`:

```
SONARR_API_KEY=        # Settings → General → API Key en Sonarr
RADARR_API_KEY=        # Settings → General → API Key en Radarr
QBITTORRENT_PASSWORD=  # tu contraseña de qBittorrent
PIA_USER=              # usuario de Private Internet Access
PIA_PASSWORD=          # contraseña de Private Internet Access
```

Restringe los permisos del `.env`:

```bash
chmod 600 ~/jellypi/.env
```

- **Decluttarr** — elimina torrents atascados y los bloquea en Sonarr/Radarr
- **Unpackerr** — extrae `.rar` y notifica a Sonarr/Radarr para importar

---

## 6. Ver contenido en el Chromecast

Instala la app **Jellyfin** desde Google Play y añade el servidor `http://jellypi.local:8096`.

---

## Puertos de referencia

| Servicio     | Puerto |
|--------------|--------|
| Jellyfin     | 8096   |
| Seerr        | 5055   |
| Sonarr       | 8989   |
| Radarr       | 7878   |
| Prowlarr     | 9696   |
| qBittorrent  | 8080   |
| Bazarr       | 6767   |
| Uptime Kuma  | 3001   |
| Gluetun      | expone el 8080 y 6881 de qBittorrent |
| Tailscale    | acceso vía `100.x.x.x` |
| FlareSolverr | 8191 |

---

## Clonar la microSD

```bash
# En Mac, SD insertada como disk4:
sudo dd if=/dev/disk4 of=~/jellypi-backup.img bs=4m status=progress
# Restaurar:
sudo dd if=~/jellypi-backup.img of=/dev/disk4 bs=4m status=progress
```

---

## Estructura del HDD

```
/mnt/storage/
├── data/
│   ├── torrents/
│   │   ├── movies/
│   │   ├── tv/
│   │   └── anime/          ← categoría sonarr-anime
│   └── media/
│       ├── movies/         ← Radarr (hardlink)
│       ├── tv/             ← Sonarr
│       └── anime/          ← Sonarr perfil anime
├── config/
└── docker/
```

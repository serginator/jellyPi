[🇬🇧 English](README.md) | 🇪🇸 Español

<img width="1376" height="768" alt="image" src="https://github.com/user-attachments/assets/fe77c9b3-d658-4faf-95a1-915a38e320aa" />

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

Cuando Sonarr y Radarr estén arriba, ejecuta `post-setup.sh` para leer sus API keys autogeneradas en `.env` y configurar de una vez las notificaciones de Telegram y decluttarr (necesita `TELEGRAM_BOT_TOKEN`/`TELEGRAM_CHAT_ID` y `QBITTORRENT_PASSWORD` ya puestos en `.env` — omite lo que no esté configurado):

```bash
chmod +x ~/jellypi/post-setup.sh && ~/jellypi/post-setup.sh
```

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
| Conexiones globales | 200 |
| Conexiones por torrent | 40 |
| Descargas activas | 4 |
| Subidas activas (seeds) | 1 |
| Slots máx. de subida | 4 |
| Límite de subida | 1200 KiB/s |
| Ratio máx | 0.2 (pausa al completar)

> Aumentado desde los límites originales más conservadores (50/10 conexiones, 500 KiB/s de subida) tras añadir Gluetun: el túnel VPN aparece como una única conexión de cara al router doméstico (en vez de una por cada peer), así que la saturación de la tabla de conexiones del router deja de ser un problema. El horario de descarga (ver abajo) sigue manteniendo toda la actividad de torrents parada en horario laboral.

**Horario de descarga** (via `qbt.sh`, instalado por `setup.sh`):

- Cada 30 min de `01:00` a `07:30` — reanuda todos los torrents (coge los que se añadan durante la noche)
- `08:00` — pausa todos los torrents

> `qbt.sh` hace login en la API en cada llamada — qBittorrent 5.x ignora el bypass de auth para localhost. Actualiza la contraseña en el script si la cambias en qBittorrent.

**Reinicio diario**: `08:05`, 5 minutos después de pausar los torrents — limpia cualquier estado atascado (fugas de memoria, sockets colgados) sin intervención. Instalado por `setup.sh` mediante una regla de sudoers limitada a `NOPASSWD: /usr/sbin/reboot` (nada más) para el usuario principal, así el cron no necesita contraseña. Comprobar con `sudo cat /etc/sudoers.d/<usuario>-reboot` y `crontab -l`.

En **Tools → Options → Downloads**, pon Default Save Path a `/data/torrents`.

Las categorías `tv` y `movies` las crea Sonarr/Radarr automáticamente. Para anime añade manualmente la categoría `sonarr-anime` con save path `/data/torrents/anime`.

**Bloquear archivos ejecutables** (a veces aparecen releases falsos/malware disfrazados de episodios antes de la fecha real de estreno — Sonarr no puede detectarlos porque el nombre parece legítimo y el tamaño no siempre es sospechoso). `setup.sh` lo aplica automáticamente en instalaciones nuevas. Para editarlo manualmente, en **Tools → Options → Downloads → Excluded file names**, añade:

```
*.exe
*.scr
*.bat
*.cmd
*.com
*.msi
*.js
*.vbs
*.jar
*.ps1
*.zipx
```

> Bug conocido en qBittorrent 5.0.x donde este filtro no se aplica (arreglado en versiones posteriores) — comprueba tu versión en Help → About si no parece funcionar.

Si se cuela un torrent falso, bórralo desde **Sonarr → Activity → Queue** (icono de papelera → marcar "Blocklist") en vez de borrarlo directamente en qBittorrent — así se bloquea ese release concreto para que Sonarr no lo vuelva a coger, y lanza una búsqueda inmediata de otra fuente. El episodio sigue monitorizado de todas formas, así que Sonarr cogerá el release real en cuanto se estrene, sin intervención manual.

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

**Quality Definitions** (Settings → Quality) — configura los límites de tamaño para `Bluray-1080p`:

| Campo | Valor |
|-------|-------|
| Preferred | `50` MB/min |
| Max | `70` MB/min |

Esto mantiene los episodios por debajo de ~4 GB incluso para episodios de 60 minutos (70 MB/min × 60 min = 4.2 GB).

**Quality Profile** — activa `Bluray-1080p`, ordena de mejor a peor:

| Calidad | Estado |
|---------|--------|
| `Bluray-1080p` | ✅ |
| `WEB-DL-1080p` | ✅ |
| `WEBRip-1080p` | ✅ |
| `Remux-1080p` | ❌ |
| `Remux-2160p` | ❌ |
| `Bluray-2160p` | ❌ |

### Radarr — `http://jellypi.local:7878`

1. **Settings → Media Management → Root Folders:** añade `/data/media/movies`
2. **Settings → Download Clients → + → qBittorrent:** Host `gluetun`, Port `8080`, Category `movies`
3. Copia la **API Key** de Settings → General

**Quality Definitions** (Settings → Quality) — configura los límites de tamaño para `Bluray-1080p`:

| Campo | Valor |
|-------|-------|
| Preferred | `80` MB/min |
| Max | `100` MB/min |

Esto limita los encodes BluRay a ~12 GB para una película de 2 horas. Los archivos Remux (200+ MB/min) se rechazan automáticamente.

**Quality Profile** — activa `Bluray-1080p`, desactiva los formatos grandes, ordena de mejor a peor:

| Calidad | Estado | Tamaño típico |
|---------|--------|---------------|
| `Bluray-1080p` | ✅ | 4-12GB |
| `WEB-DL-1080p` | ✅ | 2-8GB |
| `WEBRip-1080p` | ✅ | 2-8GB |
| `Remux-1080p` | ❌ | 20-50GB |
| `Remux-2160p` | ❌ | 40-80GB |
| `Bluray-2160p` | ❌ | 40-80GB |

Radarr elige `Bluray-1080p` primero si hay resultado; si no, cae a `WEB-DL-1080p`.

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

### Homepage (dashboard) — `http://jellypi.local:3000`

Una única página con un enlace + estadísticas en vivo de cada servicio (colas, espacio en disco, qué se está reproduciendo...), para no tener que recordar cada puerto.

Ejecuta una vez que Sonarr, Radarr y Prowlarr hayan arrancado al menos una vez:

```bash
chmod +x ~/jellypi/homepage-setup.sh && ~/jellypi/homepage-setup.sh
```

Esto lee las API keys que ya están en `.env`/generadas por Sonarr/Radarr/Prowlarr y escribe `services.yaml`, `widgets.yaml` y `settings.yaml` en `$STORAGE/config/homepage`. Jellyfin, Seerr, Bazarr y Tailscale se añaden solo como enlaces por defecto (sus keys no se generan automáticamente) — para tener también widgets con ellos:

| Servicio | Dónde conseguir la key | Variable(s) en `.env` |
|----------|-------------------------|------------------------|
| Jellyfin | Dashboard → API Keys → + | `JELLYFIN_API_KEY` |
| Seerr | Settings → General → API Key | `SEERR_API_KEY` |
| Bazarr | Settings → General → API Key | `BAZARR_API_KEY` |
| Tailscale | [Access token](https://login.tailscale.com/admin/settings/keys) + [device ID](https://login.tailscale.com/admin/machines) (selecciona la Pi → Machine Details → ID) | `TAILSCALE_API_KEY` + `TAILSCALE_DEVICE_ID` |

El widget de Jellyfin muestra el total de películas/series/episodios y qué se está reproduciendo — no puede separar el anime porque Jellyfin cuenta por tipo de elemento en todo el servidor, no por librería. Bazarr muestra el número de episodios/películas con subtítulos pendientes.

Añade las keys que quieras a `.env` y vuelve a ejecutar:

```bash
./homepage-setup.sh
docker compose restart homepage
```

(`docker compose up -d` no basta — igual que con decluttarr, no detecta cambios en un archivo montado por bind mount sin un reinicio real.)

#### Tema visual

Pon `HOMEPAGE_THEME=cyberpunk` en `.env` para un look neón/oscuro (color de acento + superposición de scanlines + brillo en títulos y enlaces), luego vuelve a ejecutar `./homepage-setup.sh` y `docker compose restart homepage`. Déjalo sin definir (o con cualquier otro valor) para el look por defecto.

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

El script incluye una lista predefinida de regiones con ping bajo en la variable `REGIONS`, al principio de `pia-benchmark.sh`. Para probar otras regiones, edita esa variable.

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

`post-setup.sh` (ver [paso 4](#4-levantar-los-servicios)) rellena `SONARR_API_KEY`/`RADARR_API_KEY` automáticamente y configura decluttarr — el resto de esta sección solo aplica si necesitas repetirlo a mano.

Restringe los permisos del `.env`:

```bash
chmod 600 ~/jellypi/.env
```

- **Decluttarr** — elimina torrents atascados y los bloquea en Sonarr/Radarr
- **Unpackerr** — extrae `.rar` y notifica a Sonarr/Radarr para importar

Decluttarr v2+ dejó de soportar variables de entorno por servicio — ahora lee un `config.yaml` montado. Ejecuta esto una vez que Sonarr/Radarr hayan arrancado al menos una vez y el `.env` tenga las API keys reales:

```bash
chmod +x ~/jellypi/decluttarr-setup.sh && ~/jellypi/decluttarr-setup.sh
docker compose restart decluttarr
```

Vuelve a ejecutarlo si cambian las API keys o la contraseña de qBittorrent en `.env`.

### Diun (sin UI)

Vigila todos los contenedores por si hay una versión nueva de imagen en su registro (todos los servicios aquí usan `:latest`) y avisa por Telegram — **no** actualiza nada automáticamente, solo notifica cuando hay algo nuevo que descargar. Reutiliza `TELEGRAM_BOT_TOKEN` y `TELEGRAM_CHAT_ID` del `.env`, sin configuración extra. Comprueba a diario a las 6am (`DIUN_WATCH_SCHEDULE`).

### Notificaciones de Telegram

Sonarr y Radarr notifican contenido añadido al seguimiento y descargas finalizadas (incluidas mejoras de calidad) mediante su integración nativa con Telegram — sin necesidad de un bot propio. Uptime Kuma notifica cambios de estado en los chequeos de la misma forma.

`post-setup.sh` (ver [paso 4](#4-levantar-los-servicios)) ejecuta `telegram-setup.sh` automáticamente si `TELEGRAM_BOT_TOKEN`/`TELEGRAM_CHAT_ID` ya están puestos en `.env` — los pasos siguientes son para la configuración inicial de esas variables o para repetirlo a mano.

1. Crea un bot con [@BotFather](https://t.me/BotFather) y copia el bot token
2. Escribe al bot y luego abre `https://api.telegram.org/bot<TOKEN>/getUpdates` para obtener tu `chat_id`
3. Añade a `.env`:

```
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
```

4. Ejecuta el script de configuración desde `~/jellypi` en el Pi para configurar Sonarr y Radarr automáticamente:

```bash
chmod +x ~/jellypi/telegram-setup.sh && ~/jellypi/telegram-setup.sh
```

5. Configura Uptime Kuma manualmente (no tiene una API REST simple): Settings → Notifications → Add → **Telegram**, usando el mismo Bot Token y Chat ID, y actívala en cada monitor (o marca "Apply on all existing monitors").

> Por qué Sonarr/Radarr en vez de qBittorrent para las notificaciones de descargas: qBittorrent no tiene concepto de "añadido al seguimiento" y sus eventos de finalización solo llevan el nombre crudo del torrent, sin metadata de serie/película. Las notificaciones de Sonarr/Radarr incluyen título, temporada/episodio o año, y calidad.

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
| Homepage     | 3000   |
| Gluetun      | expone el 8080 y 6881 de qBittorrent |
| Tailscale    | acceso vía `100.x.x.x` |
| FlareSolverr | 8191 |

---

## Backup y restauración

`backup.sh` para todos los contenedores, crea un tar de los directorios de config (sin cache ni metadata de Jellyfin) y los reinicia. Ejecutar desde `~/jellypi` en el Pi:

```bash
./backup.sh
# → backups/config-YYYYMMDD-HHMMSS.tar.gz
```

Copia el fichero fuera del Pi antes de reinstalar (scp, USB, etc.).

**Restaurar en una instalación nueva:**

```bash
git clone git@github.com:serginator/jellyPi.git ~/jellypi
cd ~/jellypi
cp /ruta/a/tu/.env .env             # copia tu .env real, no el env.example
sudo bash setup.sh                  # formatea el HDD, instala Docker y deps del sistema
docker compose up -d && sleep 30 && docker compose down   # deja que los servicios inicialicen
./restore.sh /ruta/al/backup.tar.gz # extrae config, borra listas de series/películas, arranca
```

Tras la restauración: Sonarr/Radarr tienen toda la configuración (quality profiles, custom formats, indexers, download clients) pero sin librería. Vuelve a añadir contenido por Seerr y escanea las librerías en Jellyfin.

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

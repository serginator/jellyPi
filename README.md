# jellypi

Media center para Raspberry Pi 4 con descarga automática de series y películas.

**Stack:** Jellyfin · Sonarr · Radarr · Prowlarr · qBittorrent · Seerr · Tailscale  
**Acceso en la tele:** App Jellyfin en Chromecast con Google TV  
**Añadir contenido:** Seerr desde el móvil o portátil  
**Acceso remoto:** Tailscale — disponible desde cualquier sitio sin abrir puertos

---

## Hardware necesario

- Raspberry Pi 4 (4GB o 8GB)
- microSD 32GB (High Endurance recomendada: Samsung PRO Endurance o SanDisk High Endurance)
- Disco duro externo USB de 2TB formateado en ext4
- Cable ethernet al router (recomendado) o WiFi
- Hub USB con alimentación propia si el HDD no tiene fuente propia — el HDD consume corriente al arrancar y puede impedir que el Pi conecte al WiFi

---

## 1. Preparar la microSD

Usa **Raspberry Pi Imager** (no balenaEtcher) porque permite configurar SSH y usuario antes de flashear.

Descarga: [raspberrypi.com/software](https://raspberrypi.com/software)

En el Imager:
- **Device:** Raspberry Pi 4
- **OS:** Raspberry Pi OS Lite (64-bit) — en "Raspberry Pi OS (other)"
- **Storage:** tu microSD

Antes de flashear, abre **Edit Settings** (⚙️) y configura:

```
Hostname:   jellypi
Username:   pi
Password:   la que quieras
SSH:        Enable — Use password authentication
WiFi:       dejar vacío (usa ethernet)
Locale:     Europe/Madrid / es
```

No habilites Raspberry Pi Connect.

Flashea y espera. Inserta la SD en el Pi y conéctalo al router por ethernet.

---

## 2. Primer acceso por SSH

Desde el Mac (o cualquier equipo en la misma red):

```bash
ssh pi@jellypi.local
```

Si `jellypi.local` no resuelve, busca la IP del Pi en tu router y usa `ssh pi@<IP>`.

---

## 3. Setup del sistema

Instala git e instala el repositorio en el Pi:

```bash
sudo apt install -y git
git clone https://github.com/serginator/jellyPi ~/jellypi
cd ~/jellypi
```

Copia y ajusta el `.env`:

```bash
cp env.example .env
# Edita TZ si no estás en Europe/Madrid
nano .env
```

Ejecuta el script de setup como root. El script:
- Formatea y monta el disco duro externo en `/mnt/storage`
- Crea la estructura de directorios
- Desactiva el swap
- Configura tmpfs para `/tmp` y `/var/tmp`
- Instala log2ram (logs en RAM, no en SD)
- Instala Docker y mueve sus datos al HDD
- Configura `gpu_mem=128` para hardware acceleration en Jellyfin
- Instala VueTorrent (UI móvil para qBittorrent)
- Escribe la configuración inicial de qBittorrent (límites de red, VueTorrent, sin auth localhost)
- Instala los crons de pause/resume via `qbt.sh`

```bash
sudo bash setup.sh
```

El script te preguntará qué dispositivo es el HDD (`sda`, `sda1`, etc.). Puedes verlos con `lsblk`.

> ⚠️ El setup formatea el HDD. Asegúrate de seleccionar el dispositivo correcto.

Reinicia cuando termine:

```bash
sudo reboot
```

---

## 4. Levantar los servicios

Tras el reinicio, vuelve por SSH y arranca todo:

```bash
cd ~/jellypi
docker compose up -d
```

La primera vez tarda unos minutos mientras descarga las imágenes (~1.5GB en total).

Comprueba que todo está corriendo:

```bash
docker compose ps
```

---

## 5. Configurar los servicios

Sustituye `jellypi.local` por la IP del Pi si el hostname no resuelve.

### qBittorrent — `http://jellypi.local:8080`

Credenciales por defecto: `admin` / `adminadmin`  
(Si no funcionan, mira el log: `docker compose logs qbittorrent | grep password`)

La configuración de conexiones y la UI alternativa (VueTorrent) las aplica `setup.sh` automáticamente antes del primer arranque. Si necesitas ajustar algo manualmente, edita:

```bash
nano /mnt/storage/config/qbittorrent/qBittorrent/qBittorrent.conf
docker compose restart qbittorrent
```

**Límites de red aplicados** (para no saturar el router):

| Parámetro | Valor |
|-----------|-------|
| Conexiones globales | 50 |
| Conexiones por torrent | 10 |
| Descargas activas | 1 |
| Seeds activos | 2 |
| DHT | activado |
| LSD | desactivado |
| Ratio máx | 1.0 (pausa al completar) |

**Horario de descarga** — los crons los instala `setup.sh` automáticamente en el usuario principal via `qbt.sh`:

- `01:00` — reanuda todos los torrents (`qbt.sh start`)
- `07:00` — pausa todos los torrents (`qbt.sh stop`)

> `qbt.sh` hace login en la API antes de cada llamada porque qBittorrent 5.x ignora el bypass de autenticación para localhost. Actualiza la contraseña en el script si la cambias en qBittorrent.

Para gestionar desde el móvil usa el WebUI en `http://jellypi.local:8080` — VueTorrent está optimizado para pantallas pequeñas.

En **Tools → Options → Downloads:**
- Default Save Path: `/data/torrents`

Las categorías `tv` y `movies` las crea Sonarr/Radarr automáticamente al conectarse.

Para anime añade manualmente la categoría `sonarr-anime` con save path `/data/torrents/anime`.

### Sonarr — `http://jellypi.local:8989`

En el primer acceso activa **Authentication Required → Disabled for Local Addresses** para no tener que hacer login desde la red local.

1. **Settings → Media Management → Root Folders:** añade `/data/media/tv` y `/data/media/anime`
2. **Settings → Download Clients → + → qBittorrent:**
   - Host: `qbittorrent` · Port: `8080`
   - Category: `tv`
3. Copia la **API Key** de Settings → General (la necesitarás para Prowlarr y Seerr)

**Anime en Sonarr:**

- Cuando añades una serie anime, cambia **Series Type** de `Standard` a `Anime` antes de guardar. Esto activa numeración absoluta y búsqueda correcta en Nyaa.si.
- Selecciona `/data/media/anime` como Root Folder en vez de `/data/media/tv`.
- Si una serie muestra "No results found", usa **Interactive Search** en el episodio para ver qué devuelve el indexer y por qué descarta resultados.
- Si ya tienes episodios vistos al añadir la serie, desmarca los episodios vistos en Sonarr para que no los descargue: entra a la temporada y pon **Monitored = No** en los episodios que ya tienes.

**Custom Formats para anime:**

Crea estos en **Settings → Custom Formats → +**. Todos usan condición Release Title (regex, case insensitive):

| Custom Format | Regex | Score en Quality Profile |
|---|---|---|
| `Dub` | `english.?dub\|\[dub\]\|dubbed` | `-10000` |
| `Hardcoded Subs` | `dubbed\|hardcoded\|hard.?sub\|hcsub\|\bhs\b` | `-10000` |
| `Trusted Anime Groups` | `subsplease\|erai.raws\|kawaiika.raws` | `+100` |

Los dos primeros evitan doblajes en inglés y subtítulos quemados. El tercero prioriza grupos que publican japonés con subs en inglés (sin hardcode). Bazarr añade los subtítulos en español automáticamente después de la descarga — no filtres por "spanish" en Nyaa, casi ningún release lo incluye.

### Radarr — `http://jellypi.local:7878`

1. **Settings → Media Management → Root Folders:** añade `/data/media/movies`
2. **Settings → Download Clients → + → qBittorrent:**
   - Host: `qbittorrent` · Port: `8080`
   - Category: `movies`
3. Copia la **API Key** de Settings → General

**Quality Profile — tamaño de fichero:**

En **Settings → Quality Profiles → (tu perfil)** desactiva las calidades que generan ficheros de 20-50GB:

| Calidad | Estado | Tamaño típico |
|---|---|---|
| `Remux-1080p` | ❌ desactivar | 20-50GB |
| `Remux-2160p` | ❌ desactivar | 40-80GB |
| `Bluray-2160p` | ❌ desactivar | innecesario en Pi |
| `Bluray-1080p` | ⚠️ opcional | 6-15GB |
| `WEB-DL-1080p` | ✅ activar | 2-8GB |
| `WEBRip-1080p` | ✅ activar | 2-8GB |

Para ficheros de 2-6GB deja solo `WEB-DL-1080p` y `WEBRip-1080p`. La diferencia visual respecto a un remux en una tele normal es inapreciable.

Si quieres techo de tamaño por calidad: **Settings → Quality** → edita cada entrada → campo **Max**.

### Prowlarr — `http://jellypi.local:9696`

1. **Settings → Apps → + → Sonarr:**
   - Prowlarr Server: `http://prowlarr:9696`
   - Sonarr Server: `http://sonarr:8989`
   - API Key: la de Sonarr
2. **Settings → Apps → + → Radarr:**
   - Prowlarr Server: `http://prowlarr:9696`
   - Radarr Server: `http://radarr:7878`
   - API Key: la de Radarr
3. **Indexers → + → Add Indexer:** añade tus indexers

Indexers que funcionan bien desde Pi:

| Indexer | Base URL | Para qué |
|---------|----------|----------|
| YTS | `https://yts.gg/` | Películas |
| The Pirate Bay | (primera URL de la lista) | General |
| Nyaa.si | `https://nyaa.si` | Anime |
| AnimeTosho | `https://animetosho.org` | Anime (mejor cobertura, incluye subtítulos) |

> EZTV y 1337x están bloqueados por Cloudflare desde IPs de Pi. En cada indexer elige siempre la primera URL que no sea un proxy (`proxyninja`, `torrentbay`, etc.). Nyaa.si y AnimeTosho no tienen Cloudflare agresivo.

Al añadir Nyaa.si en Prowlarr, verifica que **Settings → Apps → Sonarr → Sync Categories** incluye categorías de anime (`Anime - English Translated`, `Anime - Raw`, etc.). Sin esto Sonarr no recibe resultados.

### Jellyfin — `http://jellypi.local:8096`

En el asistente de primer arranque:
- Añade biblioteca **Movies** → carpeta: `/data/media/movies`
- Añade biblioteca **TV Shows** → carpeta: `/data/media/tv`
- Añade biblioteca **TV Shows** (o **Anime**) → carpeta: `/data/media/anime`

Para activar hardware acceleration (Pi 4):
- **Dashboard → Playback → Transcoding**
- Hardware acceleration: `Video4Linux2 (V4L2)`

### Bazarr — `http://jellypi.local:6767`

Descarga subtítulos automáticamente al terminar cada descarga.

1. **Settings → Providers → + → OpenSubtitles.com:** usuario y contraseña de opensubtitles.com
2. **Settings → Languages → + Add New Profile:** añade `Spanish`, Search only when `Always`. Guarda y márcalo como perfil por defecto en Series y Películas
3. **Settings → Sonarr:** host `sonarr`, port `8989`, API Key de Sonarr
4. **Settings → Radarr:** host `radarr`, port `7878`, API Key de Radarr
5. **Settings → Jellyfin:** host `jellyfin`, port `8096`, API Key de Jellyfin (Dashboard → API Keys → +) — notifica a Jellyfin al descargar subtítulos

### Seerr (antes Jellyseerr) — `http://jellypi.local:5055`

1. **Sign in with Jellyfin** usando tus credenciales de Jellyfin
2. Conecta con Sonarr y Radarr usando sus API Keys y `http://sonarr:8989` / `http://radarr:7878`

**Perfil de anime en Seerr:**

Añade un segundo servidor de Sonarr en **Settings → Services → Sonarr → Add Sonarr Server** con la misma configuración pero:
- Default Root Folder: `/data/media/anime`
- Activa **Anime Series Type**
- Activa **Is Default for Anime**

Con esto, el contenido etiquetado como anime en TMDB/TVDB se manda a Sonarr con la configuración correcta automáticamente. Si TMDB no lo etiqueta como anime, selecciona el perfil manualmente al pedir la serie.

Desde ahora buscas aquí lo que quieres ver y se descarga solo con subtítulos en español.

> Si al añadir una serie ves ⚠️ en episodios ya emitidos, pulsa el 🔍 de cada episodio para forzar la búsqueda. Ocurre cuando los indexers aún no están sincronizados con Prowlarr. Las descargas futuras son automáticas.

### Uptime Kuma — `http://jellypi.local:3001`

Monitoreo de todos los servicios. En el primer arranque elige **SQLite**.

Añade un monitor por cada servicio con tipo **HTTP(s)** y URL interna (nombre de contenedor):

| Servicio | URL |
|---|---|
| Jellyfin | `http://jellyfin:8096` |
| Seerr | `http://seerr:5055` |
| Sonarr | `http://sonarr:8989` |
| Radarr | `http://radarr:7878` |
| Prowlarr | `http://prowlarr:9696` |
| qBittorrent | `http://qbittorrent:8080` |
| Bazarr | `http://bazarr:6767` |

### Tailscale (acceso remoto)

Permite acceder a todos los servicios desde fuera de casa sin abrir puertos en el router. Funciona aunque tu ISP use CGNAT.

Antes de arrancar el contenedor añade en `.env`:

```
TS_AUTHKEY=tskey-auth-xxxxxxxxxxxx
```

Genera la key en [tailscale.com/admin/settings/keys](https://tailscale.com/admin/settings/keys) — marca **Reusable**.

```bash
docker compose up -d tailscale
docker exec tailscale tailscale status   # verifica que aparece "jellypi"
```

El Pi aparece como `jellypi` en [tailscale.com/admin/machines](https://tailscale.com/admin/machines) con una IP `100.x.x.x`. Desde fuera accedes a `http://100.x.x.x:8096` para Jellyfin, `100.x.x.x:5055` para Seerr, etc.

Si también usas Tailscale en el trabajo, añade la cuenta personal en la app móvil (**Add another account**) y cambia entre ellas con un tap.

### Decluttarr y Unpackerr (sin UI)

Servicios sin interfaz que funcionan en segundo plano. Solo necesitan las variables en `.env`:

```
SONARR_API_KEY=   # Settings → General → API Key en Sonarr
RADARR_API_KEY=   # Settings → General → API Key en Radarr
QBITTORRENT_PASSWORD=   # tu contraseña de qBittorrent
```

- **Decluttarr** — detecta torrents atascados sin seeds y los elimina de qBittorrent. Bloquea el torrent en Sonarr/Radarr para que busquen otra fuente.
- **Unpackerr** — extrae ficheros `.rar` automáticamente tras la descarga y notifica a Sonarr/Radarr para importar el contenido.

---

## 6. Ver contenido en el Chromecast

Instala la app **Jellyfin** desde Google Play en el Chromecast con Google TV.  
Añade servidor: `http://jellypi.local:8096`

No necesitas nada más. La Pi no va conectada a la tele.

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
| Tailscale    | (sin puerto — acceso vía IP Tailscale `100.x.x.x`) |

---

## Clonar la microSD (recomendado antes de cambiarla)

```bash
# En Mac, con la SD insertada en disk4:
sudo dd if=/dev/disk4 of=~/jellypi-backup.img bs=4m status=progress
```

Para restaurar o migrar a una nueva SD (High Endurance):

```bash
sudo dd if=~/jellypi-backup.img of=/dev/disk4 bs=4m status=progress
```

---

## Estructura del HDD

```
/mnt/storage/
├── data/
│   ├── torrents/
│   │   ├── movies/     ← qBittorrent descarga aquí
│   │   ├── tv/
│   │   └── anime/      ← categoría sonarr-anime
│   └── media/
│       ├── movies/     ← Radarr mueve aquí (hardlink, sin copia)
│       ├── tv/         ← Sonarr mueve aquí
│       └── anime/      ← Sonarr (perfil anime) mueve aquí
├── config/             ← configuración de todos los servicios
└── docker/             ← datos internos de Docker
```

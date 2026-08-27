# jellypi

Media center para Raspberry Pi 4 con descarga automática de series y películas.

**Stack:** Jellyfin · Sonarr · Radarr · Prowlarr · qBittorrent · Jellyseerr  
**Acceso en la tele:** App Jellyfin en Chromecast con Google TV  
**Añadir contenido:** Jellyseerr desde el móvil o portátil

---

## Hardware necesario

- Raspberry Pi 4 (4GB o 8GB)
- microSD 32GB (High Endurance recomendada: Samsung PRO Endurance o SanDisk High Endurance)
- Disco duro externo USB de 2TB formateado en ext4
- Cable ethernet al router

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

Clona el repositorio en el Pi:

```bash
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

En **Tools → Options → Downloads:**
- Default Save Path: `/data/torrents`

Crea dos categorías en **Tools → Options → BitTorrent:**

| Categoría | Ruta de guardado |
|-----------|-----------------|
| `tv`      | `/data/torrents/tv` |
| `movies`  | `/data/torrents/movies` |

### Sonarr — `http://jellypi.local:8989`

1. **Settings → Media Management → Root Folders:** añade `/data/media/tv`
2. **Settings → Download Clients → + → qBittorrent:**
   - Host: `qbittorrent` · Port: `8080`
   - Category: `tv`
3. Copia la **API Key** de Settings → General (la necesitarás para Prowlarr y Jellyseerr)

### Radarr — `http://jellypi.local:7878`

1. **Settings → Media Management → Root Folders:** añade `/data/media/movies`
2. **Settings → Download Clients → + → qBittorrent:**
   - Host: `qbittorrent` · Port: `8080`
   - Category: `movies`
3. Copia la **API Key** de Settings → General

### Prowlarr — `http://jellypi.local:9696`

1. **Settings → Apps → + → Sonarr:**
   - Server: `http://sonarr:8989`
   - API Key: la de Sonarr
2. **Settings → Apps → + → Radarr:**
   - Server: `http://radarr:7878`
   - API Key: la de Radarr
3. **Indexers → + → Add Indexer:** añade tus indexers de torrent favoritos

### Jellyfin — `http://jellypi.local:8096`

En el asistente de primer arranque:
- Añade biblioteca **Movies** → carpeta: `/data/media/movies`
- Añade biblioteca **TV Shows** → carpeta: `/data/media/tv`

Para activar hardware acceleration (Pi 4):
- **Dashboard → Playback → Transcoding**
- Hardware acceleration: `Video4Linux2 (V4L2)`

### Jellyseerr — `http://jellypi.local:5055`

1. **Sign in with Jellyfin** usando tus credenciales de Jellyfin
2. Conecta con Sonarr y Radarr usando sus API Keys y `http://sonarr:8989` / `http://radarr:7878`

Desde ahora buscas aquí lo que quieres ver y se descarga solo.

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
| Jellyseerr   | 5055   |
| Sonarr       | 8989   |
| Radarr       | 7878   |
| Prowlarr     | 9696   |
| qBittorrent  | 8080   |

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
│   │   └── tv/
│   └── media/
│       ├── movies/     ← Radarr mueve aquí (hardlink, sin copia)
│       └── tv/         ← Sonarr mueve aquí
├── config/             ← configuración de todos los servicios
└── docker/             ← datos internos de Docker
```

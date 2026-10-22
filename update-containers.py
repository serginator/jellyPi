#!/usr/bin/env python3
"""Container update manager for jellyPi (stdlib only).

Driven by cron (installed by update-setup.sh):

  poll      every 5 min. Turns Diun "new version" events into Telegram approval
            messages (changelog excerpt + risk flags) and applies the ones
            approved with the inline button.
  rebuilds  Sunday 09:00. Pulls the pinned linuxserver tags and applies
            same-version rebuilds (base-image / security patches) unattended.

Both end in apply(): config backup -> stop -> recreate -> health check ->
rollback (image + config) on failure -> Telegram report.

Why pins: every linuxserver service is pinned to its `version-<app version>`
tag through <SERVICE>_TAG in .env. That tag floats across rebuilds of the SAME
version, so a plain pull can only bring patches, never a new app version. New
versions only arrive through an approved update, which moves the pin.

No automatic check can promise "no breaking changes". Risk flags are keyword
matches on the release notes; health checks + rollback are the safety net.
"""
import argparse
import contextlib
import fcntl
import html
import json
import logging
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta
from logging.handlers import RotatingFileHandler
from pathlib import Path

REPO_DIR = Path(os.environ.get("JELLYPI_DIR") or Path(__file__).resolve().parent)
ENV_FILE = REPO_DIR / ".env"
COMPOSE_FILE = REPO_DIR / "docker-compose.yml"
BACKUP_DIR = REPO_DIR / "backups" / "auto"
BACKUP_KEEP = 2

# Alpine/busybox image already on the Pi (Diun's). Running tar through it lets
# the docker group read root-owned config dirs (diun, gluetun, portainer, ...)
# without sudo, which cron cannot use (sudo needs a password here).
HELPER_IMAGE = "crazymax/diun:latest"
DIUN_CONTAINER = "diun"
QUEUE_DIR = "/data"
QUEUE_FILE = "new-tags.txt"

# Services that share another service's network namespace and must be
# recreated with it (see AGENTS.md).
DEPENDENTS = {"gluetun": ["qbittorrent"]}
# decluttarr checks its targets only at startup, so restart it after these.
RESTART_DECLUTTARR_AFTER = {"gluetun", "qbittorrent", "sonarr", "radarr"}

PENDING_TTL_DAYS = 30

# Same exclusions as backup.sh (paths relative to $STORAGE/config).
BACKUP_EXCLUDES = [
    "jellyfin/cache",
    "jellyfin/data/metadata",
    "jellyfin/data/transcodes",
    "jellyfin/log",
    "romm/resources",
    "romm/redis",
    "*/logs",
]
# Regenerable dirs inside a service dir: kept from the failed copy on restore.
RESTORE_KEEP = ["jellyfin/cache", "jellyfin/data/metadata", "jellyfin/data/transcodes", "jellyfin/log"]

# service -> GitHub repo whose releases carry the app changelog.
GITHUB_NOTES = {
    "jellyfin": "jellyfin/jellyfin",
    "sonarr": "Sonarr/Sonarr",
    "radarr": "Radarr/Radarr",
    "prowlarr": "Prowlarr/Prowlarr",
    "bazarr": "morpheus65535/bazarr",
    "qbittorrent": "qbittorrent/qBittorrent",
    "gluetun": "qdm12/gluetun",
    "tailscale": "tailscale/tailscale",
    "seerr": "seerr-team/seerr",
    "portainer": "portainer/portainer",
    "romm": "rommapp/romm",
    "uptime-kuma": "louislam/uptime-kuma",
    "homepage": "gethomepage/homepage",
    "unpackerr": "Unpackerr/unpackerr",
    "decluttarr": "ManiMatter/decluttarr",
    "flaresolverr": "FlareSolverr/FlareSolverr",
    "diun": "crazy-max/diun",
}
# Where the real notes live when the GitHub release has none.
NOTES_LINK = {
    "tailscale": "https://tailscale.com/changelog",
    "romm-db": "https://mariadb.com/kb/en/release-notes/",
}

# Health probes: `url` (HTTP from the Pi host) or `exec` (inside the container).
# Services without an entry just need to be running (and Docker-healthy if the
# image defines a healthcheck).
HEALTH = {
    "jellyfin": {"url": "http://localhost:8096/health", "timeout": 600},
    "sonarr": {"url": "http://localhost:8989/ping", "timeout": 240},
    "radarr": {"url": "http://localhost:7878/ping", "timeout": 240},
    "prowlarr": {"url": "http://localhost:9696/ping", "timeout": 240},
    "bazarr": {"url": "http://localhost:6767/", "timeout": 240},
    "seerr": {"url": "http://localhost:5055/api/v1/status", "timeout": 240},
    "portainer": {"url": "http://localhost:9000/api/system/status", "timeout": 180},
    "homepage": {"url": "http://localhost:3000/", "timeout": 180},
    "uptime-kuma": {"url": "http://localhost:3001/", "timeout": 180},
    "romm": {"url": "http://localhost:8085/api/heartbeat", "timeout": 300},
    # qBittorrent's port is published through gluetun, so probe from inside.
    "qbittorrent": {"exec": ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "localhost:8080"],
                    "expect": "200", "timeout": 240},
    "tailscale": {"exec": ["tailscale", "status"], "timeout": 120},
}

RISK_RE = re.compile(
    r"breaking|incompatib|deprecat|migrat|no longer|action required|manual(ly)?\b"
    r"|\bremoved?\b|\bremoves\b|requires? (a |an )?(restart|reconfig|manual)",
    re.IGNORECASE,
)
SECURITY_RE = re.compile(r"security|\bCVE-\d", re.IGNORECASE)
PRERELEASE_RE = re.compile(r"unstable|nightly|alpha|beta|preview|develop|\brc\d*", re.IGNORECASE)
# Diun queues every tag it has never seen. In normal operation that is a handful
# per day; a burst means it is seeding a repo (first scan with a non-empty Diun
# DB, or a new entry in diun/images.yml), not that 300 versions were released.
FLOOD_LIMIT = 15
ERROR_MSG_EVERY = timedelta(hours=6)   # don't spam Telegram if a cron job keeps failing

log = logging.getLogger("update-containers")


# ── shell helpers ─────────────────────────────────────────────────────────────

def run(cmd, check=True, timeout=300, **kw):
    kw.setdefault("capture_output", True)
    kw.setdefault("text", True)
    return subprocess.run([str(c) for c in cmd], check=check, timeout=timeout, cwd=REPO_DIR, **kw)


def compose(*args, files=(), check=True, timeout=300):
    cmd = ["docker", "compose"]
    if files:
        for f in (COMPOSE_FILE, *files):
            cmd += ["-f", f]
    return run(cmd + list(args), check=check, timeout=timeout)


_MODEL = None


def compose_model(refresh=False):
    """Active compose services (honours .env, COMPOSE_PROFILES and the *_TAG pins)."""
    global _MODEL
    if _MODEL is None or refresh:
        _MODEL = json.loads(compose("config", "--format", "json").stdout)["services"]
    return _MODEL


def cname(svc):
    return compose_model()[svc].get("container_name", svc)


# ── .env ──────────────────────────────────────────────────────────────────────

def read_env(path=None):
    env = {}
    try:
        for line in (path or ENV_FILE).read_text().splitlines():
            m = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
            if m and not line.lstrip().startswith("#"):
                env[m.group(1)] = m.group(2).strip().strip("'\"")
    except FileNotFoundError:
        pass
    return env


def set_env_var(key, value, path=None):
    """Set (or, with value=None, remove) KEY in .env, keeping its mode. Returns the old value."""
    path = path or ENV_FILE
    old = read_env(path).get(key)
    lines = path.read_text().splitlines() if path.exists() else []
    out, done = [], False
    for line in lines:
        if re.match(rf"\s*{re.escape(key)}=", line):
            if value is not None and not done:
                out.append(f"{key}={value}")
            done = True
        else:
            out.append(line)
    if value is not None and not done:
        out.append(f"{key}={value}")
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text("\n".join(out) + "\n")
    with contextlib.suppress(FileNotFoundError):
        os.chmod(tmp, path.stat().st_mode & 0o777)
    os.replace(tmp, path)
    return old


def pin_var(svc):
    return svc.upper().replace("-", "_") + "_TAG"


# ── paths / state ─────────────────────────────────────────────────────────────

def storage():
    return read_env().get("STORAGE", "/mnt/storage")


def config_root():
    return Path(storage()) / "config"


def state_dir():
    d = config_root() / "update-bot"
    d.mkdir(parents=True, exist_ok=True)
    return d


def load_state():
    try:
        st = json.loads((state_dir() / "state.json").read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        st = {}
    st.setdefault("offset", 0)
    st.setdefault("next_id", 1)
    st.setdefault("pending", {})
    st.setdefault("seen", [])      # "service|tag" already offered (or applied)
    st.setdefault("applied", {})   # service -> last applied tag
    cutoff = (datetime.now() - timedelta(days=PENDING_TTL_DAYS)).isoformat()
    st["pending"] = {k: v for k, v in st["pending"].items()
                     if v["status"] in ("pending", "approved") or v["created"] > cutoff}
    return st


def save_state(st):
    p = state_dir() / "state.json"
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(st, indent=1))
    os.replace(tmp, p)


@contextlib.contextmanager
def lock(wait_seconds=0):
    """Only one update run at a time (poll every 5 min vs. a long apply)."""
    f = open(state_dir() / "lock", "w")
    deadline = time.time() + wait_seconds
    while True:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError:
            if time.time() >= deadline:
                f.close()
                yield False
                return
            time.sleep(10)
    try:
        yield True
    finally:
        f.close()


def setup_logging(verbose):
    log.setLevel(logging.INFO)
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s")
    fh = RotatingFileHandler(state_dir() / "update.log", maxBytes=512 * 1024, backupCount=2)
    fh.setFormatter(fmt)
    log.addHandler(fh)
    if verbose or sys.stdout.isatty():
        sh = logging.StreamHandler()
        sh.setFormatter(fmt)
        log.addHandler(sh)


# ── image / version helpers ───────────────────────────────────────────────────

def norm_repo(image):
    """lscr.io/linuxserver/sonarr:latest / docker.io/library/mariadb -> repo without tag."""
    ref = image.split("@")[0]
    last = ref.rsplit("/", 1)[-1]
    name = ref[: -(len(last.split(":", 1)[1]) + 1)] if ":" in last else ref
    name = re.sub(r"^docker\.io/", "", name)
    return re.sub(r"^library/", "", name)


def image_tag(image):
    last = image.split("@")[0].rsplit("/", 1)[-1]
    return last.split(":", 1)[1] if ":" in last else "latest"


def all_ints(s):
    return tuple(int(x) for x in re.findall(r"\d+", s or ""))


def lead(s):
    """First dotted number in s: 'version-12.2ubu2604' -> (12, 2); '5.3.0_v2.1.2' -> (5, 3, 0)."""
    m = re.search(r"(\d+(?:\.\d+)*)", s or "")
    return tuple(int(x) for x in m.group(1).split(".")) if m else ()


def level(cur, new):
    a, b = lead(cur), lead(new)
    if not a or not b:
        return "?"
    if a[0] != b[0]:
        return "major"
    if a[1:2] != b[1:2]:
        return "minor"
    return "patch"


LEVEL_ES = {"major": "salto MAYOR", "minor": "minor", "patch": "parche", "?": "versión sin clasificar"}


def container_image_id(svc):
    r = run(["docker", "inspect", "-f", "{{.Image}}", cname(svc)], check=False)
    return r.stdout.strip() if r.returncode == 0 else None


def local_image_id(ref):
    r = run(["docker", "image", "inspect", "-f", "{{.Id}}", ref], check=False)
    return r.stdout.strip() if r.returncode == 0 else None


def label_version(svc):
    """App version from the running container's image labels, without the -lsNNN suffix."""
    r = run(["docker", "inspect", "-f",
             '{{index .Config.Labels "org.opencontainers.image.version"}}', cname(svc)], check=False)
    v = r.stdout.strip() if r.returncode == 0 else ""
    return re.sub(r"-ls\d+$", "", v) if v and v != "latest" else ""


def container_state(svc):
    r = run(["docker", "inspect", "-f",
             "{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.RestartCount}}",
             cname(svc)], check=False)
    if r.returncode != 0:
        return ("missing", "", 0)
    status, health, restarts = r.stdout.strip().split("|")
    return (status, health, int(restarts))


def is_running(svc):
    return container_state(svc)[0] == "running"


def current_version(svc, st):
    """Best known running version: pin, image label, tailscale CLI, last applied."""
    model = compose_model()
    cands = []
    tag = image_tag(model[svc]["image"])
    if tag.startswith("version-"):
        cands.append(tag)
    if (v := label_version(svc)):
        cands.append(v)
    if svc == "tailscale":
        r = run(["docker", "exec", cname(svc), "tailscale", "version"], check=False)
        if r.returncode == 0 and r.stdout.strip():
            cands.append(r.stdout.splitlines()[0].strip())
    if st["applied"].get(svc):
        cands.append(st["applied"][svc])
    return max(cands, key=all_ints) if cands else ""


# ── GitHub release notes ──────────────────────────────────────────────────────

def github(path):
    headers = {"User-Agent": "jellypi-update", "Accept": "application/vnd.github+json"}
    if (tok := read_env().get("GITHUB_TOKEN")):
        headers["Authorization"] = f"Bearer {tok}"
    req = urllib.request.Request(f"https://api.github.com/{path}", headers=headers)
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def fetch_notes(svc, cur, new):
    """(risk_lines or None if unreadable, link, mentions_security). Notes of every
    stable release in (cur, new]; never raises."""
    repo = GITHUB_NOTES.get(svc)
    link = NOTES_LINK.get(svc) or (f"https://github.com/{repo}/releases" if repo else "")
    if not repo:
        return [], link, False
    try:
        rels = [r for r in github(f"repos/{repo}/releases?per_page=100")
                if not r.get("draft") and not r.get("prerelease")]
    except Exception as e:  # network, rate limit, renamed repo...
        log.warning("notes for %s unavailable: %s", svc, e)
        return None, link, False
    lo, hi = lead(cur), lead(new)
    sel = [r for r in rels if lead(r["tag_name"]) and (lo < lead(r["tag_name"]) <= hi if lo else lead(r["tag_name"]) == hi)]
    sel.sort(key=lambda r: lead(r["tag_name"]), reverse=True)
    sel = sel[:4]
    if sel:
        link = NOTES_LINK.get(svc) or sel[0]["html_url"]
    risks, seen = [], set()
    for r in sel:
        for line in (r.get("body") or "").splitlines():
            txt = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", line)
            txt = re.sub(r"[*_`]", "", txt).lstrip("#> -•\t").strip()
            if len(txt) > 8 and RISK_RE.search(txt) and txt.lower() not in seen:
                seen.add(txt.lower())
                risks.append(f"{r['tag_name']}: {txt[:180]}")
    security = any(SECURITY_RE.search(r.get("body") or "") for r in sel)
    return risks[:6], link, security


def build_message(item, cur, risks, link, security=False, superseded=None):
    e = html.escape
    lvl = item["level"]
    head = f"🆕 <b>{e(item['service'])}</b>: {e(cur or '?')} → {e(item['tag'])} ({LEVEL_ES[lvl]})"
    if lvl == "major":
        head = "🔴 " + head
    parts = [head, f"<code>{e(item['image'])}</code>"]
    if superseded:
        parts.append(f"Sustituye a la propuesta anterior ({e(superseded)}).")
    if risks is None:
        parts.append("⚠️ No pude leer las notas de la versión. Revísalas antes de aprobar.")
    elif risks:
        parts.append("⚠️ Señales de riesgo en las notas (palabras clave, no es una garantía):")
        parts += [f"• {e(r)}" for r in risks]
    else:
        parts.append("Sin palabras de riesgo en las notas. Eso no garantiza que no haya cambios importantes.")
    if security:
        parts.append("🛡 Las notas mencionan correcciones de seguridad (CVE).")
    if link:
        parts.append(f"📄 {e(link)}")
    parts.append("Al aprobar: backup de la config, actualización y comprobación de salud. Si falla, vuelve atrás sola.")
    return "\n".join(parts)


# ── Telegram ──────────────────────────────────────────────────────────────────

def tg(method, **params):
    env = read_env()
    token = env.get("TELEGRAM_BOT_TOKEN")
    if not token:
        raise RuntimeError("TELEGRAM_BOT_TOKEN missing in .env")
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/{method}",
        data=json.dumps(params).encode(), headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=40) as r:
            return json.load(r)["result"]
    except urllib.error.HTTPError as e:
        # Never log the URL: it contains the bot token.
        raise RuntimeError(f"telegram {method}: HTTP {e.code} {e.read()[:200]!r}") from None
    except urllib.error.URLError as e:
        raise RuntimeError(f"telegram {method}: {e.reason}") from None


def chat_id():
    cid = read_env().get("TELEGRAM_CHAT_ID")
    if not cid:
        raise RuntimeError("TELEGRAM_CHAT_ID missing in .env")
    return int(cid)


def send(text, buttons=None):
    params = {"chat_id": chat_id(), "text": text[:4000], "parse_mode": "HTML",
              "disable_web_page_preview": True}
    if buttons:
        params["reply_markup"] = {"inline_keyboard": [buttons]}
    return tg("sendMessage", **params)


def clear_buttons(message_id):
    with contextlib.suppress(Exception):
        tg("editMessageReplyMarkup", chat_id=chat_id(), message_id=message_id,
           reply_markup={"inline_keyboard": []})


# ── Diun queue ────────────────────────────────────────────────────────────────

def read_queue():
    """New-tag lines written by diun/notify.sh. Re-reads a half-processed file after a crash."""
    script = (f"cd {QUEUE_DIR}; [ -f {QUEUE_FILE}.processing ] || "
              f"{{ [ -f {QUEUE_FILE} ] && mv {QUEUE_FILE} {QUEUE_FILE}.processing; }}; "
              f"[ -f {QUEUE_FILE}.processing ] && cat {QUEUE_FILE}.processing; true")
    r = run(["docker", "exec", DIUN_CONTAINER, "sh", "-c", script], check=False)
    if r.returncode != 0:
        log.warning("cannot read Diun queue: %s", r.stderr.strip()[:200])
        return None
    return [ln.strip() for ln in r.stdout.splitlines() if ln.strip()]


def ack_queue():
    run(["docker", "exec", DIUN_CONTAINER, "rm", "-f", f"{QUEUE_DIR}/{QUEUE_FILE}.processing"], check=False)


def ingest_queue(st):
    """Queue lines -> pending approvals (and their Telegram messages)."""
    lines = read_queue()
    if not lines:          # None = diun unreachable, [] = nothing queued (most runs)
        return
    entries = list(dict.fromkeys(lines))
    if len(entries) > FLOOD_LIMIT:
        log.warning("Diun queued %d tags at once: treating as a seeding scan and dropping them", len(entries))
        ack_queue()
        with contextlib.suppress(Exception):
            send(f"ℹ️ Diun ha encolado {len(entries)} tags de golpe (parece un primer escaneo de imágenes "
                 "nuevas). Los he ignorado: no es una avalancha de versiones nuevas.")
        return
    model = compose_model()
    by_repo = {norm_repo(s["image"]): n for n, s in model.items()}
    newest = {}   # one proposal per service: the newest tag of this batch
    for image in entries:
        svc, tag = by_repo.get(norm_repo(image)), image_tag(image)
        if not svc or tag == "latest" or PRERELEASE_RE.search(tag):
            log.info("ignoring queue entry %s", image)
            continue
        if svc not in newest or all_ints(tag) > all_ints(image_tag(newest[svc][1])):
            newest[svc] = (svc, image)
    for svc, image in newest.values():
        tag = image_tag(image)
        key = f"{svc}|{tag}"
        cur = current_version(svc, st)
        if key in st["seen"] or (cur and all_ints(tag) <= all_ints(cur)):
            log.info("skip %s (seen or not newer than %s)", key, cur or "?")
            continue
        old = next((p for p in st["pending"].values() if p["service"] == svc and p["status"] == "pending"), None)
        item = {"id": st["next_id"], "service": svc, "image": image, "tag": tag, "from": cur,
                "level": level(cur, tag), "status": "pending", "created": datetime.now().isoformat()}
        risks, link, security = fetch_notes(svc, cur, tag)
        buttons = [{"text": "✅ Actualizar", "callback_data": f"ok:{item['id']}"},
                   {"text": "⏭ Omitir", "callback_data": f"skip:{item['id']}"}]
        msg = send(build_message(item, cur, risks, link, security, superseded=old["tag"] if old else None), buttons)
        item["message_id"] = msg["message_id"]
        st["next_id"] += 1
        st["pending"][str(item["id"])] = item
        st["seen"] = (st["seen"] + [key])[-500:]
        if old:
            old["status"] = "superseded"
            clear_buttons(old["message_id"])
        save_state(st)
    ack_queue()


# ── backup / restore (no sudo: through the helper container) ─────────────────

def ts():
    return datetime.now().strftime("%Y%m%d-%H%M%S")


def config_rels(svc, root=None, model=None):
    """Bind-mounted config paths of svc, relative to $STORAGE/config."""
    root = root or config_root()
    model = model or compose_model()
    rels = []
    for v in model[svc].get("volumes", []):
        src = v.get("source", "")
        if v.get("type") == "bind" and src.startswith(f"{root}/") and Path(src).exists():
            rel = os.path.relpath(src, root)
            if rel not in BACKUP_EXCLUDES:   # whole-dir exclusions (romm/resources, romm/redis)
                rels.append(rel)
    rels = sorted(set(rels))
    return [r for r in rels if not any(r.startswith(o + "/") for o in rels)]


def backup_service(svc, root=None, model=None, out_dir=None):
    root = root or config_root()
    rels = config_rels(svc, root, model)
    if not rels:
        return None
    out_dir = out_dir or BACKUP_DIR
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"{svc}-{ts()}.tar.gz"
    cmd = ["docker", "run", "--rm", "--entrypoint", "tar", "-v", f"{root}:/src:ro", HELPER_IMAGE,
           "czf", "-", "-C", "/src"]
    for e in BACKUP_EXCLUDES:
        cmd += ["--exclude", e]
    cmd += rels
    with open(out, "wb") as f:
        r = subprocess.run(cmd, stdout=f, stderr=subprocess.PIPE, timeout=3600)
    if r.returncode != 0 or subprocess.run(["gzip", "-t", str(out)]).returncode != 0:
        out.unlink(missing_ok=True)
        raise RuntimeError(f"backup of {svc} failed: {r.stderr.decode()[:300]}")
    return out


def restore_service(svc, tarball, root=None, model=None):
    """Move the current config aside (*.failed-<ts>), unpack the backup, keep regenerable dirs."""
    root = root or config_root()
    rels = config_rels(svc, root, model)
    stamp = ts()
    script = f"""set -e
stamp="$1"; shift
for r in "$@"; do [ -e "/c/$r" ] && mv "/c/$r" "/c/$r.failed-$stamp"; done
tar xzf /b/backup.tar.gz -C /c
for e in $KEEP; do
  top="${{e%%/*}}"; sub="${{e#*/}}"
  if [ -d "/c/$top.failed-$stamp" ] && [ -e "/c/$top.failed-$stamp/$sub" ]; then
    mkdir -p "$(dirname "/c/$top/$sub")"; mv "/c/$top.failed-$stamp/$sub" "/c/$top/$sub"
  fi
done
"""
    run(["docker", "run", "--rm", "--entrypoint", "sh", "-e", "KEEP=" + " ".join(RESTORE_KEEP),
         "-v", f"{root}:/c", "-v", f"{tarball}:/b/backup.tar.gz:ro", HELPER_IMAGE,
         "-c", script, "sh", stamp, *rels], timeout=3600)


def prune_backups(svc):
    old = sorted(BACKUP_DIR.glob(f"{svc}-*.tar.gz"), reverse=True)[BACKUP_KEEP:]
    for p in old:
        p.unlink(missing_ok=True)


# ── health ────────────────────────────────────────────────────────────────────

def probe(svc):
    h = HEALTH.get(svc, {})
    if "url" in h:
        try:
            with urllib.request.urlopen(h["url"], timeout=5) as r:
                return 200 <= r.status < 400
        except urllib.error.HTTPError as e:
            return e.code in (401, 403)   # up, just wants auth
        except Exception:
            return False
    if "exec" in h:
        r = run(["docker", "exec", cname(svc), *h["exec"]], check=False, timeout=30)
        return r.returncode == 0 and h.get("expect", "") in r.stdout
    return True


def wait_healthy(svc, timeout=None):
    timeout = timeout or HEALTH.get(svc, {}).get("timeout", 180)
    start = time.time()
    while time.time() - start < timeout:
        status, health, restarts = container_state(svc)
        if status in ("exited", "dead", "missing") or restarts >= 3:
            return False, int(time.time() - start)
        if status == "running" and health in ("", "healthy") and probe(svc):
            return True, int(time.time() - start)
        time.sleep(5)
    return False, int(time.time() - start)


# ── apply ─────────────────────────────────────────────────────────────────────

def order(services):
    """Bases first (gluetun before qbittorrent), the rest alphabetical."""
    dependents = {d for ds in DEPENDENTS.values() for d in ds}
    return sorted(services, key=lambda s: (s in dependents, s))


def snapshot_image(svc, image_id):
    if image_id:
        run(["docker", "tag", image_id, f"jellypi-rollback/{svc}:prev"], check=False)


def rollback(svc, kind, backup):
    """Old image (+ old config for version bumps). Returns (ok, detail)."""
    run(["docker", "rm", "-f", cname(svc)], check=False, timeout=120)  # also detaches netns dependents
    if kind == "bump" and backup:
        restore_service(svc, backup)
    override = state_dir() / "rollback.yml"
    override.write_text(f"services:\n  {svc}:\n    image: jellypi-rollback/{svc}:prev\n    pull_policy: never\n")
    compose("up", "-d", "--no-deps", "--force-recreate", svc, files=(override,), timeout=600)
    ok, _ = wait_healthy(svc)
    return ok, ("imagen y config anteriores restauradas" if kind == "bump" and backup else "imagen anterior restaurada")


def apply(items):
    """items: [{"service", "tag" (pin target or None), "kind": "bump"|"rebuild"}].

    Returns {"lines": [...], "ok": [svc], "failed": [svc], "versions": {svc: version}}.
    """
    model = compose_model(refresh=True)
    wanted = list(dict.fromkeys(i["service"] for i in items))
    todo = list(wanted)
    for s in wanted:
        todo += [d for d in DEPENDENTS.get(s, []) if d in model and d not in todo]
    kinds = {i["service"]: i["kind"] for i in items}
    was_running = {s: is_running(s) for s in set(todo) | {"decluttarr"} if s in model}
    before = {s: container_image_id(s) for s in todo}
    before_ver = {s: current_version(s, load_state()) for s in todo}
    for s in todo:
        snapshot_image(s, before[s])

    old_pins = {}
    for i in items:
        if i.get("tag") and image_tag(model[i["service"]]["image"]).startswith("version-"):
            old_pins[pin_var(i["service"])] = set_env_var(pin_var(i["service"]), i["tag"])
    if old_pins:
        model = compose_model(refresh=True)

    def undo_pins(only=None):
        for var, old in old_pins.items():
            if only is None or var == pin_var(only):
                set_env_var(var, old)

    res = {"lines": [], "ok": [], "failed": [], "nochange": [], "versions": {}}
    try:
        compose("pull", *todo, timeout=1800)
    except subprocess.CalledProcessError as e:
        undo_pins()
        res["failed"] = wanted
        res["lines"].append(f"❌ No pude descargar las imágenes; no he tocado nada.\n<code>{html.escape((e.stderr or '')[-300:])}</code>")
        return res

    after = {s: local_image_id(model[s]["image"]) for s in todo}
    changed = [s for s in todo if before[s] != after[s]]
    forced = [d for s in changed for d in DEPENDENTS.get(s, []) if d in todo and d not in changed]
    recreate = order(changed + forced)
    for s in wanted:
        if s not in recreate:
            res["nochange"].append(s)
            res["lines"].append(f"ℹ️ <b>{s}</b>: la imagen ya era la última, sin cambios "
                                "(quizá el registro aún no ha movido <code>latest</code>). "
                                "No volveré a avisar de esta versión.")
    if not recreate:
        return res

    running = [s for s in recreate if was_running.get(s)]
    stopped = [s for s in recreate if not was_running.get(s)]
    backups = {}
    try:
        if running:
            compose("stop", *running, timeout=600)
        for s in recreate:
            backups[s] = backup_service(s)
    except Exception as e:
        log.exception("backup failed")
        if running:
            compose("start", *running, check=False, timeout=600)
        undo_pins()
        res["failed"] = wanted
        res["lines"].append(f"❌ Backup falló, no he actualizado nada: <code>{html.escape(str(e)[:300])}</code>")
        return res

    failed = []
    health = {}
    for s in running:
        if s in failed:                    # its base (gluetun) failed: rolled back below
            continue
        try:
            compose("up", "-d", "--no-deps", "--force-recreate", s, timeout=900)
            ok, secs = wait_healthy(s)
        except Exception:
            log.exception("recreate of %s failed", s)
            ok, secs = False, 0
        health[s] = secs
        if not ok:
            failed.append(s)
            # dependents hang off the broken network namespace
            failed += [d for d in DEPENDENTS.get(s, []) if d in running and d not in failed]
    for s in stopped:                      # was stopped by hand: new image, but stay stopped
        compose("up", "--no-start", "--no-deps", "--force-recreate", s, timeout=600)

    rolled = {}
    for s in order(failed):
        try:
            rolled[s] = rollback(s, kinds.get(s, "rebuild"), backups.get(s))
        except Exception as e:
            log.exception("rollback of %s failed", s)
            rolled[s] = (False, f"rollback falló: {e}")
        undo_pins(only=s)

    if any(s in RESTART_DECLUTTARR_AFTER for s in recreate) and was_running.get("decluttarr"):
        for dep in ("qbittorrent", "sonarr", "radarr"):
            if dep in model and was_running.get(dep, is_running(dep)):
                wait_healthy(dep, 120)
        compose("restart", "decluttarr", check=False, timeout=300)

    for s in recreate:
        if s in failed:
            ok, detail = rolled.get(s, (False, "sin rollback"))
            res["failed"].append(s)
            res["lines"].append(
                f"❌ <b>{s}</b> no pasó la comprobación de salud → {html.escape(detail)}"
                + ("" if ok else " ⚠️ <b>el rollback también falló: revisa a mano</b>")
                + (f"\nBackup: <code>{backups[s]}</code>" if backups.get(s) else ""))
        else:
            ver = current_version(s, load_state())
            res["ok"].append(s)
            res["versions"][s] = ver
            how = "estaba parado: queda parado hasta que lo arranques" if s in stopped else f"sano en {health.get(s, 0)} s"
            line = f"✅ <b>{s}</b>: {html.escape(before_ver.get(s) or '?')} → {html.escape(ver or '?')} ({how})"
            if backups.get(s):
                line += f"\nBackup: <code>{backups[s].name}</code>"
            res["lines"].append(line)
            if backups.get(s):
                prune_backups(s)
    return res


# ── commands ──────────────────────────────────────────────────────────────────

def report(title, res, notify=True):
    text = title + "\n" + "\n".join(res["lines"])
    log.info(re.sub(r"<[^>]+>", "", text))
    if notify:
        send(text)


def cmd_poll(args):
    with lock() as got:
        if not got:
            log.info("another run in progress, skipping")
            return
        st = load_state()
        ingest_queue(st)
        approved = [p for p in st["pending"].values() if p["status"] == "approved"]   # resume after a crash
        if not approved and not any(p["status"] == "pending" for p in st["pending"].values()):
            return         # nobody to hear from: no Telegram call on most runs
        for u in tg("getUpdates", offset=st["offset"], timeout=0, allowed_updates=["callback_query"]):
            st["offset"] = u["update_id"] + 1
            cq = u.get("callback_query")
            if not cq:
                continue
            msg = cq.get("message") or {}
            if (msg.get("chat") or {}).get("id") != chat_id():
                log.warning("callback from unauthorized chat ignored")
                tg("answerCallbackQuery", callback_query_id=cq["id"], text="No autorizado")
                continue
            action, _, pid = (cq.get("data") or "").partition(":")
            item = st["pending"].get(pid)
            if not item or item["status"] != "pending" or action not in ("ok", "skip"):
                tg("answerCallbackQuery", callback_query_id=cq["id"], text="Caducado o ya procesado")
                clear_buttons(msg.get("message_id"))
                continue
            clear_buttons(item["message_id"])
            if action == "skip":
                item["status"] = "skipped"
                tg("answerCallbackQuery", callback_query_id=cq["id"], text="Omitida")
            else:
                item["status"] = "approved"
                approved.append(item)
                tg("answerCallbackQuery", callback_query_id=cq["id"], text="Aprobada: actualizando…")
        for p in list(approved):   # an apply that keeps crashing must not loop every 5 min
            p["attempts"] = p.get("attempts", 0) + 1
            if p["attempts"] > 2:
                p["status"] = "failed"
                approved.remove(p)
                send(f"❌ Dejo de reintentar {p['service']} → {p['tag']} tras varios errores. "
                     f"Revisa {state_dir()}/update.log.")
        save_state(st)
        if not approved:
            return
        send("⏳ Actualizando: " + ", ".join(f"{p['service']} → {p['tag']}" for p in approved)
             + ". Puede tardar varios minutos (Jellyfin ~5).")
        res = apply([{"service": p["service"], "tag": p["tag"], "kind": "bump"} for p in approved])
        for p in approved:
            p["status"] = "failed" if p["service"] in res["failed"] else "done"
            if p["status"] == "done" and p["service"] not in res["nochange"]:
                st["applied"][p["service"]] = p["tag"]
        save_state(st)
        report("🔧 <b>Resultado de la actualización</b>", res)


def cmd_rebuilds(args):
    with lock(wait_seconds=1800) as got:
        if not got:
            log.warning("could not get the lock in 30 min, skipping")
            return
        model = compose_model(refresh=True)
        pinned = [s for s, d in model.items() if image_tag(d["image"]).startswith("version-") and is_running(s)]
        if not pinned:
            log.info("no pinned running services; run update-setup.sh")
            return
        compose("pull", *pinned, timeout=1800)
        changed = [s for s in pinned if container_image_id(s) != local_image_id(model[s]["image"])]
        if not changed:
            log.info("no rebuilds for %s", ", ".join(pinned))
            return
        log.info("rebuilds available: %s", ", ".join(changed))
        res = apply([{"service": s, "tag": None, "kind": "rebuild"} for s in changed])
        report("♻️ <b>Reconstrucciones semanales</b> (misma versión de la app, parches de imagen base)", res,
               notify=not args.quiet)


def cmd_apply(args):
    with lock(wait_seconds=600) as got:
        if not got:
            sys.exit("another update run is in progress")
        tag = args.tag
        items = [{"service": s, "tag": tag, "kind": "bump" if tag else "rebuild"} for s in args.services]
        res = apply(items)
        report("🔧 <b>Actualización manual</b>", res, notify=not args.quiet)
        sys.exit(1 if res["failed"] else 0)


def tag_exists(image, tag):
    """HEAD the manifest on the registry (lscr.io is a front for ghcr.io/linuxserver)."""
    repo = norm_repo(image).replace("lscr.io/", "")
    host = "ghcr.io"
    with urllib.request.urlopen(f"https://{host}/token?scope=repository:{repo}:pull", timeout=20) as r:
        token = json.load(r)["token"]
    req = urllib.request.Request(
        f"https://{host}/v2/{repo}/manifests/{tag}", method="HEAD",
        headers={"Authorization": f"Bearer {token}",
                 "Accept": "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json"})
    try:
        urllib.request.urlopen(req, timeout=20)
        return True
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return False
        raise


def cmd_pin(args):
    """Pin every linuxserver service to the version-<x> tag it is running now."""
    model = compose_model()
    for svc, d in model.items():
        if not d["image"].startswith("lscr.io/linuxserver/"):
            continue
        tag = image_tag(d["image"])
        if tag.startswith("version-"):
            print(f"{svc}: already pinned ({tag})")
            continue
        ver = label_version(svc)
        if not ver:
            print(f"{svc}: no version label on the running image, skipping")
            continue
        pin = f"version-{ver}"
        if not tag_exists(d["image"], pin):
            print(f"{svc}: tag {pin} not found on the registry, skipping")
            continue
        print(f"{svc}: {pin}")
        if not args.dry_run:
            set_env_var(pin_var(svc), pin)


def cmd_status(args):
    st = load_state()
    model = compose_model()
    for s in order(model):
        print(f"{s:14} {model[s]['image']:60} running={current_version(s, st) or '?'}")
    pend = [p for p in st["pending"].values() if p["status"] in ("pending", "approved")]
    print(f"\npending approvals: {[(p['service'], p['tag'], p['status']) for p in pend] or 'none'}")


def cmd_preview(args):
    """Print the approval message for service cur->new without sending anything."""
    model = compose_model()
    item = {"service": args.service, "image": model[args.service]["image"], "tag": args.new,
            "level": level(args.cur, args.new)}
    risks, link, security = fetch_notes(args.service, args.cur, args.new)
    print(re.sub(r"<[^>]+>", "", html.unescape(build_message(item, args.cur, risks, link, security))))


def cmd_test(args):
    send("✅ Prueba del gestor de actualizaciones de jellyPi: el bot puede escribirte.")
    print("sent")


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("-v", "--verbose", action="store_true")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("poll", help="ingest Diun events, handle Telegram approvals").set_defaults(fn=cmd_poll)
    r = sub.add_parser("rebuilds", help="apply same-version rebuilds of pinned services")
    r.add_argument("--quiet", action="store_true", help="no Telegram report")
    r.set_defaults(fn=cmd_rebuilds)
    a = sub.add_parser("apply", help="update services now (no approval step)")
    a.add_argument("services", nargs="+")
    a.add_argument("--tag", help="new pin for a pinned service (version bump)")
    a.add_argument("--quiet", action="store_true", help="no Telegram report")
    a.set_defaults(fn=cmd_apply)
    pn = sub.add_parser("pin", help="pin linuxserver services to their running version tag")
    pn.add_argument("--dry-run", action="store_true")
    pn.set_defaults(fn=cmd_pin)
    sub.add_parser("status").set_defaults(fn=cmd_status)
    pv = sub.add_parser("preview", help="print the approval message without sending it")
    for arg in ("service", "cur", "new"):
        pv.add_argument(arg)
    pv.set_defaults(fn=cmd_preview)
    sub.add_parser("test-message").set_defaults(fn=cmd_test)
    args = p.parse_args()
    setup_logging(args.verbose)
    try:
        args.fn(args)
    except SystemExit:
        raise
    except Exception as e:
        log.exception("unexpected error in %s", args.cmd)
        if args.cmd in ("poll", "rebuilds"):
            notify_error(args.cmd, e)
        sys.exit(1)


def notify_error(cmd, e):
    """Telegram alert for a crashed cron job, at most once per ERROR_MSG_EVERY."""
    with contextlib.suppress(Exception):
        st = load_state()
        last = st.get("last_error_sent")
        if last and datetime.now() - datetime.fromisoformat(last) < ERROR_MSG_EVERY:
            return
        send(f"❌ Error inesperado en el gestor de actualizaciones ({cmd}): "
             f"<code>{html.escape(str(e)[:300])}</code>\nLog: {state_dir()}/update.log\n"
             f"(No repetiré este aviso en {int(ERROR_MSG_EVERY.total_seconds() // 3600)} h.)")
        st["last_error_sent"] = datetime.now().isoformat()
        save_state(st)


if __name__ == "__main__":
    main()

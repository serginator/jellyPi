# jellyPi — Instructions for Copilot

## Before anything else

Read the **full** handoff before doing anything in this repo:
`~/projects/claude-plans-and-docs/jellypi_media-center/handoff.md`

It's the most up-to-date source of truth: current status, day-by-day history
of applied fixes, hardware, network, pending items, and things to watch. This
file (`AGENTS.md`) only covers stable repo conventions, not project status —
don't duplicate that here or try to keep it in sync with the handoff.

After any relevant change in a session, propose updating the handoff
(explaining what was done and why, not just the what) instead of assuming it
will be remembered from one session to the next.

## What this repo is

A Docker Compose stack for a Raspberry Pi 4 acting as a media server:
Jellyfin + Sonarr/Radarr/Prowlarr/Bazarr + qBittorrent behind a VPN
(Gluetun/PIA) + Homepage/Portainer/Uptime Kuma + Tailscale for remote access.
The code/config lives in this repo (Mac), and is deployed and operated on the
actual Pi (`ssh pi@jellypi.local`, repo cloned at `~/jellypi`).

## Repo conventions

- The `*-setup.sh` scripts (`homepage-setup.sh`, `decluttarr-setup.sh`,
  `telegram-setup.sh`, `post-setup.sh`) generate YAML config under
  `$STORAGE/config/...` from `.env`. After regenerating, apply with
  `docker compose restart <service>`, **not** `up -d` — compose doesn't
  detect content changes in a mounted file, only changes to the service
  definition.
- `backup.sh`/`restore.sh` run over remote SSH need a pseudo-terminal: always
  use `ssh -t pi@jellypi.local "cd jellypi && ./backup.sh"` (there's
  interactive sudo with no `NOPASSWD` except for `reboot`).
- If `gluetun` is restarted/recreated, also recreate `qbittorrent` in the same
  `docker compose up -d` (it uses `network_mode: service:gluetun` and won't
  reconnect on its own if gluetun's network namespace changes).
- `.env` holds plaintext credentials and is in `.gitignore` — never commit
  real values; `env.example` is the public template.
- All services use `:latest` — before `docker compose pull/up -d`, check the
  image's changelog/release notes if Diun notified an update, and back up
  first with `backup.sh`.
- Don't run `git commit`/`git push` unless the user explicitly asks for it in
  that same conversation, even if they approved the file changes.

#!/usr/bin/env bash
# Run at @reboot (cron). After a reboot all containers start at once. decluttarr checks
# qBittorrent, Sonarr and Radarr only at startup and marks them "SKIP … not reachable" if they
# are still starting: it never retries. Wait until the three answer, then restart decluttarr.
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

wait_for() {  # wait_for <url> [seconds]
  local i
  for ((i = 0; i < ${2:-300}; i += 5)); do
    curl -s -o /dev/null --max-time 3 "$1" && return 0
    sleep 5
  done
  return 1
}

sleep 30  # let the Docker daemon and the containers come up
wait_for http://localhost:8989/ping
wait_for http://localhost:7878/ping
wait_for http://localhost:8080/
docker compose restart decluttarr

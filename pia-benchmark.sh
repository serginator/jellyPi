#!/bin/bash

REGIONS=("ES Madrid" "ES Valencia" "France" "Netherlands" "Nigeria" "Portugal" "Romania")
DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"
TEST_URL="https://speed.cloudflare.com/__down?bytes=10000000"

best_region=""
best_speed=0

speed_kbps() {
    local str value unit
    str=$(echo "$1" | grep -oE '[0-9.]+ [KMG]B/s' | tail -1)
    value=$(echo "$str" | awk '{print $1}')
    unit=$(echo "$str" | awk '{print $2}')
    case "$unit" in
        KB/s) echo "$value" | awk '{printf "%d", $1}' ;;
        MB/s) echo "$value" | awk '{printf "%d", $1 * 1024}' ;;
        GB/s) echo "$value" | awk '{printf "%d", $1 * 1024 * 1024}' ;;
        *)    echo "0" ;;
    esac
}

set_region() {
    if grep -q "^PIA_SERVER_REGION=" "$ENV_FILE"; then
        sed -i "s|^PIA_SERVER_REGION=.*|PIA_SERVER_REGION=$1|" "$ENV_FILE"
    else
        echo "PIA_SERVER_REGION=$1" >> "$ENV_FILE"
    fi
}

for region in "${REGIONS[@]}"; do
    echo "==> $region"
    set_region "$region"
    docker compose -f "$DIR/docker-compose.yml" --env-file "$ENV_FILE" up -d gluetun > /dev/null 2>&1

    echo -n "    connecting"
    status="starting"
    for _ in $(seq 1 30); do
        sleep 2
        status=$(docker inspect --format '{{.State.Health.Status}}' gluetun 2>/dev/null || echo "starting")
        [ "$status" = "healthy" ] && break
        echo -n "."
    done
    echo " [$status]"

    if [ "$status" != "healthy" ]; then
        echo "    VPN no conectó, saltando"
        continue
    fi

    result=$(docker exec gluetun wget -O /dev/null "$TEST_URL" 2>&1)
    speed_human=$(echo "$result" | grep -oE '[0-9.]+ [KMG]B/s' | tail -1)
    kbps=$(speed_kbps "$result")
    echo "    $speed_human"

    if [ -n "$kbps" ] && [ "$kbps" -gt "$best_speed" ]; then
        best_speed=$kbps
        best_region="$region"
    fi
done

echo ""
echo "Ganador: $best_region ($best_speed KB/s)"
set_region "$best_region"
docker compose -f "$DIR/docker-compose.yml" --env-file "$ENV_FILE" up -d gluetun > /dev/null 2>&1
docker compose -f "$DIR/docker-compose.yml" --env-file "$ENV_FILE" up -d qbittorrent > /dev/null 2>&1
echo "Hecho — Gluetun y qBittorrent reiniciados con la mejor región."

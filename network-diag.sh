#!/usr/bin/env bash
set -uo pipefail
# Diagnóstico del corte de red Tenda (WiFi sin internet) mientras la Pi está
# encendida. Ejecutar en la Pi (por SSH desde el ZTE, que no se ve afectado)
# en cuanto el Tenda empiece a fallar, o justo tras encenderla para comparar
# con el estado sano. No modifica nada, solo recolecta datos.
#
# Uso: ssh -t pi@jellypi.local "cd jellypi && ./network-diag.sh" | tee diag-$(date +%Y%m%d-%H%M).log

echo "=== $(date) ==="

echo -e "\n--- ip_forward / proxy_arp (leído directo de /proc/sys, sin depender del PATH de sysctl) ---"
for f in /proc/sys/net/ipv4/ip_forward /proc/sys/net/ipv4/conf/all/proxy_arp /proc/sys/net/ipv4/conf/eth0/proxy_arp; do
  printf '%s = %s\n' "$f" "$(cat "$f" 2>/dev/null || echo '?')"
done

echo -e "\n--- IP / rutas ---"
ip -4 addr show eth0
ip route

echo -e "\n--- Tabla ARP (buscar el gateway del ZTE y MACs duplicadas) ---"
arp -n 2>/dev/null || ip neigh show

echo -e "\n--- Contadores de interfaz eth0 (errores/colisiones/drops) ---"
ip -s link show eth0

echo -e "\n--- Interrupciones eth0 por núcleo (comparar sano vs. fallando) ---"
grep -i eth0 /proc/interrupts || echo "(no encontrado, revisar nombre de interrupción de red con: cat /proc/interrupts)"

echo -e "\n--- Estado Tailscale ---"
docker exec tailscale tailscale status 2>&1 || echo "(no se pudo consultar tailscale)"

echo -e "\n--- Captura de 20s de ARP/broadcast/multicast en eth0 (requiere sudo con TTY real) ---"
if [ -t 0 ]; then
  if ! command -v tcpdump >/dev/null 2>&1; then
    echo "tcpdump no está instalado, instalando (sudo apt install -y tcpdump)..."
    sudo apt-get update -qq && sudo apt-get install -y -qq tcpdump
  fi
  sudo timeout 20 tcpdump -i eth0 -nn arp or broadcast or multicast > /tmp/netdiag-capture.txt 2>/tmp/netdiag-capture.err
  cat /tmp/netdiag-capture.txt
  echo "Resumen por tipo:"
  grep -c " ARP, " /tmp/netdiag-capture.txt 2>/dev/null | xargs echo "  paquetes ARP:"
  wc -l < /tmp/netdiag-capture.txt | xargs echo "  paquetes totales:"
else
  echo "(omitido: sin TTY interactivo no se puede pedir la contraseña de sudo."
  echo " Ejecuta este script tú mismo con 'ssh -t' desde tu propio terminal para incluir esta parte)"
  cat /tmp/netdiag-capture.err 2>/dev/null
fi

echo -e "\n=== Fin diagnóstico ==="

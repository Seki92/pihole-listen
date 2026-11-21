#!/usr/bin/env bash
# =============================================================================
# ki-server-einrichten.sh – lokale KI (Ollama) auf einem Server ohne Grafikkarte
# =============================================================================
# Als root auf dem KI-Server ausführen:
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/Seki92/pihole-listen/master/tools/ki-server-einrichten.sh)
#
# Was passiert:
#   1. Die Hardware wird angezeigt (CPU, RAM, freier Platz).
#   2. Ollama wird mit dem offiziellen Installationsskript installiert.
#   3. Ollama lauscht auf Port 11434 – erreichbar NUR vom Portainer-Server
#      (Ollama selbst hat kein Passwort). Die Regel gilt auch nach Neustarts.
#   4. Kontextlänge 32768 Tokens (genug für Websuche), das Modell bleibt
#      24 Stunden im Arbeitsspeicher, damit Antworten nicht erst laden müssen.
#   5. Das Modell wird geladen (Standard: qwen3.6:35b-a3b, rund 24 GB) und
#      die Geschwindigkeit gemessen.
#
# Ohne Rückfragen:
#   PORTAINER_IP=1.2.3.4 MODELL=qwen3.6:35b-a3b ki-server-einrichten.sh
#
# Erlaubte IPs später ändern: /etc/ollama-erlaubt bearbeiten (mit Leerzeichen
# getrennt), dann: systemctl restart ollama-firewall
# =============================================================================
set -euo pipefail

MODELL="${MODELL:-qwen3.6:35b-a3b}"
KONTEXT="${KONTEXT:-32768}"
ERLAUBT_DATEI=/etc/ollama-erlaubt
DROPIN=/etc/systemd/system/ollama.service.d/einstellungen.conf
FW_SKRIPT=/usr/local/sbin/ollama-firewall
FW_UNIT=/etc/systemd/system/ollama-firewall.service
API=http://127.0.0.1:11434

schritt() { printf '\n== %s\n' "$*"; }
info()    { printf '   %s\n' "$*"; }
warn()    { printf '   WARNUNG: %s\n' "$*" >&2; }
abbruch() { printf '\nABBRUCH: %s\n' "$*" >&2; exit 1; }

TTY=/dev/tty
{ : <"$TTY"; } 2>/dev/null || TTY=/dev/stdin

ist_ipv4() {
  local ip=$1 teil teile
  [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -ra teile <<<"$ip"
  for teil in "${teile[@]}"; do (( 10#$teil <= 255 )) || return 1; done
}

pakete() {
  local fehlt=() eintrag
  for eintrag in "$@"; do command -v "${eintrag%%:*}" >/dev/null || fehlt+=("${eintrag#*:}"); done
  (( ${#fehlt[@]} )) || return 0
  info "Installiere: ${fehlt[*]}"
  apt-get update -q >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${fehlt[@]}" >/dev/null
}

# -----------------------------------------------------------------------------
hardware_zeigen() {
  local cpu kerne sockel numa ram avx
  cpu=$(lscpu | sed -n 's/^Model name:[[:space:]]*//p' | head -1)
  kerne=$(nproc)
  sockel=$(lscpu | sed -n 's/^Socket(s):[[:space:]]*//p' | head -1)
  numa=$(lscpu | sed -n 's/^NUMA node(s):[[:space:]]*//p' | head -1)
  ram=$(awk '/^MemTotal:/ {printf "%d", $2 / 1024 / 1024}' /proc/meminfo)
  if grep -qw avx512f /proc/cpuinfo; then avx="AVX-512 (schnell)"
  elif grep -qw avx2 /proc/cpuinfo; then avx="AVX2 (gut)"
  elif grep -qw avx /proc/cpuinfo; then avx="nur AVX (alt, deutlich langsamer)"
  else avx="kein AVX (zu alt für Ollama)"; fi
  info "CPU:       ${cpu:-unbekannt}"
  info "Threads:   $kerne   Sockel: ${sockel:-?}   NUMA-Knoten: ${numa:-?}"
  info "RAM:       ${ram} GB"
  info "Befehle:   $avx"
  info "Frei auf /: $(df -BG --output=avail / | tail -1 | tr -d ' ')"
  (( ram >= 32 )) || abbruch "Weniger als 32 GB RAM – dafür ist dieses Skript nicht gedacht."
}

erlaubte_ip_festlegen() {
  local ip=${PORTAINER_IP:-}
  if [[ -z $ip && -s $ERLAUBT_DATEI ]]; then
    ip=$(<"$ERLAUBT_DATEI")
    info "Erlaubte IPs aus $ERLAUBT_DATEI: $ip"
    return 0
  fi
  while [[ -z $ip ]] || ! ist_ipv4 "$ip"; do
    [[ -n $ip ]] && info "Das ist keine gültige IPv4-Adresse."
    read -rp "IPv4-Adresse des Portainer-Servers (dort läuft später n8n): " ip <"$TTY"
  done
  printf '%s\n' "$ip" >"$ERLAUBT_DATEI"
  info "Nur $ip (und dieser Server selbst) darf Ollama erreichen."
}

firewall_einrichten() {
  pakete iptables:iptables
  cat >"$FW_SKRIPT" <<'EOF'
#!/bin/sh
# Lässt Ollama (Port 11434) nur von den IPs in /etc/ollama-erlaubt zu.
# Angelegt von ki-server-einrichten.sh
set -e
ERLAUBT=$(cat /etc/ollama-erlaubt 2>/dev/null || true)
for T in iptables ip6tables; do
  command -v "$T" >/dev/null 2>&1 || continue
  "$T" -N OLLAMA_SCHUTZ 2>/dev/null || true
  "$T" -F OLLAMA_SCHUTZ
  "$T" -C INPUT -p tcp --dport 11434 -j OLLAMA_SCHUTZ 2>/dev/null \
    || "$T" -I INPUT -p tcp --dport 11434 -j OLLAMA_SCHUTZ
done
iptables -A OLLAMA_SCHUTZ -s 127.0.0.0/8 -j ACCEPT
for IP in $ERLAUBT; do iptables -A OLLAMA_SCHUTZ -s "$IP" -j ACCEPT; done
iptables -A OLLAMA_SCHUTZ -j DROP
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -A OLLAMA_SCHUTZ -s ::1 -j ACCEPT
  ip6tables -A OLLAMA_SCHUTZ -j DROP
fi
EOF
  chmod 755 "$FW_SKRIPT"
  cat >"$FW_UNIT" <<EOF
[Unit]
Description=Firewall-Regel für Ollama (Port 11434)
Wants=network-pre.target
Before=network-pre.target ollama.service

[Service]
Type=oneshot
ExecStart=$FW_SKRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable ollama-firewall >/dev/null 2>&1
  systemctl restart ollama-firewall
  info "Firewall-Regel aktiv, sie wird bei jedem Start neu gesetzt."
}

ollama_installieren() {
  pakete curl:curl jq:jq zstd:zstd
  if command -v ollama >/dev/null; then
    info "Ollama ist schon installiert ($(ollama --version 2>/dev/null | tail -1)). Übersprungen."
  else
    curl -fsSL https://ollama.com/install.sh | sh
  fi
  mkdir -p "$(dirname "$DROPIN")"
  cat >"$DROPIN" <<EOF
[Unit]
Wants=ollama-firewall.service
After=ollama-firewall.service

[Service]
# Im Netz erreichbar; wer darf, regelt ollama-firewall
Environment="OLLAMA_HOST=0.0.0.0:11434"
# Platz für Websuche-Ergebnisse
Environment="OLLAMA_CONTEXT_LENGTH=$KONTEXT"
# Modell im RAM halten, damit Antworten nicht erst laden müssen
Environment="OLLAMA_KEEP_ALIVE=24h"
EOF
  systemctl daemon-reload
  systemctl enable ollama >/dev/null 2>&1
  systemctl restart ollama
  local _
  for _ in $(seq 1 30); do curl -fsS -m 2 "$API/api/version" >/dev/null 2>&1 && break; sleep 1; done
  curl -fsS -m 2 "$API/api/version" >/dev/null || abbruch "Ollama antwortet nicht. Prüfen mit: journalctl -u ollama -n 50"
  info "Ollama läuft: Version $(curl -fsS "$API/api/version" | jq -r .version)"
}

modell_laden() {
  local frei
  frei=$(df -BG --output=avail /usr/share 2>/dev/null | tail -1 | tr -dc '0-9')
  if (( ${frei:-0} < 35 )); then
    abbruch "Nur ${frei:-?} GB frei für die Modelle (/usr/share/ollama). Das Modell braucht rund 25 GB."
  fi
  info "Lade $MODELL – das dauert je nach Leitung einige Minuten."
  ollama pull "$MODELL"
}

geschwindigkeit_messen() {
  local antwort tps pps text
  local text_lang
  # Rund 400 Wörter Eingabe, damit auch die Lesegeschwindigkeit aussagekräftig ist
  text_lang=$(printf '%.0s Ein DNS-Server übersetzt Namen wie example.com in IP-Adressen. Fragt ein Gerät nach einer Adresse, schaut der Server zuerst in seinem Zwischenspeicher nach. Kennt er die Antwort nicht, fragt er andere Server, bis er die zuständige Stelle gefunden hat. Werbeblocker wie AdGuard beantworten Anfragen nach bekannten Werbe- und Schadseiten absichtlich mit einer leeren Antwort, sodass diese Inhalte gar nicht erst geladen werden.' {1..6})
  info "Testaufgabe an $MODELL (ohne Nachdenk-Modus), kann auf alten CPUs einige Minuten dauern ..."
  antwort=$(curl -fsS -m 1800 "$API/api/generate" -d "$(jq -cn --arg m "$MODELL" --arg t "$text_lang" \
    '{model: $m, prompt: ("Fasse diesen Text in drei kurzen Sätzen zusammen:\n\n" + $t), stream: false, think: false}')") \
    || { warn "Testfrage fehlgeschlagen. Prüfen mit: journalctl -u ollama -n 50"; return 0; }
  text=$(jq -r '.response' <<<"$antwort")
  tps=$(jq -r 'if .eval_duration > 0 then (.eval_count / (.eval_duration / 1e9) * 10 | floor / 10) else 0 end' <<<"$antwort")
  pps=$(jq -r 'if (.prompt_eval_duration // 0) > 0 then (.prompt_eval_count / (.prompt_eval_duration / 1e9) | floor) else 0 end' <<<"$antwort")
  printf '\n   Antwort: %s\n\n' "$(fold -s -w 70 <<<"$text" | sed '2,$s/^/            /')"
  info "Schreiben: $tps Tokens/s   Lesen: $pps Tokens/s"
}

# -----------------------------------------------------------------------------
(( EUID == 0 )) || abbruch "Bitte als root starten"
command -v apt-get >/dev/null || abbruch "Dieses Skript ist für Debian und Ubuntu (apt-get fehlt)"
command -v systemctl >/dev/null || abbruch "systemd wird benötigt"

schritt "1/5 Hardware"
hardware_zeigen

schritt "2/5 Wer darf die KI erreichen?"
erlaubte_ip_festlegen

schritt "3/5 Firewall für Port 11434"
firewall_einrichten

schritt "4/5 Ollama installieren"
ollama_installieren

schritt "5/5 Modell laden und testen"
modell_laden
geschwindigkeit_messen

printf '\nFertig. Ollama läuft mit %s.\n' "$MODELL"
printf '  Test vom Portainer-Server:  curl http://%s:11434   → "Ollama is running"\n' \
  "$(hostname -I | awk '{print $1}')"
printf '  Zustand:                    systemctl status ollama\n'
printf '  Chat im Terminal:           ollama run %s\n' "$MODELL"

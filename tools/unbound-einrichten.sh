#!/usr/bin/env bash
# =============================================================================
# unbound-einrichten.sh – Unbound als eigener DNS-Resolver für AdGuard Home
# =============================================================================
# Auf jedem DNS-Server (dns1 bis dns6) als root ausführen:
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/Seki92/pihole-listen/master/tools/unbound-einrichten.sh)
#
# Was passiert:
#   1. Unbound wird installiert und lauscht nur lokal auf 127.0.0.1:5335.
#      Er fragt selbst bei den Root-Servern nach (kein Cloudflare, Google, Quad9),
#      prüft DNSSEC und hält einen Cache.
#   2. Stürzt Unbound ab, startet systemd ihn nach 5 Sekunden neu.
#   3. AdGuard Home auf diesem Server fragt danach Unbound. Die bisherigen
#      Upstreams werden zu Fallback-DNS: Antwortet Unbound nicht, nimmt AdGuard
#      automatisch die. Gefiltert wird in jedem Fall weiter.
#   4. Optional meldet ein Cron-Job jede Minute an Uptime Kuma, ob Unbound antwortet.
#
# Vorher wird gesichert. AdGuard wird erst umgestellt, wenn Unbound nachweislich
# funktioniert.
#
# Weitere Aufrufe:
#   --hauptserver   Upstreams eines Hauptservers (adguard/adguardbackup) ordnen:
#                   DNS-Server in Asien werden zu Fallback-DNS
#   --zurueck       AdGuard-Upstreams auf den Stand vor dem ersten Lauf zurücksetzen
#   --hilfe         diese Hilfe
#
# Ohne Rückfragen, z. B. für Ansible:
#   AGH_URL=https://dns3.home-albrecht.com AGH_USER=… AGH_PASS=… KUMA_PUSH_URL=… \
#     unbound-einrichten.sh
#
# Für Debian und Ubuntu.
# =============================================================================
set -euo pipefail

DOMAIN="${DOMAIN:-home-albrecht.com}"
UNBOUND_ADDR="127.0.0.1:5335"
UNBOUND_CONF="/etc/unbound/unbound.conf.d/adguard-upstream.conf"
SYSTEMD_DROPIN="/etc/systemd/system/unbound.service.d/neustart.conf"
SICHERUNG_DIR="/var/backups/unbound-einrichten"
PUSH_URL_DATEI="/etc/unbound-kuma-push.url"
PUSH_SKRIPT="/usr/local/sbin/unbound-kuma-push"
PUSH_CRON="/etc/cron.d/unbound-kuma-push"
STANDARD_FALLBACK='["https://dns.quad9.net/dns-query","https://cloudflare-dns.com/dns-query"]'
TESTNAME="${TESTNAME:-debian.org}"
RAW_URL="https://raw.githubusercontent.com/Seki92/pihole-listen/master/tools/unbound-einrichten.sh"

# So taucht der Befehl in Hinweisen auf – auch beim Start über bash <(curl …)
if [[ $0 == /dev/fd/* || $0 == /proc/* || $0 == bash ]]; then AUFRUF="bash <(curl -fsSL $RAW_URL)"
else AUFRUF=$0; fi

schritt() { printf '\n== %s\n' "$*"; }
info()    { printf '   %s\n' "$*"; }
warn()    { printf '   WARNUNG: %s\n' "$*" >&2; }
abbruch() { printf '\nABBRUCH: %s\n' "$*" >&2; exit 1; }

hilfe() {
  cat <<EOF
unbound-einrichten.sh – Unbound als eigener DNS-Resolver für AdGuard Home

  $AUFRUF
      Auf einem DNS-Server (dns1 bis dns6): Unbound installieren, testen und
      AdGuard darauf umstellen. Bisherige Upstreams werden zu Fallback-DNS.

  $AUFRUF --hauptserver
      Auf einem Hauptserver (adguard/adguardbackup) die DNS-Server in Asien
      zu Fallback-DNS machen. Kann von jedem deiner Server aus laufen.

  $AUFRUF --zurueck
      AdGuard-Upstreams auf den Stand vor dem ersten Lauf zurücksetzen.

Ohne Rückfragen: AGH_URL, AGH_USER, AGH_PASS und optional KUMA_PUSH_URL setzen.
Sicherungen liegen in $SICHERUNG_DIR.
EOF
  exit 0
}

# Eingaben vom Terminal lesen, auch wenn das Skript per Pipe gestartet wurde
TTY=/dev/tty
{ : <"$TTY"; } 2>/dev/null || TTY=/dev/stdin

frage() { # frage VARIABLE "Text" [Vorgabe]
  local _antwort
  if [[ -n ${3:-} ]]; then read -rp "$2 [$3]: " _antwort <"$TTY"
  else read -rp "$2: " _antwort <"$TTY"; fi
  printf -v "$1" '%s' "${_antwort:-${3:-}}"
}
ja() { local _a; read -rp "$1 [j/N]: " _a <"$TTY"; [[ $_a =~ ^[jJyY] ]]; }

# -----------------------------------------------------------------------------
# AdGuard-Home-API
# -----------------------------------------------------------------------------
# agh METHODE PFAD [JSON] – Zugangsdaten gehen über stdin an curl, damit das
# Passwort nicht in der Prozessliste auftaucht.
agh() {
  local methode=$1 pfad=$2 daten=${3:-} cred antwort code
  cred="$AGH_USER:$AGH_PASS"; cred=${cred//\\/\\\\}; cred=${cred//\"/\\\"}
  local args=(-sS --max-time 90 -K - -X "$methode" -w $'\n%{http_code}')
  [[ -n $daten ]] && args+=(-H 'Content-Type: application/json' --data "$daten")
  antwort=$(printf 'user = "%s"\n' "$cred" | curl "${args[@]}" "$AGH_URL/control/$pfad") || return 1
  code=${antwort##*$'\n'}; antwort=${antwort%$'\n'*}
  if [[ $code != 2* ]]; then
    printf '   AdGuard antwortet mit HTTP %s: %s\n' "$code" "${antwort:0:300}" >&2
    return 1
  fi
  printf '%s' "$antwort"
}

url_host() { local h=${1#*://}; h=${h%%/*}; printf '%s' "${h%%:*}"; }

anmelden() { # anmelden "Frage" "Vorgabe"
  [[ -n ${AGH_URL:-} ]] || frage AGH_URL "$1" "${2:-}"
  [[ -n $AGH_URL ]] || abbruch "Keine Adresse angegeben"
  [[ $AGH_URL =~ ^[0-9]+$ ]] && AGH_URL="https://dns$AGH_URL.$DOMAIN"
  [[ $AGH_URL == http://* || $AGH_URL == https://* ]] || AGH_URL="https://$AGH_URL"
  AGH_URL=${AGH_URL%/}
  [[ -n ${AGH_USER:-} ]] || frage AGH_USER "AdGuard-Benutzer"
  if [[ -z ${AGH_PASS:-} ]]; then
    read -rsp "AdGuard-Passwort: " AGH_PASS <"$TTY"; echo >&2
  fi
  DNS_INFO=$(agh GET dns_info) && jq -e 'type == "object"' >/dev/null 2>&1 <<<"$DNS_INFO" \
    || abbruch "$AGH_URL ist nicht erreichbar oder die Anmeldung ist falsch"
  if [[ -n $(jq -r '.upstream_dns_file // ""' <<<"$DNS_INFO") ]]; then
    abbruch "Auf $AGH_URL kommen die Upstreams aus einer Datei (upstream_dns_file). Das stellt dieses Skript nicht um."
  fi
  info "Angemeldet bei $AGH_URL"
}

sichern() {
  local dir ts
  dir="$SICHERUNG_DIR/$(url_host "$AGH_URL")"; ts=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$dir"; chmod 700 "$SICHERUNG_DIR"
  jq '{upstream_dns: (.upstream_dns // []), fallback_dns: (.fallback_dns // [])}' \
    <<<"$DNS_INFO" >"$dir/$ts.json"
  [[ -e $dir/original.json ]] || cp "$dir/$ts.json" "$dir/original.json"
  info "Gesichert: $dir/$ts.json"
}

liste_zeigen() { # liste_zeigen JSON-ARRAY
  jq -r 'if length == 0 then "     (leer)" else .[] | "     \(.)" end' <<<"$1"
}

# testen_und_anwenden UPSTREAMS FALLBACKS HAUPT-JSON
#   HAUPT-JSON: Upstreams, von denen mindestens einer den Test bestehen muss
testen_und_anwenden() {
  local up=$1 fb=$2 pflicht=$3 daten ergebnis ok
  daten=$(jq -cn --argjson u "$up" --argjson f "$fb" \
    --argjson b "$(jq -c '.bootstrap_dns // []' <<<"$DNS_INFO")" \
    '{upstream_dns: $u, fallback_dns: $f, bootstrap_dns: $b}')
  ergebnis=$(agh POST test_upstream_dns "$daten") \
    || abbruch "AdGuard konnte die neuen Upstreams nicht testen. Nichts wurde geändert."
  info "Test durch AdGuard:"
  jq -r 'to_entries[] | "     \(if .value == "OK" then "OK     " else "FEHLER " end) \(.key)\(if .value == "OK" then "" else ": \(.value)" end)"' \
    <<<"$ergebnis"
  ok=$(jq -n --argjson e "$ergebnis" --argjson p "$pflicht" '[ $p[] | select($e[.] == "OK") ] | length')
  (( ok > 0 )) || abbruch "Kein Haupt-Upstream hat den Test bestanden. Nichts wurde geändert."

  agh POST dns_config "$(jq -cn --argjson u "$up" --argjson f "$fb" '{upstream_dns: $u, fallback_dns: $f}')" >/dev/null \
    || abbruch "AdGuard hat die neue Einstellung abgelehnt. Es gilt weiter die alte."
  DNS_INFO=$(agh GET dns_info) || abbruch "AdGuard antwortet nach der Änderung nicht mehr"
  jq -e --argjson u "$up" --argjson f "$fb" '.upstream_dns == $u and (.fallback_dns // []) == $f' \
    >/dev/null <<<"$DNS_INFO" || abbruch "Die Einstellung ist bei AdGuard nicht angekommen"
  info "In AdGuard übernommen."
}

pakete() { # pakete BEFEHL:PAKET ...   (Paket "DIG" = das passende Paket für dig)
  local fehlt=() eintrag paket
  for eintrag in "$@"; do command -v "${eintrag%%:*}" >/dev/null || fehlt+=("${eintrag#*:}"); done
  (( ${#fehlt[@]} )) || return 0
  apt-get update -q >/dev/null
  for paket in "${!fehlt[@]}"; do
    if [[ ${fehlt[$paket]} == DIG ]]; then
      if apt-cache show bind9-dnsutils >/dev/null 2>&1; then fehlt[$paket]=bind9-dnsutils
      else fehlt[$paket]=dnsutils; fi
    fi
  done
  info "Installiere: ${fehlt[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${fehlt[@]}" >/dev/null
}

# -----------------------------------------------------------------------------
# Unbound
# -----------------------------------------------------------------------------
unbound_konfig_schreiben() {
  local ram ip6=no msg=8m rrset=16m
  ram=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
  (( ram >= 1800 )) && { msg=32m; rrset=64m; }
  ip -6 route show default 2>/dev/null | grep -q . && ip6=yes
  mkdir -p "$(dirname "$UNBOUND_CONF")"
  cat >"$UNBOUND_CONF" <<EOF
# Angelegt von unbound-einrichten.sh – Unbound als Upstream für AdGuard Home.
# Unbound lauscht nur lokal; von außen ist er nicht erreichbar.
server:
    verbosity: 0
    interface: 127.0.0.1
    port: 5335
    access-control: 127.0.0.0/8 allow
    do-ip4: yes
    do-ip6: $ip6
    prefer-ip6: no
    do-udp: yes
    do-tcp: yes

    # Sicherheit und Datenschutz
    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    qname-minimisation: yes
    use-caps-for-id: no
    edns-buffer-size: 1232

    # Cache: beliebte Einträge vor Ablauf erneuern, abgelaufene als Reserve
    # ausliefern, falls ein Nameserver gerade nicht antwortet (RFC 8767)
    num-threads: 1
    msg-cache-size: $msg
    rrset-cache-size: $rrset
    prefetch: yes
    prefetch-key: yes
    serve-expired: yes
    serve-expired-ttl: 86400
    serve-expired-client-timeout: 1800
EOF
  info "Konfiguration: $UNBOUND_CONF (Cache ${msg}/${rrset}, IPv6 $ip6)"
}

# DNSSEC-Vertrauensanker nur ergänzen, wenn das Paket ihn nicht schon setzt
dnssec_anker() {
  if ! grep -rqs --exclude="$(basename "$UNBOUND_CONF")" '^[[:space:]]*auto-trust-anchor-file' \
      /etc/unbound/unbound.conf /etc/unbound/unbound.conf.d/; then
    printf '\n    # DNSSEC\n    auto-trust-anchor-file: "/var/lib/unbound/root.key"\n' >>"$UNBOUND_CONF"
  fi
}

# DNSSEC-Schlüssel der Root-Zone bereitstellen. Er kommt aus dem Paket
# dns-root-data, das apt nur als Empfehlung mitinstalliert – auf vielen
# Servern sind Empfehlungen abgeschaltet. Ohne ihn startet Unbound nicht.
anker_datei_anlegen() {
  local key=/var/lib/unbound/root.key quelle=/usr/share/dns/root.key
  [[ -s $key ]] && return 0
  if [[ ! -s $quelle ]]; then
    info "Installiere: dns-root-data"
    apt-get update -q >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q dns-root-data >/dev/null || true
  fi
  install -d -o unbound -g unbound /var/lib/unbound 2>/dev/null || mkdir -p /var/lib/unbound
  if [[ -s $quelle ]]; then
    cp "$quelle" "$key"
  elif command -v unbound-anchor >/dev/null; then
    unbound-anchor -a "$key" >/dev/null 2>&1 || true
  fi
  [[ -s $key ]] || { rm -f "$UNBOUND_CONF"; abbruch "DNSSEC-Schlüssel fehlt: dns-root-data ließ sich nicht installieren (apt install dns-root-data)"; }
  chown unbound:unbound "$key" 2>/dev/null || true
  info "DNSSEC-Schlüssel der Root-Zone bereitgestellt."
}

vorpruefen() {
  local belegt fremd
  belegt=$( { ss -Hlnup 'sport = :5335'; ss -Hlntp 'sport = :5335'; } 2>/dev/null ) || true
  if [[ -n $belegt && $belegt != *unbound* ]]; then
    abbruch "Port 5335 ist schon von einem anderen Programm belegt: $belegt"
  fi
  # Eine ältere eigene Unbound-Konfiguration (z. B. nach Pi-hole-Anleitung) würde sich beißen
  fremd=$(grep -lsE '^[[:space:]]*(interface|port):' /etc/unbound/unbound.conf.d/*.conf \
            | grep -vx "$UNBOUND_CONF") || true
  if [[ -n $fremd ]]; then
    abbruch "Es gibt schon eine eigene Unbound-Konfiguration mit interface/port:
$fremd
         Bitte prüfen und entfernen (oder umbenennen auf .bak), dann erneut starten."
  fi
}

unbound_installieren() {
  vorpruefen
  unbound_konfig_schreiben
  pakete unbound:unbound dig:DIG
  dnssec_anker
  anker_datei_anlegen
  unbound-checkconf >/dev/null || { rm -f "$UNBOUND_CONF"; abbruch "Unbound-Konfiguration fehlerhaft (unbound-checkconf)"; }

  # Unbound soll nicht in /etc/resolv.conf eingreifen (Debian/Ubuntu)
  if systemctl list-unit-files unbound-resolvconf.service >/dev/null 2>&1; then
    systemctl disable --now unbound-resolvconf.service >/dev/null 2>&1 || true
  fi
  if [[ -f /etc/resolvconf.conf ]] && grep -q '^unbound_conf=' /etc/resolvconf.conf; then
    sed -Ei 's/^unbound_conf=/#unbound_conf=/' /etc/resolvconf.conf
    rm -f /etc/unbound/unbound.conf.d/resolvconf_resolvers.conf
  fi

  # Bei Absturz nach 5 Sekunden neu starten, ohne Begrenzung der Versuche
  mkdir -p "$(dirname "$SYSTEMD_DROPIN")"
  printf '[Unit]\nStartLimitIntervalSec=0\n\n[Service]\nRestart=always\nRestartSec=5\n' >"$SYSTEMD_DROPIN"
  systemctl daemon-reload
  systemctl enable unbound >/dev/null 2>&1 || true
  systemctl restart unbound
  info "Unbound läuft und startet nach einem Absturz automatisch neu."
}

unbound_testen() {
  local antwort status
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    antwort=$(dig +time=5 +tries=1 +short @127.0.0.1 -p 5335 "$TESTNAME" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1) || true
    [[ -n $antwort ]] && break
    sleep 2
  done
  if [[ -z $antwort ]]; then
    abbruch "Unbound bekommt keine Antworten. Blockt der Anbieter ausgehende DNS-Anfragen (Port 53)?
         Prüfen mit: dig @127.0.0.1 -p 5335 $TESTNAME
         AdGuard wurde NICHT verändert."
  fi
  info "Auflösung klappt: $TESTNAME → $antwort"
  status=$(dig +time=5 +tries=1 @127.0.0.1 -p 5335 dnssec-failed.org A 2>/dev/null | grep -o 'status: [A-Z]*' | head -1) || true
  if [[ $status == "status: SERVFAIL" ]]; then
    info "DNSSEC-Prüfung aktiv: gefälschte Antworten werden abgelehnt."
  else
    warn "DNSSEC-Prüfung scheint nicht zu greifen ($status). Unbound funktioniert trotzdem."
  fi
}

# -----------------------------------------------------------------------------
# Uptime-Kuma-Push
# -----------------------------------------------------------------------------
push_einrichten() {
  local url=$1
  [[ $url == http*://*/api/push/* ]] || { warn "Das sieht nicht nach einer Push-URL aus (…/api/push/…). Übersprungen."; return 0; }
  pakete curl:curl
  umask 077; printf '%s\n' "${url%%\?*}" >"$PUSH_URL_DATEI"; umask 022
  cat >"$PUSH_SKRIPT" <<'EOF'
#!/bin/sh
# Meldet Uptime Kuma, ob Unbound auf 127.0.0.1:5335 antwortet (angelegt von unbound-einrichten.sh)
URL=$(cat /etc/unbound-kuma-push.url 2>/dev/null) || exit 0
[ -n "$URL" ] || exit 0
START=$(date +%s%3N)
if [ -n "$(dig +short +time=3 +tries=1 @127.0.0.1 -p 5335 . NS 2>/dev/null)" ]; then
  MS=$(( $(date +%s%3N) - START ))
  curl -fsS -m 15 -o /dev/null "$URL?status=up&msg=OK&ping=$MS"
else
  curl -fsS -m 15 -o /dev/null "$URL?status=down&msg=Unbound+antwortet+nicht&ping="
fi
EOF
  chmod 755 "$PUSH_SKRIPT"
  printf '# Meldet Uptime Kuma jede Minute den Zustand von Unbound\n* * * * * root %s >/dev/null 2>&1\n' \
    "$PUSH_SKRIPT" >"$PUSH_CRON"
  if "$PUSH_SKRIPT"; then info "Erste Meldung an Uptime Kuma gesendet. Ab jetzt jede Minute."
  else warn "Uptime Kuma nicht erreichbar. Der Cron-Job versucht es jede Minute weiter."; fi
}

# -----------------------------------------------------------------------------
# Abläufe
# -----------------------------------------------------------------------------
dns_server_einrichten() {
  local spezial allgemein neu_up neu_fb push_url=${KUMA_PUSH_URL:-}

  schritt "1/5 Anmeldung bei AdGuard auf diesem Server"
  pakete curl:curl jq:jq
  anmelden "Welcher DNS-Server ist das? Nummer (z. B. 3) oder Adresse"
  if [[ -z ${AGH_URL_VORGEGEBEN:-} && -z $push_url ]]; then
    while :; do
      frage push_url "Uptime-Kuma-Push-URL für diesen Server (Enter = ohne)"
      [[ -z $push_url || $push_url == http*://*/api/push/* ]] && break
      info "Das ist keine Push-URL. Du findest sie in Uptime Kuma beim Push-Monitor,"
      info "sie sieht so aus: https://status.$DOMAIN/api/push/AbC123xyz?status=up&msg=OK&ping="
    done
  fi

  schritt "2/5 Unbound installieren"
  unbound_installieren

  schritt "3/5 Unbound testen"
  unbound_testen

  schritt "4/5 AdGuard auf Unbound umstellen"
  sichern
  spezial=$(jq -c '[(.upstream_dns // [])[] | select(startswith("[/"))]' <<<"$DNS_INFO")
  allgemein=$(jq -c --arg u "$UNBOUND_ADDR" '[(.upstream_dns // [])[]
      | select((startswith("[/") or startswith("#") or . == "" or . == $u) | not)]' <<<"$DNS_INFO")
  neu_up=$(jq -cn --arg u "$UNBOUND_ADDR" --argjson s "$spezial" '[$u] + $s')
  if [[ $allgemein != "[]" ]]; then
    neu_fb=$allgemein
  elif [[ $(jq -c '.fallback_dns // []' <<<"$DNS_INFO") != "[]" ]]; then
    neu_fb=$(jq -c '.fallback_dns' <<<"$DNS_INFO")     # erneuter Lauf: Fallback bleibt
  else
    neu_fb=$STANDARD_FALLBACK
  fi
  info "Upstream neu:"; liste_zeigen "$neu_up"
  info "Fallback (springt ein, wenn Unbound nicht antwortet):"; liste_zeigen "$neu_fb"
  testen_und_anwenden "$neu_up" "$neu_fb" "[\"$UNBOUND_ADDR\"]"

  schritt "5/5 Überwachung"
  if [[ -n $push_url ]]; then push_einrichten "$push_url"
  else info "Ohne Uptime-Kuma-Push. Nachholen: Skript einfach erneut starten und die Push-URL eingeben."; fi

  printf '\nFertig. AdGuard auf %s fragt jetzt Unbound.\n' "$(url_host "$AGH_URL")"
  printf '  Zustand:       systemctl status unbound\n'
  printf '  Test:          dig @127.0.0.1 -p 5335 heise.de\n'
  printf '  Rückgängig:    %s --zurueck\n' "$AUFRUF"
}

hauptserver_ordnen() {
  local spezial allgemein auswahl n neu_up neu_fb haupt anzahl
  schritt "Upstreams eines Hauptservers ordnen"
  pakete curl:curl jq:jq
  anmelden "Adresse des Hauptservers" "https://adguard.$DOMAIN"
  spezial=$(jq -c '[(.upstream_dns // [])[] | select(startswith("[/"))]' <<<"$DNS_INFO")
  allgemein=$(jq -c '[(.upstream_dns // [])[] | select((startswith("[/") or startswith("#") or . == "") | not)]' <<<"$DNS_INFO")
  anzahl=$(jq length <<<"$allgemein")
  (( anzahl >= 2 )) || abbruch "Dort sind weniger als 2 Upstreams eingetragen. Nichts zu ordnen."

  info "Aktuelle Upstreams:"
  jq -r 'to_entries[] | "     \(.key + 1)) \(.value)"' <<<"$allgemein"
  if [[ $(jq -c '.fallback_dns // []' <<<"$DNS_INFO") != "[]" ]]; then
    info "Aktuelle Fallback-DNS (werden ersetzt):"; liste_zeigen "$(jq -c '.fallback_dns' <<<"$DNS_INFO")"
  fi
  frage auswahl "Nummern der Server in Hongkong und Tokio, mit Leerzeichen getrennt"
  [[ -n $auswahl ]] || abbruch "Nichts ausgewählt. Nichts wurde geändert."
  for n in $auswahl; do
    [[ $n =~ ^[0-9]+$ ]] && (( n >= 1 && n <= anzahl )) || abbruch "Ungültige Nummer: $n"
  done
  auswahl=$(printf '%s\n' $auswahl | jq -R 'tonumber - 1' | jq -cs 'unique')

  haupt=$(jq -c --argjson a "$auswahl" 'to_entries | map(select(.key | IN($a[]) | not) | .value)' <<<"$allgemein")
  neu_fb=$(jq -c --argjson a "$auswahl" 'to_entries | map(select(.key | IN($a[])) | .value)' <<<"$allgemein")
  [[ $haupt != "[]" ]] || abbruch "Es muss mindestens ein Server als Haupt-Upstream übrig bleiben."
  neu_up=$(jq -cn --argjson h "$haupt" --argjson s "$spezial" '$h + $s')

  info "Haupt-Upstreams (Deutschland/Finnland):"; liste_zeigen "$neu_up"
  info "Nur als Fallback (Asien):";              liste_zeigen "$neu_fb"
  ja "So übernehmen?" || abbruch "Abgebrochen. Nichts wurde geändert."
  sichern
  testen_und_anwenden "$neu_up" "$neu_fb" "$haupt"
  printf '\nFertig. Denk an den zweiten Hauptserver (%s).\n' \
    "$( [[ $AGH_URL == *adguardbackup* ]] && echo "adguard.$DOMAIN" || echo "adguardbackup.$DOMAIN")"
  printf '  Rückgängig:    %s --zurueck\n' "$AUFRUF"
}

zuruecksetzen() {
  local datei
  schritt "AdGuard-Upstreams zurücksetzen"
  pakete curl:curl jq:jq
  anmelden "Welcher Server? Nummer (z. B. 3) oder Adresse"
  datei="$SICHERUNG_DIR/$(url_host "$AGH_URL")/original.json"
  [[ -r $datei ]] || abbruch "Keine Sicherung für $(url_host "$AGH_URL") auf diesem Rechner ($datei)"
  info "Stand vor dem ersten Lauf – Upstreams:"; liste_zeigen "$(jq -c .upstream_dns "$datei")"
  info "Fallback-DNS:";                          liste_zeigen "$(jq -c .fallback_dns "$datei")"
  ja "Darauf zurücksetzen?" || abbruch "Abgebrochen. Nichts wurde geändert."
  agh POST dns_config "$(jq -c '{upstream_dns, fallback_dns}' "$datei")" >/dev/null \
    || abbruch "AdGuard hat die alte Einstellung abgelehnt"
  info "Zurückgesetzt. Unbound bleibt installiert; entfernen mit: apt purge unbound"
  [[ -f $PUSH_CRON ]] && info "Uptime-Kuma-Meldung abschalten: rm $PUSH_CRON"
  return 0
}

# -----------------------------------------------------------------------------
[[ ${1:-} == --hilfe || ${1:-} == -h ]] && hilfe
(( EUID == 0 )) || abbruch "Bitte als root starten"
command -v apt-get >/dev/null || abbruch "Dieses Skript ist für Debian und Ubuntu (apt-get fehlt)"
[[ -n ${AGH_URL:-} ]] && AGH_URL_VORGEGEBEN=1

case "${1:-}" in
  "")            dns_server_einrichten ;;
  --hauptserver) hauptserver_ordnen ;;
  --zurueck)     zuruecksetzen ;;
  *)             abbruch "Unbekannte Option: $1 (siehe --hilfe)" ;;
esac

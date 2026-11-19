#!/usr/bin/env bash
# =============================================================================
# einrichten.sh – richtet den Listen-Abgleich für alle AdGuard-Server ein.
# Einmal auf EINEM Linux-Server als root ausführen (es muss nicht auf jedem
# DNS-Server laufen – dieser eine Server gleicht alle über die AdGuard-API ab):
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/Seki92/pihole-listen/master/tools/einrichten.sh)
#
# Was passiert:
#   1. curl und jq werden installiert (falls nötig)
#   2. listen-update.sh landet in /usr/local/bin
#   3. Du gibst Benutzer und Passwort deiner AdGuard-Oberflächen ein
#      → /etc/listen-update.conf (nur für root lesbar)
#   4. Probelauf: zeigt, was auf jedem Server passieren würde
#   5. Echter Lauf + täglicher Cron-Job (/etc/cron.d/listen-update)
# =============================================================================
set -euo pipefail
weiter="" haupt="" gleich="" benutzer="" pw="" trotzdem=""

QUELLE="${QUELLE:-https://raw.githubusercontent.com/Seki92/pihole-listen/master}"
BIN="${BIN:-/usr/local/bin/listen-update.sh}"
KONF="${KONF:-/etc/listen-update.conf}"
CRON="${CRON:-/etc/cron.d/listen-update}"
EINGABE="${EINGABE:-/dev/tty}"
DOMAIN="home-albrecht.com"

exec 3<"$EINGABE"   # Eingaben kommen vom Terminal, auch wenn das Skript per curl kommt

frage() {  # frage <Variable> <Text> [Vorgabe]
  local antwort=""
  read -r -u 3 -p "$2${3:+ [$3]}: " antwort || true
  printf -v "$1" '%s' "${antwort:-${3:-}}"
}
frage_geheim() {  # frage_geheim <Variable> <Text>
  local antwort=""
  while [[ -z "$antwort" ]]; do
    read -r -s -u 3 -p "$2: " antwort || exit 1; echo
  done
  printf -v "$1" '%s' "$antwort"
}
ja() { [[ "${1,,}" =~ ^(j|ja|y|yes)$ ]]; }

[[ $EUID -eq 0 ]] || { echo "Bitte als root ausführen (z. B. erst 'sudo -i')."; exit 1; }

echo "== 1/5 Pakete"
if ! command -v curl >/dev/null || ! command -v jq >/dev/null; then
  if   command -v apt-get >/dev/null; then apt-get update -qq && apt-get install -y -qq curl jq ca-certificates >/dev/null
  elif command -v dnf     >/dev/null; then dnf install -y -q curl jq
  elif command -v yum     >/dev/null; then yum install -y -q curl jq
  elif command -v apk     >/dev/null; then apk add -q bash curl jq
  else echo "Bitte curl und jq von Hand installieren."; exit 1
  fi
fi
echo "   curl und jq sind da."

echo "== 2/5 Skript installieren"
tmp="$(mktemp)"
curl -fsSL "$QUELLE/tools/listen-update.sh" -o "$tmp"
bash -n "$tmp"
install -m 755 "$tmp" "$BIN"; rm -f "$tmp"
echo "   $BIN"

echo "== 3/5 Zugangsdaten deiner AdGuard-Oberflächen"
echo "   (Das sind die Logins der AdGuard-Weboberfläche, nicht root.)"
schreiben=1
if [[ -f "$KONF" ]]; then
  frage weiter "$KONF gibt es schon. Neu anlegen?" "n"
  ja "$weiter" || schreiben=0
fi
if (( schreiben )); then
  server_urls=()
  for i in 1 2 3 4 5 6; do server_urls+=("https://dns$i.$DOMAIN"); done
  frage haupt "Filtern adguard.$DOMAIN und adguardbackup.$DOMAIN selbst auch (eigene Listen)?" "n"
  if ja "$haupt"; then server_urls+=("https://adguard.$DOMAIN" "https://adguardbackup.$DOMAIN"); fi

  frage benutzer "AdGuard-Benutzername" "admin"
  frage gleich "Haben alle ${#server_urls[@]} Server dasselbe Passwort?" "j"
  eintraege=()
  if ja "$gleich"; then
    frage_geheim pw "Passwort"
    for u in "${server_urls[@]}"; do eintraege+=("$u|$benutzer|$pw"); done
  else
    for u in "${server_urls[@]}"; do
      frage_geheim pw "Passwort für $u"
      eintraege+=("$u|$benutzer|$pw")
    done
  fi
  unset pw

  ( umask 077
    {
      echo "# /etc/listen-update.conf – angelegt von einrichten.sh am $(date +%F)"
      echo "# Server-Adresse anpassen, falls eine Oberfläche anders erreichbar ist"
      echo "# (z. B. http://10.0.0.11:3000). Format: \"Adresse|Benutzer|Passwort\""
      echo "RAW_BASIS=\"$QUELLE\""
      echo "BLOCK_DATEIEN=(Blockliste blocklist1 blocklist3)"
      echo "ERLAUBT_DATEIEN=(whitelist)"
      echo "EXTRA_BLOCKLISTEN=("
      echo "  \"HaGeZi Multi PRO++|https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.plus.txt\""
      echo "  # Bei >= 2 GB RAM pro Server lieber tif.medium.txt"
      echo "  \"HaGeZi Threat Intelligence Mini|https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/tif.mini.txt\""
      echo ")"
      echo "SERVER=("
      for e in "${eintraege[@]}"; do printf '  %q\n' "$e"; done
      echo ")"
      echo "LOCKDATEI=/run/listen-update.lock"
    } > "$KONF"
  )
  chmod 600 "$KONF"
  echo "   $KONF angelegt (nur root kann sie lesen)."
fi

echo "== 4/5 Probelauf (ändert nichts)"
if LISTEN_UPDATE_CONF="$KONF" "$BIN" --nur-server --trocken; then
  echo "   Alle Server erreichbar."
else
  echo
  echo "   Mindestens ein Server war nicht erreichbar oder das Passwort stimmte nicht."
  echo "   Adresse/Passwort in $KONF korrigieren und dieses Skript erneut starten"
  echo "   (bei der Frage 'Neu anlegen?' dann 'n' wählen)."
  frage trotzdem "Trotzdem für die erreichbaren Server weitermachen?" "n"
  ja "$trotzdem" || exit 1
fi

echo "== 5/5 Listen auf allen Servern einrichten und täglichen Abgleich aktivieren"
LISTEN_UPDATE_CONF="$KONF" "$BIN" --nur-server || true
cat > "$CRON" <<EOF
# Gleicht täglich die Listen-Abos aller AdGuard-Server ab (angelegt von einrichten.sh)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
47 4 * * *  root  LISTEN_UPDATE_CONF=$KONF $BIN --nur-server >> /var/log/listen-update.log 2>&1
EOF
chmod 644 "$CRON"
echo "   Cron-Job: $CRON (täglich 04:47, Protokoll: /var/log/listen-update.log)"
echo
echo "Fertig. Die Listen selbst pflegt ab jetzt die GitHub-Action im Repo."

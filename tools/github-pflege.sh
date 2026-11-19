#!/usr/bin/env bash
# =============================================================================
# github-pflege.sh – erlaubt listen-update.sh, die Listen auf GitHub selbst zu
# bereinigen und zu pushen (über einen eigenen "Deploy Key" nur für dieses Repo).
# Voraussetzung: einrichten.sh wurde auf diesem Server schon ausgeführt.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/Seki92/pihole-listen/master/tools/github-pflege.sh)
#
# Was passiert:
#   1. git, ssh und dig werden installiert (falls nötig)
#   2. ein Schlüsselpaar nur für dieses Repo wird erzeugt (/root/.ssh/pihole_listen_deploy)
#   3. du trägst den öffentlichen Teil bei GitHub ein (Link wird angezeigt)
#   4. Test: darf der Server ins Repo schreiben?
#   5. /etc/listen-update.conf wird ergänzt, Cron-Job umgestellt:
#        täglich  04:47  Listen bereinigen + pushen, Server abgleichen (+ Updates)
#        monatlich am 1. um 03:17  zusätzlich tote Domains entfernen
# =============================================================================
set -euo pipefail
antwort=""

REPO="Seki92/pihole-listen"
ALIAS="github-listen"                 # eigener SSH-Name, andere GitHub-Zugänge bleiben unberührt
KONF="${KONF:-/etc/listen-update.conf}"
BIN="${BIN:-/usr/local/bin/listen-update.sh}"
CRON="${CRON:-/etc/cron.d/listen-update}"
SSH_DIR="${SSH_DIR:-/root/.ssh}"
SCHLUESSEL="$SSH_DIR/pihole_listen_deploy"
EINGABE="${EINGABE:-/dev/tty}"
# Offizieller Host-Schlüssel von GitHub (docs.github.com → "GitHub's SSH key fingerprints")
GITHUB_HOSTKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"

exec 3<"$EINGABE"
frage() { local a=""; read -r -u 3 -p "$2${3:+ [$3]}: " a || true; printf -v "$1" '%s' "${a:-${3:-}}"; }
ja() { [[ "${1,,}" =~ ^(j|ja|y|yes)$ ]]; }

[[ $EUID -eq 0 ]] || { echo "Bitte als root ausführen (z. B. erst 'sudo -i')."; exit 1; }
[[ -f "$KONF" && -x "$BIN" ]] || { echo "Bitte zuerst einrichten.sh ausführen ($KONF oder $BIN fehlt)."; exit 1; }

echo "== 1/5 Pakete"
fehlend=()
command -v git        >/dev/null || fehlend+=(git)
command -v ssh-keygen >/dev/null || fehlend+=(openssh-client)
command -v dig        >/dev/null || fehlend+=(dnsutils)
if (( ${#fehlend[@]} )); then
  if command -v apt-get >/dev/null; then apt-get update -qq && apt-get install -y -qq "${fehlend[@]}" >/dev/null
  else echo "Bitte von Hand installieren: git, ssh, dig"; exit 1
  fi
fi
echo "   git, ssh und dig sind da."

echo "== 2/5 Schlüssel für das Repo"
install -d -m 700 "$SSH_DIR"
if [[ ! -f "$SCHLUESSEL" ]]; then
  ssh-keygen -q -t ed25519 -N "" -C "listen-update@$(hostname)" -f "$SCHLUESSEL"
  echo "   neu erzeugt: $SCHLUESSEL"
else
  echo "   vorhanden:   $SCHLUESSEL"
fi
if ! grep -q "^Host $ALIAS\$" "$SSH_DIR/config" 2>/dev/null; then
  cat >> "$SSH_DIR/config" <<EOF

# für listen-update.sh (Repo $REPO)
Host $ALIAS
  HostName github.com
  User git
  IdentityFile $SCHLUESSEL
  IdentitiesOnly yes
  HostKeyAlias github.com
  StrictHostKeyChecking yes
EOF
fi
chmod 600 "$SSH_DIR/config"
touch "$SSH_DIR/known_hosts"; chmod 600 "$SSH_DIR/known_hosts"
grep -qF "$GITHUB_HOSTKEY" "$SSH_DIR/known_hosts" || echo "github.com $GITHUB_HOSTKEY" >> "$SSH_DIR/known_hosts"

schreibrecht() {  # 0 = Schlüssel darf pushen
  local out
  out=$(timeout 30 ssh -o BatchMode=yes "$ALIAS" "git-receive-pack '$REPO.git'" </dev/null 2>&1 | tr -d '\000' || true)
  if grep -q 'refs/heads/' <<<"$out"; then return 0; fi
  if grep -qi 'read only' <<<"$out"; then
    echo "   → Der Schlüssel ist eingetragen, aber ohne Schreibrecht."
    echo "     Bei GitHub den Schlüssel löschen und neu anlegen – diesmal mit Haken bei 'Allow write access'."
  elif grep -qi 'denied\|not found' <<<"$out"; then
    echo "   → GitHub kennt den Schlüssel noch nicht."
  else
    echo "   → Unerwartete Antwort: $(head -n 2 <<<"$out")"
  fi
  return 1
}

echo "== 3/5 Schlüssel bei GitHub eintragen"
if schreibrecht >/dev/null 2>&1; then
  echo "   Schon erledigt – der Schlüssel darf ins Repo schreiben."
else
  cat <<EOF

   1. Öffne:  https://github.com/$REPO/settings/keys/new
   2. Title:  listen-update $(hostname)
   3. Key:    diese EINE Zeile komplett kopieren und einfügen:

$(cat "$SCHLUESSEL.pub")

   4. Haken setzen bei  "Allow write access"
   5. Auf "Add key" klicken

   (Das ist nur der öffentliche Teil – der geheime Teil bleibt auf diesem Server.)

EOF
  for versuch in 1 2 3; do
    frage antwort "Wenn erledigt: Enter drücken"
    echo "== 4/5 Test"
    if schreibrecht; then echo "   Klappt – der Server darf ins Repo schreiben."; break; fi
    if (( versuch == 3 )); then echo "Abbruch. Später einfach dieses Skript erneut starten."; exit 1; fi
    echo "   Bitte prüfen und noch einmal Enter drücken."
  done
fi

echo "== 5/5 Konfiguration und Cron"
erg() {  # erg NAME WERT – Zeile ergänzen, wenn die Variable noch fehlt
  grep -q "^$1=" "$KONF" || printf '%s=%s\n' "$1" "$2" >> "$KONF"
}
grep -q '^# --- GitHub-Pflege' "$KONF" || printf '\n# --- GitHub-Pflege (von github-pflege.sh) ---\n' >> "$KONF"
# REPO_URL immer auf den eigenen SSH-Namen setzen (eine ältere Zeile mit
# git@github.com würde sonst den falschen Schlüssel benutzen)
sed -i '/^REPO_URL=/d' "$KONF"
erg REPO_URL "\"git@$ALIAS:$REPO.git\""
erg REPO_DIR '"/opt/pihole-listen"'
erg BRANCH '"master"'
erg GIT_NAME '"listen-update"'
erg GIT_MAIL "\"listen-update@$(hostname)\""
erg RESOLVER '"9.9.9.10"'
if ! grep -q '^AUTO_UPDATE=' "$KONF"; then
  frage antwort "AdGuard Home auf allen Servern automatisch aktualisieren, wenn eine neue Version da ist?" "j"
  if ja "$antwort"; then erg AUTO_UPDATE 1; else erg AUTO_UPDATE 0; fi
fi
chmod 600 "$KONF"

cat > "$CRON" <<EOF
# listen-update (angelegt von github-pflege.sh)
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# täglich: Listen bereinigen + nach GitHub pushen, alle Server abgleichen (+ Updates)
47 4 * * *  root  LISTEN_UPDATE_CONF=$KONF $BIN >> /var/log/listen-update.log 2>&1
# monatlich: zusätzlich tote Domains aus den Blocklisten entfernen
17 3 1 * *  root  LISTEN_UPDATE_CONF=$KONF $BIN --nur-listen --tote-pruefen >> /var/log/listen-update.log 2>&1
EOF
chmod 644 "$CRON"
echo "   $CRON umgestellt."

echo
echo "Erster Lauf (nur Listen):"
LISTEN_UPDATE_CONF="$KONF" "$BIN" --nur-listen || { echo "Fehlgeschlagen – Ausgabe oben prüfen."; exit 1; }
echo
echo "Fertig. Ab jetzt räumt der Server die Listen auf GitHub täglich selbst auf."

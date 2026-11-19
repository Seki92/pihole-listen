#!/usr/bin/env bash
# =============================================================================
# listen-update.sh
# Hält die Blocklisten im GitHub-Repo sauber und alle AdGuard-Home-Server
# (dns1 … dns6) auf demselben, aktuellen Stand.
#
# Ablauf bei jedem Lauf:
#   1. Repo holen bzw. aktualisieren (git pull)
#   2. Listen bereinigen: Kommentare, HTML-Reste, URLs, Pfade, Ports und
#      ungültige Einträge raus, Duplikate weg, sortiert speichern
#   3. Optional (--tote-pruefen): Domains entfernen, die es laut DNS nicht
#      mehr gibt (NXDOMAIN) – nur Blocklisten, nie die Whitelist
#   4. Wenn sich etwas geändert hat: commit + push nach GitHub
#   5. Auf jedem Server: fehlende Listen-Abos anlegen, abgeschaltete wieder
#      einschalten und anschließend alle Listen sofort neu laden
#   6. Wenn AUTO_UPDATE=1: AdGuard Home auf jedem Server aktualisieren, sobald
#      eine neue Version da ist – nacheinander, und erst zum nächsten Server,
#      wenn der vorige mit der neuen Version wieder läuft. Dazu gehören auch
#      die Server in NUR_UPDATE_SERVER (dort werden keine Listen angefasst).
#
# Aufruf:
#   listen-update.sh                  normaler Lauf (täglich per Cron)
#   listen-update.sh --tote-pruefen   zusätzlich tote Domains entfernen
#                                     (dauert länger, z. B. 1x im Monat)
#   listen-update.sh --nur-server     Listen nicht anfassen, nur Server abgleichen
#                                     (so läuft es per Cron auf dem Server, die
#                                     Listen pflegt die GitHub-Action im Repo)
#   listen-update.sh --nur-listen     nur Listen bereinigen/pushen, Server nicht anfassen
#                                     (so läuft es in der GitHub-Action)
#   listen-update.sh --ohne-update    AdGuard-Updates bei diesem Lauf auslassen
#   listen-update.sh --trocken        alles prüfen und anzeigen, aber nichts
#                                     pushen und an den Servern nichts ändern
#
# Konfiguration: /etc/listen-update.conf (oder Pfad in LISTEN_UPDATE_CONF)
# Benötigt:      bash, git, curl, jq, awk, sort, grep – für --tote-pruefen auch dig
#                (Debian/Ubuntu: apt install git curl jq dnsutils)
#
# Einrichtung: tools/einrichten.sh im Repo erledigt alles (Pakete, Konfiguration,
# Cron). Ohne Einrichtungsskript z. B. in /etc/cron.d/listen-update:
#   47 4 * * *  root  /usr/local/bin/listen-update.sh --nur-server >> /var/log/listen-update.log 2>&1
# =============================================================================
set -euo pipefail
export LC_ALL=C

KONFIG="${LISTEN_UPDATE_CONF:-/etc/listen-update.conf}"

# ---------- Optionen ----------------------------------------------------------
TOTE_PRUEFEN=0; TROCKEN=0; LISTEN=1; SERVER_SYNC=1; OHNE_UPDATE=0
for arg in "$@"; do
  case "$arg" in
    --tote-pruefen) TOTE_PRUEFEN=1 ;;
    --trocken)      TROCKEN=1 ;;
    --nur-server)   LISTEN=0 ;;
    --nur-listen)   SERVER_SYNC=0 ;;
    --ohne-update)  OHNE_UPDATE=1 ;;
    -h|--help)      sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $arg (siehe --help)" >&2; exit 2 ;;
  esac
done

log()    { printf '%s  %s\n' "$(date '+%F %T')" "$*"; }
warn()   { printf '%s  WARNUNG: %s\n' "$(date '+%F %T')" "$*" >&2; }
abbruch(){ printf '%s  FEHLER: %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

# ---------- Konfiguration laden -----------------------------------------------
[[ -r "$KONFIG" ]] || abbruch "Konfiguration $KONFIG nicht gefunden"
# shellcheck source=/dev/null
source "$KONFIG"

: "${BRANCH:=master}"
if (( LISTEN )); then
  : "${REPO_DIR:?REPO_DIR fehlt in $KONFIG}"
  : "${REPO_URL:?REPO_URL fehlt in $KONFIG}"
fi
if (( SERVER_SYNC )); then
  : "${RAW_BASIS:?RAW_BASIS fehlt in $KONFIG}"
fi
: "${RESOLVER:=9.9.9.10}"
: "${PARALLEL:=32}"
: "${WARTEN_NACH_PUSH:=300}"
: "${MAX_TOTE_PROZENT:=70}"
: "${AUTO_UPDATE:=0}"
: "${UPDATE_WARTEZEIT:=300}"
: "${GIT_NAME:=listen-update}"
: "${GIT_MAIL:=listen-update@localhost}"
declare -p BLOCK_DATEIEN   >/dev/null 2>&1 || abbruch "BLOCK_DATEIEN fehlt in $KONFIG"
declare -p ERLAUBT_DATEIEN >/dev/null 2>&1 || ERLAUBT_DATEIEN=()
declare -p EXTRA_BLOCKLISTEN >/dev/null 2>&1 || EXTRA_BLOCKLISTEN=()
declare -p SERVER          >/dev/null 2>&1 || SERVER=()
declare -p NUR_UPDATE_SERVER >/dev/null 2>&1 || NUR_UPDATE_SERVER=()

# ---------- Abhängigkeiten ----------------------------------------------------
benoetigt=(awk sort grep)
(( LISTEN )) && benoetigt+=(git)
(( SERVER_SYNC )) && benoetigt+=(curl jq)
(( TOTE_PRUEFEN )) && benoetigt+=(dig xargs)
for prog in "${benoetigt[@]}"; do
  command -v "$prog" >/dev/null || abbruch "'$prog' fehlt (apt install git curl jq dnsutils)"
done

# ---------- Nur ein Lauf gleichzeitig -----------------------------------------
exec 9>"${LOCKDATEI:-/tmp/listen-update.lock}"
command -v flock >/dev/null && { flock -n 9 || { log "Läuft bereits – Ende."; exit 0; }; }

ARBEIT="$(mktemp -d)"
trap 'rm -rf "$ARBEIT"' EXIT

# =============================================================================
# Listen bereinigen
# =============================================================================
# Liest eine Liste und gibt nur gültige Einträge aus. Verworfene Zeilen landen
# in der Datei, die als zweites Argument übergeben wird.
#   Modus "block":   aus https://host/pfad wird host
#   Modus "erlaubt": Einträge mit Pfad werden verworfen – das sind meist
#                    versehentlich eingefügte Listen-URLs, und den ganzen Host
#                    (z. B. raw.githubusercontent.com) freizugeben wäre falsch.
# Adblock-Regeln (||domain^, @@||domain^) bleiben unverändert erhalten,
# *.domain wird zu ||domain^ (AdGuard Home und Pi-hole ab FTL 5.22 verstehen das).
bereinige() {
  local modus="$1" verworfen="$2"
  awk -v MODUS="$modus" -v VERWORFEN="$verworfen" '
    function verwirf(z) { print z > VERWORFEN; anz_verworfen++ }
    function labels_ok(d,   n, i, p) {
      n = split(d, p, ".")
      for (i = 1; i <= n; i++) if (length(p[i]) > 63) return 0
      return 1
    }
    function domain_ok(d) {
      return length(d) <= 253 && labels_ok(d) &&
        d ~ /^([a-z0-9_]([a-z0-9_-]*[a-z0-9_])?\.)+([a-z][a-z0-9-]*[a-z0-9]|xn--[a-z0-9-]+)$/
    }
    function eintrag(e, original,   rest, wild) {
      # Adblock-Regel ohne Pfad: so übernehmen
      if (e ~ /^(@@)?\|\|[a-z0-9*._-]+\.[a-z0-9*._-]+\^(\$[a-z0-9_,=~|.-]+)?$/) { print e; return }
      sub(/^@@/, "", e); sub(/^\|\|?/, "", e)
      sub(/^[a-z][a-z0-9+.-]*:\/\//, "", e)          # http:// usw.
      rest = e; sub(/^[^\/]*/, "", rest)              # alles ab dem ersten /
      if (MODUS == "erlaubt" && rest != "" && rest != "/") { verwirf(original); return }
      sub(/[\/^$?].*$/, "", e)                          # Pfad, ^, $optionen
      sub(/:[0-9]+$/, "", e)                            # Port
      sub(/^\.+/, "", e); sub(/\.+$/, "", e)
      wild = 0
      if (e ~ /^\*\./) { e = substr(e, 3); wild = 1 }
      if (domain_ok(e)) print (wild ? "||" e "^" : e)
      else verwirf(original)
    }
    {
      z = $0
      sub(/^\357\273\277/, "", z)                       # BOM
      gsub(/\r/, "", z)
      if (z ~ /^[ \t]*[!<\[]/) { if (z !~ /^[ \t]*!/) verwirf($0); next }  # Adblock-Kommentar, HTML
      sub(/(^|[ \t])#.*$/, "", z)                       # Kommentare
      gsub(/^[ \t]+|[ \t]+$/, "", z)
      if (z == "") next
      z = tolower(z)
      n = split(z, t, /[ \t]+/)
      start = 1
      if (n >= 2 && (t[1] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || (t[1] ~ /^[0-9a-f:]+$/ && index(t[1], ":")))) start = 2  # hosts-Format
      for (i = start; i <= n; i++) eintrag(t[i], $0)
    }
  '
}

# Zählt echte Einträge (ohne Leer-/Kommentarzeilen)
zaehle() { grep -cvE '^[[:space:]]*($|#|!)' "$1" || true; }

# Entfernt NXDOMAIN-Domains aus einer bereits bereinigten Blockliste.
tote_entfernen() {
  local datei="$1" kandidaten="$ARBEIT/kandidaten" tote="$ARBEIT/tote" gesamt anzahl
  export RESOLVER
  pruefe() {  # liest Domains von stdin, gibt die mit NXDOMAIN aus
    xargs -r -P "$PARALLEL" -n 200 bash -c '
      for d in "$@"; do
        s=$(dig +tries=2 +time=2 +noall +comments @"$RESOLVER" "$d" A 2>/dev/null | grep -o "status: [A-Z]*" | head -n1)
        if [ "$s" = "status: NXDOMAIN" ]; then echo "$d"; fi
      done' _
  }
  # Test: Der Resolver muss erreichbar und ungefiltert sein
  dig +tries=2 +time=3 +short @"$RESOLVER" example.com A | grep -qE '^[0-9.]+$' \
    || { warn "Resolver $RESOLVER nicht erreichbar – Tote-Prüfung übersprungen"; return 0; }
  dig +tries=2 +time=3 +noall +comments @"$RESOLVER" doubleclick.net A | grep -q 'status: NOERROR' \
    || { warn "Resolver $RESOLVER filtert offenbar (doubleclick.net geblockt) – Tote-Prüfung übersprungen"; return 0; }

  gesamt=$(grep -cv -e '^||' -e '^@@' "$datei" || true)
  if (( gesamt == 0 )); then return 0; fi
  log "  $datei: prüfe $gesamt Domains über $RESOLVER (kann dauern) …"
  grep -v -e '^||' -e '^@@' "$datei" | pruefe | sort -u > "$kandidaten" || true
  # Zweiter Durchgang nur für die Kandidaten, damit kurze Aussetzer nichts löschen
  pruefe < "$kandidaten" | sort -u > "$tote" || true
  anzahl=$(wc -l < "$tote")
  if (( gesamt > 0 && anzahl * 100 > gesamt * MAX_TOTE_PROZENT )); then
    warn "  $datei: $anzahl von $gesamt wären tot (> ${MAX_TOTE_PROZENT} %) – sieht nach Resolver-Problem aus, nichts entfernt"
    return 0
  fi
  if (( anzahl > 0 )); then
    grep -vxFf "$tote" "$datei" > "$ARBEIT/ohne_tote" || true
    cat "$ARBEIT/ohne_tote" > "$datei"
  fi
  log "  $datei: $anzahl tote Domains entfernt"
}

listen_aktualisieren() {
  if [[ -d "$REPO_DIR/.git" ]]; then
    git -C "$REPO_DIR" fetch -q origin "$BRANCH"
    git -C "$REPO_DIR" checkout -q "$BRANCH"
    git -C "$REPO_DIR" merge -q --ff-only "origin/$BRANCH" \
      || abbruch "Lokales Repo weicht von GitHub ab – bitte $REPO_DIR prüfen"
  else
    log "Klone $REPO_URL nach $REPO_DIR"
    git clone -q --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
  fi
  cd "$REPO_DIR"

  local datei modus vorher eindeutig nachher verworfen e
  for datei in "${BLOCK_DATEIEN[@]}" "${ERLAUBT_DATEIEN[@]}"; do
    [[ -f "$datei" ]] || { warn "$datei fehlt im Repo – übersprungen"; continue; }
    modus=block
    for e in "${ERLAUBT_DATEIEN[@]}"; do
      if [[ "$e" == "$datei" ]]; then modus=erlaubt; fi
    done
    verworfen="$ARBEIT/verworfen_$datei"; : > "$verworfen"
    vorher=$(zaehle "$datei")
    eindeutig=$( { grep -vE '^[[:space:]]*($|#|!)' "$datei" || true; } | tr -d '\r' | sed 's/[[:space:]]*$//' | sort -u | wc -l)
    bereinige "$modus" "$verworfen" < "$datei" | sort -u > "$ARBEIT/neu"
    nachher=$(wc -l < "$ARBEIT/neu")
    # Schutz vor Fehlern: nie mehr als die Hälfte der eindeutigen Einträge wegwerfen
    if (( eindeutig > 100 && nachher * 2 < eindeutig )); then
      warn "$datei: nach Bereinigung nur noch $nachher von $eindeutig eindeutigen Einträgen – nichts geändert, bitte prüfen"
      continue
    fi
    cat "$ARBEIT/neu" > "$datei"
    log "$datei: $vorher Zeilen → $nachher Einträge ($(wc -l < "$verworfen") ungültige Zeilen verworfen)"
    if [[ "$modus" == block ]] && (( TOTE_PRUEFEN )); then tote_entfernen "$datei"; fi
  done

  # Hinweis, falls Werbe-Server freigegeben sind (wird nur gemeldet, nicht geändert)
  local f verdacht
  for f in "${ERLAUBT_DATEIEN[@]}"; do
    [[ -f "$f" ]] || continue
    verdacht=$(grep -E '(^|[.|-])(ads?|adserver|adservices?|adsystem|adnxs|doubleclick|googlesyndication|flashtalking|smartadserver|openx|criteo|taboola|outbrain)[.^-]' "$f" | head -n 20 | tr '\n' ' ' || true)
    if [[ -n "$verdacht" ]]; then
      warn "$f gibt Werbe-Server frei (Freigaben schlagen jede Blockliste): $verdacht"
    fi
  done

  git add -- "${BLOCK_DATEIEN[@]}" "${ERLAUBT_DATEIEN[@]}" 2>/dev/null || true
  if git diff --cached --quiet; then
    log "Listen unverändert – nichts zu pushen."
    return 0
  fi
  if (( TROCKEN )); then
    log "[trocken] Änderungen:"; git diff --cached --stat | tail -n 5
    git reset -q --hard "origin/$BRANCH"
    return 0
  fi
  git -c user.name="$GIT_NAME" -c user.email="$GIT_MAIL" \
    commit -q -m "Listen automatisch bereinigt ($(date +%F))"
  if ! git push -q origin "$BRANCH"; then
    log "Push abgelehnt – hole neue Änderungen und versuche es erneut"
    git -c user.name="$GIT_NAME" -c user.email="$GIT_MAIL" pull -q --rebase origin "$BRANCH" \
      || { git rebase --abort 2>/dev/null || true; abbruch "Konflikt beim Zusammenführen – bitte von Hand lösen"; }
    git push -q origin "$BRANCH" || abbruch "Push nach GitHub fehlgeschlagen"
  fi
  log "Änderungen nach GitHub gepusht."
  GEPUSHT=1
}

# =============================================================================
# AdGuard-Home-Server abgleichen
# =============================================================================
# agh METHODE PFAD [JSON] – Anfrage an die AdGuard-Home-API des aktuellen Servers.
# Zugangsdaten gehen per Konfiguration über stdin an curl, damit das Passwort
# nicht in der Prozessliste auftaucht.
agh() {
  local methode="$1" pfad="$2" daten="${3:-}" cred
  cred="$AGH_USER:$AGH_PASS"; cred="${cred//\\/\\\\}"; cred="${cred//\"/\\\"}"
  local args=(-fsS --max-time 180 -K - -X "$methode")
  [[ -n "$daten" ]] && args+=(-H 'Content-Type: application/json' --data "$daten")
  printf 'user = "%s"\n' "$cred" | curl "${args[@]}" "$AGH_URL/control/$pfad"
}

# Sorgt dafür, dass eine Liste abonniert und eingeschaltet ist.
#   abo_sicherstellen <status-json> <name> <url> <whitelist:true|false> [repo-dateiname]
abo_sicherstellen() {
  local status="$1" name="$2" url="$3" wl="$4" datei="${5:-}" feld zustand vorhandene_url
  if [[ "$wl" == true ]]; then feld=whitelist_filters; else feld=filters; fi
  # Repo-Listen auch erkennen, wenn sie mit anderer Raw-URL-Schreibweise abonniert sind
  local treffer
  treffer=$(jq -r --arg u "$url" --arg d "$datei" --arg f "$feld" '
    [ (.[$f] // [])[]
      | select(.url == $u or ($d != "" and (.url | ascii_downcase | contains("seki92/pihole-listen"))
                                       and (.url | endswith("/" + $d)))) ]
    | if length == 0 then "fehlt -" else "\(.[0].enabled) \(.[0].url)" end' <<<"$status") || return 1
  zustand="${treffer%% *}"; vorhandene_url="${treffer#* }"

  case "$zustand" in
    true)  return 0 ;;
    false)
      log "    schalte ein: $name"
      (( TROCKEN )) && return 0
      agh POST filtering/set_url "$(jq -cn --arg n "$name" --arg u "$vorhandene_url" --argjson w "$wl" \
        '{url:$u, whitelist:$w, data:{name:$n, url:$u, enabled:true}}')" >/dev/null ;;
    *)
      log "    abonniere: $name"
      (( TROCKEN )) && return 0
      agh POST filtering/add_url "$(jq -cn --arg n "$name" --arg u "$url" --argjson w "$wl" \
        '{name:$n, url:$u, whitelist:$w}')" >/dev/null ;;
  esac
}

SERVER_FEHLER=0
server_abgleichen() {
  local eintrag eintrag2 status ok=0 datei name url abo_fehler soll n1 n2
  soll=$(printf '%s\n' "${EXTRA_BLOCKLISTEN[@]}" | cut -d'|' -f2 | jq -R . | jq -cs .)
  for eintrag in "${SERVER[@]}"; do
    IFS='|' read -r AGH_URL AGH_USER AGH_PASS <<<"$eintrag"
    AGH_URL="${AGH_URL%/}"
    log "Server $AGH_URL"
    if ! status=$(agh GET filtering/status) || ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$status"; then
      warn "  $AGH_URL nicht erreichbar oder Anmeldung falsch – übersprungen"
      SERVER_FEHLER=$((SERVER_FEHLER + 1)); continue
    fi
    if [[ "$(jq -r '.enabled' <<<"$status")" != true ]]; then
      warn "  Filterung ist auf $AGH_URL ausgeschaltet!"
    fi

    abo_fehler=0
    for datei in "${BLOCK_DATEIEN[@]}"; do
      abo_sicherstellen "$status" "Seki92 $datei" "$RAW_BASIS/$datei" false "$datei" || abo_fehler=1
    done
    for eintrag2 in "${EXTRA_BLOCKLISTEN[@]}"; do
      IFS='|' read -r name url <<<"$eintrag2"
      abo_sicherstellen "$status" "$name" "$url" false || abo_fehler=1
    done
    for datei in "${ERLAUBT_DATEIEN[@]}"; do
      abo_sicherstellen "$status" "Seki92 $datei" "$RAW_BASIS/$datei" true "$datei" || abo_fehler=1
    done
    if (( abo_fehler )); then
      warn "  Nicht alle Listen-Abos auf $AGH_URL konnten angepasst werden"
      SERVER_FEHLER=$((SERVER_FEHLER + 1))
    fi

    # Listen, die nicht in der Konfiguration stehen, nur melden – nie löschen
    jq -r --argjson soll "$soll" '
      (.filters // [])[] | select(.enabled)
      | select((.url | ascii_downcase | contains("seki92/pihole-listen")) | not)
      | select(.url as $u | ($soll | any(.[]; . == $u)) | not)
      | "  zusätzlich aktiv (bleibt): \(.name)"' <<<"$status" | while IFS= read -r z; do log "$z"; done || true

    if (( TROCKEN )); then
      log "  [trocken] würde jetzt Block- und Erlaubt-Listen neu laden"
    else
      n1=$(agh POST filtering/refresh '{"whitelist":false}' | jq -r '.updated // 0') || n1="?"
      n2=$(agh POST filtering/refresh '{"whitelist":true}'  | jq -r '.updated // 0') || n2="?"
      log "  neu geladen: $n1 Blocklisten, $n2 Erlaubt-Listen"
      if [[ "$n1" == "?" || "$n2" == "?" ]]; then SERVER_FEHLER=$((SERVER_FEHLER + 1)); fi
    fi
    ok=$((ok + 1))
  done
  log "Server fertig: $ok von ${#SERVER[@]} abgeglichen, $SERVER_FEHLER Fehler"
}

# =============================================================================
# AdGuard Home aktualisieren
# =============================================================================
# Nutzt die eingebaute Update-Funktion von AdGuard Home (wie der Button in der
# Oberfläche). Die Server werden nacheinander aktualisiert; kommt einer nach dem
# Update nicht mit der neuen Version zurück, bleiben alle weiteren unangetastet.
adguard_updates() {
  local eintrag status info aktuell neu kann aus version t zurueck
  log "Prüfe AdGuard-Home-Updates"
  for eintrag in "${SERVER[@]}" "${NUR_UPDATE_SERVER[@]}"; do
    IFS='|' read -r AGH_URL AGH_USER AGH_PASS <<<"$eintrag"
    AGH_URL="${AGH_URL%/}"
    if ! status=$(agh GET status 2>/dev/null) || ! aktuell=$(jq -er '.version' <<<"$status" 2>/dev/null); then
      warn "  $AGH_URL: Version nicht abrufbar – übersprungen"; continue
    fi
    if ! info=$(agh POST version.json '{"recheck_now":true}' 2>/dev/null) || ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$info"; then
      warn "  $AGH_URL: Update-Prüfung fehlgeschlagen (AdGuard-Update-Server nicht erreichbar?)"; continue
    fi
    neu=$(jq -r '.new_version // ""' <<<"$info")
    kann=$(jq -r '.can_autoupdate // false' <<<"$info")
    aus=$(jq -r '.disabled // false' <<<"$info")
    if [[ "$aus" == true ]]; then
      log "  $AGH_URL: $aktuell (Update-Prüfung ist in AdGuard abgeschaltet)"; continue
    fi
    if [[ -z "$neu" || "$neu" == "$aktuell" ]]; then
      log "  $AGH_URL: $aktuell ist aktuell"; continue
    fi
    if [[ "$kann" != true ]]; then
      warn "  $AGH_URL: $neu verfügbar, kann aber nicht automatisch installiert werden (Docker/Snap/Paketverwaltung?)"; continue
    fi
    if (( TROCKEN )); then
      log "  [trocken] $AGH_URL: würde $aktuell → $neu aktualisieren"; continue
    fi
    log "  $AGH_URL: aktualisiere $aktuell → $neu"
    if ! agh POST update '{}' >/dev/null 2>&1; then
      warn "  $AGH_URL: Update ließ sich nicht starten – weitere Updates gestoppt"
      SERVER_FEHLER=$((SERVER_FEHLER + 1)); return
    fi
    zurueck=0
    for (( t = 0; t < UPDATE_WARTEZEIT; t += 5 )); do
      sleep 5
      version=$(agh GET status 2>/dev/null | jq -r '.version // ""' 2>/dev/null) || version=""
      if [[ "$version" == "$neu" ]]; then zurueck=1; break; fi
    done
    if (( ! zurueck )); then
      warn "  $AGH_URL: nach ${UPDATE_WARTEZEIT}s nicht mit $neu zurück – weitere Updates gestoppt, bitte prüfen!"
      SERVER_FEHLER=$((SERVER_FEHLER + 1)); return
    fi
    log "  $AGH_URL: läuft jetzt mit $neu"
  done
}

# =============================================================================
# Hauptteil
# =============================================================================
log "=== listen-update startet$( (( TROCKEN )) && echo ' (trocken)') ==="
GEPUSHT=0
if (( LISTEN )); then
  listen_aktualisieren
fi
if (( SERVER_SYNC )); then
  (( ${#SERVER[@]} )) || abbruch "Keine SERVER in $KONFIG eingetragen"
  if (( GEPUSHT && WARTEN_NACH_PUSH > 0 )); then
    # raw.githubusercontent.com liefert bis zu ~5 Minuten die alte Version aus
    log "Warte ${WARTEN_NACH_PUSH}s, bis GitHub die neuen Listen ausliefert …"
    sleep "$WARTEN_NACH_PUSH"
  fi
  server_abgleichen
  if (( AUTO_UPDATE && ! OHNE_UPDATE )); then adguard_updates; fi
  if (( SERVER_FEHLER )); then log "=== Ende mit Fehlern ==="; exit 1; fi
fi
log "=== fertig ==="

# VPS Installer — Piano di implementazione

> **Per agenti esecutori:** SOTTO-SKILL RICHIESTA: usare superpowers:subagent-driven-development (consigliato) oppure superpowers:executing-plans per eseguire questo piano task per task. Gli step usano checkbox (`- [ ]`) per il tracciamento.

**Goal:** un comando unico che porta una VPS OVH Debian 13 appena installata a uno stato sicuro, con stack web opzionale e dominio del pannello pronto, lasciando sulla macchina solo i file documentati in `PANEL-HANDOFF.md`.

**Architecture:** repository bash modulare. `install.sh` (bootstrap verificato con hash) estrae la release in `/root/vps-installer`, riparte dentro `tmux` e lancia `run.sh`. `run.sh` esegue `wizard.sh` (whiptail, tutte le domande all'inizio, risposte in `answers.env`) e poi gli step `steps/NN-*.sh` in ordine, segnando quelli completati in `state` per la ripresa. Le funzioni riusabili stanno in `lib/` (testate con bats) e vengono copiate in `/opt/vps/lib` per gli script wrapper `tools/vps-*` usati in seguito dal pannello.

**Tech Stack:** bash 5.2, whiptail, envsubst (gettext-base), jq, curl, gpg, ufw, fail2ban, nginx (nginx.org), PHP 8.4 (sury), MariaDB 11.8 (Debian), Redis, certbot + plugin dns-cloudflare (Debian), msmtp, phpMyAdmin (upstream verificato), bats-core, shellcheck, GitHub Actions.

**Spec:** [`docs/specs/2026-10-07-vps-installer-design.md`](../specs/2026-10-07-vps-installer-design.md) + contratto [`docs/PANEL-HANDOFF.md`](../PANEL-HANDOFF.md). Leggere entrambi prima di iniziare.

## Global Constraints

- Target: **Debian 13 (trixie)** soltanto; `VERSION_CODENAME` deve essere `trixie`.
- Tutti gli script: `#!/usr/bin/env bash`, `set -Eeuo pipefail` + `trap ERR` (via `enable_error_trap`), fine riga **LF**.
- Messaggi all'utente e commenti in **italiano**; nomi di funzioni/variabili in inglese, `snake_case` per funzioni, `UPPER_SNAKE` per variabili globali/risposte.
- **Segreti mai in argv, mai nel log, mai stampati** (eccezione: riepilogo finale su `/dev/tty`). Passano via file 600, stdin o variabili d'ambiente.
- Ogni file scritto in `/etc` o `/opt/vps` passa da `write_file` (atomico) o `install -m`.
- Ogni step è **idempotente** (rilanciabile senza danni).
- Percorsi fissi: installer `/root/vps-installer`, log `/var/log/vps-installer.log`, strumenti `/opt/vps/{bin,lib,templates,secrets}`, manifest `/opt/vps/manifest.json`, pannello `/var/www/<dominio-pannello>`.
- `PHP_VERSION="8.4"`, `VPS_INSTALLER_VERSION="1.0.0"` (in `lib/common.sh`; il tag di release deve essere `v1.0.0`).
- Prefisso DB/utenti dei siti: `site_`. Utenti riservati: `root debian panel www-data nginx mysql redis daemon bin sys nobody` e `site_*`.
- Repo esterni consentiti: `nginx.org`, `packages.sury.org`. Tutto il resto da Debian, tranne phpMyAdmin (upstream con GPG + SHA256).
- Fingerprint delle chiavi fissati nel codice (verificarli alla fonte durante l'implementazione, vedi Task 6/16/17/10).

## Review Focus

1. **Connessione SSH che cade a metà installazione** → l'installazione continua in `tmux` e, se un comando fallisce, il rilancio riparte dallo step non completato senza rifare la procedura guidata. Test: Task 11 (ripresa dopo errore), Task 12 (rilancio dentro tmux).
2. **Chiave SSH incollata male** (CRLF di Windows, spazi finali, due righe, chiave privata, RSA corta) → la procedura guidata deve rifiutarla con un messaggio chiaro, non creare un utente senza accesso. Test: Task 3.
3. **Password con caratteri speciali** (`$ ' " \` spazi) per utente, SMTP, DB → devono sopravvivere a salvataggio/ricaricamento delle risposte, al file msmtp e all'SQL. Test: Task 2, Task 8, Task 9.
4. **Dominio del pannello che non punta ancora alla VPS** (senza Cloudflare) → lo step SSL si ferma con istruzioni precise e la ripresa funziona dopo aver sistemato il DNS. Test: Task 5, Task 10.
5. **Rilancio su macchina già installata** → niente regole UFW duplicate o obsolete, password DB riusate, utenti/DB creati con `IF NOT EXISTS`. Test: Task 7 (regole UFW obsolete), Task 8 (SQL idempotente), Task 2 (`env_get`).

---

## Ambiente di test

Il PC di sviluppo è Windows con WSL (`Debian`, `Ubuntu`), senza Docker. I test girano in WSL con `tests/run.sh`, che copia il repository nel filesystem Linux (su `/mnt/c` i permessi dei file non funzionano). Una tantum, l'utente deve installare gli strumenti (serve la sua password sudo di WSL):

```
! wsl -d Debian -- sudo apt-get install -y bats shellcheck jq gettext-base openssh-client gpg curl openssl rsync
```

Comando di test usato in tutto il piano (dalla cartella del repository, in PowerShell o Git Bash):

```
wsl -d Debian -- bash tests/run.sh
```

Per un singolo file: `wsl -d Debian -- bash tests/run.sh tests/validate.bats`.

---

### Task 1: Scheletro del repository e infrastruttura di test

**Files:**
- Create: `.gitattributes`, `.shellcheckrc`, `.gitignore`, `tests/test_helper.bash`, `tests/run.sh`, `tests/smoke.bats`, `.github/workflows/ci.yml`

**Interfaces:**
- Produces: `setup_common` (bats helper: imposta `REPO_ROOT`, `VPS_ROOT`, `VPS_LOG`, `VPS_OPT`, `VPS_STATE`, `VPS_ANSWERS`, `VPS_TEMPLATES`, `VPS_NO_CHOWN=1`, carica `lib/*.sh`), `make_stub NOME CORPO` (crea un eseguibile finto in `$BATS_TEST_TMPDIR/bin`, messo in testa a `PATH`), `tests/run.sh [file.bats...]`.

- [ ] **Step 1: File di configurazione del repository**

`.gitattributes`:
```
* text=auto eol=lf
*.png binary
/tests export-ignore
/docs export-ignore
/.github export-ignore
/.gitattributes export-ignore
/.gitignore export-ignore
/.shellcheckrc export-ignore
```

`.shellcheckrc`:
```
external-sources=true
# Le librerie sono caricate con un ciclo (SC1090/SC1091) e le risposte
# della procedura guidata arrivano da answers.env (SC2154). I filtri jq e i
# template nginx usano $ tra apici singoli di proposito (SC2016).
disable=SC1090,SC1091,SC2154,SC2016
```

`.gitignore`:
```
*.log
/dist/
```

- [ ] **Step 2: Helper dei test**

`tests/test_helper.bash`:
```bash
# shellcheck shell=bash
# Helper comuni per i test bats.

setup_common() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO_ROOT
  export VPS_ROOT="$BATS_TEST_TMPDIR/root"
  export VPS_LOG="$BATS_TEST_TMPDIR/test.log"
  export VPS_OPT="$BATS_TEST_TMPDIR/opt"
  export VPS_STATE="$VPS_ROOT/state"
  export VPS_ANSWERS="$VPS_ROOT/answers.env"
  export VPS_TEMPLATES="$REPO_ROOT/templates"
  export VPS_NO_CHOWN=1
  mkdir -p "$VPS_ROOT" "$VPS_OPT"
  local f
  shopt -s nullglob
  for f in "$REPO_ROOT"/lib/*.sh; do
    source "$f"
  done
  shopt -u nullglob
}

# make_stub NOME CORPO: crea un comando finto che sostituisce quello vero.
make_stub() {
  local dir="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$dir/$1"
  chmod +x "$dir/$1"
  case ":$PATH:" in
    *":$dir:"*) ;;
    *) PATH="$dir:$PATH" ;;
  esac
  export PATH
}
```

- [ ] **Step 3: Runner dei test**

`tests/run.sh`:
```bash
#!/usr/bin/env bash
# Esegue shellcheck e bats. Da Windows: wsl -d Debian -- bash tests/run.sh
set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for tool in bats shellcheck jq envsubst ssh-keygen gpg; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Manca '$tool'. Installa: sudo apt-get install -y bats shellcheck jq gettext-base openssh-client gpg curl openssl rsync" >&2
    exit 2
  }
done

# Su /mnt/* (disco Windows) i permessi dei file non funzionano: copia in /tmp.
work="$src"
if [[ "$src" == /mnt/* ]]; then
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  rsync -a --exclude .git "$src"/ "$work"/
fi
cd "$work"

mapfile -t files < <(find . -path ./.git -prune -o -type f \( -name '*.sh' -o -path './tools/vps-*' \) -print | sort)
if ((${#files[@]})); then
  shellcheck -x "${files[@]}"
fi

if (($#)); then
  bats "$@"
else
  bats tests
fi
```

- [ ] **Step 4: Test di fumo**

`tests/smoke.bats`:
```bash
setup() {
  load test_helper
  setup_common
}

@test "l'ambiente di test è pronto" {
  [ -d "$VPS_ROOT" ]
  [ "$VPS_NO_CHOWN" = "1" ]
}

@test "make_stub sostituisce un comando" {
  make_stub hostname 'echo finto'
  run hostname
  [ "$output" = "finto" ]
}
```

- [ ] **Step 5: CI**

`.github/workflows/ci.yml`:
```yaml
name: ci
on:
  push:
  pull_request:
jobs:
  test:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - run: sudo apt-get update -qq && sudo apt-get install -y -qq bats shellcheck jq gettext-base openssh-client gpg rsync
      - run: bash tests/run.sh
```

- [ ] **Step 6: Strumenti in WSL**

Chiedere all'utente di eseguire (serve la sua password sudo WSL):
```
! wsl -d Debian -- sudo apt-get install -y bats shellcheck jq gettext-base openssh-client gpg curl openssl rsync
```

- [ ] **Step 7: Eseguire i test**

Run: `wsl -d Debian -- bash tests/run.sh`
Expected: `2 tests, 0 failures`

- [ ] **Step 8: Normalizzare i fine riga e fare commit**

```bash
git add --renormalize .
git add .gitattributes .shellcheckrc .gitignore tests .github
git update-index --chmod=+x tests/run.sh
git commit -m "chore: repository skeleton, test runner and CI"
```

---

### Task 2: `lib/common.sh` e `lib/answers.sh`

**Files:**
- Create: `lib/common.sh`, `lib/answers.sh`
- Test: `tests/common.bats`, `tests/answers.bats`

**Interfaces:**
- Produces (`common.sh`): variabili `VPS_ROOT VPS_LOG VPS_STATE VPS_ANSWERS VPS_OPT VPS_TEMPLATES NGINX_SNIPPETS VPS_INSTALLER_VERSION PHP_VERSION`; funzioni `log MSG`, `die MSG` (exit 1), `on_error`, `enable_error_trap`, `state_done NOME` (0/1), `state_mark NOME`, `apt_install PKG...`, `rand_secret [N=32]` (alfanumerico), `write_file PATH MODE OWNER:GROUP` (stdin, atomico), `own OWNER:GROUP PATH...` (chown saltato se `VPS_NO_CHOWN=1`), `is_yes VAL`, `trim STR`, `env_get FILE KEY`, `in_list NEEDLE ITEM...`.
- Produces (`answers.sh`): array `ANSWER_VARS`; `answers_save [FILE]`, `answers_load [FILE]` (carica, esporta, chiama `answers_derive`), `answers_derive` (esporta `PANEL_ROOT`, `SSH_ALLOW_USERS`).

- [ ] **Step 1: Test che falliscono**

`tests/common.bats`:
```bash
setup() {
  load test_helper
  setup_common
}

@test "write_file scrive in modo atomico con i permessi richiesti" {
  printf 'segreto\n' | write_file "$BATS_TEST_TMPDIR/f" 600 "$(id -un):$(id -gn)"
  [ "$(cat "$BATS_TEST_TMPDIR/f")" = "segreto" ]
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/f")" = "600" ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -name '.tmp.*')" ]
}

@test "rand_secret genera stringhe alfanumeriche della lunghezza richiesta" {
  run rand_secret 20
  [ "${#output}" -eq 20 ]
  [[ "$output" =~ ^[A-Za-z0-9]+$ ]]
  run rand_secret
  [ "${#output}" -eq 32 ]
}

@test "state_mark e state_done tracciano gli step" {
  run state_done 10-system
  [ "$status" -ne 0 ]
  state_mark 10-system
  state_done 10-system
  run state_done 10-sys
  [ "$status" -ne 0 ]
}

@test "state_mark non fallisce se la cartella è stata cancellata" {
  rm -rf "$VPS_ROOT"
  run state_mark 99-finalize
  [ "$status" -eq 0 ]
}

@test "trim toglie CR e spazi ai lati" {
  run trim $'  ssh-ed25519 AAAA nome \r\n'
  [ "$output" = "ssh-ed25519 AAAA nome" ]
}

@test "env_get legge una chiave e restituisce vuoto se manca" {
  printf 'DB_PASS=abc123\nDB_USER=panel\n' >"$BATS_TEST_TMPDIR/.env"
  run env_get "$BATS_TEST_TMPDIR/.env" DB_PASS
  [ "$output" = "abc123" ]
  run env_get "$BATS_TEST_TMPDIR/.env" NOPE
  [ "$output" = "" ]
  run env_get "$BATS_TEST_TMPDIR/manca.env" DB_PASS
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "is_yes e in_list" {
  is_yes yes
  run is_yes no
  [ "$status" -ne 0 ]
  in_list b a b c
  run in_list z a b c
  [ "$status" -ne 0 ]
}

@test "die scrive nel log ed esce con 1" {
  run die "qualcosa"
  [ "$status" -eq 1 ]
  grep -q "ERRORE: qualcosa" "$VPS_LOG"
}
```

`tests/answers.bats`:
```bash
setup() {
  load test_helper
  setup_common
}

@test "le risposte sopravvivono a caratteri speciali" {
  ADMIN_USER=manu
  ADMIN_PASS=$'p@ss $word \'quote\' "dq" \\back'
  SMTP_PASS='a$b`c'
  ADMIN_PUBKEY='ssh-ed25519 AAAAC3Nza manu@pc'
  answers_save
  [ "$(stat -c %a "$VPS_ANSWERS")" = "600" ]
  local expected_pass="$ADMIN_PASS" expected_smtp="$SMTP_PASS"
  unset ADMIN_USER ADMIN_PASS SMTP_PASS ADMIN_PUBKEY
  answers_load
  [ "$ADMIN_PASS" = "$expected_pass" ]
  [ "$SMTP_PASS" = "$expected_smtp" ]
  [ "$ADMIN_PUBKEY" = "ssh-ed25519 AAAAC3Nza manu@pc" ]
}

@test "answers_load esporta e calcola le variabili derivate" {
  ADMIN_USER=manu ROOT_LOGIN=no PANEL_DOMAIN=panel.miosito.it
  answers_save
  unset ADMIN_USER ROOT_LOGIN PANEL_DOMAIN
  answers_load
  [ "$PANEL_ROOT" = "/var/www/panel.miosito.it" ]
  [ "$SSH_ALLOW_USERS" = "manu" ]
  run bash -c 'echo "$ADMIN_USER"'
  [ "$output" = "manu" ]
}

@test "con root prohibit-password anche root è in AllowUsers" {
  ADMIN_USER=manu ROOT_LOGIN=prohibit-password
  answers_derive
  [ "$SSH_ALLOW_USERS" = "manu root" ]
}

@test "answers_load fallisce se il file manca" {
  run answers_load "$BATS_TEST_TMPDIR/nessuno.env"
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Verificare che falliscano**

Run: `wsl -d Debian -- bash tests/run.sh tests/common.bats tests/answers.bats`
Expected: FAIL (`write_file: command not found` e simili)

- [ ] **Step 3: Implementazione**

`lib/common.sh`:
```bash
# shellcheck shell=bash
# Funzioni comuni a installer e script wrapper.

: "${VPS_ROOT:=/root/vps-installer}"
: "${VPS_LOG:=/var/log/vps-installer.log}"
: "${VPS_STATE:=$VPS_ROOT/state}"
: "${VPS_ANSWERS:=$VPS_ROOT/answers.env}"
: "${VPS_OPT:=/opt/vps}"
: "${VPS_TEMPLATES:=$VPS_ROOT/templates}"
: "${NGINX_SNIPPETS:=/etc/nginx/snippets}"
VPS_INSTALLER_VERSION="1.0.0"
PHP_VERSION="8.4"

log() {
  local line
  line="[$(date '+%F %T')] $*"
  printf '%s\n' "$line" >&2
  printf '%s\n' "$line" >>"$VPS_LOG" 2>/dev/null || true
}

die() {
  log "ERRORE: $*"
  exit 1
}

on_error() {
  local rc=$?
  log "ERRORE (exit $rc) in ${BASH_SOURCE[1]:-?}:${BASH_LINENO[0]:-?}: ${BASH_COMMAND}"
  exit "$rc"
}

enable_error_trap() {
  set -Eeuo pipefail
  trap on_error ERR
}

state_done() {
  [[ -f "$VPS_STATE" ]] && grep -qxF -- "$1" "$VPS_STATE"
}

state_mark() {
  if [[ -d "$(dirname "$VPS_STATE")" ]]; then
    printf '%s\n' "$1" >>"$VPS_STATE"
  fi
}

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    "$@" >>"$VPS_LOG" 2>&1
}

rand_secret() {
  local n="${1:-32}" out=""
  while ((${#out} < n)); do
    out+="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')"
  done
  printf '%s' "${out:0:n}"
}

own() {
  if [[ "${VPS_NO_CHOWN:-}" != 1 ]]; then
    chown "$@"
  fi
}

# write_file PATH MODE OWNER:GROUP — contenuto da stdin, sostituzione atomica.
write_file() {
  local path="$1" mode="$2" owner="$3" tmp
  tmp="$(mktemp "$(dirname "$path")/.tmp.XXXXXX")"
  cat >"$tmp"
  chmod "$mode" "$tmp"
  own "$owner" "$tmp"
  mv -f "$tmp" "$path"
}

is_yes() {
  [[ "${1:-}" == "yes" ]]
}

trim() {
  local s="${1//$'\r'/}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# env_get FILE KEY — valore di KEY=... in un file .env (vuoto se assente).
env_get() {
  [[ -f "$1" ]] || return 0
  awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$1"
}

in_list() {
  local needle="$1" item
  shift
  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}
```

`lib/answers.sh`:
```bash
# shellcheck shell=bash
# Risposte della procedura guidata: salvataggio, caricamento, variabili derivate.

ANSWER_VARS=(
  HOSTNAME_NEW TIMEZONE LOCALE
  ADMIN_USER ADMIN_PASS ADMIN_PUBKEY
  SSH_PORT ROOT_LOGIN
  WANT_NGINX WANT_PHP WANT_MARIADB WANT_REDIS WANT_CERTBOT WANT_PMA
  PANEL_ENABLED PANEL_DOMAIN
  CF_ENABLED CF_API_TOKEN CF_ZONE CF_ZONE_ID CF_LOCK_ORIGIN
  MAIL_ENABLED SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASS SMTP_FROM ALERT_EMAIL
)

answers_save() {
  local file="${1:-$VPS_ANSWERS}" v
  for v in "${ANSWER_VARS[@]}"; do
    printf '%s=%q\n' "$v" "${!v:-}"
  done | write_file "$file" 600 "$(id -un):$(id -gn)"
}

answers_load() {
  local file="${1:-$VPS_ANSWERS}" v
  [[ -f "$file" ]] || die "File delle risposte non trovato: $file"
  source "$file"
  for v in "${ANSWER_VARS[@]}"; do
    export "${v?}"
  done
  answers_derive
}

answers_derive() {
  PANEL_ROOT="/var/www/${PANEL_DOMAIN:-_}"
  if [[ "${ROOT_LOGIN:-no}" == "prohibit-password" ]]; then
    SSH_ALLOW_USERS="${ADMIN_USER:-} root"
  else
    SSH_ALLOW_USERS="${ADMIN_USER:-}"
  fi
  export PANEL_ROOT SSH_ALLOW_USERS
}
```

- [ ] **Step 4: Verificare che passino**

Run: `wsl -d Debian -- bash tests/run.sh tests/common.bats tests/answers.bats`
Expected: tutti PASS, shellcheck senza errori.

- [ ] **Step 5: Commit**

```bash
git add lib/common.sh lib/answers.sh tests/common.bats tests/answers.bats
git commit -m "feat(lib): common helpers and wizard answers persistence"
```

---

### Task 3: `lib/validate.sh`

**Files:**
- Create: `lib/validate.sh`
- Test: `tests/validate.bats`

**Interfaces:**
- Consumes: `in_list` (Task 2).
- Produces: `RESERVED_USERS` (array); validatori che restituiscono 0/1 senza output: `valid_domain`, `valid_hostname`, `valid_username`, `valid_port`, `valid_smtp_port`, `valid_password` (≥12 caratteri, una riga), `valid_line` (non vuota, una riga), `valid_email`, `valid_timezone` (usa `ZONEINFO_DIR`, default `/usr/share/zoneinfo`), `valid_locale`, `valid_cf_token`, `valid_ssh_pubkey`.

- [ ] **Step 1: Test che falliscono**

`tests/validate.bats`:
```bash
setup() {
  load test_helper
  setup_common
}

@test "domini" {
  valid_domain panel.miosito.it
  valid_domain miosito.it
  valid_domain a-b.c-d.example.com
  run valid_domain Panel.Miosito.it; [ "$status" -ne 0 ]
  run valid_domain miosito; [ "$status" -ne 0 ]
  run valid_domain -bad.it; [ "$status" -ne 0 ]
  run valid_domain "bad domain.it"; [ "$status" -ne 0 ]
  run valid_domain ""; [ "$status" -ne 0 ]
}

@test "hostname" {
  valid_hostname vps-01
  run valid_hostname vps.01; [ "$status" -ne 0 ]
  run valid_hostname -vps; [ "$status" -ne 0 ]
}

@test "username: formato e nomi riservati" {
  valid_username manu
  valid_username dev_ops-1
  run valid_username root; [ "$status" -ne 0 ]
  run valid_username debian; [ "$status" -ne 0 ]
  run valid_username panel; [ "$status" -ne 0 ]
  run valid_username site_foo; [ "$status" -ne 0 ]
  run valid_username 1manu; [ "$status" -ne 0 ]
  run valid_username Manu; [ "$status" -ne 0 ]
}

@test "porta SSH" {
  valid_port 22
  valid_port 2222
  valid_port 41822
  run valid_port 80; [ "$status" -ne 0 ]
  run valid_port 666; [ "$status" -ne 0 ]
  run valid_port 3306; [ "$status" -ne 0 ]
  run valid_port 65536; [ "$status" -ne 0 ]
  run valid_port 0022; [ "$status" -ne 0 ]
  run valid_port abc; [ "$status" -ne 0 ]
}

@test "porta SMTP" {
  valid_smtp_port 587
  valid_smtp_port 465
  run valid_smtp_port 26; [ "$status" -ne 0 ]
}

@test "password e righe" {
  valid_password 'Lunga-abbastanza!'
  run valid_password 'corta'; [ "$status" -ne 0 ]
  run valid_password $'abcdefghijkl\nmn'; [ "$status" -ne 0 ]
  valid_line 'utente@gmail.com'
  run valid_line ''; [ "$status" -ne 0 ]
  run valid_line $'a\rb'; [ "$status" -ne 0 ]
}

@test "email" {
  valid_email mario@example.com
  run valid_email mario; [ "$status" -ne 0 ]
  run valid_email 'a b@c.it'; [ "$status" -ne 0 ]
}

@test "fuso orario e locale" {
  mkdir -p "$BATS_TEST_TMPDIR/zi/Europe"
  touch "$BATS_TEST_TMPDIR/zi/Europe/Rome"
  ZONEINFO_DIR="$BATS_TEST_TMPDIR/zi" valid_timezone Europe/Rome
  ZONEINFO_DIR="$BATS_TEST_TMPDIR/zi" run valid_timezone Europe/Milano
  [ "$status" -ne 0 ]
  ZONEINFO_DIR="$BATS_TEST_TMPDIR/zi" run valid_timezone ../etc/passwd
  [ "$status" -ne 0 ]
  valid_locale it_IT.UTF-8
  run valid_locale it_IT; [ "$status" -ne 0 ]
}

@test "token Cloudflare (solo formato)" {
  valid_cf_token "$(printf 'a%.0s' {1..40})"
  run valid_cf_token "corto"; [ "$status" -ne 0 ]
  run valid_cf_token "con spazi $(printf 'a%.0s' {1..40})"; [ "$status" -ne 0 ]
}

@test "chiave SSH pubblica ed25519 valida" {
  ssh-keygen -q -t ed25519 -N '' -C 'manu@pc' -f "$BATS_TEST_TMPDIR/k"
  valid_ssh_pubkey "$(cat "$BATS_TEST_TMPDIR/k.pub")"
}

@test "chiave SSH: rifiuta privata, multilinea, spazzatura, RSA corta" {
  ssh-keygen -q -t ed25519 -N '' -f "$BATS_TEST_TMPDIR/k"
  run valid_ssh_pubkey "$(cat "$BATS_TEST_TMPDIR/k")"; [ "$status" -ne 0 ]
  run valid_ssh_pubkey "$(cat "$BATS_TEST_TMPDIR/k.pub")"$'\n'"$(cat "$BATS_TEST_TMPDIR/k.pub")"; [ "$status" -ne 0 ]
  run valid_ssh_pubkey "ssh-ed25519 nonbase64!!"; [ "$status" -ne 0 ]
  ssh-keygen -q -t rsa -b 1024 -N '' -f "$BATS_TEST_TMPDIR/r"
  run valid_ssh_pubkey "$(cat "$BATS_TEST_TMPDIR/r.pub")"; [ "$status" -ne 0 ]
}

@test "chiave SSH incollata da Windows passa dopo trim" {
  ssh-keygen -q -t ed25519 -N '' -f "$BATS_TEST_TMPDIR/k"
  valid_ssh_pubkey "$(trim "  $(cat "$BATS_TEST_TMPDIR/k.pub")"$' \r\n')"
}
```

- [ ] **Step 2: Verificare che falliscano**

Run: `wsl -d Debian -- bash tests/run.sh tests/validate.bats`
Expected: FAIL (`valid_domain: command not found`)

- [ ] **Step 3: Implementazione**

`lib/validate.sh`:
```bash
# shellcheck shell=bash
# Validazione degli input. Ogni funzione restituisce 0 (valido) o 1, senza output.

RESERVED_USERS=(root debian panel www-data nginx mysql redis daemon bin sys nobody)

valid_domain() {
  local d="$1"
  ((${#d} >= 4 && ${#d} <= 253)) || return 1
  [[ "$d" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

valid_hostname() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

valid_username() {
  local u="$1"
  [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1
  [[ "$u" != site_* ]] || return 1
  ! in_list "$u" "${RESERVED_USERS[@]}"
}

valid_port() {
  local p="$1"
  [[ "$p" =~ ^[1-9][0-9]{1,4}$ ]] || return 1
  if ((p == 22)); then
    return 0
  fi
  ((p >= 1024 && p <= 65535)) || return 1
  ! in_list "$p" 3306 6379 8080
}

valid_smtp_port() {
  in_list "$1" 25 465 587 2525
}

valid_line() {
  [[ -n "$1" && "$1" != *$'\n'* && "$1" != *$'\r'* ]]
}

valid_password() {
  valid_line "$1" && ((${#1} >= 12))
}

valid_email() {
  [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
}

valid_timezone() {
  [[ "$1" =~ ^[A-Za-z_]+(/[A-Za-z0-9_+-]+)*$ ]] || return 1
  [[ -f "${ZONEINFO_DIR:-/usr/share/zoneinfo}/$1" ]]
}

valid_locale() {
  [[ "$1" =~ ^[a-z]{2,3}_[A-Z]{2}\.UTF-8$ ]]
}

valid_cf_token() {
  [[ "$1" =~ ^[A-Za-z0-9_-]{30,200}$ ]]
}

valid_ssh_pubkey() {
  local key="$1" tmp info bits rc=0
  valid_line "$key" || return 1
  [[ "$key" != *"PRIVATE KEY"* ]] || return 1
  [[ "$key" =~ ^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\ [A-Za-z0-9+/]+=*(\ .*)?$ ]] || return 1
  tmp="$(mktemp)"
  printf '%s\n' "$key" >"$tmp"
  info="$(ssh-keygen -l -f "$tmp" 2>/dev/null)" || rc=1
  rm -f "$tmp"
  ((rc == 0)) || return 1
  if [[ "$key" == ssh-rsa* ]]; then
    bits="${info%% *}"
    ((bits >= 2048)) || return 1
  fi
  return 0
}
```

- [ ] **Step 4: Verificare che passino**

Run: `wsl -d Debian -- bash tests/run.sh tests/validate.bats`
Expected: tutti PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/validate.sh tests/validate.bats
git commit -m "feat(lib): input validators"
```

---

### Task 4: `lib/template.sh`

**Files:**
- Create: `lib/template.sh`, `templates/.gitkeep`
- Test: `tests/template.bats`

**Interfaces:**
- Consumes: `write_file`, `die`, `ANSWER_VARS`.
- Produces: `KNOWN_TEMPLATE_VARS` (array di variabili derivate ammesse nei template), `render_template SRC DEST MODE OWNER:GROUP VAR...` (sostituisce **solo** le variabili elencate; `die` se una non è definita), `template_vars_in FILE` (elenco `${VAR}` maiuscole presenti). Convenzione: template con variabili → estensione `.tmpl`; file statici → nessuna variabile `${MAIUSCOLA}`.

- [ ] **Step 1: Test che falliscono**

`tests/template.bats`:
```bash
setup() {
  load test_helper
  setup_common
}

@test "render_template sostituisce solo le variabili elencate" {
  printf 'server_name ${PANEL_DOMAIN};\nreturn 301 https://$host$request_uri;\nx ${OTHER}\n' >"$BATS_TEST_TMPDIR/t.tmpl"
  PANEL_DOMAIN=panel.miosito.it
  OTHER=no
  render_template "$BATS_TEST_TMPDIR/t.tmpl" "$BATS_TEST_TMPDIR/out" 644 "$(id -un):$(id -gn)" PANEL_DOMAIN
  grep -qxF 'server_name panel.miosito.it;' "$BATS_TEST_TMPDIR/out"
  grep -qxF 'return 301 https://$host$request_uri;' "$BATS_TEST_TMPDIR/out"
  grep -qxF 'x ${OTHER}' "$BATS_TEST_TMPDIR/out"
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/out")" = "644" ]
}

@test "render_template fallisce se una variabile non è definita" {
  printf '${NOPE_VAR}\n' >"$BATS_TEST_TMPDIR/t.tmpl"
  unset NOPE_VAR
  run render_template "$BATS_TEST_TMPDIR/t.tmpl" "$BATS_TEST_TMPDIR/out" 644 "$(id -un):$(id -gn)" NOPE_VAR
  [ "$status" -eq 1 ]
  [ ! -f "$BATS_TEST_TMPDIR/out" ]
}

@test "render_template conserva valori con dollari e virgolette" {
  printf 'password "${SMTP_PASS_ESC}"\n' >"$BATS_TEST_TMPDIR/t.tmpl"
  SMTP_PASS_ESC='a$b\"c'
  render_template "$BATS_TEST_TMPDIR/t.tmpl" "$BATS_TEST_TMPDIR/out" 600 "$(id -un):$(id -gn)" SMTP_PASS_ESC
  grep -qxF 'password "a$b\"c"' "$BATS_TEST_TMPDIR/out"
}

@test "i template .tmpl usano solo variabili note" {
  local f v known=("${ANSWER_VARS[@]}" "${KNOWN_TEMPLATE_VARS[@]}")
  shopt -s nullglob
  for f in "$REPO_ROOT"/templates/*.tmpl; do
    for v in $(template_vars_in "$f"); do
      in_list "$v" "${known[@]}" || { echo "$f: variabile sconosciuta $v"; return 1; }
    done
  done
}

@test "i template statici non contengono variabili maiuscole" {
  local f
  shopt -s nullglob
  for f in "$REPO_ROOT"/templates/*; do
    [[ "$f" == *.tmpl || "$f" == */.gitkeep ]] && continue
    [ -z "$(template_vars_in "$f")" ] || { echo "$f: rinominalo .tmpl"; return 1; }
  done
}
```

- [ ] **Step 2: Verificare che falliscano**

Run: `wsl -d Debian -- bash tests/run.sh tests/template.bats`
Expected: FAIL (`render_template: command not found`)

- [ ] **Step 3: Implementazione**

`lib/template.sh`:
```bash
# shellcheck shell=bash
# Rendering dei template con envsubst, limitato alle variabili elencate.

# Variabili non presenti in ANSWER_VARS ma ammesse nei template.
KNOWN_TEMPLATE_VARS=(
  PANEL_ROOT SSH_ALLOW_USERS PHP_VERSION VPS_OPT
  PMA_BLOWFISH PMA_CONTROL_PASS
  SMTP_TLS_STARTTLS SMTP_PASS_ESC
)

# render_template SRC DEST MODE OWNER:GROUP VAR...
render_template() {
  local src="$1" dest="$2" mode="$3" owner="$4" v shell_format=""
  shift 4
  [[ -f "$src" ]] || die "Template non trovato: $src"
  for v in "$@"; do
    [[ -v "$v" ]] || die "Variabile non definita per il template $(basename "$src"): $v"
    export "${v?}"
    shell_format+="\${$v} "
  done
  envsubst "$shell_format" <"$src" | write_file "$dest" "$mode" "$owner"
}

template_vars_in() {
  { grep -oE '\$\{[A-Z][A-Z0-9_]*\}' "$1" || true; } | tr -d '${}' | sort -u
}
```

`templates/.gitkeep`: file vuoto.

- [ ] **Step 4: Verificare che passino**

Run: `wsl -d Debian -- bash tests/run.sh tests/template.bats`
Expected: tutti PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/template.sh templates/.gitkeep tests/template.bats
git commit -m "feat(lib): explicit-variable template rendering"
```

---

### Task 5: `lib/components.sh`, `lib/net.sh`, `lib/preflight.sh`

**Files:**
- Create: `lib/components.sh`, `lib/net.sh`, `lib/preflight.sh`
- Test: `tests/components.bats`, `tests/net.bats`, `tests/preflight.bats`

**Interfaces:**
- Consumes: `is_yes`.
- Produces:
  - `components_from_selection SEL` (righe `nginx php mariadb redis certbot pma` → imposta `WANT_*` a yes/no), `components_allow_panel` (0 se nginx+php+mariadb+certbot), `resolve_components` (corregge le dipendenze, imposta `COMPONENT_NOTES`, una nota per riga), `components_summary` (stampa elenco leggibile).
  - `server_ipv4`, `server_ipv6` (vuoto se assente), `dns_points_here DOMINIO IP`, `domain_suffixes DOMINIO`.
  - `os_codename` (usa `OS_RELEASE_FILE`, default `/etc/os-release`), `preflight_errors` (stampa un errore per riga; nessun output = ok).

- [ ] **Step 1: Test che falliscono**

`tests/components.bats`:
```bash
setup() {
  load test_helper
  setup_common
}

@test "components_from_selection imposta le variabili" {
  components_from_selection $'nginx\nphp\ncertbot'
  [ "$WANT_NGINX" = yes ]; [ "$WANT_PHP" = yes ]; [ "$WANT_CERTBOT" = yes ]
  [ "$WANT_MARIADB" = no ]; [ "$WANT_REDIS" = no ]; [ "$WANT_PMA" = no ]
}

@test "il pannello richiede nginx, php, mariadb e certbot" {
  components_from_selection $'nginx\nphp\nmariadb\ncertbot'
  components_allow_panel
  components_from_selection $'nginx\nphp\nmariadb'
  run components_allow_panel
  [ "$status" -ne 0 ]
}

@test "resolve_components disattiva pannello e phpMyAdmin se mancano dipendenze" {
  components_from_selection $'nginx\nphp\npma'
  PANEL_ENABLED=yes
  resolve_components
  [ "$PANEL_ENABLED" = no ]
  [ "$WANT_PMA" = no ]
  [[ "$COMPONENT_NOTES" == *"Pannello disattivato"* ]]
  [[ "$COMPONENT_NOTES" == *"phpMyAdmin disattivato"* ]]
}

@test "resolve_components non tocca una selezione coerente" {
  components_from_selection $'nginx\nphp\nmariadb\ncertbot\npma'
  PANEL_ENABLED=yes
  resolve_components
  [ "$PANEL_ENABLED" = yes ]
  [ "$WANT_PMA" = yes ]
  [ -z "$COMPONENT_NOTES" ]
}
```

`tests/net.bats`:
```bash
setup() {
  load test_helper
  setup_common
}

@test "server_ipv4 legge l'indirizzo sorgente" {
  make_stub ip 'echo "1.1.1.1 via 203.0.113.1 dev ens3 src 203.0.113.10 uid 0"'
  run server_ipv4
  [ "$output" = "203.0.113.10" ]
}

@test "server_ipv6 prende il primo globale non deprecato" {
  make_stub ip 'cat <<EOF
2: ens3: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
    inet6 2001:db8:100::dead/56 scope global deprecated
    inet6 2001:db8:100::1:2cf7/56 scope global
EOF'
  run server_ipv6
  [ "$output" = "2001:db8:100::1:2cf7" ]
}

@test "server_ipv6 vuoto se non c'è IPv6" {
  make_stub ip 'true'
  run server_ipv6
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "dns_points_here" {
  make_stub getent 'printf "203.0.113.10     STREAM panel.miosito.it\n203.0.113.10     DGRAM\n"'
  dns_points_here panel.miosito.it 203.0.113.10
  run dns_points_here panel.miosito.it 1.2.3.4
  [ "$status" -ne 0 ]
}

@test "dns_points_here fallisce se il dominio non risolve" {
  make_stub getent 'exit 2'
  run dns_points_here panel.miosito.it 203.0.113.10
  [ "$status" -ne 0 ]
}

@test "domain_suffixes" {
  run domain_suffixes panel.miosito.it
  [ "${lines[0]}" = "panel.miosito.it" ]
  [ "${lines[1]}" = "miosito.it" ]
  [ "${#lines[@]}" -eq 2 ]
}
```

`tests/preflight.bats`:
```bash
setup() {
  load test_helper
  setup_common
  make_stub df 'printf "Avail\n  40G\n"'
  make_stub getent 'echo "151.101.2.132 deb.debian.org"'
}

@test "os_codename legge os-release" {
  printf 'ID=debian\nVERSION_CODENAME=trixie\n' >"$BATS_TEST_TMPDIR/os"
  OS_RELEASE_FILE="$BATS_TEST_TMPDIR/os" run os_codename
  [ "$output" = "trixie" ]
}

@test "preflight segnala Debian non supportata" {
  printf 'ID=debian\nVERSION_CODENAME=bookworm\n' >"$BATS_TEST_TMPDIR/os"
  OS_RELEASE_FILE="$BATS_TEST_TMPDIR/os" run preflight_errors
  [[ "$output" == *"Debian 13"* ]]
}

@test "preflight non segnala il sistema se è trixie" {
  printf 'ID=debian\nVERSION_CODENAME=trixie\n' >"$BATS_TEST_TMPDIR/os"
  OS_RELEASE_FILE="$BATS_TEST_TMPDIR/os" run preflight_errors
  [[ "$output" != *"Debian 13"* ]]
}

@test "preflight segnala disco pieno e DNS rotto" {
  make_stub df 'printf "Avail\n   2G\n"'
  make_stub getent 'exit 2'
  printf 'VERSION_CODENAME=trixie\n' >"$BATS_TEST_TMPDIR/os"
  OS_RELEASE_FILE="$BATS_TEST_TMPDIR/os" run preflight_errors
  [[ "$output" == *"Spazio disco"* ]]
  [[ "$output" == *"DNS"* ]]
}
```

- [ ] **Step 2: Verificare che falliscano**

Run: `wsl -d Debian -- bash tests/run.sh tests/components.bats tests/net.bats tests/preflight.bats`
Expected: FAIL (funzioni non definite)

- [ ] **Step 3: Implementazione**

`lib/components.sh`:
```bash
# shellcheck shell=bash
# Componenti scelti nella procedura guidata e loro dipendenze.

components_from_selection() {
  local item
  WANT_NGINX=no WANT_PHP=no WANT_MARIADB=no WANT_REDIS=no WANT_CERTBOT=no WANT_PMA=no
  while read -r item; do
    case "$item" in
      nginx) WANT_NGINX=yes ;;
      php) WANT_PHP=yes ;;
      mariadb) WANT_MARIADB=yes ;;
      redis) WANT_REDIS=yes ;;
      certbot) WANT_CERTBOT=yes ;;
      pma) WANT_PMA=yes ;;
    esac
  done <<<"$1"
}

components_allow_panel() {
  is_yes "${WANT_NGINX:-}" && is_yes "${WANT_PHP:-}" && is_yes "${WANT_MARIADB:-}" && is_yes "${WANT_CERTBOT:-}"
}

resolve_components() {
  COMPONENT_NOTES=""
  if is_yes "${PANEL_ENABLED:-}" && ! components_allow_panel; then
    PANEL_ENABLED=no
    COMPONENT_NOTES+="Pannello disattivato: richiede Nginx, PHP, MariaDB e Certbot."$'\n'
  fi
  if is_yes "${WANT_PMA:-}" && ! is_yes "${PANEL_ENABLED:-}"; then
    WANT_PMA=no
    COMPONENT_NOTES+="phpMyAdmin disattivato: viene servito solo sul dominio del pannello."$'\n'
  fi
  COMPONENT_NOTES="${COMPONENT_NOTES%$'\n'}"
}

components_summary() {
  local out=()
  is_yes "${WANT_NGINX:-}" && out+=(Nginx)
  is_yes "${WANT_PHP:-}" && out+=("PHP $PHP_VERSION")
  is_yes "${WANT_MARIADB:-}" && out+=(MariaDB)
  is_yes "${WANT_REDIS:-}" && out+=(Redis)
  is_yes "${WANT_CERTBOT:-}" && out+=(Certbot)
  is_yes "${WANT_PMA:-}" && out+=(phpMyAdmin)
  if ((${#out[@]} == 0)); then
    echo "nessuno"
  else
    local IFS=', '
    echo "${out[*]}"
  fi
}
```

Nota: in `components_summary` le righe `is_yes ... && out+=(...)` non sono l'ultimo comando della funzione, quindi un `is_yes` falso non attiva `errexit`.

`lib/net.sh`:
```bash
# shellcheck shell=bash
# Rete: IP del server, controllo DNS, suffissi di dominio.

server_ipv4() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }'
}

server_ipv6() {
  ip -6 addr show scope global 2>/dev/null | awk '/inet6/ && !/deprecated/ { sub(/\/.*/, "", $2); print $2; exit }'
}

# dns_points_here DOMINIO IP — 0 se il dominio risolve (anche) all'IP indicato.
dns_points_here() {
  local ips
  ips="$(getent ahostsv4 "$1" 2>/dev/null | awk '{ print $1 }' | sort -u)" || return 1
  grep -qxF -- "$2" <<<"$ips"
}

# domain_suffixes panel.miosito.it → panel.miosito.it, miosito.it
domain_suffixes() {
  local d="$1"
  while [[ "$d" == *.* ]]; do
    printf '%s\n' "$d"
    d="${d#*.}"
  done
}
```

`lib/preflight.sh`:
```bash
# shellcheck shell=bash
# Controlli iniziali prima della procedura guidata.

os_codename() {
  (
    source "${OS_RELEASE_FILE:-/etc/os-release}"
    printf '%s' "${VERSION_CODENAME:-}"
  )
}

preflight_errors() {
  local avail
  if [[ "$(os_codename)" != "trixie" ]]; then
    echo "Sistema non supportato: serve Debian 13 (trixie)."
  fi
  if ((EUID != 0)); then
    echo "Servono i privilegi di root (lancia con sudo)."
  fi
  avail="$(df --output=avail -BG / | tail -n 1 | tr -dc '0-9')"
  if ((${avail:-0} < 5)); then
    echo "Spazio disco insufficiente: ${avail:-0}G liberi, ne servono almeno 5."
  fi
  if ! getent hosts deb.debian.org >/dev/null 2>&1; then
    echo "Rete o DNS non funzionanti: deb.debian.org non risolve."
  fi
}
```

- [ ] **Step 4: Verificare che passino**

Run: `wsl -d Debian -- bash tests/run.sh tests/components.bats tests/net.bats tests/preflight.bats`
Expected: tutti PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/components.sh lib/net.sh lib/preflight.sh tests/components.bats tests/net.bats tests/preflight.bats
git commit -m "feat(lib): component dependencies, network helpers, preflight checks"
```

---

### Task 6: `lib/apt.sh` — chiavi dei repository verificate

**Files:**
- Create: `lib/apt.sh`
- Test: `tests/apt.bats`

**Interfaces:**
- Consumes: `die`, `in_list`.
- Produces: `gpg_primary_fprs FILE` (fingerprint delle chiavi primarie, una per riga), `gpg_keyring_install SRC DEST FPR...` (installa il keyring binario in DEST solo se **tutte** le chiavi primarie sono nell'elenco; accetta chiavi armored o binarie), `apt_add_repo NOME KEYRING RIGA_DEB` (scrive `/etc/apt/sources.list.d/NOME.list` e fa `apt-get update`).

- [ ] **Step 1: Test che falliscono**

`tests/apt.bats`:
```bash
setup() {
  load test_helper
  setup_common
  export GNUPGHOME="$BATS_TEST_TMPDIR/gnupg"
  mkdir -m 700 "$GNUPGHOME"
  gpg --batch --quiet --passphrase '' --quick-gen-key 'Test Repo <repo@example.com>' ed25519 sign never
  gpg --batch --armor --export repo@example.com >"$BATS_TEST_TMPDIR/key.asc"
  FPR="$(gpg --batch --with-colons --list-keys repo@example.com | awk -F: '$1=="fpr"{print $10; exit}')"
}

@test "gpg_primary_fprs restituisce il fingerprint" {
  run gpg_primary_fprs "$BATS_TEST_TMPDIR/key.asc"
  [ "$output" = "$FPR" ]
}

@test "gpg_keyring_install accetta una chiave attesa e la converte in binario" {
  gpg_keyring_install "$BATS_TEST_TMPDIR/key.asc" "$BATS_TEST_TMPDIR/repo.gpg" AAAA "$FPR"
  [ -f "$BATS_TEST_TMPDIR/repo.gpg" ]
  ! grep -q 'BEGIN PGP' "$BATS_TEST_TMPDIR/repo.gpg"
  run gpg_primary_fprs "$BATS_TEST_TMPDIR/repo.gpg"
  [ "$output" = "$FPR" ]
}

@test "gpg_keyring_install rifiuta una chiave inattesa" {
  run gpg_keyring_install "$BATS_TEST_TMPDIR/key.asc" "$BATS_TEST_TMPDIR/repo.gpg" 0000000000000000000000000000000000000000
  [ "$status" -eq 1 ]
  [ ! -f "$BATS_TEST_TMPDIR/repo.gpg" ]
}

@test "gpg_keyring_install rifiuta un file che non è una chiave" {
  echo "<html>errore</html>" >"$BATS_TEST_TMPDIR/bad.asc"
  run gpg_keyring_install "$BATS_TEST_TMPDIR/bad.asc" "$BATS_TEST_TMPDIR/repo.gpg" "$FPR"
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Verificare che falliscano**

Run: `wsl -d Debian -- bash tests/run.sh tests/apt.bats`
Expected: FAIL (`gpg_primary_fprs: command not found`)

- [ ] **Step 3: Implementazione**

`lib/apt.sh`:
```bash
# shellcheck shell=bash
# Repository APT esterni con chiavi verificate tramite fingerprint fissati.

gpg_primary_fprs() {
  local gh
  gh="$(mktemp -d)"
  gpg --homedir "$gh" --batch --with-colons --show-keys "$1" 2>/dev/null \
    | awk -F: '$1 == "pub" { p = 1; next } $1 == "fpr" && p { print $10; p = 0 }' || true
  rm -rf "$gh"
}

# gpg_keyring_install SRC DEST FPR... — installa il keyring solo se tutte le
# chiavi primarie contenute in SRC sono tra i fingerprint attesi.
gpg_keyring_install() {
  local src="$1" dest="$2" fprs f gh
  shift 2
  fprs="$(gpg_primary_fprs "$src")"
  [[ -n "$fprs" ]] || die "Nessuna chiave GPG valida in $src"
  while read -r f; do
    in_list "$f" "$@" || die "Chiave GPG non attesa per $(basename "$dest"): $f"
  done <<<"$fprs"
  if grep -q -- '-----BEGIN PGP' "$src"; then
    gh="$(mktemp -d)"
    gpg --homedir "$gh" --batch --yes --dearmor -o "$dest.tmp" "$src"
    rm -rf "$gh"
  else
    cp "$src" "$dest.tmp"
  fi
  chmod 644 "$dest.tmp"
  mv -f "$dest.tmp" "$dest"
}

# apt_add_repo NOME KEYRING "deb [signed-by=KEYRING] URL SUITE COMPONENTI"
apt_add_repo() {
  printf '%s\n' "$3" | write_file "/etc/apt/sources.list.d/$1.list" 644 root:root
  apt-get update -q >>"$VPS_LOG" 2>&1
}
```

Nota: il secondo argomento di `apt_add_repo` (keyring) è documentativo; la riga deb deve già contenere `signed-by=`. Mantenerlo per leggibilità nelle chiamate.

- [ ] **Step 4: Verificare che passino**

Run: `wsl -d Debian -- bash tests/run.sh tests/apt.bats`
Expected: tutti PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/apt.sh tests/apt.bats
git commit -m "feat(lib): fingerprint-pinned apt keyrings"
```

---

### Task 7: `lib/cloudflare.sh` e `lib/cfips.sh`

**Files:**
- Create: `lib/cloudflare.sh`, `lib/cfips.sh`
- Test: `tests/cloudflare.bats`, `tests/cfips.bats`

**Interfaces:**
- Consumes: `die`, `log`, `write_file`, `is_yes`, `domain_suffixes`, `NGINX_SNIPPETS`.
- Produces:
  - `cf_api METODO PERCORSO [JSON]` (token da `$CF_API_TOKEN`, passato a curl **via file header**, mai in argv; stampa la risposta), `cf_find_zone DOMINIO` (stampa `ZONE_ID ZONE_NAME`, 1 se non trovata), `cf_upsert_record ZONE_ID TIPO NOME CONTENUTO` (record proxato, crea o aggiorna), `cf_token_from_ini [FILE]` (default `$VPS_OPT/secrets/cloudflare.ini`).
  - `cf_fetch_ips` (CIDR v4+v6, una per riga; 1 se la lista è sospetta), `realip_snippet` (CIDR da stdin → configurazione Nginx), `ufw_stale_rules TAG VALIDE` (legge `ufw status numbered` da stdin, stampa i numeri delle regole con commento TAG il cui CIDR non è in VALIDE, in ordine decrescente), `cf_apply_ips LOCK` (aggiorna snippet real_ip e, se LOCK=yes, le regole UFW 80/443).

- [ ] **Step 1: Test che falliscono**

`tests/cloudflare.bats`:
```bash
setup() {
  load test_helper
  setup_common
  export STUB_LOG="$BATS_TEST_TMPDIR/curl.args" STUB_HDR="$BATS_TEST_TMPDIR/curl.hdr"
  make_stub curl '
printf "%s\n" "$*" >>"$STUB_LOG"
for a in "$@"; do case "$a" in @*) cat "${a#@}" >>"$STUB_HDR";; esac; done
url="${*: -1}"
case "$url" in
  *"name=panel.miosito.it&"*) echo "{\"success\":true,\"result\":[]}" ;;
  *"name=miosito.it&"*) echo "{\"success\":true,\"result\":[{\"id\":\"zone123\",\"name\":\"miosito.it\"}]}" ;;
  *"dns_records?type=A"*) echo "{\"success\":true,\"result\":[]}" ;;
  *"dns_records") echo "{\"success\":true,\"result\":{\"id\":\"rec1\"}}" ;;
  *) echo "{\"success\":false,\"result\":[],\"errors\":[{\"message\":\"boh\"}]}" ;;
esac'
  export CF_API_TOKEN="tok_SEGRETO_1234567890abcdefghijklmnop"
}

@test "il token non compare mai negli argomenti di curl" {
  cf_api GET /zones >/dev/null
  ! grep -q "SEGRETO" "$STUB_LOG"
  grep -q "Authorization: Bearer tok_SEGRETO" "$STUB_HDR"
}

@test "cf_api senza token muore" {
  unset CF_API_TOKEN
  run cf_api GET /zones
  [ "$status" -eq 1 ]
}

@test "cf_find_zone risale fino alla zona" {
  run cf_find_zone panel.miosito.it
  [ "$status" -eq 0 ]
  [ "$output" = "zone123 miosito.it" ]
}

@test "cf_find_zone fallisce se nessuna zona è accessibile" {
  run cf_find_zone panel.altro.it
  [ "$status" -eq 1 ]
}

@test "cf_upsert_record crea il record se non esiste" {
  cf_upsert_record zone123 A panel.miosito.it 203.0.113.10
  grep -q -- "-X POST" "$STUB_LOG"
  grep -q '"proxied":true' "$STUB_LOG"
}

@test "cf_token_from_ini legge il token" {
  printf 'dns_cloudflare_api_token = abc_DEF-123\n' >"$BATS_TEST_TMPDIR/cf.ini"
  run cf_token_from_ini "$BATS_TEST_TMPDIR/cf.ini"
  [ "$output" = "abc_DEF-123" ]
}
```

`tests/cfips.bats`:
```bash
setup() {
  load test_helper
  setup_common
}

ips_fixture() {
  printf '173.245.48.0/20\n103.21.244.0/22\n103.22.200.0/22\n103.31.4.0/22\n141.101.64.0/18\n108.162.192.0/18\n190.93.240.0/20\n188.114.96.0/20\n197.234.240.0/22\n198.41.128.0/17\n162.158.0.0/15\n104.16.0.0/13\n104.24.0.0/14\n172.64.0.0/13\n131.0.72.0/22\n'
}

@test "cf_fetch_ips unisce v4 e v6 e scarta righe strane" {
  make_stub curl '
case "${*: -1}" in
  *ips-v4) printf "173.245.48.0/20\n103.21.244.0/22\n103.22.200.0/22\n103.31.4.0/22\n141.101.64.0/18\n108.162.192.0/18\n190.93.240.0/20\n188.114.96.0/20\n<html>\n" ;;
  *ips-v6) printf "2400:cb00::/32\n2606:4700::/32\n2803:f800::/32\n" ;;
esac'
  run cf_fetch_ips
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 11 ]
  [[ "$output" != *html* ]]
  [[ "$output" == *"2606:4700::/32"* ]]
}

@test "cf_fetch_ips fallisce con una lista troppo corta" {
  make_stub curl 'echo "1.2.3.0/24"'
  run cf_fetch_ips
  [ "$status" -eq 1 ]
}

@test "cf_fetch_ips fallisce se curl fallisce" {
  make_stub curl 'exit 22'
  run cf_fetch_ips
  [ "$status" -eq 1 ]
}

@test "realip_snippet" {
  run realip_snippet < <(printf '173.245.48.0/20\n2400:cb00::/32\n')
  [[ "$output" == *"set_real_ip_from 173.245.48.0/20;"* ]]
  [[ "$output" == *"set_real_ip_from 2400:cb00::/32;"* ]]
  [[ "$output" == *"real_ip_header CF-Connecting-IP;"* ]]
}

@test "ufw_stale_rules trova solo le regole obsolete, dalla più alta" {
  local status_out
  status_out='Status: active

     To                         Action      From
     --                         ------      ----
[ 1] 41822/tcp                  ALLOW IN    Anywhere                   # ssh
[ 2] 80,443/tcp                 ALLOW IN    173.245.48.0/20            # cloudflare
[ 3] 80,443/tcp                 ALLOW IN    9.9.9.0/24                 # cloudflare
[ 4] 41822/tcp (v6)             ALLOW IN    Anywhere (v6)              # ssh
[ 5] 80,443/tcp (v6)            ALLOW IN    2400:cb00::/32             # cloudflare
[ 6] 80,443/tcp (v6)            ALLOW IN    2001:db8::/32              # cloudflare'
  run ufw_stale_rules cloudflare $'173.245.48.0/20\n2400:cb00::/32' <<<"$status_out"
  [ "${lines[0]}" = "6" ]
  [ "${lines[1]}" = "3" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "cf_apply_ips senza blocco scrive solo lo snippet" {
  export NGINX_SNIPPETS="$BATS_TEST_TMPDIR/snippets"
  cf_fetch_ips() { ips_fixture; }
  make_stub ufw 'echo "ufw $*" >>"$BATS_TEST_TMPDIR/ufw.log"'
  make_stub systemctl 'exit 3'
  cf_apply_ips no
  grep -q "set_real_ip_from 173.245.48.0/20;" "$NGINX_SNIPPETS/cloudflare-realip.conf"
  [ ! -f "$BATS_TEST_TMPDIR/ufw.log" ]
}

@test "cf_apply_ips con blocco aggiunge le regole cloudflare" {
  export NGINX_SNIPPETS="$BATS_TEST_TMPDIR/snippets"
  cf_fetch_ips() { ips_fixture; }
  make_stub ufw 'echo "ufw $*" >>"$BATS_TEST_TMPDIR/ufw.log"'
  make_stub systemctl 'exit 3'
  cf_apply_ips yes
  grep -q "allow proto tcp from 173.245.48.0/20 to any port 80,443 comment cloudflare" "$BATS_TEST_TMPDIR/ufw.log"
}
```

- [ ] **Step 2: Verificare che falliscano**

Run: `wsl -d Debian -- bash tests/run.sh tests/cloudflare.bats tests/cfips.bats`
Expected: FAIL (funzioni non definite)

- [ ] **Step 3: Implementazione**

`lib/cloudflare.sh`:
```bash
# shellcheck shell=bash
# API Cloudflare. Il token sta in $CF_API_TOKEN e arriva a curl tramite un
# file header temporaneo (600), così non compare mai tra gli argomenti (ps).

: "${CF_API:=https://api.cloudflare.com/client/v4}"

cf_api() {
  local method="$1" path="$2" data="${3:-}" hdr rc=0
  [[ -n "${CF_API_TOKEN:-}" ]] || die "Token Cloudflare mancante"
  hdr="$(mktemp)"
  chmod 600 "$hdr"
  printf 'Authorization: Bearer %s\n' "$CF_API_TOKEN" >"$hdr"
  local args=(-sS --max-time 30 -X "$method" -H @"$hdr" -H 'Content-Type: application/json')
  if [[ -n "$data" ]]; then
    args+=(--data "$data")
  fi
  curl "${args[@]}" "$CF_API$path" || rc=$?
  rm -f "$hdr"
  return "$rc"
}

# cf_find_zone DOMINIO → "ZONE_ID ZONE_NAME"
cf_find_zone() {
  local cand resp id
  while read -r cand; do
    resp="$(cf_api GET "/zones?name=$cand&status=active")" || return 1
    id="$(jq -r '.result[0].id // empty' <<<"$resp" 2>/dev/null || true)"
    if [[ -n "$id" ]]; then
      printf '%s %s\n' "$id" "$cand"
      return 0
    fi
  done < <(domain_suffixes "$1")
  return 1
}

# cf_upsert_record ZONE_ID TIPO NOME CONTENUTO — record proxato.
cf_upsert_record() {
  local zone="$1" type="$2" name="$3" content="$4" body resp id
  body="$(jq -nc --arg t "$type" --arg n "$name" --arg c "$content" \
    '{type: $t, name: $n, content: $c, ttl: 1, proxied: true}')"
  resp="$(cf_api GET "/zones/$zone/dns_records?type=$type&name=$name")"
  id="$(jq -r '.result[0].id // empty' <<<"$resp")"
  if [[ -n "$id" ]]; then
    resp="$(cf_api PUT "/zones/$zone/dns_records/$id" "$body")"
  else
    resp="$(cf_api POST "/zones/$zone/dns_records" "$body")"
  fi
  if ! jq -e '.success == true' >/dev/null <<<"$resp"; then
    log "Cloudflare: record $type $name non salvato: $(jq -c '.errors' <<<"$resp")"
    return 1
  fi
}

cf_token_from_ini() {
  sed -n 's/^dns_cloudflare_api_token *= *//p' "${1:-$VPS_OPT/secrets/cloudflare.ini}"
}
```

`lib/cfips.sh`:
```bash
# shellcheck shell=bash
# IP di Cloudflare: real_ip di Nginx e regole UFW per 80/443.

: "${CF_IPS_URL:=https://www.cloudflare.com}"

cf_fetch_ips() {
  local v4 v6 out
  v4="$(curl -fsS --max-time 30 "$CF_IPS_URL/ips-v4")" || return 1
  v6="$(curl -fsS --max-time 30 "$CF_IPS_URL/ips-v6")" || return 1
  out="$(printf '%s\n%s\n' "$v4" "$v6" | grep -E '^[0-9a-fA-F:.]+/[0-9]{1,3}$' || true)"
  (($(grep -c . <<<"$out") >= 10)) || return 1
  printf '%s\n' "$out"
}

realip_snippet() {
  local c
  echo "# Generato da vps-cf-ips-update: non modificare a mano."
  while read -r c; do
    if [[ -n "$c" ]]; then
      printf 'set_real_ip_from %s;\n' "$c"
    fi
  done
  echo "real_ip_header CF-Connecting-IP;"
}

# ufw_stale_rules TAG VALIDE < "ufw status numbered"
ufw_stale_rules() {
  local tag="$1" valid="$2" n cidr
  sed -nE "s/^\[ *([0-9]+)\][^A-Z]*ALLOW IN +([^ ]+) .*# ${tag}\$/\1 \2/p" \
    | while read -r n cidr; do
      if ! grep -qxF -- "$cidr" <<<"$valid"; then
        echo "$n"
      fi
    done | sort -rn
}

cf_apply_ips() {
  local lock="$1" ips c n stale
  ips="$(cf_fetch_ips)" || die "Impossibile scaricare la lista degli IP Cloudflare"
  mkdir -p "$NGINX_SNIPPETS"
  realip_snippet <<<"$ips" | write_file "$NGINX_SNIPPETS/cloudflare-realip.conf" 644 root:root
  if is_yes "$lock"; then
    while read -r c; do
      ufw allow proto tcp from "$c" to any port 80,443 comment cloudflare >/dev/null
    done <<<"$ips"
    stale="$(ufw status numbered | ufw_stale_rules cloudflare "$ips")"
    for n in $stale; do
      ufw --force delete "$n" >/dev/null
    done
  fi
  if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
    nginx -t >>"$VPS_LOG" 2>&1
    systemctl reload nginx
  fi
}
```

- [ ] **Step 4: Verificare che passino**

Run: `wsl -d Debian -- bash tests/run.sh tests/cloudflare.bats tests/cfips.bats`
Expected: tutti PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cloudflare.sh lib/cfips.sh tests/cloudflare.bats tests/cfips.bats
git commit -m "feat(lib): Cloudflare API, real_ip snippet and UFW origin lock"
```

---

### Task 8: `lib/sql.sh`, `lib/summary.sh`, `lib/ssh.sh`

**Files:**
- Create: `lib/sql.sh`, `lib/summary.sh`, `lib/ssh.sh`
- Test: `tests/sql.bats`, `tests/summary.bats`, `tests/ssh.bats`

**Interfaces:**
- Consumes: `die`, `write_file`.
- Produces:
  - `sql_quote STR` (letterale SQL tra apici), `sql_ident_ok NOME`, `sql_db_with_user DB UTENTE PASS`, `sql_user_grant UTENTE PASS PRIVILEGI OGGETTO`, `sql_secure_installation HOSTNAME` (tutti stampano SQL idempotente).
  - `summary_set CHIAVE VALORE` (in `$VPS_SUMMARY`, default `$VPS_ROOT/summary.env`, 600), `summary_load`.
  - `admin_logged_in UTENTE` (0 se `loginctl` mostra una sessione dell'utente).

- [ ] **Step 1: Test che falliscono**

`tests/sql.bats`:
```bash
setup() {
  load test_helper
  setup_common
}

@test "sql_quote raddoppia apici e backslash" {
  run sql_quote "a'b\\c"
  [ "$output" = "'a''b\\\\c'" ]
}

@test "sql_db_with_user è idempotente e quota la password" {
  run sql_db_with_user panel panel "x'y"
  [[ "$output" == *'CREATE DATABASE IF NOT EXISTS `panel`'* ]]
  [[ "$output" == *"CREATE USER IF NOT EXISTS 'panel'@'localhost' IDENTIFIED BY 'x''y';"* ]]
  [[ "$output" == *"ALTER USER 'panel'@'localhost' IDENTIFIED BY 'x''y';"* ]]
  [[ "$output" == *"GRANT ALL PRIVILEGES ON \`panel\`.* TO 'panel'@'localhost';"* ]]
}

@test "sql_db_with_user rifiuta nomi pericolosi" {
  run sql_db_with_user 'panel`; DROP' panel x
  [ "$status" -eq 1 ]
}

@test "sql_user_grant con wildcard dei siti" {
  run sql_user_grant panel_dbadmin pw 'ALL PRIVILEGES' '`site\_%`.*'
  [[ "$output" == *"GRANT ALL PRIVILEGES ON \`site\\_%\`.* TO 'panel_dbadmin'@'localhost';"* ]]
}

@test "sql_secure_installation" {
  run sql_secure_installation vps-01
  [[ "$output" == *"DROP USER IF EXISTS ''@'vps-01';"* ]]
  [[ "$output" == *'DROP DATABASE IF EXISTS `test`;'* ]]
  [[ "$output" == *"FLUSH PRIVILEGES;"* ]]
}
```

`tests/summary.bats`:
```bash
setup() {
  load test_helper
  setup_common
}

@test "summary_set e summary_load" {
  summary_set PMA_BASIC_PASS 'abc$def'
  summary_set PANEL_DBADMIN_PASS 'xyz'
  [ "$(stat -c %a "$VPS_ROOT/summary.env")" = "600" ]
  unset PMA_BASIC_PASS PANEL_DBADMIN_PASS
  summary_load
  [ "$PMA_BASIC_PASS" = 'abc$def' ]
  [ "$PANEL_DBADMIN_PASS" = 'xyz' ]
}

@test "summary_load senza file non fallisce" {
  run summary_load
  [ "$status" -eq 0 ]
}
```

`tests/ssh.bats`:
```bash
setup() {
  load test_helper
  setup_common
}

@test "admin_logged_in trova la sessione" {
  make_stub loginctl 'printf "  3 1000 debian - pts/0 active no -\n  7 1001 manu   - pts/1 active no -\n"'
  admin_logged_in manu
  run admin_logged_in altro
  [ "$status" -ne 0 ]
}

@test "admin_logged_in senza sessioni" {
  make_stub loginctl 'true'
  run admin_logged_in manu
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Verificare che falliscano**

Run: `wsl -d Debian -- bash tests/run.sh tests/sql.bats tests/summary.bats tests/ssh.bats`
Expected: FAIL (funzioni non definite)

- [ ] **Step 3: Implementazione**

`lib/sql.sh`:
```bash
# shellcheck shell=bash
# Generazione di SQL idempotente per MariaDB.

sql_quote() {
  local s="$1" q="'" b='\'
  s="${s//"$b"/"$b$b"}"
  s="${s//"$q"/"$q$q"}"
  printf "'%s'" "$s"
}

sql_ident_ok() {
  [[ "$1" =~ ^[a-z][a-z0-9_]{0,63}$ ]]
}

# sql_db_with_user DB UTENTE PASSWORD
sql_db_with_user() {
  if ! sql_ident_ok "$1" || ! sql_ident_ok "$2"; then
    die "Nome di database o utente non valido: $1 / $2"
  fi
  printf 'CREATE DATABASE IF NOT EXISTS `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\n' "$1"
  sql_user_grant "$2" "$3" "ALL PRIVILEGES" "\`$1\`.*"
}

# sql_user_grant UTENTE PASSWORD PRIVILEGI OGGETTO
sql_user_grant() {
  sql_ident_ok "$1" || die "Nome utente DB non valido: $1"
  printf "CREATE USER IF NOT EXISTS '%s'@'localhost' IDENTIFIED BY %s;\n" "$1" "$(sql_quote "$2")"
  printf "ALTER USER '%s'@'localhost' IDENTIFIED BY %s;\n" "$1" "$(sql_quote "$2")"
  printf "GRANT %s ON %s TO '%s'@'localhost';\n" "$3" "$4" "$1"
}

# sql_secure_installation HOSTNAME — equivalente di mysql_secure_installation.
sql_secure_installation() {
  printf "DROP USER IF EXISTS ''@'localhost';\n"
  printf "DROP USER IF EXISTS ''@%s;\n" "$(sql_quote "$1")"
  printf "DROP USER IF EXISTS 'root'@'%%';\n"
  printf 'DROP DATABASE IF EXISTS `test`;\n'
  printf "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\\\_%%';\n"
  printf 'FLUSH PRIVILEGES;\n'
}
```

`lib/summary.sh`:
```bash
# shellcheck shell=bash
# Dati da mostrare una sola volta nel riepilogo finale (cancellati con l'installer).

summary_file() {
  printf '%s' "${VPS_SUMMARY:-$VPS_ROOT/summary.env}"
}

summary_set() {
  local f
  f="$(summary_file)"
  if [[ ! -f "$f" ]]; then
    : | write_file "$f" 600 "$(id -un):$(id -gn)"
  fi
  printf '%s=%q\n' "$1" "$2" >>"$f"
}

summary_load() {
  local f
  f="$(summary_file)"
  if [[ -f "$f" ]]; then
    source "$f"
  fi
}
```

`lib/ssh.sh`:
```bash
# shellcheck shell=bash
# Verifica che l'utente admin sia davvero entrato con la nuova configurazione.

admin_logged_in() {
  loginctl list-sessions --no-legend 2>/dev/null \
    | awk -v u="$1" '$3 == u { f = 1 } END { exit !f }'
}
```

- [ ] **Step 4: Verificare che passino**

Run: `wsl -d Debian -- bash tests/run.sh tests/sql.bats tests/summary.bats tests/ssh.bats`
Expected: tutti PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/sql.sh lib/summary.sh lib/ssh.sh tests/sql.bats tests/summary.bats tests/ssh.bats
git commit -m "feat(lib): idempotent SQL, final summary store, SSH session check"
```

---

### Task 9: `lib/mail.sh`, `lib/manifest.sh`, `lib/tools.sh`

**Files:**
- Create: `lib/mail.sh`, `lib/manifest.sh`, `lib/tools.sh`, `templates/msmtprc.tmpl`
- Test: `tests/mail.bats`, `tests/manifest.bats`, `tests/tools-lib.bats`

**Interfaces:**
- Consumes: `render_template`, `write_file`, `server_ipv4`, `server_ipv6`, `pma_installed_version` (Task 10; in `manifest_build`, chiamata a runtime).
- Produces:
  - `mail_escape STR`, `mail_render_config` (usa `SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASS SMTP_FROM ALERT_EMAIL`; scrive `$VPS_OPT/secrets/msmtprc`, symlink `$MSMTPRC_LINK`, `$ALIASES_FILE`), `mail_send_test DESTINATARIO`. Variabili: `MSMTPRC_LINK` (default `/etc/msmtprc`), `ALIASES_FILE` (default `/etc/aliases`).
  - `manifest_path`, `manifest_group` (`panel` se esiste, altrimenti `root`), `manifest_build` (stampa JSON), `manifest_write`, `manifest_set FILTRO [ARGOMENTI_JQ...]`.
  - `json_ok [ARGOMENTI_JQ... FILTRO]`, `json_err MSG` (stampa ed esce 1), `tool_init` (errexit + trap JSON + `die` che stampa JSON), `read_stdin_limited [BYTE=4096]`.

- [ ] **Step 1: Test che falliscono**

`tests/mail.bats`:
```bash
setup() {
  load test_helper
  setup_common
  export MSMTPRC_LINK="$BATS_TEST_TMPDIR/msmtprc-link" ALIASES_FILE="$BATS_TEST_TMPDIR/aliases"
  SMTP_HOST=smtp.gmail.com SMTP_PORT=587 SMTP_USER=manu@gmail.com
  SMTP_PASS='ab"c\d$e' SMTP_FROM=manu@gmail.com ALERT_EMAIL=avvisi@gmail.com
}

@test "mail_escape protegge virgolette e backslash" {
  run mail_escape 'a"b\c'
  [ "$output" = 'a\"b\\c' ]
}

@test "mail_render_config scrive msmtprc, symlink e alias" {
  mail_render_config
  local f="$VPS_OPT/secrets/msmtprc"
  [ "$(stat -c %a "$f")" = "600" ]
  grep -qxF 'host smtp.gmail.com' "$f"
  grep -qxF 'tls_starttls on' "$f"
  grep -qxF 'password "ab\"c\\d$e"' "$f"
  [ "$(readlink "$MSMTPRC_LINK")" = "$f" ]
  grep -qxF 'root: avvisi@gmail.com' "$ALIASES_FILE"
}

@test "porta 465 usa TLS diretto" {
  SMTP_PORT=465
  mail_render_config
  grep -qxF 'tls_starttls off' "$VPS_OPT/secrets/msmtprc"
}
```

`tests/manifest.bats`:
```bash
setup() {
  load test_helper
  setup_common
  server_ipv4() { echo 203.0.113.10; }
  server_ipv6() { echo ""; }
  pma_installed_version() { echo 5.2.3; }
  HOSTNAME_NEW=vps-01 ADMIN_USER=manu SSH_PORT=41822 ROOT_LOGIN=no
  WANT_NGINX=yes WANT_PHP=yes WANT_MARIADB=yes WANT_REDIS=no WANT_CERTBOT=yes WANT_PMA=yes
  CF_ENABLED=yes CF_LOCK_ORIGIN=yes CF_ZONE=miosito.it
  MAIL_ENABLED=no ALERT_EMAIL=""
  PANEL_ENABLED=yes PANEL_DOMAIN=panel.miosito.it PANEL_ROOT=/var/www/panel.miosito.it
}

@test "manifest_build produce il JSON del contratto" {
  run manifest_build
  [ "$status" -eq 0 ]
  [ "$(jq -r .admin_user <<<"$output")" = manu ]
  [ "$(jq -r .ssh_port <<<"$output")" = 41822 ]
  [ "$(jq -r .ipv6 <<<"$output")" = null ]
  [ "$(jq -r .components.php <<<"$output")" = "8.4" ]
  [ "$(jq -r .components.redis <<<"$output")" = false ]
  [ "$(jq -r .components.phpmyadmin <<<"$output")" = "5.2.3" ]
  [ "$(jq -r .cloudflare.origin_locked <<<"$output")" = true ]
  [ "$(jq -r .mail.configured <<<"$output")" = false ]
  [ "$(jq -r .panel.php_socket <<<"$output")" = "/run/php/php8.4-fpm-panel.sock" ]
  [ "$(jq -r .conventions.site_db_prefix <<<"$output")" = site_ ]
}

@test "manifest senza pannello" {
  PANEL_ENABLED=no
  run manifest_build
  [ "$(jq -r .panel <<<"$output")" = null ]
}

@test "manifest_write e manifest_set" {
  manifest_write
  [ "$(stat -c %a "$VPS_OPT/manifest.json")" = "640" ]
  manifest_set '.mail.configured = true | .mail.alert_email = $e' --arg e avvisi@gmail.com
  [ "$(jq -r .mail.alert_email "$VPS_OPT/manifest.json")" = avvisi@gmail.com ]
}
```

`tests/tools-lib.bats`:
```bash
setup() {
  load test_helper
  setup_common
}

@test "json_ok semplice e con argomenti" {
  run json_ok
  [ "$output" = '{"ok":true}' ]
  run json_ok --arg v 1.2 '{ok:true,version:$v}'
  [ "$output" = '{"ok":true,"version":"1.2"}' ]
}

@test "json_err esce con 1 e JSON valido" {
  run json_err 'token "non" valido'
  [ "$status" -eq 1 ]
  [ "$(jq -r .error <<<"$output")" = 'token "non" valido' ]
  [ "$(jq -r .ok <<<"$output")" = false ]
}

@test "tool_init trasforma die in errore JSON" {
  run bash -c "source '$REPO_ROOT/lib/common.sh'; source '$REPO_ROOT/lib/tools.sh'; tool_init; die 'rotto' 2>/dev/null"
  [ "$status" -eq 1 ]
  [ "$(jq -r .error <<<"$output")" = rotto ]
}

@test "read_stdin_limited tronca l'input" {
  run bash -c "source '$REPO_ROOT/lib/tools.sh'; printf '0123456789' | read_stdin_limited 4"
  [ "$output" = "0123" ]
}
```

- [ ] **Step 2: Verificare che falliscano**

Run: `wsl -d Debian -- bash tests/run.sh tests/mail.bats tests/manifest.bats tests/tools-lib.bats`
Expected: FAIL (funzioni non definite)

- [ ] **Step 3: Implementazione**

`templates/msmtprc.tmpl`:
```
# Generato da vps-installer / vps-smtp: non modificare a mano.
defaults
auth on
tls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile /var/log/msmtp.log
aliases /etc/aliases

account default
host ${SMTP_HOST}
port ${SMTP_PORT}
tls_starttls ${SMTP_TLS_STARTTLS}
from ${SMTP_FROM}
user ${SMTP_USER}
password "${SMTP_PASS_ESC}"
```

`lib/mail.sh`:
```bash
# shellcheck shell=bash
# Email in uscita tramite msmtp.

: "${MSMTPRC_LINK:=/etc/msmtprc}"
: "${ALIASES_FILE:=/etc/aliases}"

mail_escape() {
  local s="$1" b='\' d='"'
  s="${s//"$b"/"$b$b"}"
  s="${s//"$d"/"$b$d"}"
  printf '%s' "$s"
}

mail_render_config() {
  SMTP_TLS_STARTTLS=on
  if [[ "$SMTP_PORT" == 465 ]]; then
    SMTP_TLS_STARTTLS=off
  fi
  SMTP_PASS_ESC="$(mail_escape "$SMTP_PASS")"
  install -d -m 700 "$VPS_OPT/secrets"
  render_template "$VPS_TEMPLATES/msmtprc.tmpl" "$VPS_OPT/secrets/msmtprc" 600 root:root \
    SMTP_HOST SMTP_PORT SMTP_TLS_STARTTLS SMTP_FROM SMTP_USER SMTP_PASS_ESC
  ln -sfn "$VPS_OPT/secrets/msmtprc" "$MSMTPRC_LINK"
  printf 'root: %s\ndefault: %s\n' "$ALERT_EMAIL" "$ALERT_EMAIL" | write_file "$ALIASES_FILE" 644 root:root
}

mail_send_test() {
  local to="$1" from host
  from="$(awk '$1 == "from" { print $2; exit }' "$VPS_OPT/secrets/msmtprc")"
  host="$(hostname)"
  printf 'Subject: Email di prova da %s\nFrom: %s\nTo: %s\nContent-Type: text/plain; charset=UTF-8\n\nEmail di prova inviata da %s il %s.\n' \
    "$host" "$from" "$to" "$host" "$(date '+%F %T')" | msmtp -t >>"$VPS_LOG" 2>&1
}
```

`lib/manifest.sh`:
```bash
# shellcheck shell=bash
# /opt/vps/manifest.json: informazioni non segrete lette dal pannello.

manifest_path() {
  printf '%s/manifest.json' "$VPS_OPT"
}

manifest_group() {
  if getent group panel >/dev/null 2>&1; then
    echo panel
  else
    echo root
  fi
}

manifest_build() {
  jq -n \
    --arg version "$VPS_INSTALLER_VERSION" --arg at "$(date -Iseconds)" \
    --arg hostname "$HOSTNAME_NEW" --arg ipv4 "$(server_ipv4)" --arg ipv6 "$(server_ipv6)" \
    --arg user "$ADMIN_USER" --argjson port "$SSH_PORT" --arg root "$ROOT_LOGIN" \
    --arg nginx "$WANT_NGINX" --arg php "$WANT_PHP" --arg phpv "$PHP_VERSION" \
    --arg mariadb "$WANT_MARIADB" --arg redis "$WANT_REDIS" --arg certbot "$WANT_CERTBOT" \
    --arg pma "$(pma_installed_version)" \
    --arg cf "$CF_ENABLED" --arg cflock "$CF_LOCK_ORIGIN" --arg zone "$CF_ZONE" \
    --arg mail "$MAIL_ENABLED" --arg alert "$ALERT_EMAIL" \
    --arg panel "$PANEL_ENABLED" --arg pdomain "$PANEL_DOMAIN" --arg proot "$PANEL_ROOT" \
    '{
      installer_version: $version,
      installed_at: $at,
      hostname: $hostname,
      ipv4: $ipv4,
      ipv6: (if $ipv6 == "" then null else $ipv6 end),
      admin_user: $user,
      ssh_port: $port,
      root_login: $root,
      components: {
        nginx: ($nginx == "yes"),
        php: (if $php == "yes" then $phpv else null end),
        mariadb: ($mariadb == "yes"),
        redis: ($redis == "yes"),
        certbot: ($certbot == "yes"),
        phpmyadmin: (if $pma == "" then null else $pma end)
      },
      cloudflare: {
        enabled: ($cf == "yes"),
        origin_locked: ($cf == "yes" and $cflock == "yes"),
        zone: (if $cf == "yes" then $zone else null end),
        ips_updated_at: null
      },
      mail: {
        configured: ($mail == "yes"),
        alert_email: (if $mail == "yes" then $alert else null end)
      },
      panel: (if $panel == "yes" then {
        domain: $pdomain,
        path: $proot,
        php_socket: ("/run/php/php" + $phpv + "-fpm-panel.sock"),
        pma_path: "/pma/"
      } else null end),
      conventions: {
        site_root: "/var/www/<dominio>",
        site_db_prefix: "site_",
        site_user_prefix: "site_"
      }
    }'
}

manifest_write() {
  manifest_build | write_file "$(manifest_path)" 640 "root:$(manifest_group)"
}

# manifest_set FILTRO [ARGOMENTI_JQ...]
manifest_set() {
  local filter="$1" f
  shift
  f="$(manifest_path)"
  jq "$@" "$filter" "$f" | write_file "$f" 640 "root:$(manifest_group)"
}
```

`lib/tools.sh`:
```bash
# shellcheck shell=bash
# Supporto per gli script wrapper /opt/vps/bin/vps-*: output JSON su stdout.

json_ok() {
  if (($#)); then
    jq -nc "$@"
  else
    printf '{"ok":true}\n'
  fi
}

json_err() {
  jq -nc --arg e "$1" '{ok: false, error: $e}'
  exit 1
}

tool_init() {
  set -Eeuo pipefail
  trap 'json_err "errore interno (dettagli in $VPS_LOG)"' ERR
  die() {
    log "ERRORE: $*"
    json_err "$*"
  }
}

read_stdin_limited() {
  head -c "${1:-4096}"
}
```

- [ ] **Step 4: Verificare che passino**

Run: `wsl -d Debian -- bash tests/run.sh tests/mail.bats tests/manifest.bats tests/tools-lib.bats`
Expected: tutti PASS (anche `tests/template.bats`, che ora controlla `msmtprc.tmpl`).

- [ ] **Step 5: Commit**

```bash
git add lib/mail.sh lib/manifest.sh lib/tools.sh templates/msmtprc.tmpl tests/mail.bats tests/manifest.bats tests/tools-lib.bats
git commit -m "feat(lib): msmtp config, manifest, JSON helpers for wrappers"
```

---

### Task 10: `lib/ssl.sh` e `lib/pma.sh`

**Files:**
- Create: `lib/ssl.sh`, `lib/pma.sh`
- Test: `tests/ssl.bats`, `tests/pma.bats`

**Interfaces:**
- Consumes: `die`, `log`, `is_yes`, `server_ipv4`, `dns_points_here`, `own`, `manifest_group`.
- Produces:
  - `ssl_obtain_cert DOMINIO` (DNS-01 Cloudflare se `CF_ENABLED=yes`, altrimenti webroot `/var/www/_acme` dopo il controllo DNS; `die` con istruzioni se fallisce).
  - `PMA_DIR` (default `$VPS_OPT/phpmyadmin`), `HTPASSWD_PMA` (default `/etc/nginx/.htpasswd-pma`), `PMA_SIGNER_FPRS` (array), `pma_latest_version`, `pma_installed_version`, `pma_verify_sig FILE ASC KEYRING`, `pma_fetch VERSIONE WORKDIR` (stampa la cartella estratta), `pma_install_tree SRC` (sostituisce `PMA_DIR` conservando `config.inc.php`), `pma_update_to VERSIONE`, `pma_controlpass_from_config`, `pma_set_basic_auth UTENTE` (password da stdin).

- [ ] **Step 1: Verificare il fingerprint del firmatario di phpMyAdmin**

Aprire https://docs.phpmyadmin.net/en/latest/setup.html#verifying-phpmyadmin-releases e confermare il fingerprint della chiave di firma delle release (atteso: `3D06 A59E CE73 0EB7 1B51 1C17 CE75 2F17 8259 BD92`, Isaac Bennetch). Se la documentazione elenca altri firmatari attuali, aggiungerli a `PMA_SIGNER_FPRS` nello Step 4.

- [ ] **Step 2: Test che falliscono**

`tests/ssl.bats`:
```bash
setup() {
  load test_helper
  setup_common
  export CERTBOT_LOG="$BATS_TEST_TMPDIR/certbot.args"
  make_stub certbot 'printf "%s\n" "$*" >>"$CERTBOT_LOG"'
  server_ipv4() { echo 203.0.113.10; }
}

@test "con Cloudflare usa la challenge DNS" {
  CF_ENABLED=yes
  ssl_obtain_cert panel.miosito.it
  grep -q -- "--dns-cloudflare-credentials $VPS_OPT/secrets/cloudflare.ini" "$CERTBOT_LOG"
  grep -q -- "--register-unsafely-without-email" "$CERTBOT_LOG"
  ! grep -q -- "--webroot" "$CERTBOT_LOG"
}

@test "senza Cloudflare usa il webroot se il DNS punta qui" {
  CF_ENABLED=no
  dns_points_here() { return 0; }
  ssl_obtain_cert panel.miosito.it
  grep -q -- "--webroot -w /var/www/_acme" "$CERTBOT_LOG"
}

@test "senza Cloudflare si ferma con istruzioni se il DNS non punta qui" {
  CF_ENABLED=no
  dns_points_here() { return 1; }
  run ssl_obtain_cert panel.miosito.it
  [ "$status" -eq 1 ]
  [[ "$output" == *"non punta a 203.0.113.10"* ]]
  [[ "$output" == *"run.sh"* ]]
  [ ! -f "$CERTBOT_LOG" ]
}

@test "errore di certbot diventa un messaggio chiaro" {
  CF_ENABLED=yes
  make_stub certbot 'exit 1'
  run ssl_obtain_cert panel.miosito.it
  [ "$status" -eq 1 ]
  [[ "$output" == *"certbot non è riuscito"* ]]
}
```

`tests/pma.bats`:
```bash
setup() {
  load test_helper
  setup_common
  export PMA_DIR="$VPS_OPT/phpmyadmin"
}

@test "pma_latest_version legge version.json" {
  make_stub curl 'echo "{\"version\": \"5.2.3\", \"date\": \"2025-10-01\"}"'
  run pma_latest_version
  [ "$output" = "5.2.3" ]
}

@test "pma_latest_version rifiuta risposte strane" {
  make_stub curl 'echo "<html>manutenzione</html>"'
  run pma_latest_version
  [ "$status" -ne 0 ]
}

@test "pma_installed_version legge la versione installata" {
  mkdir -p "$PMA_DIR/libraries/classes"
  printf "<?php\nfinal class Version\n{\n    public const VERSION = '5.2.3' . VERSION_SUFFIX;\n}\n" >"$PMA_DIR/libraries/classes/Version.php"
  run pma_installed_version
  [ "$output" = "5.2.3" ]
}

@test "pma_installed_version vuoto se non installato" {
  run pma_installed_version
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "pma_controlpass_from_config" {
  mkdir -p "$PMA_DIR"
  printf "<?php\n\$cfg['Servers'][\$i]['controlpass'] = 'Abc123xyz';\n" >"$PMA_DIR/config.inc.php"
  run pma_controlpass_from_config
  [ "$output" = "Abc123xyz" ]
}

@test "pma_install_tree conserva la configurazione e toglie setup" {
  mkdir -p "$PMA_DIR" "$VPS_OPT/new/setup" "$VPS_OPT/new/libraries"
  echo vecchia >"$PMA_DIR/config.inc.php"
  echo nuovo >"$VPS_OPT/new/index.php"
  pma_install_tree "$VPS_OPT/new"
  [ "$(cat "$PMA_DIR/config.inc.php")" = vecchia ]
  [ "$(cat "$PMA_DIR/index.php")" = nuovo ]
  [ ! -d "$PMA_DIR/setup" ]
  [ ! -d "$PMA_DIR.old" ]
  [ "$(stat -c %a "$PMA_DIR/index.php")" = "640" ]
}

@test "pma_verify_sig accetta solo il firmatario atteso e file integri" {
  export GNUPGHOME="$BATS_TEST_TMPDIR/gnupg"
  mkdir -m 700 "$GNUPGHOME"
  gpg --batch --quiet --passphrase '' --quick-gen-key 'PMA Test <pma@example.com>' ed25519 sign never
  local fpr
  fpr="$(gpg --batch --with-colons --list-keys pma@example.com | awk -F: '$1=="fpr"{print $10; exit}')"
  gpg --batch --export pma@example.com >"$BATS_TEST_TMPDIR/keyring"
  echo contenuto >"$BATS_TEST_TMPDIR/pma.tar.xz"
  gpg --batch --quiet --armor --detach-sign -o "$BATS_TEST_TMPDIR/pma.tar.xz.asc" "$BATS_TEST_TMPDIR/pma.tar.xz"
  PMA_SIGNER_FPRS=("$fpr")
  pma_verify_sig "$BATS_TEST_TMPDIR/pma.tar.xz" "$BATS_TEST_TMPDIR/pma.tar.xz.asc" "$BATS_TEST_TMPDIR/keyring"
  PMA_SIGNER_FPRS=(0000000000000000000000000000000000000000)
  run pma_verify_sig "$BATS_TEST_TMPDIR/pma.tar.xz" "$BATS_TEST_TMPDIR/pma.tar.xz.asc" "$BATS_TEST_TMPDIR/keyring"
  [ "$status" -ne 0 ]
  PMA_SIGNER_FPRS=("$fpr")
  echo manomesso >>"$BATS_TEST_TMPDIR/pma.tar.xz"
  run pma_verify_sig "$BATS_TEST_TMPDIR/pma.tar.xz" "$BATS_TEST_TMPDIR/pma.tar.xz.asc" "$BATS_TEST_TMPDIR/keyring"
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 3: Verificare che falliscano**

Run: `wsl -d Debian -- bash tests/run.sh tests/ssl.bats tests/pma.bats`
Expected: FAIL (funzioni non definite)

- [ ] **Step 4: Implementazione**

`lib/ssl.sh`:
```bash
# shellcheck shell=bash
# Certificati Let's Encrypt (usato dall'installer e, in futuro, da vps-site).

ssl_obtain_cert() {
  local d="$1" ip
  local args=(certonly -n --agree-tos --register-unsafely-without-email
    --keep-until-expiring --cert-name "$d" -d "$d")
  if is_yes "${CF_ENABLED:-no}"; then
    args+=(--dns-cloudflare --dns-cloudflare-credentials "$VPS_OPT/secrets/cloudflare.ini"
      --dns-cloudflare-propagation-seconds 30)
  else
    ip="$(server_ipv4)"
    if ! dns_points_here "$d" "$ip"; then
      die "Il dominio $d non punta a $ip. Crea il record DNS A ($d -> $ip), attendi la propagazione e riprendi con: sudo bash $VPS_ROOT/run.sh"
    fi
    args+=(--webroot -w /var/www/_acme)
  fi
  log "SSL: richiedo il certificato per $d"
  certbot "${args[@]}" >>"$VPS_LOG" 2>&1 \
    || die "certbot non è riuscito a ottenere il certificato per $d (dettagli in $VPS_LOG)"
}
```

`lib/pma.sh`:
```bash
# shellcheck shell=bash
# phpMyAdmin: ultima versione upstream, verificata con SHA256 e firma GPG.

: "${PMA_DIR:=$VPS_OPT/phpmyadmin}"
: "${HTPASSWD_PMA:=/etc/nginx/.htpasswd-pma}"
: "${PMA_BASE_URL:=https://files.phpmyadmin.net}"
# Fingerprint dei firmatari delle release (https://docs.phpmyadmin.net, "Verifying phpMyAdmin releases").
PMA_SIGNER_FPRS=(3D06A59ECE730EB71B511C17CE752F178259BD92)

pma_latest_version() {
  local v
  v="$(curl -fsS --max-time 30 https://www.phpmyadmin.net/home_page/version.json | jq -r '.version' 2>/dev/null)" || return 1
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  printf '%s\n' "$v"
}

pma_installed_version() {
  local f
  for f in "$PMA_DIR/libraries/classes/Version.php" "$PMA_DIR/src/Version.php"; do
    if [[ -f "$f" ]]; then
      sed -nE "s/.*VERSION = '([0-9]+\.[0-9]+\.[0-9]+)'.*/\1/p" "$f" | head -n 1
      return 0
    fi
  done
}

pma_controlpass_from_config() {
  sed -nE "s/.*\['controlpass'\] = '([A-Za-z0-9]+)'.*/\1/p" "$PMA_DIR/config.inc.php" 2>/dev/null | head -n 1
}

# pma_verify_sig FILE ASC KEYRING — 0 se firmato da uno dei PMA_SIGNER_FPRS.
pma_verify_sig() {
  local gh status f
  gh="$(mktemp -d)"
  gpg --homedir "$gh" --batch --quiet --import "$3" 2>>"$VPS_LOG" || true
  status="$(gpg --homedir "$gh" --batch --status-fd 1 --verify "$2" "$1" 2>>"$VPS_LOG" || true)"
  rm -rf "$gh"
  for f in "${PMA_SIGNER_FPRS[@]}"; do
    if grep -qE "^\[GNUPG:\] VALIDSIG .*\b$f\b" <<<"$status"; then
      return 0
    fi
  done
  return 1
}

# pma_fetch VERSIONE WORKDIR — scarica, verifica, estrae; stampa la cartella estratta.
pma_fetch() {
  local v="$1" w="$2" base f
  base="$PMA_BASE_URL/phpMyAdmin/$v"
  f="phpMyAdmin-$v-all-languages.tar.xz"
  log "phpMyAdmin: scarico la versione $v"
  curl -fsS --max-time 300 -o "$w/$f" "$base/$f"
  curl -fsS --max-time 30 -o "$w/$f.asc" "$base/$f.asc"
  curl -fsS --max-time 30 -o "$w/$f.sha256" "$base/$f.sha256"
  curl -fsS --max-time 30 -o "$w/keyring" "$PMA_BASE_URL/phpmyadmin.keyring"
  (cd "$w" && sha256sum -c --status "$f.sha256") || die "phpMyAdmin $v: SHA256 non valido"
  pma_verify_sig "$w/$f" "$w/$f.asc" "$w/keyring" || die "phpMyAdmin $v: firma GPG non valida"
  tar -xJf "$w/$f" -C "$w"
  printf '%s\n' "$w/phpMyAdmin-$v-all-languages"
}

# pma_install_tree SRC — sostituisce PMA_DIR conservando config.inc.php.
pma_install_tree() {
  local src="$1" old="$PMA_DIR.old"
  if [[ -f "$PMA_DIR/config.inc.php" ]]; then
    cp -p "$PMA_DIR/config.inc.php" "$src/config.inc.php"
  fi
  rm -rf "$src/setup" "$src/examples" "$old"
  own -R "root:$(manifest_group)" "$src"
  find "$src" -type d -exec chmod 750 {} +
  find "$src" -type f -exec chmod 640 {} +
  if [[ -d "$PMA_DIR" ]]; then
    mv "$PMA_DIR" "$old"
  fi
  mv "$src" "$PMA_DIR"
  rm -rf "$old"
}

pma_update_to() {
  local v="$1" work src
  work="$(mktemp -d "$VPS_OPT/.pma.XXXXXX")"
  src="$(pma_fetch "$v" "$work")"
  pma_install_tree "$src"
  rm -rf "$work"
}

# pma_set_basic_auth UTENTE — password da stdin, hash bcrypt.
pma_set_basic_auth() {
  htpasswd -B -i -c "$HTPASSWD_PMA" "$1" >>"$VPS_LOG" 2>&1
  own root:www-data "$HTPASSWD_PMA"
  chmod 640 "$HTPASSWD_PMA"
}
```

- [ ] **Step 5: Verificare che passino**

Run: `wsl -d Debian -- bash tests/run.sh tests/ssl.bats tests/pma.bats`
Expected: tutti PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/ssl.sh lib/pma.sh tests/ssl.bats tests/pma.bats
git commit -m "feat(lib): certificate issuance and verified phpMyAdmin install"
```

---

### Task 11: `run.sh` — esecuzione degli step con ripresa

**Files:**
- Create: `run.sh`, `steps/.gitkeep`
- Test: `tests/run.bats`

**Interfaces:**
- Consumes: tutte le `lib/*.sh`, `answers_load`, `state_done`, `state_mark`.
- Produces: `run_steps` (esegue `$VPS_ROOT/steps/[0-9][0-9]-*.sh` in ordine; ogni step definisce `step_main` e opzionalmente `step_enabled`; ogni step gira in una subshell; lo stato viene segnato solo se lo step riesce), `main [--reset]`. Contratto degli step: **file che definiscono solo funzioni/array**, nessun codice al livello superiore.

- [ ] **Step 1: Test che falliscono**

`tests/run.bats`:
```bash
setup() {
  load test_helper
  setup_common
  mkdir -p "$VPS_ROOT/steps"
  source "$REPO_ROOT/run.sh"
  export OUT="$BATS_TEST_TMPDIR/out"
}

@test "esegue gli step in ordine e segna lo stato" {
  printf 'step_main() { echo 10 >>"$OUT"; }\n' >"$VPS_ROOT/steps/10-a.sh"
  printf 'step_main() { echo 20 >>"$OUT"; }\n' >"$VPS_ROOT/steps/20-b.sh"
  run_steps
  [ "$(cat "$OUT")" = $'10\n20' ]
  state_done 10-a
  state_done 20-b
}

@test "salta gli step già completati" {
  printf 'step_main() { echo 10 >>"$OUT"; }\n' >"$VPS_ROOT/steps/10-a.sh"
  state_mark 10-a
  run_steps
  [ ! -f "$OUT" ]
}

@test "salta gli step non richiesti ma li segna" {
  printf 'step_enabled() { return 1; }\nstep_main() { echo no >>"$OUT"; }\n' >"$VPS_ROOT/steps/40-nginx.sh"
  run_steps
  [ ! -f "$OUT" ]
  state_done 40-nginx
}

@test "si ferma al primo errore e la ripresa riparte da lì" {
  printf 'step_main() { echo 10 >>"$OUT"; }\n' >"$VPS_ROOT/steps/10-a.sh"
  printf 'step_main() { false; echo mai >>"$OUT"; }\n' >"$VPS_ROOT/steps/20-b.sh"
  printf 'step_main() { echo 30 >>"$OUT"; }\n' >"$VPS_ROOT/steps/30-c.sh"
  run run_steps
  [ "$status" -ne 0 ]
  [ "$(cat "$OUT")" = "10" ]
  run state_done 20-b
  [ "$status" -ne 0 ]
  printf 'step_main() { echo 20 >>"$OUT"; }\n' >"$VPS_ROOT/steps/20-b.sh"
  run_steps
  [ "$(cat "$OUT")" = $'10\n20\n30' ]
}

@test "uno step non eredita step_enabled dal precedente" {
  printf 'step_enabled() { return 1; }\nstep_main() { :; }\n' >"$VPS_ROOT/steps/10-a.sh"
  printf 'step_main() { echo 20 >>"$OUT"; }\n' >"$VPS_ROOT/steps/20-b.sh"
  run_steps
  [ "$(cat "$OUT")" = "20" ]
}
```

- [ ] **Step 2: Verificare che falliscano**

Run: `wsl -d Debian -- bash tests/run.sh tests/run.bats`
Expected: FAIL (`run.sh` non esiste)

- [ ] **Step 3: Implementazione**

`run.sh`:
```bash
#!/usr/bin/env bash
# Esegue la procedura guidata (se serve) e poi gli step, con ripresa.

if [[ -z "${VPS_ROOT:-}" ]]; then
  VPS_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
fi
export VPS_ROOT
export VPS_TEMPLATES="${VPS_TEMPLATES:-$VPS_ROOT/templates}"
for _lib in "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"/lib/*.sh; do
  source "$_lib"
done

run_steps() {
  local f name
  for f in "$VPS_ROOT"/steps/[0-9][0-9]-*.sh; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f" .sh)"
    if state_done "$name"; then
      log "Step $name già completato, salto."
      continue
    fi
    log "=== Step $name ==="
    # Subshell: ogni step ha le sue funzioni e un errore non segna lo stato.
    (
      set -Eeuo pipefail
      step_enabled() { return 0; }
      source "$f"
      if step_enabled; then
        step_main
      else
        log "Step $name non richiesto, salto."
      fi
    ) || return $?
    state_mark "$name"
  done
}

main() {
  enable_error_trap
  ((EUID == 0)) || die "Esegui come root: sudo bash $0"
  touch "$VPS_LOG"
  chmod 600 "$VPS_LOG"
  if [[ "${1:-}" == "--reset" ]]; then
    rm -f "$VPS_ANSWERS" "$VPS_STATE" "$VPS_ROOT/summary.env"
  fi
  if [[ ! -f "$VPS_ANSWERS" ]]; then
    bash "$VPS_ROOT/wizard.sh" || die "Procedura guidata annullata."
  else
    log "Risposte già presenti: riprendo dall'ultimo step non completato."
  fi
  answers_load
  run_steps
  log "Installazione terminata."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
```

Il `set -Eeuo pipefail` dentro la subshell garantisce che uno step si fermi al primo errore anche quando `run_steps` è chiamata senza `enable_error_trap` (nei test); `|| return $?` propaga il fallimento senza segnare lo stato.

- [ ] **Step 4: Verificare che passino**

Run: `wsl -d Debian -- bash tests/run.sh tests/run.bats`
Expected: tutti PASS.

- [ ] **Step 5: Commit**

```bash
touch steps/.gitkeep
git add run.sh steps/.gitkeep tests/run.bats
git update-index --chmod=+x run.sh
git commit -m "feat: step runner with resumable state"
```

---

### Task 12: `install.sh` — bootstrap

**Files:**
- Create: `install.sh`
- Test: `tests/install.bats`

**Interfaces:**
- Produces: segnaposto `__VERSION__`, `__TARBALL_SHA256__`, `__REPO__` (sostituiti dalla release, Task 22); variabili sovrascrivibili nei test `VPS_DEST` (default `/root/vps-installer`), `RELEASE_BASE_URL` (default `https://github.com/$REPO/releases/download`); funzioni `fetch_release [TAR_LOCALE]`, `bootstrap_deps`, `main [--local FILE] [--reset]`. Esporta `VPS_BOOTSTRAP` (percorso di `install.sh`, cancellato a fine installazione).

- [ ] **Step 1: Test che falliscono**

`tests/install.bats`:
```bash
setup() {
  load test_helper
  export VPS_DEST="$BATS_TEST_TMPDIR/dest"
  mkdir -p "$BATS_TEST_TMPDIR/pkg/vps-installer"
  echo 'echo ciao' >"$BATS_TEST_TMPDIR/pkg/vps-installer/run.sh"
  tar -czf "$BATS_TEST_TMPDIR/rel.tar.gz" -C "$BATS_TEST_TMPDIR/pkg" vps-installer
  source "$BATS_TEST_DIRNAME/../install.sh"
}

@test "fetch_release estrae un archivio locale" {
  fetch_release "$BATS_TEST_TMPDIR/rel.tar.gz"
  [ -f "$VPS_DEST/run.sh" ]
  [ "$(stat -c %a "$VPS_DEST")" = "700" ]
}

@test "fetch_release scarica e verifica l'hash" {
  mkdir -p "$BATS_TEST_TMPDIR/www/v9.9.9"
  cp "$BATS_TEST_TMPDIR/rel.tar.gz" "$BATS_TEST_TMPDIR/www/v9.9.9/vps-installer-v9.9.9.tar.gz"
  VPS_VERSION=v9.9.9
  TARBALL_SHA256="$(sha256sum "$BATS_TEST_TMPDIR/rel.tar.gz" | cut -d' ' -f1)"
  RELEASE_BASE_URL="file://$BATS_TEST_TMPDIR/www"
  fetch_release ""
  [ -f "$VPS_DEST/run.sh" ]
}

@test "fetch_release rifiuta un hash sbagliato" {
  mkdir -p "$BATS_TEST_TMPDIR/www/v9.9.9"
  cp "$BATS_TEST_TMPDIR/rel.tar.gz" "$BATS_TEST_TMPDIR/www/v9.9.9/vps-installer-v9.9.9.tar.gz"
  VPS_VERSION=v9.9.9
  TARBALL_SHA256=0000000000000000000000000000000000000000000000000000000000000000
  RELEASE_BASE_URL="file://$BATS_TEST_TMPDIR/www"
  run fetch_release ""
  [ "$status" -ne 0 ]
  [ ! -f "$VPS_DEST/run.sh" ]
}

@test "senza release richiede --local" {
  TARBALL_SHA256=__TARBALL_SHA256__
  run fetch_release ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"--local"* ]]
}
```

- [ ] **Step 2: Verificare che falliscano**

Run: `wsl -d Debian -- bash tests/run.sh tests/install.bats`
Expected: FAIL (`install.sh` non esiste)

- [ ] **Step 3: Implementazione**

`install.sh`:
```bash
#!/usr/bin/env bash
# vps-installer — bootstrap: scarica la release, la verifica e avvia l'installazione.
# Uso: sudo bash install.sh [--reset] [--local archivio.tar.gz]
# (set -Eeuo pipefail è in main: il file viene anche caricato dai test.)

VPS_VERSION="__VERSION__"
TARBALL_SHA256="__TARBALL_SHA256__"
REPO="__REPO__"
: "${VPS_DEST:=/root/vps-installer}"
: "${RELEASE_BASE_URL:=https://github.com/$REPO/releases/download}"

usage() {
  cat <<'EOF'
Uso: sudo bash install.sh [opzioni]
  --reset           ricomincia dalla procedura guidata
  --local FILE      usa un archivio locale invece di scaricarlo
  -h, --help        mostra questo aiuto
Se la connessione cade: ricollegati e lancia  sudo tmux attach -t vps-installer
EOF
}

bootstrap_deps() {
  echo "Preparo gli strumenti di base..."
  apt-get update -q >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
    tmux whiptail jq curl gettext-base openssl ca-certificates >/dev/null
}

fetch_release() {
  local tar="$1" tmp=""
  if [[ -z "$tar" ]]; then
    if [[ "$TARBALL_SHA256" == __* ]]; then
      echo "Questo install.sh non proviene da una release: usa --local archivio.tar.gz" >&2
      return 1
    fi
    tmp="$(mktemp -d)"
    tar="$tmp/vps-installer.tar.gz"
    curl -fsSL --max-time 120 -o "$tar" "$RELEASE_BASE_URL/$VPS_VERSION/vps-installer-$VPS_VERSION.tar.gz"
    if ! echo "$TARBALL_SHA256  $tar" | sha256sum -c - >/dev/null 2>&1; then
      rm -rf "$tmp"
      echo "Hash dell'archivio non valido: interrompo." >&2
      return 1
    fi
  fi
  install -d -m 700 "$VPS_DEST"
  tar -xzf "$tar" -C "$VPS_DEST" --strip-components=1 --no-same-owner
  if [[ -n "$tmp" ]]; then
    rm -rf "$tmp"
  fi
}

main() {
  set -Eeuo pipefail
  local self orig_args=("$@") local_tar="" run_args=()
  self="$(readlink -f "$0")"
  while (($#)); do
    case "$1" in
      --local) local_tar="${2:?manca il file}"; local_tar="$(readlink -f "$local_tar")"; shift 2 ;;
      --reset) run_args+=(--reset); shift ;;
      -h | --help) usage; exit 0 ;;
      *) echo "Opzione sconosciuta: $1" >&2; usage; exit 1 ;;
    esac
  done
  if ((EUID != 0)); then
    echo "Esegui con: sudo bash $self" >&2
    exit 1
  fi
  if [[ -z "${TMUX:-}" ]]; then
    bootstrap_deps
    echo "Avvio dentro tmux. Se la connessione cade: sudo tmux attach -t vps-installer"
    sleep 2
    exec tmux new-session -A -s vps-installer bash "$self" "${orig_args[@]}"
  fi
  if [[ ! -f "$VPS_DEST/run.sh" ]]; then
    fetch_release "$local_tar"
  fi
  export VPS_BOOTSTRAP="$self"
  bash "$VPS_DEST/run.sh" "${run_args[@]}" || {
    echo
    echo "Installazione interrotta. Dettagli: /var/log/vps-installer.log"
    echo "Per riprendere: sudo bash $self"
    echo "ATTENZIONE: $VPS_DEST/answers.env contiene segreti finché l'installazione non termina."
    read -r -p "Premi Invio per chiudere." _ || true
    exit 1
  }
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
```

- [ ] **Step 4: Verificare che passino**

Run: `wsl -d Debian -- bash tests/run.sh tests/install.bats`
Expected: tutti PASS.

- [ ] **Step 5: Commit**

```bash
git add install.sh tests/install.bats
git update-index --chmod=+x install.sh
git commit -m "feat: verified bootstrap with tmux resume"
```

---

### Task 13: `wizard.sh` — procedura guidata

**Files:**
- Create: `wizard.sh`
- Test: `tests/wizard.bats` (solo sintassi e caricamento; l'interazione si verifica nel Task 23)

**Interfaces:**
- Consumes: `trim`, validatori (Task 3), `components_*`/`resolve_components` (Task 5), `server_ipv4`, `dns_points_here`, `cf_find_zone`, `preflight_errors`, `answers_save`.
- Produces: `answers.env` con tutte le `ANSWER_VARS`. Valori: `WANT_*`, `PANEL_ENABLED`, `CF_ENABLED`, `CF_LOCK_ORIGIN`, `MAIL_ENABLED` ∈ {`yes`,`no`}; `ROOT_LOGIN` ∈ {`no`,`prohibit-password`}.

- [ ] **Step 1: Test che fallisce**

`tests/wizard.bats`:
```bash
setup() {
  load test_helper
  setup_common
}

@test "wizard.sh si carica senza eseguire main" {
  run bash -c "source '$REPO_ROOT/wizard.sh'; declare -F ask_input wizard_cloudflare wizard_summary >/dev/null"
  [ "$status" -eq 0 ]
}

@test "wizard_defaults azzera tutte le risposte" {
  source "$REPO_ROOT/wizard.sh"
  ADMIN_USER=vecchio
  wizard_defaults
  [ "$ADMIN_USER" = "" ]
  [ "$WANT_NGINX" = no ]
  [ "$CF_ENABLED" = no ]
}
```

- [ ] **Step 2: Verificare che fallisca**

Run: `wsl -d Debian -- bash tests/run.sh tests/wizard.bats`
Expected: FAIL (`wizard.sh` non esiste)

- [ ] **Step 3: Implementazione**

`wizard.sh`:
```bash
#!/usr/bin/env bash
# Procedura guidata: tutte le domande all'inizio, risposte in answers.env.

if [[ -z "${VPS_ROOT:-}" ]]; then
  VPS_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
fi
export VPS_ROOT
for _lib in "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"/lib/*.sh; do
  source "$_lib"
done

W_TITLE="VPS Installer $VPS_INSTALLER_VERSION"

wt() {
  whiptail --title "$W_TITLE" "$@" 3>&1 1>&2 2>&3
}

confirm_quit() {
  if wt --yesno "Vuoi annullare l'installazione?" 8 60; then
    exit 1
  fi
}

# ask_input VAR TESTO DEFAULT VALIDATORE MESSAGGIO_ERRORE
ask_input() {
  local var="$1" text="$2" def="$3" validator="$4" err="$5" val
  while true; do
    if ! val="$(wt --inputbox "$text" 14 78 "$def")"; then
      confirm_quit
      continue
    fi
    val="$(trim "$val")"
    if "$validator" "$val"; then
      printf -v "$var" '%s' "$val"
      return 0
    fi
    wt --msgbox "$err" 12 78 || true
    def="$val"
  done
}

# ask_secret VAR TESTO VALIDATORE MESSAGGIO_ERRORE
ask_secret() {
  local var="$1" text="$2" validator="$3" err="$4" val
  while true; do
    if ! val="$(wt --passwordbox "$text" 12 78)"; then
      confirm_quit
      continue
    fi
    if "$validator" "$val"; then
      printf -v "$var" '%s' "$val"
      return 0
    fi
    wt --msgbox "$err" 10 78 || true
  done
}

ask_new_password() {
  local var="$1" text="$2" p1 p2
  while true; do
    ask_secret p1 "$text" valid_password "La password deve avere almeno 12 caratteri e stare su una riga."
    ask_secret p2 "Ripeti la password:" valid_password "La password deve avere almeno 12 caratteri."
    if [[ "$p1" == "$p2" ]]; then
      printf -v "$var" '%s' "$p1"
      return 0
    fi
    wt --msgbox "Le password non coincidono, riprova." 8 60 || true
  done
}

# ask_yesno VAR TESTO [DEFAULT=yes]
ask_yesno() {
  local var="$1" text="$2" def="${3:-yes}" opts=()
  if [[ "$def" == no ]]; then
    opts+=(--defaultno)
  fi
  if wt "${opts[@]}" --yesno "$text" 12 78; then
    printf -v "$var" yes
  else
    printf -v "$var" no
  fi
}

# ask_menu VAR TESTO DEFAULT TAG DESCRIZIONE [TAG DESCRIZIONE...]
ask_menu() {
  local var="$1" text="$2" def="$3" val
  shift 3
  while ! val="$(wt --default-item "$def" --menu "$text" 16 78 6 "$@")"; do
    confirm_quit
  done
  printf -v "$var" '%s' "$val"
}

wizard_defaults() {
  local v
  for v in "${ANSWER_VARS[@]}"; do
    printf -v "$v" '%s' ""
  done
  WANT_NGINX=no WANT_PHP=no WANT_MARIADB=no WANT_REDIS=no WANT_CERTBOT=no WANT_PMA=no
  PANEL_ENABLED=no CF_ENABLED=no CF_LOCK_ORIGIN=no MAIL_ENABLED=no ROOT_LOGIN=no
}

wizard_preflight() {
  local errs
  errs="$(preflight_errors)"
  if [[ -n "$errs" ]]; then
    wt --msgbox "Impossibile continuare:\n\n$errs" 16 78 || true
    exit 1
  fi
  wt --msgbox "Benvenuto.\n\nTi farò alcune domande, poi l'installazione procederà da sola.\nAlla fine ti chiederò di verificare l'accesso SSH da una seconda finestra.\n\nTieni pronta la tua chiave SSH PUBBLICA (es. il contenuto di ~/.ssh/id_ed25519.pub)." 16 78 || true
}

wizard_system() {
  ask_input HOSTNAME_NEW "Nome host della VPS (minuscole, cifre, trattini):" \
    "$(hostname -s | tr '[:upper:]' '[:lower:]')" valid_hostname "Nome host non valido."
  ask_input TIMEZONE "Fuso orario:" "Europe/Rome" valid_timezone "Fuso orario non valido (es. Europe/Rome)."
  ask_input LOCALE "Lingua di sistema (locale):" "it_IT.UTF-8" valid_locale "Locale non valido (es. it_IT.UTF-8)."
}

wizard_user() {
  ask_input ADMIN_USER "Nome del tuo utente amministratore (per SSH e sudo):" "" valid_username \
    "Nome utente non valido o riservato.\nUsa minuscole, cifre, _ o -, iniziando con una lettera.\nNon usare root, debian, panel o nomi che iniziano con site_."
  ask_new_password ADMIN_PASS "Password per $ADMIN_USER (serve per sudo, minimo 12 caratteri):"
  ask_input ADMIN_PUBKEY "Incolla la tua chiave SSH PUBBLICA (una riga, es. ssh-ed25519 AAAA... nome):" "" valid_ssh_pubkey \
    "Chiave non valida.\nIncolla il contenuto del file .pub (una sola riga).\nNON incollare la chiave privata.\nSono accettate ed25519, ecdsa e rsa da almeno 2048 bit."
}

wizard_ssh() {
  ask_input SSH_PORT "Porta SSH (consigliata una porta alta casuale):" "$(shuf -i 20000-60000 -n 1)" valid_port \
    "Porta non valida: usa 22 oppure 1024-65535 (escluse 3306, 6379, 8080)."
  ask_menu ROOT_LOGIN "Accesso SSH come root:" no \
    no "Bloccato (consigliato)" \
    prohibit-password "Consentito solo con chiave SSH"
}

wizard_stack() {
  local sel
  while ! sel="$(wt --separate-output --checklist "Componenti da installare (spazio per selezionare, Invio per confermare):" 18 78 6 \
    nginx "Nginx (web server)" ON \
    php "PHP $PHP_VERSION" ON \
    mariadb "MariaDB (database)" ON \
    redis "Redis (cache)" ON \
    certbot "Certbot (certificati SSL)" ON \
    pma "phpMyAdmin (sul dominio del pannello)" ON)"; do
    confirm_quit
  done
  components_from_selection "$sel"
}

wizard_panel() {
  if ! components_allow_panel; then
    PANEL_ENABLED=no
    return 0
  fi
  ask_yesno PANEL_ENABLED "Preparare ora il dominio del pannello di gestione?\n\n(vhost, SSL, database, utente dedicato: il codice del pannello si installa dopo)" yes
  if is_yes "$PANEL_ENABLED"; then
    ask_input PANEL_DOMAIN "Dominio del pannello (es. panel.miosito.it):" "" valid_domain \
      "Dominio non valido (solo minuscole, es. panel.miosito.it)."
  fi
}

wizard_cloudflare() {
  local zone_domain="${PANEL_DOMAIN:-}" found ip
  ask_yesno CF_ENABLED "Usi Cloudflare per i domini di questa VPS?" yes
  if ! is_yes "$CF_ENABLED"; then
    ip="$(server_ipv4)"
    if is_yes "$PANEL_ENABLED" && ! dns_points_here "$PANEL_DOMAIN" "$ip"; then
      wt --msgbox "Attenzione: $PANEL_DOMAIN non punta ancora a $ip.\n\nCrea il record DNS A prima che inizi lo step SSL, altrimenti l'installazione si fermerà lì (potrai riprenderla)." 14 78 || true
    fi
    return 0
  fi
  if [[ -z "$zone_domain" ]]; then
    ask_input zone_domain "Dominio principale gestito su Cloudflare (es. miosito.it):" "" valid_domain "Dominio non valido."
  fi
  while true; do
    ask_secret CF_API_TOKEN "API token Cloudflare\n(permesso Zone > DNS > Edit sulla zona di $zone_domain):" valid_cf_token \
      "Formato del token non valido."
    if found="$(CF_API_TOKEN="$CF_API_TOKEN" cf_find_zone "$zone_domain")"; then
      CF_ZONE_ID="${found%% *}"
      CF_ZONE="${found#* }"
      break
    fi
    wt --msgbox "Il token non è valido oppure non ha accesso alla zona di $zone_domain. Riprova." 10 78 || true
  done
  ask_yesno CF_LOCK_ORIGIN "Accettare traffico web (80/443) SOLO dagli IP di Cloudflare?\n\n(consigliato: nasconde la VPS a chi la cerca direttamente)" yes
}

wizard_mail() {
  local choice
  ask_menu choice "Email per gli avvisi (fail2ban, aggiornamenti, certificati):" later \
    later "Configura dopo dal pannello (consigliato)" \
    now "Configura ora (SMTP)"
  if [[ "$choice" == later ]]; then
    MAIL_ENABLED=no
    return 0
  fi
  MAIL_ENABLED=yes
  ask_input SMTP_HOST "Server SMTP (es. smtp.gmail.com, smtp-relay.brevo.com):" "smtp.gmail.com" valid_domain "Host non valido."
  ask_input SMTP_PORT "Porta SMTP (587 STARTTLS, 465 TLS):" "587" valid_smtp_port "Porta non valida (25, 465, 587, 2525)."
  ask_input SMTP_USER "Utente SMTP:" "" valid_line "Utente non valido."
  ask_secret SMTP_PASS "Password SMTP (per Gmail: una app password):" valid_line "Password non valida."
  ask_input SMTP_FROM "Indirizzo mittente:" "$SMTP_USER" valid_email "Email non valida."
  ask_input ALERT_EMAIL "Email che riceve gli avvisi:" "$SMTP_FROM" valid_email "Email non valida."
}

wizard_summary() {
  local s panel cf mail
  panel="no"
  if is_yes "$PANEL_ENABLED"; then panel="$PANEL_DOMAIN"; fi
  cf="no"
  if is_yes "$CF_ENABLED"; then
    cf="sì, zona $CF_ZONE"
    if is_yes "$CF_LOCK_ORIGIN"; then cf+=", 80/443 solo da Cloudflare"; fi
  fi
  mail="da configurare dal pannello"
  if is_yes "$MAIL_ENABLED"; then mail="$SMTP_USER via $SMTP_HOST:$SMTP_PORT, avvisi a $ALERT_EMAIL"; fi
  s="Host:        $HOSTNAME_NEW ($TIMEZONE, $LOCALE)\n"
  s+="Utente:      $ADMIN_USER (password ****, chiave ${ADMIN_PUBKEY%% *})\n"
  s+="SSH:         porta $SSH_PORT, root: $ROOT_LOGIN, password disattivate\n"
  s+="Componenti:  $(components_summary)\n"
  s+="Pannello:    $panel\n"
  s+="Cloudflare:  $cf\n"
  s+="Email:       $mail\n"
  if [[ -n "${COMPONENT_NOTES:-}" ]]; then
    s+="\nCorrezioni automatiche:\n$COMPONENT_NOTES\n"
  fi
  wt --scrolltext --msgbox "Riepilogo delle scelte:\n\n$s" 22 78 || true
  ask_menu WIZARD_CHOICE "Come vuoi procedere?" install \
    install "Installa" \
    restart "Ricomincia le domande" \
    quit "Annulla"
}

main() {
  enable_error_trap
  ((EUID == 0)) || die "Esegui come root"
  wizard_preflight
  while true; do
    wizard_defaults
    wizard_system
    wizard_user
    wizard_ssh
    wizard_stack
    wizard_panel
    wizard_cloudflare
    wizard_mail
    resolve_components
    wizard_summary
    case "$WIZARD_CHOICE" in
      install) break ;;
      restart) continue ;;
      *) exit 1 ;;
    esac
  done
  answers_save
  log "Procedura guidata completata, risposte salvate."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
```

- [ ] **Step 4: Verificare che passino**

Run: `wsl -d Debian -- bash tests/run.sh tests/wizard.bats`
Expected: tutti PASS, shellcheck pulito su `wizard.sh`.

- [ ] **Step 5: Commit**

```bash
git add wizard.sh tests/wizard.bats
git update-index --chmod=+x wizard.sh
git commit -m "feat: whiptail wizard"
```

---

### Task 14: Step 10 (sistema) e 20 (utente e SSH)

**Files:**
- Create: `steps/10-system.sh`, `steps/20-user-ssh.sh`, `templates/chrony-vps.sources`, `templates/apt-52vps-unattended`, `templates/apt-20auto-upgrades`, `templates/sshd-10-vps.conf.tmpl`
- Test: `tests/steps.bats`

**Interfaces:**
- Consumes: `apt_install`, `render_template`, `log`, risposte (`HOSTNAME_NEW TIMEZONE LOCALE ADMIN_USER ADMIN_PASS ADMIN_PUBKEY SSH_PORT ROOT_LOGIN SSH_ALLOW_USERS`).
- Produces: `/opt/vps` (755) e `/opt/vps/secrets` (700) creati dallo step 10; `$VPS_ROOT/sshd-10-vps.conf` pronto (attivato nello step 99). Pacchetti base disponibili per gli step successivi: `htop git curl unzip 7zip ca-certificates gnupg whiptail jq gettext-base locales chrony unattended-upgrades apt-listchanges tmux openssl cron xz-utils`.

- [ ] **Step 1: Test generico sugli step (fallisce finché gli step non esistono)**

`tests/steps.bats`:
```bash
setup() {
  load test_helper
  setup_common
}

@test "ogni step è bash valido e definisce step_main senza codice al livello superiore" {
  local f count=0
  for f in "$REPO_ROOT"/steps/[0-9][0-9]-*.sh; do
    [ -f "$f" ] || continue
    count=$((count + 1))
    bash -n "$f"
    run bash -c "source '$f' >/dev/null; declare -F step_main >/dev/null"
    [ "$status" -eq 0 ] || { echo "$f: manca step_main"; return 1; }
    run bash -c "source '$f'"
    [ -z "$output" ] || { echo "$f: produce output al caricamento"; return 1; }
  done
  [ "$count" -gt 0 ]
}

@test "sshd-10-vps.conf disattiva password e limita gli utenti" {
  SSH_PORT=41822 ROOT_LOGIN=no SSH_ALLOW_USERS=manu
  render_template "$REPO_ROOT/templates/sshd-10-vps.conf.tmpl" "$BATS_TEST_TMPDIR/sshd" 644 "$(id -un):$(id -gn)" SSH_PORT ROOT_LOGIN SSH_ALLOW_USERS
  grep -qxF 'Port 41822' "$BATS_TEST_TMPDIR/sshd"
  grep -qxF 'PasswordAuthentication no' "$BATS_TEST_TMPDIR/sshd"
  grep -qxF 'PermitRootLogin no' "$BATS_TEST_TMPDIR/sshd"
  grep -qxF 'AllowUsers manu' "$BATS_TEST_TMPDIR/sshd"
}
```

- [ ] **Step 2: Verificare che falliscano**

Run: `wsl -d Debian -- bash tests/run.sh tests/steps.bats`
Expected: FAIL (nessuno step / template mancante)

- [ ] **Step 3: Template**

`templates/chrony-vps.sources`:
```
pool 0.it.pool.ntp.org iburst
pool 1.it.pool.ntp.org iburst
pool 2.it.pool.ntp.org iburst
```

`templates/apt-52vps-unattended`:
```
// vps-installer: solo pacchetti Debian, riavvio automatico alle 04:00 se serve.
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename},label=Debian";
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
        "origin=Debian,codename=${distro_codename}-updates";
};
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Mail "root";
Unattended-Upgrade::MailReport "only-on-error";
```

`templates/apt-20auto-upgrades`:
```
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
```

`templates/sshd-10-vps.conf.tmpl`:
```
# vps-installer: ha la precedenza su 50-cloud-init.conf (in sshd vale il primo valore letto).
Port ${SSH_PORT}
PermitRootLogin ${ROOT_LOGIN}
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
X11Forwarding no
AllowUsers ${SSH_ALLOW_USERS}
MaxAuthTries 3
LoginGraceTime 30
```

- [ ] **Step 4: Step 10**

`steps/10-system.sh`:
```bash
# shellcheck shell=bash
# Sistema: aggiornamenti, hostname, fuso orario, locale, NTP, aggiornamenti automatici.

step_main() {
  log "Sistema: aggiornamento dei pacchetti (può richiedere qualche minuto)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q >>"$VPS_LOG" 2>&1
  apt-get full-upgrade -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold >>"$VPS_LOG" 2>&1
  apt_install htop git curl unzip 7zip ca-certificates gnupg whiptail jq gettext-base \
    locales chrony unattended-upgrades apt-listchanges tmux openssl cron xz-utils

  install -d -m 755 "$VPS_OPT"
  install -d -m 700 "$VPS_OPT/secrets"

  log "Sistema: hostname $HOSTNAME_NEW"
  hostnamectl set-hostname "$HOSTNAME_NEW"
  if grep -q '^127\.0\.1\.1' /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1 $HOSTNAME_NEW/" /etc/hosts
  else
    echo "127.0.1.1 $HOSTNAME_NEW" >>/etc/hosts
  fi

  log "Sistema: fuso orario $TIMEZONE, locale $LOCALE"
  timedatectl set-timezone "$TIMEZONE"
  if ! grep -q "^${LOCALE} UTF-8" /etc/locale.gen; then
    echo "$LOCALE UTF-8" >>/etc/locale.gen
  fi
  locale-gen >>"$VPS_LOG" 2>&1
  update-locale LANG="$LOCALE"

  log "Sistema: NTP (chrony)"
  install -D -m 644 "$VPS_TEMPLATES/chrony-vps.sources" /etc/chrony/sources.d/vps.sources
  systemctl restart chrony

  log "Sistema: aggiornamenti di sicurezza automatici"
  install -m 644 "$VPS_TEMPLATES/apt-52vps-unattended" /etc/apt/apt.conf.d/52vps-unattended
  install -m 644 "$VPS_TEMPLATES/apt-20auto-upgrades" /etc/apt/apt.conf.d/20auto-upgrades
  systemctl enable --now unattended-upgrades >>"$VPS_LOG" 2>&1
}
```

- [ ] **Step 5: Step 20**

`steps/20-user-ssh.sh`:
```bash
# shellcheck shell=bash
# Utente amministratore e configurazione SSH (preparata qui, attivata nello step 99).

step_main() {
  local home keys
  log "Utente: $ADMIN_USER"
  if ! id "$ADMIN_USER" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "$ADMIN_USER"
  fi
  usermod -aG sudo "$ADMIN_USER"
  printf '%s:%s\n' "$ADMIN_USER" "$ADMIN_PASS" | chpasswd

  home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
  keys="$home/.ssh/authorized_keys"
  install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$home/.ssh"
  touch "$keys"
  if ! grep -qxF -- "$ADMIN_PUBKEY" "$keys"; then
    printf '%s\n' "$ADMIN_PUBKEY" >>"$keys"
  fi
  chown "$ADMIN_USER:$ADMIN_USER" "$keys"
  chmod 600 "$keys"
  if [[ -f "$home/.bashrc" ]]; then
    sed -i 's/^#\?force_color_prompt=.*/force_color_prompt=yes/' "$home/.bashrc"
  fi

  log "SSH: preparo la configurazione (verrà attivata e verificata alla fine)"
  render_template "$VPS_TEMPLATES/sshd-10-vps.conf.tmpl" "$VPS_ROOT/sshd-10-vps.conf" 644 root:root \
    SSH_PORT ROOT_LOGIN SSH_ALLOW_USERS
}
```

- [ ] **Step 6: Verificare che passino**

Run: `wsl -d Debian -- bash tests/run.sh tests/steps.bats tests/template.bats`
Expected: tutti PASS.

- [ ] **Step 7: Commit**

```bash
git add steps/10-system.sh steps/20-user-ssh.sh templates/chrony-vps.sources templates/apt-52vps-unattended templates/apt-20auto-upgrades templates/sshd-10-vps.conf.tmpl tests/steps.bats
git commit -m "feat(steps): base system and admin user"
```

---

### Task 15: Step 30 — firewall e fail2ban SSH

**Files:**
- Create: `steps/30-firewall.sh`, `templates/jail-sshd.local.tmpl`
- Test: `tests/steps.bats` (aggiungere un test)

**Interfaces:**
- Consumes: `apt_install`, `cf_apply_ips`, `write_file`, `render_template`, risposte `SSH_PORT CF_ENABLED CF_LOCK_ORIGIN`.
- Produces: UFW attivo con regole `ssh-installer` (22, rimossa nello step 99), `ssh`, `http`/`https` oppure `cloudflare`; `$NGINX_SNIPPETS/cloudflare-realip.conf` sempre presente (vuoto senza Cloudflare); jail `/etc/fail2ban/jail.d/vps-sshd.local`.

- [ ] **Step 1: Test che fallisce**

Aggiungere a `tests/steps.bats`:
```bash
@test "jail sshd sulla porta scelta con backend systemd" {
  SSH_PORT=41822
  render_template "$REPO_ROOT/templates/jail-sshd.local.tmpl" "$BATS_TEST_TMPDIR/jail" 644 "$(id -un):$(id -gn)" SSH_PORT
  grep -qE '^port += 41822$' "$BATS_TEST_TMPDIR/jail"
  grep -qE '^backend += systemd$' "$BATS_TEST_TMPDIR/jail"
}
```

- [ ] **Step 2: Verificare che fallisca**

Run: `wsl -d Debian -- bash tests/run.sh tests/steps.bats`
Expected: FAIL (template mancante)

- [ ] **Step 3: Implementazione**

`templates/jail-sshd.local.tmpl`:
```
# vps-installer
[sshd]
enabled  = true
port     = ${SSH_PORT}
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
bantime.increment = true
```

`steps/30-firewall.sh`:
```bash
# shellcheck shell=bash
# Firewall UFW e fail2ban per SSH. Le jail Nginx arrivano con lo step 40.

step_main() {
  apt_install ufw fail2ban python3-systemd nftables

  log "Firewall: UFW"
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow 22/tcp comment ssh-installer >/dev/null
  ufw allow "$SSH_PORT/tcp" comment ssh >/dev/null

  mkdir -p "$NGINX_SNIPPETS"
  if is_yes "$CF_ENABLED" && is_yes "$CF_LOCK_ORIGIN"; then
    ufw delete allow 80/tcp >/dev/null 2>&1 || true
    ufw delete allow 443/tcp >/dev/null 2>&1 || true
  else
    ufw allow 80/tcp comment http >/dev/null
    ufw allow 443/tcp comment https >/dev/null
  fi
  if is_yes "$CF_ENABLED"; then
    log "Firewall: IP Cloudflare (real_ip$(is_yes "$CF_LOCK_ORIGIN" && echo ' + blocco origine'))"
    cf_apply_ips "$CF_LOCK_ORIGIN"
  else
    echo "# Cloudflare non attivo" | write_file "$NGINX_SNIPPETS/cloudflare-realip.conf" 644 root:root
  fi
  ufw --force enable >/dev/null

  log "Firewall: fail2ban per SSH sulla porta $SSH_PORT"
  render_template "$VPS_TEMPLATES/jail-sshd.local.tmpl" /etc/fail2ban/jail.d/vps-sshd.local 644 root:root SSH_PORT
  systemctl enable fail2ban >>"$VPS_LOG" 2>&1
  systemctl restart fail2ban
}
```

- [ ] **Step 4: Verificare che passino**

Run: `wsl -d Debian -- bash tests/run.sh tests/steps.bats tests/template.bats`
Expected: tutti PASS.

- [ ] **Step 5: Commit**

```bash
git add steps/30-firewall.sh templates/jail-sshd.local.tmpl tests/steps.bats
git commit -m "feat(steps): UFW, Cloudflare origin lock, fail2ban sshd"
```

---

### Task 16: Step 40 — Nginx

**Files:**
- Create: `steps/40-nginx.sh`, `templates/nginx.conf`, `templates/nginx-ssl-params.conf`, `templates/nginx-security-headers.conf`, `templates/nginx-acme.conf`, `templates/jail-nginx.local`
- Test: `tests/steps.bats` (aggiungere un test)

**Interfaces:**
- Consumes: `gpg_keyring_install`, `apt_add_repo`, `os_codename`, `apt_install`, `write_file`.
- Produces: Nginx da nginx.org attivo come `www-data`; snippet in `/etc/nginx/snippets/`: `ssl-params.conf`, `security-headers.conf`, `acme.conf`, `cloudflare-realip.conf`; `/var/www/_acme`; zona `req_limit_per_ip`; `apache2-utils` (per `htpasswd`); jail Nginx solo senza Cloudflare.

- [ ] **Step 1: Verificare i fingerprint di nginx.org**

Aprire https://nginx.org/en/linux_packages.html#Debian e confermare i fingerprint delle chiavi di firma. Attesi: `573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62`, `8540A6F18833A80E9C1653A42FD21310B49F6B46`, `9E9BE90EACBCDE69FE9B204CBCDCD8A38D88A2B3`. Aggiornare `NGINX_KEY_FPRS` se la pagina ne elenca di diversi.

- [ ] **Step 2: Test che fallisce**

Aggiungere a `tests/steps.bats`:
```bash
@test "nginx.conf: default server 444, reject handshake, real_ip incluso, utente www-data" {
  local f="$REPO_ROOT/templates/nginx.conf"
  grep -qxF 'user www-data;' "$f"
  grep -q 'return 444;' "$f"
  grep -q 'ssl_reject_handshake on;' "$f"
  grep -q 'include /etc/nginx/snippets/cloudflare-realip.conf;' "$f"
  grep -q 'limit_req_zone $binary_remote_addr zone=req_limit_per_ip' "$f"
  grep -q 'X-Content-Type-Options "nosniff"' "$REPO_ROOT/templates/nginx-security-headers.conf"
  ! grep -qi 'X-Xss-Protection' "$REPO_ROOT/templates/nginx-security-headers.conf"
  ! grep -q 'ssl_stapling' "$REPO_ROOT/templates/nginx-ssl-params.conf"
}
```

- [ ] **Step 3: Verificare che fallisca**

Run: `wsl -d Debian -- bash tests/run.sh tests/steps.bats`
Expected: FAIL (template mancanti)

- [ ] **Step 4: Template**

`templates/nginx.conf`:
```nginx
# vps-installer
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log warn;

events {
    worker_connections 1024;
    multi_accept on;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 15;
    types_hash_max_size 2048;
    server_tokens off;
    client_max_body_size 64m;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
    access_log /var/log/nginx/access.log main;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript image/svg+xml;

    # IP reali dei visitatori dietro Cloudflare (file generato, vuoto senza Cloudflare)
    include /etc/nginx/snippets/cloudflare-realip.conf;

    limit_req_zone $binary_remote_addr zone=req_limit_per_ip:10m rate=10r/s;
    limit_req_status 429;

    include /etc/nginx/conf.d/*.conf;

    # Richieste per host sconosciuti: chiudi la connessione
    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        server_name _;
        include /etc/nginx/snippets/acme.conf;
        location / {
            return 444;
        }
    }

    # HTTPS per host sconosciuti: rifiuta l'handshake (non rivela i domini ospitati)
    server {
        listen 443 ssl default_server;
        listen [::]:443 ssl default_server;
        server_name _;
        ssl_reject_handshake on;
    }
}
```

`templates/nginx-ssl-params.conf`:
```nginx
# Mozilla "intermediate" (TLS 1.2/1.3). Niente OCSP: Let's Encrypt lo ha dismesso.
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers off;
ssl_session_timeout 1d;
ssl_session_cache shared:SSL:10m;
ssl_session_tickets off;
```

`templates/nginx-security-headers.conf`:
```nginx
add_header Strict-Transport-Security "max-age=63072000" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "DENY" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
```

`templates/nginx-acme.conf`:
```nginx
location ^~ /.well-known/acme-challenge/ {
    root /var/www/_acme;
    default_type text/plain;
}
```

`templates/jail-nginx.local`:
```
# vps-installer (solo senza Cloudflare)
[nginx-limit-req]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/*error.log
backend  = auto
maxretry = 10

[nginx-botsearch]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/*error.log
backend  = auto
maxretry = 5
```

- [ ] **Step 5: Step 40**

`steps/40-nginx.sh`:
```bash
# shellcheck shell=bash
# Nginx dal repository ufficiale nginx.org.

NGINX_KEY_FPRS=(
  573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62
  8540A6F18833A80E9C1653A42FD21310B49F6B46
  9E9BE90EACBCDE69FE9B204CBCDCD8A38D88A2B3
)

step_enabled() {
  is_yes "$WANT_NGINX"
}

step_main() {
  local keyring=/usr/share/keyrings/nginx-archive-keyring.gpg tmp
  log "Nginx: repository nginx.org"
  tmp="$(mktemp)"
  curl -fsS --max-time 30 -o "$tmp" https://nginx.org/keys/nginx_signing.key
  gpg_keyring_install "$tmp" "$keyring" "${NGINX_KEY_FPRS[@]}"
  rm -f "$tmp"
  printf 'Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n' \
    | write_file /etc/apt/preferences.d/99nginx 644 root:root
  apt_add_repo nginx "$keyring" "deb [signed-by=$keyring] https://nginx.org/packages/debian $(os_codename) nginx"
  apt_install nginx apache2-utils

  log "Nginx: configurazione"
  rm -f /etc/nginx/conf.d/default.conf
  install -d -m 755 "$NGINX_SNIPPETS" /var/www /var/www/_acme
  if [[ ! -f "$NGINX_SNIPPETS/cloudflare-realip.conf" ]]; then
    echo "# Cloudflare non attivo" | write_file "$NGINX_SNIPPETS/cloudflare-realip.conf" 644 root:root
  fi
  install -m 644 "$VPS_TEMPLATES/nginx-ssl-params.conf" "$NGINX_SNIPPETS/ssl-params.conf"
  install -m 644 "$VPS_TEMPLATES/nginx-security-headers.conf" "$NGINX_SNIPPETS/security-headers.conf"
  install -m 644 "$VPS_TEMPLATES/nginx-acme.conf" "$NGINX_SNIPPETS/acme.conf"
  install -m 644 "$VPS_TEMPLATES/nginx.conf" /etc/nginx/nginx.conf
  nginx -t >>"$VPS_LOG" 2>&1
  systemctl enable nginx >>"$VPS_LOG" 2>&1
  systemctl restart nginx

  if is_yes "$CF_ENABLED"; then
    rm -f /etc/fail2ban/jail.d/vps-nginx.local
  else
    log "Nginx: jail fail2ban per Nginx"
    install -m 644 "$VPS_TEMPLATES/jail-nginx.local" /etc/fail2ban/jail.d/vps-nginx.local
  fi
  systemctl restart fail2ban
}
```

- [ ] **Step 6: Verificare che passino**

Run: `wsl -d Debian -- bash tests/run.sh tests/steps.bats tests/template.bats`
Expected: tutti PASS.

- [ ] **Step 7: Commit**

```bash
git add steps/40-nginx.sh templates/nginx.conf templates/nginx-ssl-params.conf templates/nginx-security-headers.conf templates/nginx-acme.conf templates/jail-nginx.local tests/steps.bats
git commit -m "feat(steps): nginx from nginx.org with hardened defaults"
```

---

### Task 17: Step 50 (PHP), 60 (MariaDB), 70 (Redis), 75 (email), 80 (SSL)

**Files:**
- Create: `steps/50-php.sh`, `steps/60-mariadb.sh`, `steps/70-redis.sh`, `steps/75-mail.sh`, `steps/80-ssl.sh`, `templates/php-90-vps.ini`, `templates/mariadb-90-vps.cnf`, `templates/certbot-reload-nginx.sh`
- Test: `tests/steps.bats` (il test generico copre i nuovi step)

**Interfaces:**
- Consumes: `gpg_keyring_install`, `apt_add_repo`, `os_codename`, `sql_secure_installation`, `mail_render_config`, `ssl_obtain_cert`, `write_file`.
- Produces: PHP-FPM `php8.4-fpm` attivo (pool `www` ancora presente); MariaDB solo su 127.0.0.1, sicura; Redis su localhost; msmtp installato (configurato solo con `MAIL_ENABLED=yes`); `/opt/vps/secrets/cloudflare.ini` (con Cloudflare); certificato `/etc/letsencrypt/live/$PANEL_DOMAIN/` (con pannello); deploy hook che ricarica Nginx.

- [ ] **Step 1: Verificare il fingerprint di sury**

Aprire https://packages.sury.org/php/README.txt (o la pagina del progetto) e confermare il fingerprint della chiave del repository. Atteso: `15058500A0235D97F5D10063B188E2B695BD4743`. Aggiornare `SURY_KEY_FPRS` se diverso.

- [ ] **Step 2: Template**

`templates/php-90-vps.ini`:
```ini
; vps-installer
upload_max_filesize = 64M
post_max_size = 64M
memory_limit = 256M
expose_php = Off
cgi.fix_pathinfo = 0
```

`templates/mariadb-90-vps.cnf`:
```ini
# vps-installer
[mysqld]
bind-address = 127.0.0.1
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
```

`templates/certbot-reload-nginx.sh`:
```bash
#!/bin/sh
# Ricarica Nginx dopo ogni rinnovo dei certificati.
nginx -t && systemctl reload nginx
```

- [ ] **Step 3: Step 50**

`steps/50-php.sh`:
```bash
# shellcheck shell=bash
# PHP 8.4 dal repository sury.

SURY_KEY_FPRS=(15058500A0235D97F5D10063B188E2B695BD4743)

step_enabled() {
  is_yes "$WANT_PHP"
}

step_main() {
  local keyring=/usr/share/keyrings/sury-php.gpg tmp p="php$PHP_VERSION"
  log "PHP: repository packages.sury.org"
  tmp="$(mktemp)"
  curl -fsS --max-time 30 -o "$tmp" https://packages.sury.org/php/apt.gpg
  gpg_keyring_install "$tmp" "$keyring" "${SURY_KEY_FPRS[@]}"
  rm -f "$tmp"
  apt_add_repo php "$keyring" "deb [signed-by=$keyring] https://packages.sury.org/php/ $(os_codename) main"

  log "PHP: installo PHP $PHP_VERSION"
  apt_install "$p-fpm" "$p-cli" "$p-common" "$p-mysql" "$p-xml" "$p-curl" "$p-gd" "$p-imagick" \
    "$p-intl" "$p-mbstring" "$p-opcache" "$p-redis" "$p-soap" "$p-zip"
  install -m 644 "$VPS_TEMPLATES/php-90-vps.ini" "/etc/php/$PHP_VERSION/fpm/conf.d/90-vps.ini"
  install -m 644 "$VPS_TEMPLATES/php-90-vps.ini" "/etc/php/$PHP_VERSION/cli/conf.d/90-vps.ini"
  "php-fpm$PHP_VERSION" -t >>"$VPS_LOG" 2>&1
  systemctl enable "$p-fpm" >>"$VPS_LOG" 2>&1
  systemctl restart "$p-fpm"
}
```

- [ ] **Step 4: Step 60**

`steps/60-mariadb.sh`:
```bash
# shellcheck shell=bash
# MariaDB dal repository Debian, messa in sicurezza.

step_enabled() {
  is_yes "$WANT_MARIADB"
}

step_main() {
  log "MariaDB: installazione"
  apt_install mariadb-server mariadb-client
  install -m 644 "$VPS_TEMPLATES/mariadb-90-vps.cnf" /etc/mysql/mariadb.conf.d/90-vps.cnf
  systemctl enable mariadb >>"$VPS_LOG" 2>&1
  systemctl restart mariadb
  log "MariaDB: messa in sicurezza (root solo via unix_socket)"
  sql_secure_installation "$(hostname)" | mariadb
}
```

- [ ] **Step 5: Step 70**

`steps/70-redis.sh`:
```bash
# shellcheck shell=bash
# Redis solo su localhost.

step_enabled() {
  is_yes "$WANT_REDIS"
}

step_main() {
  log "Redis: installazione"
  apt_install redis-server
  local conf=/etc/redis/redis.conf
  sed -i -E 's/^#? *bind .*/bind 127.0.0.1 -::1/' "$conf"
  sed -i -E 's/^#? *protected-mode .*/protected-mode yes/' "$conf"
  systemctl enable redis-server >>"$VPS_LOG" 2>&1
  systemctl restart redis-server
}
```

- [ ] **Step 6: Step 75**

`steps/75-mail.sh`:
```bash
# shellcheck shell=bash
# msmtp: installato sempre, configurato solo se richiesto (altrimenti dal pannello).

step_main() {
  echo "msmtp msmtp/apparmor boolean false" | debconf-set-selections
  apt_install msmtp msmtp-mta
  if is_yes "$MAIL_ENABLED"; then
    log "Email: configuro msmtp ($SMTP_HOST:$SMTP_PORT)"
    mail_render_config
  else
    log "Email: da configurare dal pannello"
  fi
}
```

- [ ] **Step 7: Step 80**

`steps/80-ssl.sh`:
```bash
# shellcheck shell=bash
# Certbot (Debian) e certificato del dominio del pannello.

step_enabled() {
  is_yes "$WANT_CERTBOT"
}

step_main() {
  log "SSL: installo certbot"
  apt_install certbot python3-certbot-dns-cloudflare
  install -D -m 755 "$VPS_TEMPLATES/certbot-reload-nginx.sh" /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
  if is_yes "$CF_ENABLED"; then
    printf 'dns_cloudflare_api_token = %s\n' "$CF_API_TOKEN" \
      | write_file "$VPS_OPT/secrets/cloudflare.ini" 600 root:root
  fi
  if is_yes "$PANEL_ENABLED"; then
    ssl_obtain_cert "$PANEL_DOMAIN"
  fi
}
```

- [ ] **Step 8: Verificare che passino**

Run: `wsl -d Debian -- bash tests/run.sh tests/steps.bats tests/template.bats`
Expected: tutti PASS, shellcheck pulito.

- [ ] **Step 9: Commit**

```bash
git add steps/50-php.sh steps/60-mariadb.sh steps/70-redis.sh steps/75-mail.sh steps/80-ssl.sh templates/php-90-vps.ini templates/mariadb-90-vps.cnf templates/certbot-reload-nginx.sh
git commit -m "feat(steps): PHP, MariaDB, Redis, mail, certbot"
```

---

### Task 18: Step 85 — dominio del pannello

**Files:**
- Create: `steps/85-panel.sh`, `templates/php-pool-panel.conf.tmpl`, `templates/nginx-panel.conf.tmpl`, `templates/panel-placeholder.html`
- Test: `tests/steps.bats` (aggiungere un test)

**Interfaces:**
- Consumes: `env_get`, `rand_secret`, `sql_db_with_user`, `sql_user_grant`, `render_template`, `write_file`, `cf_upsert_record`, `server_ipv4`, `server_ipv6`, `summary_set`, risposte `PANEL_DOMAIN PANEL_ROOT CF_ENABLED CF_ZONE_ID CF_API_TOKEN`.
- Produces: utente di sistema `panel`; struttura `$PANEL_ROOT/{public,app,config,storage/{sessions,tmp,pma-tmp},logs}`; `$PANEL_ROOT/config/.env` con `DB_HOST DB_NAME DB_USER DB_PASS DBADMIN_USER DBADMIN_PASS`; pool `/etc/php/8.4/fpm/pool.d/panel.conf` (socket `/run/php/php8.4-fpm-panel.sock`); pool `www` disattivato; vhost `/etc/nginx/conf.d/$PANEL_DOMAIN.conf` che include `/etc/nginx/snippets/panel.d/*.conf`; `summary_set PANEL_DBADMIN_PASS` alla prima creazione.

- [ ] **Step 1: Test che fallisce**

Aggiungere a `tests/steps.bats`:
```bash
@test "vhost e pool del pannello" {
  PANEL_DOMAIN=panel.miosito.it PANEL_ROOT=/var/www/panel.miosito.it
  render_template "$REPO_ROOT/templates/nginx-panel.conf.tmpl" "$BATS_TEST_TMPDIR/vhost" 644 "$(id -un):$(id -gn)" PANEL_DOMAIN PANEL_ROOT PHP_VERSION
  grep -q 'server_name panel.miosito.it;' "$BATS_TEST_TMPDIR/vhost"
  grep -q 'ssl_certificate /etc/letsencrypt/live/panel.miosito.it/fullchain.pem;' "$BATS_TEST_TMPDIR/vhost"
  grep -q 'root /var/www/panel.miosito.it/public;' "$BATS_TEST_TMPDIR/vhost"
  grep -q 'include /etc/nginx/snippets/panel.d/\*.conf;' "$BATS_TEST_TMPDIR/vhost"
  grep -q 'limit_req zone=req_limit_per_ip' "$BATS_TEST_TMPDIR/vhost"
  grep -q 'return 301 https://$host$request_uri;' "$BATS_TEST_TMPDIR/vhost"
  render_template "$REPO_ROOT/templates/php-pool-panel.conf.tmpl" "$BATS_TEST_TMPDIR/pool" 644 "$(id -un):$(id -gn)" PANEL_ROOT PHP_VERSION VPS_OPT
  grep -qxF 'listen = /run/php/php8.4-fpm-panel.sock' "$BATS_TEST_TMPDIR/pool"
  grep -q "open_basedir\] = /var/www/panel.miosito.it/:$VPS_OPT/phpmyadmin/:$VPS_OPT/manifest.json" "$BATS_TEST_TMPDIR/pool"
}
```

- [ ] **Step 2: Verificare che fallisca**

Run: `wsl -d Debian -- bash tests/run.sh tests/steps.bats`
Expected: FAIL (template mancanti)

- [ ] **Step 3: Template**

`templates/php-pool-panel.conf.tmpl`:
```ini
; vps-installer: pool del pannello
[panel]
user = panel
group = panel
listen = /run/php/php${PHP_VERSION}-fpm-panel.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = ondemand
pm.max_children = 10
pm.process_idle_timeout = 30s
pm.max_requests = 500
php_admin_value[open_basedir] = ${PANEL_ROOT}/:${VPS_OPT}/phpmyadmin/:${VPS_OPT}/manifest.json
php_admin_value[session.save_path] = ${PANEL_ROOT}/storage/sessions
php_admin_value[upload_tmp_dir] = ${PANEL_ROOT}/storage/tmp
php_admin_value[sys_temp_dir] = ${PANEL_ROOT}/storage/tmp
php_admin_value[error_log] = ${PANEL_ROOT}/logs/php-error.log
php_admin_flag[log_errors] = on
php_admin_flag[display_errors] = off
```

`templates/nginx-panel.conf.tmpl`:
```nginx
# vps-installer: pannello
server {
    listen 80;
    listen [::]:80;
    server_name ${PANEL_DOMAIN};
    include /etc/nginx/snippets/acme.conf;
    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${PANEL_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${PANEL_DOMAIN}/privkey.pem;
    include /etc/nginx/snippets/ssl-params.conf;
    include /etc/nginx/snippets/security-headers.conf;

    root ${PANEL_ROOT}/public;
    index index.php index.html;

    access_log /var/log/nginx/${PANEL_DOMAIN}.access.log main;
    error_log /var/log/nginx/${PANEL_DOMAIN}.error.log error;

    limit_req zone=req_limit_per_ip burst=20 nodelay;

    location ~ /\.(?!well-known) {
        deny all;
    }

    # Estensioni del pannello (es. phpMyAdmin)
    include /etc/nginx/snippets/panel.d/*.conf;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        try_files $uri =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm-panel.sock;
    }
}
```

`templates/panel-placeholder.html`:
```html
<!doctype html>
<html lang="it">
<head><meta charset="utf-8"><meta name="robots" content="noindex"><title>Pannello</title></head>
<body style="font-family:system-ui,sans-serif;max-width:40rem;margin:4rem auto;padding:0 1rem">
<h1>Pannello in arrivo</h1>
<p>Il server è pronto. Il codice del pannello non è ancora installato.</p>
</body>
</html>
```

- [ ] **Step 4: Step 85**

`steps/85-panel.sh`:
```bash
# shellcheck shell=bash
# Dominio del pannello: utente, cartelle, DB, pool PHP, DNS Cloudflare, vhost.

step_enabled() {
  is_yes "$PANEL_ENABLED"
}

panel_user_and_dirs() {
  if ! id panel >/dev/null 2>&1; then
    useradd --system --home-dir "$PANEL_ROOT" --no-create-home --shell /usr/sbin/nologin --user-group panel
  fi
  usermod -aG panel www-data
  install -d -m 750 -o panel -g panel "$PANEL_ROOT" "$PANEL_ROOT/public" "$PANEL_ROOT/app" \
    "$PANEL_ROOT/config" "$PANEL_ROOT/logs"
  install -d -m 700 -o panel -g panel "$PANEL_ROOT/storage" "$PANEL_ROOT/storage/sessions" \
    "$PANEL_ROOT/storage/tmp" "$PANEL_ROOT/storage/pma-tmp"
  if [[ ! -e "$PANEL_ROOT/public/index.php" && ! -e "$PANEL_ROOT/public/index.html" ]]; then
    install -m 640 -o panel -g panel "$VPS_TEMPLATES/panel-placeholder.html" "$PANEL_ROOT/public/index.html"
  fi
}

panel_database() {
  local env="$PANEL_ROOT/config/.env" db_pass admin_pass
  db_pass="$(env_get "$env" DB_PASS)"
  admin_pass="$(env_get "$env" DBADMIN_PASS)"
  if [[ -z "$db_pass" ]]; then db_pass="$(rand_secret 32)"; fi
  if [[ -z "$admin_pass" ]]; then
    admin_pass="$(rand_secret 24)"
    summary_set PANEL_DBADMIN_PASS "$admin_pass"
  fi
  {
    sql_db_with_user panel panel "$db_pass"
    sql_user_grant panel_dbadmin "$admin_pass" "ALL PRIVILEGES" '`site\_%`.*'
    echo "FLUSH PRIVILEGES;"
  } | mariadb
  printf 'DB_HOST=localhost\nDB_NAME=panel\nDB_USER=panel\nDB_PASS=%s\nDBADMIN_USER=panel_dbadmin\nDBADMIN_PASS=%s\n' \
    "$db_pass" "$admin_pass" | write_file "$env" 600 panel:panel
}

panel_php_pool() {
  local pool_dir="/etc/php/$PHP_VERSION/fpm/pool.d"
  render_template "$VPS_TEMPLATES/php-pool-panel.conf.tmpl" "$pool_dir/panel.conf" 644 root:root \
    PANEL_ROOT PHP_VERSION VPS_OPT
  if [[ -f "$pool_dir/www.conf" ]]; then
    mv "$pool_dir/www.conf" "$pool_dir/www.conf.disabled"
  fi
  "php-fpm$PHP_VERSION" -t >>"$VPS_LOG" 2>&1
  systemctl restart "php$PHP_VERSION-fpm"
}

panel_dns() {
  local v6
  is_yes "$CF_ENABLED" || return 0
  log "Pannello: record DNS su Cloudflare"
  cf_upsert_record "$CF_ZONE_ID" A "$PANEL_DOMAIN" "$(server_ipv4)" || die "Record A su Cloudflare non creato"
  v6="$(server_ipv6)"
  if [[ -n "$v6" ]]; then
    cf_upsert_record "$CF_ZONE_ID" AAAA "$PANEL_DOMAIN" "$v6" || die "Record AAAA su Cloudflare non creato"
  fi
}

panel_vhost() {
  install -d -m 755 "$NGINX_SNIPPETS/panel.d"
  render_template "$VPS_TEMPLATES/nginx-panel.conf.tmpl" "/etc/nginx/conf.d/$PANEL_DOMAIN.conf" 644 root:root \
    PANEL_DOMAIN PANEL_ROOT PHP_VERSION
  nginx -t >>"$VPS_LOG" 2>&1
  systemctl reload nginx
}

step_main() {
  log "Pannello: preparo $PANEL_DOMAIN"
  panel_user_and_dirs
  panel_database
  panel_php_pool
  panel_dns
  panel_vhost
}
```

- [ ] **Step 5: Verificare che passino**

Run: `wsl -d Debian -- bash tests/run.sh tests/steps.bats tests/template.bats`
Expected: tutti PASS.

- [ ] **Step 6: Commit**

```bash
git add steps/85-panel.sh templates/php-pool-panel.conf.tmpl templates/nginx-panel.conf.tmpl templates/panel-placeholder.html tests/steps.bats
git commit -m "feat(steps): panel domain with isolated user, pool, DB and vhost"
```

---

### Task 19: Step 90 — phpMyAdmin

**Files:**
- Create: `steps/90-phpmyadmin.sh`, `templates/pma-config.inc.php.tmpl`, `templates/nginx-pma.conf.tmpl`
- Test: `tests/steps.bats` (aggiungere un test)

**Interfaces:**
- Consumes: `pma_latest_version`, `pma_update_to`, `pma_installed_version`, `pma_controlpass_from_config`, `pma_set_basic_auth`, `sql_user_grant`, `rand_secret`, `render_template`, `summary_set`, `PMA_DIR`, `HTPASSWD_PMA`.
- Produces: `/opt/vps/phpmyadmin` (root:panel, 750/640), `config.inc.php`, DB `phpmyadmin` + utente `pma`, `/etc/nginx/.htpasswd-pma` (utente = `ADMIN_USER`), `/etc/nginx/snippets/panel.d/pma.conf`; `summary_set PMA_BASIC_PASS` alla prima creazione.

- [ ] **Step 1: Test che fallisce**

Aggiungere a `tests/steps.bats`:
```bash
@test "configurazione phpMyAdmin e location nginx" {
  PMA_BLOWFISH=abcdefghijklmnopqrstuvwxyz012345 PMA_CONTROL_PASS=Ctrl123 PANEL_ROOT=/var/www/panel.miosito.it PANEL_DOMAIN=panel.miosito.it
  render_template "$REPO_ROOT/templates/pma-config.inc.php.tmpl" "$BATS_TEST_TMPDIR/cfg" 640 "$(id -un):$(id -gn)" PMA_BLOWFISH PMA_CONTROL_PASS PANEL_ROOT PANEL_DOMAIN
  grep -q "\['controlpass'\] = 'Ctrl123';" "$BATS_TEST_TMPDIR/cfg"
  grep -q "\['AllowRoot'\] = false;" "$BATS_TEST_TMPDIR/cfg"
  grep -q "TempDir'\] = '/var/www/panel.miosito.it/storage/pma-tmp';" "$BATS_TEST_TMPDIR/cfg"
  render_template "$REPO_ROOT/templates/nginx-pma.conf.tmpl" "$BATS_TEST_TMPDIR/pma" 644 "$(id -un):$(id -gn)" VPS_OPT PHP_VERSION
  grep -q 'auth_basic_user_file /etc/nginx/.htpasswd-pma;' "$BATS_TEST_TMPDIR/pma"
  grep -q 'fastcgi_param SCRIPT_FILENAME $request_filename;' "$BATS_TEST_TMPDIR/pma"
  grep -q "alias $VPS_OPT/phpmyadmin/;" "$BATS_TEST_TMPDIR/pma"
}
```

Aggiungere anche `PANEL_DOMAIN` ai template ammessi: è già in `ANSWER_VARS`, nessuna modifica a `KNOWN_TEMPLATE_VARS`.

- [ ] **Step 2: Verificare che fallisca**

Run: `wsl -d Debian -- bash tests/run.sh tests/steps.bats`
Expected: FAIL (template mancanti)

- [ ] **Step 3: Template**

`templates/pma-config.inc.php.tmpl`:
```php
<?php
// vps-installer: configurazione phpMyAdmin (conservata dagli aggiornamenti).
declare(strict_types=1);

$cfg['blowfish_secret'] = '${PMA_BLOWFISH}';

$i = 0;
$i++;
$cfg['Servers'][$i]['auth_type'] = 'cookie';
$cfg['Servers'][$i]['host'] = 'localhost';
$cfg['Servers'][$i]['AllowNoPassword'] = false;
$cfg['Servers'][$i]['AllowRoot'] = false;

$cfg['Servers'][$i]['controluser'] = 'pma';
$cfg['Servers'][$i]['controlpass'] = '${PMA_CONTROL_PASS}';
$cfg['Servers'][$i]['pmadb'] = 'phpmyadmin';
$cfg['Servers'][$i]['bookmarktable'] = 'pma__bookmark';
$cfg['Servers'][$i]['relation'] = 'pma__relation';
$cfg['Servers'][$i]['table_info'] = 'pma__table_info';
$cfg['Servers'][$i]['table_coords'] = 'pma__table_coords';
$cfg['Servers'][$i]['pdf_pages'] = 'pma__pdf_pages';
$cfg['Servers'][$i]['column_info'] = 'pma__column_info';
$cfg['Servers'][$i]['history'] = 'pma__history';
$cfg['Servers'][$i]['table_uiprefs'] = 'pma__table_uiprefs';
$cfg['Servers'][$i]['tracking'] = 'pma__tracking';
$cfg['Servers'][$i]['userconfig'] = 'pma__userconfig';
$cfg['Servers'][$i]['recent'] = 'pma__recent';
$cfg['Servers'][$i]['favorite'] = 'pma__favorite';
$cfg['Servers'][$i]['users'] = 'pma__users';
$cfg['Servers'][$i]['usergroups'] = 'pma__usergroups';
$cfg['Servers'][$i]['navigationhiding'] = 'pma__navigationhiding';
$cfg['Servers'][$i]['savedsearches'] = 'pma__savedsearches';
$cfg['Servers'][$i]['central_columns'] = 'pma__central_columns';
$cfg['Servers'][$i]['designer_settings'] = 'pma__designer_settings';
$cfg['Servers'][$i]['export_templates'] = 'pma__export_templates';

$cfg['TempDir'] = '${PANEL_ROOT}/storage/pma-tmp';
$cfg['PmaAbsoluteUri'] = 'https://${PANEL_DOMAIN}/pma/';
$cfg['VersionCheck'] = false;
```

`templates/nginx-pma.conf.tmpl`:
```nginx
# vps-installer: phpMyAdmin solo sul dominio del pannello
location = /pma {
    return 301 /pma/;
}

location ^~ /pma/ {
    alias ${VPS_OPT}/phpmyadmin/;
    index index.php;
    auth_basic "Area riservata";
    auth_basic_user_file /etc/nginx/.htpasswd-pma;

    location ~ ^/pma/(libraries|templates|vendor|sql|src|setup)/ {
        deny all;
    }
    location ~ ^/pma/config\.inc\.php$ {
        deny all;
    }
    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $request_filename;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm-panel.sock;
    }
}
```

- [ ] **Step 4: Step 90**

`steps/90-phpmyadmin.sh`:
```bash
# shellcheck shell=bash
# phpMyAdmin: ultima versione verificata, servita solo su <pannello>/pma/.

step_enabled() {
  is_yes "$WANT_PMA"
}

pma_install_or_update() {
  local latest current
  latest="$(pma_latest_version)" || die "Impossibile leggere l'ultima versione di phpMyAdmin"
  current="$(pma_installed_version)"
  if [[ "$current" == "$latest" ]]; then
    log "phpMyAdmin: versione $current già installata"
  else
    pma_update_to "$latest"
  fi
}

pma_configure() {
  PMA_CONTROL_PASS="$(pma_controlpass_from_config)"
  if [[ -z "$PMA_CONTROL_PASS" ]]; then
    PMA_CONTROL_PASS="$(rand_secret 32)"
    PMA_BLOWFISH="$(rand_secret 32)"
    render_template "$VPS_TEMPLATES/pma-config.inc.php.tmpl" "$PMA_DIR/config.inc.php" 640 root:panel \
      PMA_BLOWFISH PMA_CONTROL_PASS PANEL_ROOT PANEL_DOMAIN
  fi
  mariadb <"$PMA_DIR/sql/create_tables.sql"
  {
    sql_user_grant pma "$PMA_CONTROL_PASS" "SELECT, INSERT, UPDATE, DELETE" '`phpmyadmin`.*'
    echo "FLUSH PRIVILEGES;"
  } | mariadb
}

pma_web_access() {
  local pass
  if [[ ! -f "$HTPASSWD_PMA" ]]; then
    pass="$(rand_secret 20)"
    printf '%s' "$pass" | pma_set_basic_auth "$ADMIN_USER"
    summary_set PMA_BASIC_PASS "$pass"
  fi
  render_template "$VPS_TEMPLATES/nginx-pma.conf.tmpl" "$NGINX_SNIPPETS/panel.d/pma.conf" 644 root:root \
    VPS_OPT PHP_VERSION
  nginx -t >>"$VPS_LOG" 2>&1
  systemctl reload nginx
}

step_main() {
  log "phpMyAdmin: installazione"
  apt_install xz-utils
  install -d -m 755 "$VPS_OPT"
  pma_install_or_update
  pma_configure
  pma_web_access
}
```

- [ ] **Step 5: Verificare che passino**

Run: `wsl -d Debian -- bash tests/run.sh tests/steps.bats tests/template.bats`
Expected: tutti PASS.

- [ ] **Step 6: Commit**

```bash
git add steps/90-phpmyadmin.sh templates/pma-config.inc.php.tmpl templates/nginx-pma.conf.tmpl tests/steps.bats
git commit -m "feat(steps): verified phpMyAdmin on panel domain only"
```

---

### Task 20: Script wrapper (`tools/`) e step 95

**Files:**
- Create: `tools/vps-status`, `tools/vps-cf-token`, `tools/vps-cf-ips-update`, `tools/vps-smtp`, `tools/vps-pma-pass`, `tools/vps-pma-update`, `steps/95-vps-tools.sh`, `templates/sudoers-vps-panel`, `templates/cron-vps`
- Test: `tests/tools.bats`

**Interfaces:**
- Consumes: tutte le `lib/*.sh` (da `${VPS_LIB:-$VPS_OPT/lib}`), `tool_init`, `json_ok`, `json_err`, `manifest_*`, `cf_*`, `mail_*`, `pma_*`, validatori.
- Produces: comandi in `/opt/vps/bin` come da `PANEL-HANDOFF.md` sez. 4 (output JSON, segreti da stdin); `/opt/vps/lib`, `/opt/vps/templates`, `/opt/vps/manifest.json`; `/etc/sudoers.d/vps-panel` (solo con pannello); `/etc/cron.d/vps` (solo con Cloudflare).

- [ ] **Step 1: Test che falliscono**

`tests/tools.bats`:
```bash
setup() {
  load test_helper
  setup_common
  export VPS_LIB="$REPO_ROOT/lib" MSMTPRC_LINK="$BATS_TEST_TMPDIR/msmtprc" ALIASES_FILE="$BATS_TEST_TMPDIR/aliases"
  T="$REPO_ROOT/tools"
  jq -n '{admin_user:"manu", cloudflare:{enabled:true, origin_locked:false, zone:"miosito.it"}, mail:{configured:false}, components:{phpmyadmin:"5.2.3"}}' >"$VPS_OPT/manifest.json"
}

@test "vps-status restituisce JSON valido" {
  make_stub systemctl 'echo active'
  make_stub apt 'printf "Listing...\nnginx/stable 1.28 amd64 [upgradable from: 1.27]\n"'
  run bash "$T/vps-status"
  [ "$status" -eq 0 ]
  [ "$(jq -r .ok <<<"$output")" = true ]
  [ "$(jq -r .services.nginx <<<"$output")" = active ]
  [ "$(jq -r .updates.upgradable <<<"$output")" = 1 ]
  jq -e '.disk.total > 0' <<<"$output"
}

@test "vps-cf-token rifiuta token malformati senza chiamare Cloudflare" {
  make_stub curl 'echo chiamato >>"$BATS_TEST_TMPDIR/curl.called"'
  run bash -c "printf 'corto' | bash '$T/vps-cf-token' set"
  [ "$status" -eq 1 ]
  [ "$(jq -r .ok <<<"$output")" = false ]
  [ ! -f "$BATS_TEST_TMPDIR/curl.called" ]
}

@test "vps-cf-token senza azione valida" {
  run bash "$T/vps-cf-token" boh
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == uso:* ]]
}

@test "vps-smtp set scrive la configurazione e aggiorna il manifest" {
  run bash -c "printf '%s' '{\"host\":\"smtp.gmail.com\",\"port\":587,\"user\":\"manu@gmail.com\",\"pass\":\"app pass\",\"from\":\"manu@gmail.com\",\"alert_email\":\"avvisi@gmail.com\"}' | bash '$T/vps-smtp' set"
  [ "$status" -eq 0 ]
  grep -qxF 'host smtp.gmail.com' "$VPS_OPT/secrets/msmtprc"
  [ "$(jq -r .mail.configured "$VPS_OPT/manifest.json")" = true ]
  [ "$(jq -r .mail.alert_email "$VPS_OPT/manifest.json")" = avvisi@gmail.com ]
}

@test "vps-smtp set rifiuta input non valido" {
  run bash -c "printf '%s' '{\"host\":\"smtp gmail\",\"port\":587}' | bash '$T/vps-smtp' set"
  [ "$status" -eq 1 ]
  [ "$(jq -r .ok <<<"$output")" = false ]
  [ ! -f "$VPS_OPT/secrets/msmtprc" ]
}

@test "vps-pma-pass rifiuta password corte" {
  run bash -c "printf 'corta' | bash '$T/vps-pma-pass' set"
  [ "$status" -eq 1 ]
  [[ "$(jq -r .error <<<"$output")" == *"12 caratteri"* ]]
}

@test "vps-pma-update non fa nulla se già aggiornato" {
  export PMA_DIR="$VPS_OPT/phpmyadmin"
  mkdir -p "$PMA_DIR/libraries/classes"
  printf "    public const VERSION = '5.2.3' . VERSION_SUFFIX;\n" >"$PMA_DIR/libraries/classes/Version.php"
  make_stub curl 'echo "{\"version\":\"5.2.3\"}"'
  run bash "$T/vps-pma-update"
  [ "$status" -eq 0 ]
  [ "$(jq -r .updated <<<"$output")" = false ]
}

@test "il sudoers elenca solo gli script wrapper" {
  run grep -c '/opt/vps/bin/vps-' "$REPO_ROOT/templates/sudoers-vps-panel"
  [ "$output" -ge 1 ]
  ! grep -q 'ALL$' "$REPO_ROOT/templates/sudoers-vps-panel"
}
```

- [ ] **Step 2: Verificare che falliscano**

Run: `wsl -d Debian -- bash tests/run.sh tests/tools.bats`
Expected: FAIL (script mancanti)

- [ ] **Step 3: Intestazione comune degli script**

Ogni file in `tools/` inizia con queste righe (poi il codice specifico):
```bash
#!/usr/bin/env bash
: "${VPS_OPT:=/opt/vps}" "${VPS_LOG:=/var/log/vps-tools.log}"
: "${VPS_TEMPLATES:=$VPS_OPT/templates}"
for _lib in "${VPS_LIB:-$VPS_OPT/lib}"/*.sh; do
  source "$_lib"
done
tool_init
```

- [ ] **Step 4: `tools/vps-status`**

```bash
#!/usr/bin/env bash
# vps-status — stato del server in JSON.
: "${VPS_OPT:=/opt/vps}" "${VPS_LOG:=/var/log/vps-tools.log}"
: "${VPS_TEMPLATES:=$VPS_OPT/templates}"
for _lib in "${VPS_LIB:-$VPS_OPT/lib}"/*.sh; do
  source "$_lib"
done
tool_init

services='{}'
for s in nginx "php$PHP_VERSION-fpm" mariadb redis-server fail2ban; do
  st="$(systemctl is-active "$s" 2>/dev/null || true)"
  services="$(jq -c --arg k "$s" --arg v "${st:-unknown}" '. + {($k): $v}' <<<"$services")"
done
read -r dsize dused davail < <(df -B1 --output=size,used,avail / | tail -n 1)
read -r mtotal mused mavail < <(free -b | awk '/^Mem:/ { print $2, $3, $7 }')
read -r l1 l5 l15 _ </proc/loadavg
up="$(cut -d' ' -f1 /proc/uptime)"
upg="$(apt list --upgradable 2>/dev/null | grep -c 'upgradable from' || true)"
reboot=false
if [[ -f /var/run/reboot-required ]]; then
  reboot=true
fi

json_ok --argjson services "$services" \
  --argjson dsize "$dsize" --argjson dused "$dused" --argjson davail "$davail" \
  --argjson mtotal "$mtotal" --argjson mused "$mused" --argjson mavail "$mavail" \
  --argjson l1 "$l1" --argjson l5 "$l5" --argjson l15 "$l15" \
  --argjson up "${up%.*}" --argjson upg "${upg:-0}" --argjson reboot "$reboot" \
  '{ok: true, services: $services,
    disk: {total: $dsize, used: $dused, available: $davail},
    memory: {total: $mtotal, used: $mused, available: $mavail},
    load: [$l1, $l5, $l15], uptime_seconds: $up,
    updates: {upgradable: $upg, reboot_required: $reboot}}'
```

- [ ] **Step 5: `tools/vps-cf-token`**

```bash
#!/usr/bin/env bash
# vps-cf-token set|test — sostituisce (token da stdin) o verifica il token Cloudflare.
: "${VPS_OPT:=/opt/vps}" "${VPS_LOG:=/var/log/vps-tools.log}"
: "${VPS_TEMPLATES:=$VPS_OPT/templates}"
for _lib in "${VPS_LIB:-$VPS_OPT/lib}"/*.sh; do
  source "$_lib"
done
tool_init

zone="$(jq -r '.cloudflare.zone // empty' "$(manifest_path)")"
case "${1:-}" in
  set)
    token="$(trim "$(read_stdin_limited 512)")"
    valid_cf_token "$token" || json_err "formato del token non valido"
    [[ -n "$zone" ]] || json_err "Cloudflare non è attivo su questa VPS"
    CF_API_TOKEN="$token" cf_find_zone "$zone" >/dev/null || json_err "il token non ha accesso alla zona $zone"
    printf 'dns_cloudflare_api_token = %s\n' "$token" \
      | write_file "$VPS_OPT/secrets/cloudflare.ini" 600 root:root
    json_ok
    ;;
  test)
    [[ -n "$zone" ]] || json_err "Cloudflare non è attivo su questa VPS"
    CF_API_TOKEN="$(cf_token_from_ini)"
    cf_find_zone "$zone" >/dev/null || json_err "il token salvato non ha accesso alla zona $zone"
    json_ok
    ;;
  *)
    json_err "uso: vps-cf-token set|test (token da stdin per set)"
    ;;
esac
```

- [ ] **Step 6: `tools/vps-cf-ips-update`**

```bash
#!/usr/bin/env bash
# vps-cf-ips-update — aggiorna real_ip di Nginx e regole UFW con gli IP Cloudflare.
: "${VPS_OPT:=/opt/vps}" "${VPS_LOG:=/var/log/vps-tools.log}"
: "${VPS_TEMPLATES:=$VPS_OPT/templates}"
for _lib in "${VPS_LIB:-$VPS_OPT/lib}"/*.sh; do
  source "$_lib"
done
tool_init

m="$(manifest_path)"
[[ "$(jq -r '.cloudflare.enabled' "$m")" == true ]] || json_err "Cloudflare non è attivo su questa VPS"
lock=no
if [[ "$(jq -r '.cloudflare.origin_locked' "$m")" == true ]]; then
  lock=yes
fi
cf_apply_ips "$lock"
now="$(date -Iseconds)"
manifest_set '.cloudflare.ips_updated_at = $t' --arg t "$now"
json_ok --arg t "$now" '{ok: true, updated_at: $t}'
```

- [ ] **Step 7: `tools/vps-smtp`**

```bash
#!/usr/bin/env bash
# vps-smtp set|test EMAIL|disable — configurazione email (JSON da stdin per set).
# JSON: {"host","port","user","pass","from","alert_email"}
: "${VPS_OPT:=/opt/vps}" "${VPS_LOG:=/var/log/vps-tools.log}"
: "${VPS_TEMPLATES:=$VPS_OPT/templates}"
for _lib in "${VPS_LIB:-$VPS_OPT/lib}"/*.sh; do
  source "$_lib"
done
tool_init

case "${1:-}" in
  set)
    cfg="$(read_stdin_limited 4096)"
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$cfg" || json_err "configurazione JSON non valida"
    SMTP_HOST="$(jq -r '.host // ""' <<<"$cfg")"
    SMTP_PORT="$(jq -r '.port // "" | tostring' <<<"$cfg")"
    SMTP_USER="$(jq -r '.user // ""' <<<"$cfg")"
    SMTP_PASS="$(jq -r '.pass // ""' <<<"$cfg")"
    SMTP_FROM="$(jq -r '.from // ""' <<<"$cfg")"
    ALERT_EMAIL="$(jq -r '.alert_email // ""' <<<"$cfg")"
    valid_domain "$SMTP_HOST" || json_err "host SMTP non valido"
    valid_smtp_port "$SMTP_PORT" || json_err "porta SMTP non valida (25, 465, 587, 2525)"
    valid_line "$SMTP_USER" || json_err "utente SMTP non valido"
    valid_line "$SMTP_PASS" || json_err "password SMTP non valida"
    valid_email "$SMTP_FROM" || json_err "mittente non valido"
    valid_email "$ALERT_EMAIL" || json_err "email degli avvisi non valida"
    mail_render_config
    manifest_set '.mail.configured = true | .mail.alert_email = $e' --arg e "$ALERT_EMAIL"
    json_ok
    ;;
  test)
    valid_email "${2:-}" || json_err "uso: vps-smtp test EMAIL"
    [[ -f "$VPS_OPT/secrets/msmtprc" ]] || json_err "email non configurata"
    mail_send_test "$2" || json_err "invio non riuscito (dettagli in /var/log/msmtp.log)"
    json_ok
    ;;
  disable)
    rm -f "$VPS_OPT/secrets/msmtprc" "$MSMTPRC_LINK"
    manifest_set '.mail.configured = false | .mail.alert_email = null'
    json_ok
    ;;
  *)
    json_err "uso: vps-smtp set|test EMAIL|disable"
    ;;
esac
```

- [ ] **Step 8: `tools/vps-pma-pass` e `tools/vps-pma-update`**

`tools/vps-pma-pass`:
```bash
#!/usr/bin/env bash
# vps-pma-pass set — nuova password (da stdin) per la basic auth di phpMyAdmin.
: "${VPS_OPT:=/opt/vps}" "${VPS_LOG:=/var/log/vps-tools.log}"
: "${VPS_TEMPLATES:=$VPS_OPT/templates}"
for _lib in "${VPS_LIB:-$VPS_OPT/lib}"/*.sh; do
  source "$_lib"
done
tool_init

[[ "${1:-}" == set ]] || json_err "uso: vps-pma-pass set (password da stdin)"
pass="$(read_stdin_limited 256)"
pass="${pass%$'\n'}"
valid_password "$pass" || json_err "password non valida: minimo 12 caratteri, una riga"
user="$(jq -r '.admin_user // empty' "$(manifest_path)")"
valid_username "$user" || json_err "utente admin non valido nel manifest"
printf '%s' "$pass" | pma_set_basic_auth "$user"
json_ok
```

`tools/vps-pma-update`:
```bash
#!/usr/bin/env bash
# vps-pma-update — aggiorna phpMyAdmin all'ultima versione verificata.
: "${VPS_OPT:=/opt/vps}" "${VPS_LOG:=/var/log/vps-tools.log}"
: "${VPS_TEMPLATES:=$VPS_OPT/templates}"
for _lib in "${VPS_LIB:-$VPS_OPT/lib}"/*.sh; do
  source "$_lib"
done
tool_init

latest="$(pma_latest_version)" || json_err "impossibile leggere l'ultima versione di phpMyAdmin"
current="$(pma_installed_version)"
if [[ "$latest" == "$current" ]]; then
  json_ok --arg v "$current" '{ok: true, updated: false, version: $v}'
  exit 0
fi
pma_update_to "$latest"
manifest_set '.components.phpmyadmin = $v' --arg v "$latest"
json_ok --arg v "$latest" --arg old "$current" '{ok: true, updated: true, version: $v, previous: $old}'
```

- [ ] **Step 9: Template di sistema**

`templates/sudoers-vps-panel`:
```
# vps-installer: il pannello può eseguire come root SOLO questi script.
Defaults:panel !requiretty
panel ALL=(root) NOPASSWD: /opt/vps/bin/vps-status, /opt/vps/bin/vps-cf-token, /opt/vps/bin/vps-cf-ips-update, /opt/vps/bin/vps-smtp, /opt/vps/bin/vps-pma-pass, /opt/vps/bin/vps-pma-update
```

`templates/cron-vps`:
```
# vps-installer
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 3 * * 1 root /opt/vps/bin/vps-cf-ips-update >/dev/null 2>&1
```

- [ ] **Step 10: Step 95**

`steps/95-vps-tools.sh`:
```bash
# shellcheck shell=bash
# Strumenti per il pannello: /opt/vps/{bin,lib,templates}, manifest, sudoers, cron.

step_main() {
  log "Strumenti: installo /opt/vps"
  install -d -m 755 "$VPS_OPT" "$VPS_OPT/bin" "$VPS_OPT/lib" "$VPS_OPT/templates"
  install -d -m 700 "$VPS_OPT/secrets"
  install -m 644 "$VPS_ROOT"/lib/*.sh "$VPS_OPT/lib/"
  install -m 644 "$VPS_ROOT"/templates/* "$VPS_OPT/templates/"
  install -m 755 "$VPS_ROOT"/tools/vps-* "$VPS_OPT/bin/"
  manifest_write

  if is_yes "$PANEL_ENABLED"; then
    local tmp="$VPS_ROOT/sudoers-vps-panel"
    cp "$VPS_TEMPLATES/sudoers-vps-panel" "$tmp"
    visudo -cqf "$tmp" || die "Regole sudoers non valide"
    install -m 440 -o root -g root "$tmp" /etc/sudoers.d/vps-panel
  fi

  if is_yes "$CF_ENABLED"; then
    install -m 644 "$VPS_TEMPLATES/cron-vps" /etc/cron.d/vps
    manifest_set '.cloudflare.ips_updated_at = $t' --arg t "$(date -Iseconds)"
  fi
}
```

Nota: `install -m 644 .../templates/*` copia anche `.gitkeep`? No: il glob `*` non include file nascosti. Va bene.

- [ ] **Step 11: Verificare che passino**

Run: `wsl -d Debian -- bash tests/run.sh tests/tools.bats tests/steps.bats tests/template.bats`
Expected: tutti PASS, shellcheck pulito anche sui file `tools/vps-*`.

- [ ] **Step 12: Commit**

```bash
git add tools steps/95-vps-tools.sh templates/sudoers-vps-panel templates/cron-vps tests/tools.bats
git update-index --chmod=+x tools/vps-status tools/vps-cf-token tools/vps-cf-ips-update tools/vps-smtp tools/vps-pma-pass tools/vps-pma-update
git commit -m "feat: root wrappers for the panel, manifest, sudoers and cron"
```

---

### Task 21: Step 99 — test anti-blocco, pulizia, riavvio

**Files:**
- Create: `steps/99-finalize.sh`, `templates/vps-firstboot-cleanup.service`
- Test: `tests/steps.bats` (il test generico copre lo step), `tests/finalize.bats`

**Interfaces:**
- Consumes: `admin_logged_in`, `server_ipv4`, `state_done`, `state_mark`, `mail_send_test`, `summary_load`, `VPS_BOOTSTRAP`.
- Produces: SSH attivo con `10-vps.conf`, porta 22 chiusa, utente `debian` bloccato (eliminato al riavvio), cloud-init disattivato, `/root/vps-installer` cancellato, riavvio. Sotto-stato `99-finalize:ssh` per non ripetere il test se uno step successivo fallisce.

- [ ] **Step 1: Test che fallisce**

`tests/finalize.bats`:
```bash
setup() {
  load test_helper
  setup_common
  source "$REPO_ROOT/steps/99-finalize.sh"
  ADMIN_USER=manu SSH_PORT=41822 PANEL_ENABLED=yes PANEL_DOMAIN=panel.miosito.it PANEL_ROOT=/var/www/panel.miosito.it
  WANT_PMA=yes MAIL_ENABLED=no CF_ENABLED=yes
  server_ipv4() { echo 203.0.113.10; }
}

@test "il riepilogo contiene accesso SSH, pannello e credenziali phpMyAdmin" {
  summary_set PMA_BASIC_PASS 'Pma-Segreta-1'
  summary_set PANEL_DBADMIN_PASS 'Db-Segreta-1'
  run finalize_summary_text
  [[ "$output" == *"ssh -p 41822 manu@203.0.113.10"* ]]
  [[ "$output" == *"https://panel.miosito.it/pma/"* ]]
  [[ "$output" == *"manu / Pma-Segreta-1"* ]]
  [[ "$output" == *"panel_dbadmin / Db-Segreta-1"* ]]
  [[ "$output" == *"Full (strict)"* ]]
}

@test "il riepilogo non inventa password già esistenti" {
  run finalize_summary_text
  [[ "$output" == *"(invariata)"* ]]
}

@test "il riepilogo non finisce nel log" {
  summary_set PMA_BASIC_PASS 'Pma-Segreta-1'
  finalize_summary_text >/dev/null
  ! grep -q 'Pma-Segreta-1' "$VPS_LOG" 2>/dev/null
}
```

- [ ] **Step 2: Verificare che fallisca**

Run: `wsl -d Debian -- bash tests/run.sh tests/finalize.bats`
Expected: FAIL (step mancante)

- [ ] **Step 3: Template del servizio**

`templates/vps-firstboot-cleanup.service`:
```ini
[Unit]
Description=vps-installer: rimozione dell'utente debian di OVH
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'pkill -KILL -u debian || true; userdel -r debian || true; rm -f /etc/sudoers.d/90-cloud-init-users; systemctl disable vps-firstboot-cleanup.service; rm -f /etc/systemd/system/vps-firstboot-cleanup.service; systemctl daemon-reload'

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 4: Step 99**

`steps/99-finalize.sh`:
```bash
# shellcheck shell=bash
# Attiva SSH con test anti-blocco, chiude l'accesso di default, riepilogo, pulizia, riavvio.

ssh_wait_confirmation() {
  local ip ans deadline=$((SECONDS + 600))
  ip="$(server_ipv4)"
  cat >/dev/tty <<EOF

=================== TEST ACCESSO SSH ===================
Lascia aperta QUESTA finestra. Aprine una NUOVA e accedi con:

    ssh -p $SSH_PORT $ADMIN_USER@$ip

Quando sei dentro, torna qui e scrivi OK.
Hai 10 minuti, poi la configurazione SSH viene ripristinata.
=========================================================
EOF
  while ((SECONDS < deadline)); do
    if read -r -t 30 -p "> " ans </dev/tty; then
      if [[ "${ans^^}" == "OK" ]]; then
        if admin_logged_in "$ADMIN_USER"; then
          return 0
        fi
        echo "Non vedo sessioni attive di $ADMIN_USER. Accedi dalla nuova finestra e riprova." >/dev/tty
      fi
    fi
  done
  return 1
}

finalize_ssh() {
  local conf=/etc/ssh/sshd_config.d/10-vps.conf
  if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    log "SSH: passo da ssh.socket a ssh.service"
    systemctl disable --now ssh.socket >>"$VPS_LOG" 2>&1
    systemctl enable --now ssh.service >>"$VPS_LOG" 2>&1
  fi
  install -m 644 "$VPS_ROOT/sshd-10-vps.conf" "$conf"
  if ! sshd -t >>"$VPS_LOG" 2>&1; then
    rm -f "$conf"
    die "Configurazione SSH non valida: ripristinata la precedente."
  fi
  systemctl reload ssh
  if ! ssh_wait_confirmation; then
    rm -f "$conf"
    systemctl reload ssh
    die "Accesso non confermato: SSH ripristinato (porta 22 ancora aperta). Controlla chiave e porta, poi riprendi con: sudo bash $VPS_ROOT/run.sh"
  fi
  if [[ "$SSH_PORT" != 22 ]]; then
    ufw delete allow 22/tcp >/dev/null 2>&1 || true
  fi
  log "SSH: nuova configurazione attiva e verificata"
}

finalize_default_user() {
  if [[ "$ADMIN_USER" == debian ]] || ! id debian >/dev/null 2>&1; then
    return 0
  fi
  log "Utente debian: bloccato ora, eliminato al prossimo avvio"
  usermod -L -e 1 debian
  rm -f /home/debian/.ssh/authorized_keys
  install -m 644 "$VPS_TEMPLATES/vps-firstboot-cleanup.service" /etc/systemd/system/vps-firstboot-cleanup.service
  systemctl daemon-reload
  systemctl enable vps-firstboot-cleanup.service >>"$VPS_LOG" 2>&1
}

finalize_cloud_init() {
  if [[ -d /etc/cloud ]]; then
    touch /etc/cloud/cloud-init.disabled
    log "cloud-init disattivato"
  fi
}

finalize_mail_test() {
  is_yes "$MAIL_ENABLED" || return 0
  if mail_send_test "$ALERT_EMAIL"; then
    log "Email di prova inviata a $ALERT_EMAIL"
  else
    log "ATTENZIONE: email di prova non inviata (potrai configurarla dal pannello)"
  fi
}

finalize_summary_text() {
  local ip
  summary_load
  ip="$(server_ipv4)"
  echo
  echo "=================== INSTALLAZIONE COMPLETATA ==================="
  echo "Annota questi dati: NON verranno mostrati di nuovo."
  echo
  echo "SSH:          ssh -p $SSH_PORT $ADMIN_USER@$ip"
  if is_yes "$PANEL_ENABLED"; then
    echo "Pannello:     https://$PANEL_DOMAIN  (pagina segnaposto)"
  fi
  if is_yes "$WANT_PMA"; then
    echo "phpMyAdmin:   https://$PANEL_DOMAIN/pma/"
    echo "  accesso web:  $ADMIN_USER / ${PMA_BASIC_PASS:-(invariata)}"
    echo "  login DB:     panel_dbadmin / ${PANEL_DBADMIN_PASS:-(invariata, vedi $PANEL_ROOT/config/.env)}"
  fi
  if is_yes "$MAIL_ENABLED"; then
    echo "Email avvisi:  $ALERT_EMAIL"
  else
    echo "Email avvisi:  da configurare dal pannello"
  fi
  if is_yes "$CF_ENABLED"; then
    echo "Cloudflare:   imposta SSL/TLS su \"Full (strict)\" nella dashboard della zona."
  fi
  echo "Log:          $VPS_LOG"
  echo "================================================================"
}

finalize_cleanup_and_reboot() {
  read -r -p "Premi Invio per cancellare i file dell'installer e riavviare..." _ </dev/tty || true
  log "Pulizia dei file dell'installer e riavvio"
  if [[ -n "${VPS_BOOTSTRAP:-}" && -f "$VPS_BOOTSTRAP" ]]; then
    rm -f "$VPS_BOOTSTRAP"
  fi
  rm -rf "$VPS_ROOT"
  systemctl reboot
}

step_main() {
  if ! state_done "99-finalize:ssh"; then
    finalize_ssh
    state_mark "99-finalize:ssh"
  fi
  finalize_default_user
  finalize_cloud_init
  finalize_mail_test
  finalize_summary_text >/dev/tty
  finalize_cleanup_and_reboot
}
```

- [ ] **Step 5: Verificare che passino**

Run: `wsl -d Debian -- bash tests/run.sh`
Expected: l'intera suite PASS, shellcheck pulito.

- [ ] **Step 6: Commit**

```bash
git add steps/99-finalize.sh templates/vps-firstboot-cleanup.service tests/finalize.bats
git commit -m "feat(steps): anti-lockout SSH switch, cleanup and reboot"
```

---

### Task 22: Release automatica e README

**Files:**
- Create: `.github/workflows/release.yml`, `README.md`
- Test: `tests/release.bats`

**Interfaces:**
- Consumes: segnaposto di `install.sh` (Task 12), `VPS_INSTALLER_VERSION` (Task 2).
- Produces: per ogni tag `vX.Y.Z` una release GitHub con `install.sh` (segnaposto sostituiti) e `vps-installer-vX.Y.Z.tar.gz`; il comando unico nelle note.

- [ ] **Step 1: Test che fallisce**

`tests/release.bats`:
```bash
setup() {
  load test_helper
}

@test "install.sh contiene i segnaposto della release" {
  grep -q '^VPS_VERSION="__VERSION__"$' "$BATS_TEST_DIRNAME/../install.sh"
  grep -q '^TARBALL_SHA256="__TARBALL_SHA256__"$' "$BATS_TEST_DIRNAME/../install.sh"
  grep -q '^REPO="__REPO__"$' "$BATS_TEST_DIRNAME/../install.sh"
}

@test "il workflow controlla che il tag corrisponda alla versione" {
  grep -q 'VPS_INSTALLER_VERSION' "$BATS_TEST_DIRNAME/../.github/workflows/release.yml"
}

@test "l'archivio di release esclude test e documentazione" {
  grep -qxF '/tests export-ignore' "$BATS_TEST_DIRNAME/../.gitattributes"
  grep -qxF '/docs export-ignore' "$BATS_TEST_DIRNAME/../.gitattributes"
}
```

- [ ] **Step 2: Verificare che fallisca**

Run: `wsl -d Debian -- bash tests/run.sh tests/release.bats`
Expected: FAIL (workflow mancante)

- [ ] **Step 3: Workflow di release**

`.github/workflows/release.yml`:
````yaml
name: release
on:
  push:
    tags: ['v*']
permissions:
  contents: write
jobs:
  release:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - run: sudo apt-get update -qq && sudo apt-get install -y -qq bats shellcheck jq gettext-base openssh-client gpg rsync
      - run: bash tests/run.sh
      - name: Versione coerente
        run: |
          v="$(sed -n 's/^VPS_INSTALLER_VERSION="\(.*\)"$/\1/p' lib/common.sh)"
          test "v$v" = "$GITHUB_REF_NAME" || { echo "Tag $GITHUB_REF_NAME diverso da VPS_INSTALLER_VERSION=$v"; exit 1; }
      - name: Build
        run: |
          set -euo pipefail
          V="$GITHUB_REF_NAME"
          mkdir dist
          git archive --format=tar.gz --prefix=vps-installer/ -o "dist/vps-installer-$V.tar.gz" HEAD
          SHA="$(sha256sum "dist/vps-installer-$V.tar.gz" | cut -d' ' -f1)"
          sed -e "s/__VERSION__/$V/" -e "s/__TARBALL_SHA256__/$SHA/" -e "s#__REPO__#$GITHUB_REPOSITORY#" install.sh > dist/install.sh
          ISHA="$(sha256sum dist/install.sh | cut -d' ' -f1)"
          {
            echo "Comando di installazione (su una VPS Debian 13 appena creata, come utente debian):"
            echo
            echo '```bash'
            echo "curl -fsSL https://github.com/$GITHUB_REPOSITORY/releases/download/$V/install.sh -o install.sh && echo \"$ISHA  install.sh\" | sha256sum -c - && sudo bash install.sh"
            echo '```'
          } > notes.md
      - run: gh release create "$GITHUB_REF_NAME" dist/* --title "$GITHUB_REF_NAME" --notes-file notes.md
        env:
          GH_TOKEN: ${{ github.token }}
````

- [ ] **Step 4: README**

`README.md`:
````markdown
# vps-installer

Prepara una VPS **Debian 13** appena creata (pensato per OVH) con un solo comando:
utente amministratore, SSH sicuro, firewall, fail2ban, aggiornamenti automatici e,
a scelta, Nginx, PHP 8.4, MariaDB, Redis, Certbot, phpMyAdmin e il dominio del pannello.

## Uso

1. Crea la VPS con Debian 13 e genera la password dell'utente `debian` dal Manager OVH.
2. Collegati: `ssh debian@IP_DELLA_VPS`
3. Copia il comando dalla [pagina dell'ultima release](../../releases/latest) e incollalo.
   Il comando verifica l'hash dello script prima di eseguirlo.
4. Rispondi alle domande. Poi l'installazione procede da sola.
5. Alla fine apri una **seconda finestra** e accedi con il nuovo utente e la nuova porta,
   come indicato a schermo, poi scrivi `OK`.
6. Annota il riepilogo (credenziali mostrate una sola volta). La VPS si riavvia.

Serve la tua chiave SSH **pubblica** (es. contenuto di `~/.ssh/id_ed25519.pub`).
Se non ce l'hai: `ssh-keygen -t ed25519` sul tuo PC.

## Se qualcosa va storto

- **Connessione caduta:** ricollegati e lancia `sudo tmux attach -t vps-installer`.
- **Errore a metà:** correggi la causa (vedi `/var/log/vps-installer.log`) e rilancia
  `sudo bash install.sh`: riparte dallo step che era fallito, senza rifare le domande.
- **Ricominciare da capo:** `sudo bash install.sh --reset`.
- **Bloccato fuori da SSH:** usa la console **KVM** dal Manager OVH.

## Dopo l'installazione

Restano solo i file descritti in [`docs/PANEL-HANDOFF.md`](docs/PANEL-HANDOFF.md),
il contratto con il pannello di gestione.

## Sviluppo

- Test: `bash tests/run.sh` (da Windows: `wsl -d Debian -- bash tests/run.sh`).
- Release: aggiorna `VPS_INSTALLER_VERSION` in `lib/common.sh`, poi
  `git tag vX.Y.Z && git push --tags`. La GitHub Action pubblica `install.sh`,
  l'archivio e il comando con l'hash.
- Spec: [`docs/specs/2026-10-07-vps-installer-design.md`](docs/specs/2026-10-07-vps-installer-design.md)
````

- [ ] **Step 5: Verificare che passino**

Run: `wsl -d Debian -- bash tests/run.sh`
Expected: l'intera suite PASS.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/release.yml README.md tests/release.bats
git commit -m "ci: tagged releases with verified install command; README"
```

---

### Task 23: Collaudo su VPS reale

Questo task non scrive codice: verifica il comportamento su una macchina vera. Serve l'utente (VPS OVH reinstallabile con Debian 13 dal Manager, oppure una VM Debian 13). Ogni scenario parte da una reinstallazione pulita.

**Files:**
- Create: `docs/collaudo-v1.0.0.md` (esito di ogni scenario)

- [ ] **Step 1: Preparare l'archivio**

Dal PC: `git archive --format=tar.gz --prefix=vps-installer/ -o vps-installer-dev.tar.gz HEAD`, poi
`scp vps-installer-dev.tar.gz install.sh debian@IP:` e sulla VPS `sudo bash install.sh --local vps-installer-dev.tar.gz`.

- [ ] **Step 2: Scenario 1 — tutto attivo con Cloudflare (blocco origine)**

Verifiche dopo il riavvio (`ssh -p PORTA utente@IP`):
```bash
sudo ss -tlnp | grep -E ':(PORTA|80|443|3306|6379) '     # 3306 e 6379 solo su 127.0.0.1
sudo ufw status numbered                                  # niente 22, 80/443 solo "# cloudflare"
sudo fail2ban-client status                               # solo sshd
sudo sshd -T | grep -E '^(port|passwordauthentication|permitrootlogin|allowusers) '
id debian                                                 # "no such user"
curl -sI https://panel.miosito.it | head -1               # 200 (via Cloudflare)
curl -sI https://panel.miosito.it/pma/ | head -1          # 401
curl -skI --resolve x.example:443:IP https://x.example    # handshake rifiutato
sudo -u panel sudo -n /opt/vps/bin/vps-status | jq .ok    # true
sudo -u panel sudo -n /bin/ls                             # negato
ls -la /root                                              # niente vps-installer
sudo grep -ri 'TOKEN_O_PASSWORD_USATE' /var/log/vps-installer.log  # nessun risultato
```
Accesso a phpMyAdmin con basic auth e poi `panel_dbadmin`: deve vedere solo DB `site_*`.

- [ ] **Step 3: Scenario 2 — tutto attivo senza Cloudflare e senza email**

Record A creato a mano prima dello step SSL. Verificare: 80/443 aperte a tutti, jail `nginx-limit-req` e `nginx-botsearch` attive, certificato emesso via webroot.

- [ ] **Step 4: Scenario 3 — errore a metà e ripresa**

Senza Cloudflare, **senza** record A: lo step `80-ssl` deve fermarsi con il messaggio "non punta a ...". Creare il record, rilanciare `sudo bash install.sh`: niente domande, ripartenza da `80-ssl`, completamento.

- [ ] **Step 5: Scenario 4 — test anti-blocco senza conferma**

Al test SSH non accedere e attendere 10 minuti: lo script deve ripristinare SSH (porta 22 ancora funzionante) e fermarsi. Rilanciare e completare.

- [ ] **Step 6: Scenario 5 — connessione persa**

Durante lo step 10 chiudere la finestra SSH. Ricollegarsi come `debian` e `sudo tmux attach -t vps-installer`: l'installazione è andata avanti.

- [ ] **Step 7: Scenario 6 — rilancio idempotente**

Prima del riavvio finale (scenario 1 interrotto a step 95 con Ctrl+C), cancellare da `state` le righe da `30-firewall` in poi e rilanciare: nessuna regola UFW duplicata, password DB invariate (`config/.env` uguale), Nginx e PHP-FPM attivi.

- [ ] **Step 8: Registrare gli esiti e fare commit**

Scrivere `docs/collaudo-v1.0.0.md` con: data, tipo di VPS, per ogni scenario "OK" oppure il problema trovato e il commit che lo corregge. Correggere i problemi con il ciclo TDD dei task precedenti (test che riproduce, fix, test verde).

```bash
git add docs/collaudo-v1.0.0.md
git commit -m "docs: v1.0.0 acceptance test results"
```

Poi: creare il repository GitHub pubblico `vps-installer`, `git remote add origin ...`, `git push -u origin main`, `git tag v1.0.0 && git push --tags` (solo con conferma dell'utente).

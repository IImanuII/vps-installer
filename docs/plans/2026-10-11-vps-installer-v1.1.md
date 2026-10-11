# Installer v1.1 (vps-panel-install / vps-panel-update) — Piano di implementazione

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Plancia si installa sulla VPS con `sudo vps-panel-install` e si aggiorna con `sudo vps-panel-update`, con rollback di codice e database.

**Architecture:** Due repository. In `vps-panel` (Plancia 2.1.0) i log passano in `<radice>/logs/`, `create-admin.php` guadagna `--dry-run` e nasce `install/migrations/`. In `vps-installer` (1.1.0) una libreria `lib/panel_deploy.sh` (funzioni `pd_*`) è usata da due script interattivi in `tools/`; git lavora in place nella radice del pannello con una deploy key di root; `install.sh --tools-only` porta gli script su una VPS già installata.

**Tech Stack:** bash 5 + bats + shellcheck (installer), PHP 8.4 + runner `tests/run.php` (pannello), MariaDB 11.8, git, WSL Debian per i test.

**Spec:** `vps-installer/docs/specs/2026-10-11-vps-installer-v1.1-design.md`

## Global Constraints

- Repository `IImanuII/vps-panel` resta **privato**, non si rinomina. URL di deploy: `git@github.com:IImanuII/vps-panel.git`.
- Commit con email `122299974+IImanuII@users.noreply.github.com` (già in `git config` dei due repo); messaggi in inglese stile conventional commit, trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Rami di lavoro: `vps-panel` → `v2.1-deploy`; `vps-installer` → `v1.1`. Niente push, niente tag spinti: lo fa il controller alla fine, con l'ok dell'utente.
- Testi per l'utente, commenti e documenti **in italiano**, come il codice intorno.
- Segreti (token Telegram, password) **solo da stdin o pipe**: mai argomenti di comando, mai variabili esportate, mai nei log.
- Sotto `sudo` (variabile `SUDO_USER` presente) gli script ignorano l'ambiente del chiamante: tutte le variabili sovrascrivibili tornano ai valori fissi (come `tools/vps-pma-pass`).
- Tag di rilascio: solo `^v[0-9]+\.[0-9]+\.[0-9]+$`. Migrazioni: `install/migrations/X.Y.Z.sql`, idempotenti.
- Versioni: `VPS_INSTALLER_VERSION="1.1.0"`, Plancia `APP_VERSION` `2.1.0` con data `2026-10-11`.
- Test installer: `wsl -d Debian -- bash tests/run.sh` (shellcheck + bats). Test pannello: `wsl -d Debian -- bash tests/run.sh` dentro `vps-panel` (603 test verdi alla partenza). Nel Bash tool usare percorsi `/mnt/c/...`, non `wslpath`.
- Funzioni `pd_*` chiamate in contesto `if`/`||` girano senza `errexit`: **ogni comando che può fallire dentro di esse ha il suo `|| return 1`**.

## Review Focus

1. **Rilancio dopo interruzione** di `vps-panel-install` a metà (dopo il checkout, prima del super_admin): deve riprendere senza duplicare `APP_KEY`, senza ricreare la chiave, senza un secondo super_admin → test "rilancio" nel Task 7.
2. **Rollback quando fallisce anche il ripristino** (DB giù): uscita 2 e percorso del dump nel messaggio, mai un "ok" falso → test nel Task 8.
3. **Tag non conformi nel repository** (`v3.0`, `v3.0.0-rc1`, `latest`): mai scelti come bersaglio → test in Task 4.
4. **Input da pipe chiusa** (EOF a metà delle domande): lo script esce con 1 e un messaggio, non gira all'infinito → test nel Task 7.
5. **Update concorrente** con il lock già preso: esce subito con 1 senza toccare niente → test nel Task 8.

---

## Parte A — `vps-panel` (Plancia 2.1.0)

Lavorare in `C:\Users\Manu\Documents\MEGAsync\progetti\pannello-vps\vps-panel`, ramo nuovo `v2.1-deploy` da `master`.

### Task 1: Log in `<radice>/logs/` e `php-error.log` nei Registri

**Files:**
- Modify: `app/shared/Core/Config.php` (array `$percorsi`, ~riga 36)
- Modify: `app/shared/Support/Log.php` (`dir()` ~riga 178, `recenti()` ~riga 140, commento ~riga 56)
- Modify: `app/shared/Support/Errori.php:13` (commento)
- Modify: `.gitignore`
- Create: `logs/.gitkeep`; Delete: `storage/logs/.gitkeep`
- Test: `tests/layout_test.php`, `tests/logs_test.php`

**Interfaces:**
- Produces: costante `LOGS_PATH` (= `PANEL_ROOT . '/logs'`); `Log::recenti()` conta anche le righe nel formato di `error_log` di PHP (`[11-Oct-2026 10:00:00 Europe/Rome] ...`).

- [ ] **Step 1: Crea il ramo**

```bash
cd /c/Users/Manu/Documents/MEGAsync/progetti/pannello-vps/vps-panel
git checkout master && git pull --ff-only && git checkout -b v2.1-deploy
```

- [ ] **Step 2: Test che falliscono**

In `tests/layout_test.php`, nel primo test, dopo `assert_same($r . '/storage', STORAGE_PATH);` aggiungi:

```php
    assert_same($r . '/logs', LOGS_PATH);
```

e rinomina il test `'struttura: storage/logs e storage/locks si creano se mancano'` in `'struttura: la cartella dei log si crea se manca'` (corpo invariato).

In fondo a `tests/logs_test.php` aggiungi:

```php
test('registri: php-error.log del pool PHP-FPM e un canale come gli altri', function () {
    _lgIsolato(function (string $dir) {
        // Formato di error_log di PHP: data con il mese in lettere e il fuso.
        $adesso = date('d-M-Y H:i:s') . ' Europe/Rome';
        file_put_contents($dir . '/php-error.log', "[{$adesso}] PHP Warning:  qualcosa in /x.php on line 3\n"
            . "[01-Jan-2020 10:00:00 UTC] PHP Notice:  vecchia\n");

        $canali = array_column(Log::canali(), null, 'canale');
        assert_true(isset($canali['php-error']), 'php-error.log deve comparire fra i canali');
        assert_same(2, $canali['php-error']['righe']);
        assert_same(1, $canali['php-error']['recenti'], 'solo la riga di oggi e recente');
        assert_true(str_contains(Log::coda('php-error')[0], 'vecchia'), 'la coda parte dalla piu recente scritta');
    });
});

test('registri: la cartella predefinita e LOGS_PATH', function () {
    $prima = Log::dirCorrente();
    Log::useDir(null);
    try {
        $f = LOGS_PATH . '/plancia_test_' . bin2hex(random_bytes(3)) . '.log';
        Log::write(basename($f, '.log'), 'prova');
        assert_true(is_file($f), 'il registro deve finire in LOGS_PATH');
        @unlink($f);
    } finally {
        Log::useDir($prima);
    }
});
```

Nota: `coda()` restituisce dalla riga **più in fondo** al file; nel file sopra l'ultima riga è "vecchia", quindi `[0]` contiene "vecchia". `Log::useDir(?string)` accetta già `null`.

- [ ] **Step 3: Esegui e verifica che fallisca**

Run: `wsl -d Debian -- bash -lc 'cd /mnt/c/Users/Manu/Documents/MEGAsync/progetti/pannello-vps/vps-panel && bash tests/run.sh'`
Expected: FAIL su `LOGS_PATH` non definita e sul conteggio `recenti` di `php-error`.

- [ ] **Step 4: Implementa**

`Config.php`, nell'array `$percorsi` dopo `'STORAGE_PATH'`:

```php
            'LOGS_PATH'     => $panelRoot . '/logs',
```

`Log.php`, `dir()`:

```php
    private static function dir(): ?string
    {
        return self::$dir ?? (defined('LOGS_PATH') ? LOGS_PATH : null);
    }
```

`Log.php`, in `recenti()` sostituisci il blocco del `preg_match` e del confronto con:

```php
            // Due formati: il nostro (`[2026-10-11 10:00:00]`) e quello di
            // error_log di PHP (`[11-Oct-2026 10:00:00 Europe/Rome]`), che scrive
            // php-error.log del pool.
            if (preg_match('/^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}|\d{2}-[A-Z][a-z]{2}-\d{4} \d{2}:\d{2}:\d{2}(?: [A-Za-z_\/+-]+)?)\]/', $riga, $m) !== 1) {
                continue;
            }
            $quando = strtotime($m[1]);
            if ($quando !== false && $quando >= $limite) {
                $quante++;
            }
```

Commento in `Log.php` ~riga 56: `storage/logs` → `logs/`. In `Errori.php:13`: `` `storage/logs` `` → `` `logs/` ``.

`.gitignore`: sostituisci il blocco da `# Storage runtime` fino a `/public/index.html` compreso con:

```gitignore
# Storage runtime: la radice del pannello e' il repository, e storage/ sta
# fuori da public/ (non raggiungibile dal web). L'installer vi crea anche
# sessions/, tmp/ e pma-tmp/ (pool PHP-FPM, phpMyAdmin): di tracciato resta
# solo il .gitkeep di locks/.
/storage/*
!/storage/locks/
/storage/locks/*
!/storage/locks/.gitkeep

# Registri: logs/ la crea l'installer, e ci scrive anche PHP-FPM (php-error.log).
/logs/*
!/logs/.gitkeep

# Segnaposto del webroot creato dall'installer (lo toglie vps-panel-install)
/public/index.html
```

```bash
git rm -q storage/logs/.gitkeep
mkdir -p logs && : > logs/.gitkeep && git add -f logs/.gitkeep
```

- [ ] **Step 5: Esegui la suite**

Run: come Step 3. Expected: tutti verdi (605 circa).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(logs): write logs to <root>/logs and read php-error.log

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 2: `create-admin.php --dry-run`

**Files:**
- Modify: `app/cli/create-admin.php`
- Test: `tests/createadmin_test.php`

**Interfaces:**
- Produces: `php app/cli/create-admin.php --dry-run --username=U --telegram-id=N` (password su stdin) → uscita 0 se i dati sono validi, 1 con messaggio su stderr se no; **non** legge il `.env`, **non** tocca il DB, non stampa niente su stdout. Usato da `vps-panel-install` (Task 7).

- [ ] **Step 1: Test che falliscono** — in fondo a `tests/createadmin_test.php`:

```php
test('create-admin --dry-run: dati validi, nessun utente creato', function () {
    $nome = 'cli_' . bin2hex(random_bytes(3));
    [$code, $out, $err] = _caRun(['--dry-run', '--username=' . $nome, '--telegram-id=123456'], "Una-Password-12!\n");
    assert_same(0, $code, $err);
    assert_same('', $out);
    assert_same(null, User::findByUsername($nome), 'il dry-run non deve scrivere');
});

test('create-admin --dry-run: password debole rifiutata con 1', function () {
    [$code, , $err] = _caRun(['--dry-run', '--username=cli_x', '--telegram-id=123456'], "debole\n");
    assert_same(1, $code);
    assert_true(str_contains($err, '12 caratteri'), $err);
});

test('create-admin --dry-run: funziona anche senza configurazione', function () {
    // Il dry-run serve prima di sapere se il .env e completo: non deve leggerlo.
    $cmd = [PHP_BINARY, dirname(__DIR__) . '/app/cli/create-admin.php', '--dry-run', '--username=cli_y', '--telegram-id=42'];
    $env = array_merge(getenv(), ['PLANCIA_ENV_FILE' => sys_get_temp_dir() . '/non_esiste_' . bin2hex(random_bytes(3))]);
    $p = proc_open($cmd, [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, null, $env);
    fwrite($pipes[0], "Una-Password-12!\n");
    fclose($pipes[0]);
    stream_get_contents($pipes[1]);
    $err = stream_get_contents($pipes[2]);
    fclose($pipes[1]);
    fclose($pipes[2]);
    assert_same(0, proc_close($p), (string) $err);
});
```

- [ ] **Step 2: Esegui** — Expected: FAIL (opzione sconosciuta: lo script crea davvero l'utente o esce 2).

- [ ] **Step 3: Implementa** — in `create-admin.php`:

Nel docblock, dopo la riga di esempio, aggiungi:

```php
 *   php app/cli/create-admin.php --dry-run --username=manu --telegram-id=123456789 < password.txt
 *
 * Con --dry-run controlla solo i dati (stesse regole) e esce 0 se vanno bene:
 * non legge la configurazione e non tocca il database. Lo usa vps-panel-install
 * per ridomandare i dati sbagliati prima di creare l'utente.
```

Cambia `getopt` e aggiungi la lettura del flag:

```php
$opt = getopt('', ['username:', 'telegram-id:', 'password:', 'dry-run']);
$dryRun = array_key_exists('dry-run', $opt);
```

Subito dopo il controllo `PasswordPolicy::firstError` (prima del `try`):

```php
if ($dryRun) {
    exit(0);
}
```

- [ ] **Step 4: Esegui la suite** — Expected: tutti verdi.

- [ ] **Step 5: Commit**

```bash
git add app/cli/create-admin.php tests/createadmin_test.php
git commit -m "feat(cli): create-admin --dry-run validates input without writing

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 3: Migrazioni, documenti, versione 2.1.0 e tag locale

**Files:**
- Create: `install/migrations/README.md`, `tests/migrations_test.php`
- Modify: `app/shared/Core/Config.php` (~riga 93-94), `app/backend/CHANGELOG.md` (in testa), `Documenti/deploy/README.md`, `.claude/CLAUDE.md` (sez. "Da allineare con installer v1.1" e sez. 5), `Documenti/PIANO/2026-10-07-vps-sp1-pulizia-design.md` (nessuna modifica di contenuto; solo se cita `storage/logs` come stato attuale, aggiungi "(da 2.1.0: `logs/`)")

**Interfaces:**
- Consumes: `LOGS_PATH` (Task 1), `--dry-run` (Task 2).
- Produces: tag annotato **locale** `v2.1.0` sul commit finale del ramo dopo il merge in `master` (lo crea il controller, vedi Step 7). `install/migrations/` esiste nel repo.

Il controllo "APP_VERSION uguale alla prima voce del CHANGELOG" chiesto dalla spec esiste già (`tests/changelog_test.php`, righe 68 e 108): non va riscritto.

- [ ] **Step 1: Test che fallisce** — `tests/migrations_test.php`:

```php
<?php
declare(strict_types=1);

/**
 * install/migrations/: le applica vps-panel-update, in ordine di versione, fra
 * la versione installata (esclusa) e quella nuova (inclusa). Un nome fuori
 * formato verrebbe ignorato in silenzio: meglio che la suite lo dica subito.
 */

test('migrazioni: la cartella esiste e i nomi sono X.Y.Z.sql', function () {
    $dir = dirname(__DIR__) . '/install/migrations';
    assert_true(is_dir($dir), 'manca install/migrations/');
    foreach (glob($dir . '/*') ?: [] as $f) {
        $nome = basename($f);
        if ($nome === 'README.md') {
            continue;
        }
        assert_true(preg_match('/^\d+\.\d+\.\d+\.sql$/', $nome) === 1, 'nome non valido: ' . $nome);
    }
});

test('migrazioni: nessuna e piu nuova della versione in uso', function () {
    foreach (glob(dirname(__DIR__) . '/install/migrations/*.sql') ?: [] as $f) {
        $v = basename($f, '.sql');
        assert_true(version_compare($v, APP_VERSION, '<='), "migrazione $v oltre APP_VERSION " . APP_VERSION);
    }
});
```

- [ ] **Step 2: Esegui** — Expected: FAIL "manca install/migrations/".

- [ ] **Step 3: Crea `install/migrations/README.md`**

```markdown
# Migrazioni dello schema

`install/schema.sql` descrive sempre un'installazione **nuova e completa**. Quando una
versione cambia lo schema di un'installazione esistente, la modifica va anche qui:

- un file per versione: `X.Y.Z.sql`, con X.Y.Z = la versione di Plancia che la introduce;
- contenuto **idempotente** (`ADD COLUMN IF NOT EXISTS`, `CREATE TABLE IF NOT EXISTS`, ...):
  `vps-panel-update` lo rilancia senza danni se un aggiornamento viene ripetuto;
- niente dati di esempio, niente `DROP` senza un piano di ritorno.

`vps-panel-update` (in `vps-installer`) applica in ordine i file con versione maggiore di
quella installata e minore o uguale a quella nuova, dopo `schema.sql`. Prima fa un dump del
database: se qualcosa fallisce, ripristina dump e codice.
```

- [ ] **Step 4: Versione e CHANGELOG**

`Config.php`: `APP_VERSION` → `'2.1.0'`, `APP_VERSION_DATE` → `'2026-10-11'`.

In testa a `app/backend/CHANGELOG.md`, sotto `# Changelog`, aggiungi (formato come la voce 2.0.0; i test di `changelog_test.php` controllano che la prima voce sia `(v2.1.0)`):

```markdown
## 2026-10-11 - Messa in produzione con vps-panel-install (v2.1.0)
### Perche'
Plancia si installa e si aggiorna con due comandi dell'installer v1.1 (`vps-panel-install`, `vps-panel-update`) invece che a mano. Servivano tre cose dal pannello: i log dove li mette l'installer, un modo per controllare i dati del primo super_admin senza crearlo, e un posto per le migrazioni.

### Nuovo
- I registri stanno in `<radice>/logs/` (costante `LOGS_PATH`), accanto a `php-error.log` del pool PHP-FPM, che ora compare in **Sicurezza → Registri** come gli altri canali.
- `app/cli/create-admin.php --dry-run`: controlla username, id Telegram e password senza leggere la configurazione e senza scrivere.
- `install/migrations/X.Y.Z.sql`: le applica `vps-panel-update`, dopo un dump del database.

### Tolto
- `storage/logs/`: i registri sono in `logs/`.

### File modificati
- `app/shared/Core/Config.php` - `LOGS_PATH`, v2.1.0
- `app/shared/Support/Log.php` - cartella `LOGS_PATH`, date nel formato di `error_log`
- `app/cli/create-admin.php` - `--dry-run`
- `install/migrations/README.md`, `tests/migrations_test.php` - nuovi
- `Documenti/deploy/README.md`, `.claude/CLAUDE.md` - messa in produzione con l'installer v1.1
```

- [ ] **Step 5: `Documenti/deploy/README.md`**

Sostituisci il paragrafo **"La messa in produzione la fara' `vps-panel-install`..."** e la sezione **"## Procedura manuale"** (passi 1–6, fino alla tabella di verifica compresa) con:

````markdown
## Installazione

Sulla VPS, da utente amministratore (quello creato dall'installer):

1. **Installer v1.1.** Su una VPS installata con una versione precedente:

   ```bash
   curl -fsSLO https://github.com/IImanuII/vps-installer/releases/download/v1.1.0/install.sh
   sudo bash install.sh --tools-only
   ```

   Ricopia solo gli script in `/opt/vps`, senza procedura guidata.
2. **Plancia:** `sudo vps-panel-install`. Lo script:
   - crea la deploy key e la stampa: va aggiunta su GitHub in
     `IImanuII/vps-panel` → Settings → Deploy keys, **senza** "Allow write access";
   - chiede il token del bot Telegram (da @BotFather) e lo verifica;
   - scarica l'ultimo rilascio `vX.Y.Z` nella radice del pannello e toglie il segnaposto;
   - aggiunge a `config/.env` `APP_KEY` (solo se manca) e `TELEGRAM_BOT_TOKEN`;
   - applica `install/schema.sql`;
   - chiede username, id Telegram (da @userinfobot) e password del primo super_admin;
   - scrive `/etc/cron.d/vps-panel` (manutenzione notturna), ricarica PHP-FPM e controlla `/health`.

   Se si interrompe, si rilancia: riprende senza rifare cio' che e' gia' fatto.

## Aggiornamento

```bash
sudo vps-panel-update              # all'ultimo rilascio vX.Y.Z
sudo vps-panel-update --ref v2.1.0 # a un rilascio preciso
```

Prima di toccare qualcosa salva il database in `/opt/vps/backups/panel/` (gli ultimi 5). Poi
checkout del tag, `schema.sql`, migrazioni di `install/migrations/`, `php -l`, reload di
PHP-FPM e `/health`. Se un passo fallisce torna alla versione di prima, codice e database.
`config/.env`, `logs/` e `storage/` non vengono toccati.

**Rilasciare una versione:** aggiornare `APP_VERSION` e il CHANGELOG, mergiare in `master`,
poi `git tag -a vX.Y.Z -m "Plancia X.Y.Z" && git push origin vX.Y.Z`. Una modifica allo schema
va anche in `install/migrations/X.Y.Z.sql` (vedi il README della cartella).

## Verifica dopo l'installazione

| URL | Atteso |
|---|---|
| `https://<dominio>/health` | 200 `OK` |
| `https://<dominio>/` | 302 verso `/login` (solo senza prefisso del pannello: con un prefisso la radice nuda da 404) |
| `https://<dominio>/.env` | 403 o 404 (non e' sotto `public/`) |
| `https://<dominio>/app/shared/Core/Config.php` | 404 |
| `https://<dominio>/assets/admin/tokens.css` | 200 |

Poi il login completo, con il codice Telegram, e la checklist "Verifica manuale" qui sotto.
````

Nella sezione "## Struttura sul server" sostituisci `storage/  logs/ e locks/ (scrivibili da `panel`)` con `storage/  sessioni, tmp, locks/     logs/  registri (anche php-error.log)`. Lascia invariate "Requisiti", "Verifica manuale" e "Persistenza", ma in "Persistenza" sostituisci la frase su `ALTER TABLE` nel CHANGELOG con: `Le modifiche allo schema dopo un rilascio vanno in install/migrations/X.Y.Z.sql: le applica vps-panel-update.` e `config/.env e storage/` con `config/.env, logs/ e storage/`.

In fondo aggiungi:

````markdown
## Appendice: procedura manuale

Solo se gli script dell'installer non sono disponibili. Da root, nella radice del pannello,
con una credenziale di lettura per il repository privato:

```bash
cd /var/www/<dominio>
git init -b main && git remote add origin git@github.com:IImanuII/vps-panel.git
git fetch --tags origin && git checkout -f vX.Y.Z && chown -R panel:panel .
rm -f public/index.html
grep -q '^APP_KEY=' config/.env || printf 'APP_KEY=%s\n' "$(openssl rand -base64 32)" >> config/.env
grep -q '^TELEGRAM_BOT_TOKEN=' config/.env || printf 'TELEGRAM_BOT_TOKEN=%s\n' '<token>' >> config/.env
mariadb panel < install/schema.sql
printf '%s\n' '<password>' | runuser -u panel -- php app/cli/create-admin.php --username=<tuo> --telegram-id=<id>
echo '0 3 * * * panel /usr/bin/php /var/www/<dominio>/app/cron/maintenance.php >/dev/null 2>&1' > /etc/cron.d/vps-panel
systemctl reload php8.4-fpm
```
````

- [ ] **Step 6: `.claude/CLAUDE.md`**

Togli tutta la sezione `### Da allineare con installer v1.1` (righe ~164-171). Nella sez. 5 cambia la voce 2 in:

```markdown
2. **Installer v1.1** — fatto (Plancia 2.1.0): `vps-panel-install` / `vps-panel-update` in
   `vps-installer`, log in `logs/`, migrazioni in `install/migrations/`.
```

Nella mappa della struttura (riga ~39) sostituisci `storage/    logs/ e locks/, scrivibili dall'utente `panel`` con `storage/    sessioni, tmp e locks/, scrivibili dall'utente `panel`` e aggiungi sotto `logs/       registri dell'app e php-error.log del pool (fuori da git)`. Controlla con `grep -rn "storage/logs" --include=*.md --include=*.php .` (escluso CHANGELOG e `Documenti/PIANO`) che non resti niente.

- [ ] **Step 7: Suite completa, commit, merge locale e tag**

```bash
wsl -d Debian -- bash -lc 'cd /mnt/c/Users/Manu/Documents/MEGAsync/progetti/pannello-vps/vps-panel && bash tests/run.sh'
git add -A
git commit -m "docs(deploy): Plancia 2.1.0, install and update through vps-installer 1.1

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Expected: tutti verdi. **Non** mergiare e non taggare qui: merge in `master` e `git tag -a v2.1.0 -m "Plancia 2.1.0"` li fa il controller dopo la review del Task 3 (il tag serve all'end-to-end del Task 9, che legge il repository locale). Push solo a fine piano con l'ok dell'utente.

---

## Parte B — `vps-installer` (1.1.0)

Lavorare in `C:\Users\Manu\Documents\MEGAsync\progetti\pannello-vps\vps-installer`, ramo nuovo `v1.1` da `main` (la spec è già committata su `main`).

### Task 4: `lib/panel_deploy.sh` — git, chiave, tag, `.env`

**Files:**
- Create: `lib/panel_deploy.sh`, `templates/github-known-hosts`, `tests/panel_helper.bash`, `tests/panel_deploy.bats`

**Interfaces:**
- Consumes: `env_get`, `env_merge`, `own`, `log`, `die`, `manifest_path`, `sql_ident_ok` (lib esistenti).
- Produces (usate dai Task 5, 7, 8):
  - variabili con default: `PANEL_REPO`, `PD_REPO_WEB`, `PD_KEY`, `PD_KNOWN_HOSTS`, `PD_BACKUPS`, `PD_CRON`, `PD_LOCK`, `PD_PHP`
  - `pd_load` → imposta `PANEL_DOMAIN`, `PANEL_ROOT`, `PD_ENV`; `die` se manca qualcosa
  - `pd_git ARGS…` → git nella radice con chiave e known_hosts
  - `pd_key_ensure` → 0/1
  - `pd_latest_tag` → stampa `vX.Y.Z` o niente
  - `pd_current_tag` → stampa il tag esatto di HEAD o niente
  - `pd_ver_gt A B` → 0 se `A > B` (A, B senza `v`)
  - `pd_checkout TAG` → 0/1
  - `pd_env_merge TOKEN` → aggiunge `APP_KEY` se manca e `TELEGRAM_BOT_TOKEN` se `TOKEN` non è vuoto
  - `pd_db_name` → stampa `DB_NAME` del `.env` (validato) o ritorna 1
  - `pd_as_panel CMD…` → `runuser -u panel --` (o diretto con `PD_AS_PANEL=0`)
- Helper di test `tests/panel_helper.bash`: `pd_test_setup` (repository finto con tag `v1.0.0`, `v1.1.0`, radice del pannello finta, manifest, stub) e `pd_test_installed TAG` (simula un'installazione a quel tag).

- [ ] **Step 1: Crea il ramo**

```bash
cd /c/Users/Manu/Documents/MEGAsync/progetti/pannello-vps/vps-installer
git checkout main && git pull --ff-only && git checkout -b v1.1
```

- [ ] **Step 2: `templates/github-known-hosts`**

Prendi le chiavi da `https://api.github.com/meta` (campo `ssh_keys`) e scrivi:

```
github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
```

Se `api.github.com/meta` riporta chiavi diverse, usa quelle e segnalalo nel report. Le impronte attese (pubblicate da GitHub) sono nel test sotto.

- [ ] **Step 3: `tests/panel_helper.bash`**

```bash
# shellcheck shell=bash
# Repository finto di Plancia, radice del pannello finta e stub dei comandi
# esterni, per panel_deploy.bats e per i test dei due script.

pd_test_setup() {
  export PANEL_REPO="$BATS_TEST_TMPDIR/repo.git"
  export PD_TEST=1 PD_AS_PANEL=0 PD_SKIP_TELEGRAM_CHECK=1
  export PD_HEALTH_URL=http://127.0.0.1:9/health PD_CURL_RESOLVE="" PD_HEALTH_SLEEP=0
  export PD_BACKUPS="$BATS_TEST_TMPDIR/backups" PD_CRON="$BATS_TEST_TMPDIR/cron-vps-panel"
  export PD_LOCK="$BATS_TEST_TMPDIR/update.lock" PD_KEY="$VPS_OPT/secrets/panel-deploy-key"
  export PD_PHP="$BATS_TEST_TMPDIR/bin/php" VPS_LIB="$REPO_ROOT/lib"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  P="$BATS_TEST_TMPDIR/panel"
  mkdir -p "$P/config" "$P/public" "$P/logs" "$P/storage"
  printf 'DB_HOST=localhost\nDB_NAME=panel\nDB_USER=panel\nDB_PASS=segreto\n' >"$P/config/.env"
  echo segnaposto >"$P/public/index.html"
  jq -n --arg p "$P" '{installer_version:"1.1.0", panel:{domain:"panel.test", path:$p}}' >"$VPS_OPT/manifest.json"

  local w="$BATS_TEST_TMPDIR/work"
  git init -q --bare "$PANEL_REPO"
  git init -q -b main "$w"
  mkdir -p "$w/install/migrations" "$w/public" "$w/app/cli"
  echo '-- schema' >"$w/install/schema.sql"
  echo '<?php echo "OK";' >"$w/public/index.php"
  echo '<?php' >"$w/app/cli/create-admin.php"
  git -C "$w" add -A && git -C "$w" commit -qm v1.0.0 && git -C "$w" tag v1.0.0
  echo '-- migrazione 1.1.0' >"$w/install/migrations/1.1.0.sql"
  git -C "$w" add -A && git -C "$w" commit -qm v1.1.0 && git -C "$w" tag v1.1.0
  git -C "$w" push -q "$PANEL_REPO" main --tags
  PD_WORK="$w"

  make_stub mariadb 'printf "%s\n" "$*" >>"$BATS_TEST_TMPDIR/mariadb.args"
case " $* " in
  *" -e "*) printf "%s\n" "${MARIADB_OUT:-0}" ;;
  *) cat >>"$BATS_TEST_TMPDIR/mariadb.sql" ;;
esac
exit "${MARIADB_RC:-0}"'
  make_stub mariadb-dump 'echo "-- dump $*"'
  make_stub curl 'echo x >>"$BATS_TEST_TMPDIR/curl.calls"; echo "${CURL_OUT:-OK}"; exit "${CURL_RC:-0}"'
  make_stub systemctl 'printf "%s\n" "$*" >>"$BATS_TEST_TMPDIR/systemctl.args"'
  make_stub php 'T="$BATS_TEST_TMPDIR"
if [[ "$1" == -l ]]; then exit "${PHP_LINT_RC:-0}"; fi
if [[ " $* " == *" --dry-run "* ]]; then
  n=$(( $(cat "$T/dry.n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$T/dry.n"
  cat >/dev/null
  (( n > ${PHP_DRY_FAILS:-0} )) || { echo "Errore: dati non validi" >&2; exit 1; }
  exit 0
fi
printf "%s\n" "$*" >>"$T/php.args"; cat >>"$T/php.stdin"; exit "${PHP_RC:-0}"'
}

# pd_test_installed TAG — la radice come la lascia un'installazione riuscita a TAG.
pd_test_installed() {
  pd_load
  pd_git init -q -b main
  pd_git remote add origin "$PANEL_REPO"
  pd_git fetch -q --tags origin
  pd_checkout "$1"
  manifest_set '.panel.version = $v' --arg v "${1#v}"
  rm -f "$BATS_TEST_TMPDIR/mariadb.sql" "$BATS_TEST_TMPDIR/mariadb.args"
}

# pd_test_tag TAG [FILE CONTENUTO] — aggiunge un rilascio al repository finto.
pd_test_tag() {
  if (($# == 3)); then
    mkdir -p "$(dirname "$PD_WORK/$2")"
    printf '%s\n' "$3" >"$PD_WORK/$2"
  else
    echo "$1" >>"$PD_WORK/CHANGES"
  fi
  git -C "$PD_WORK" add -A && git -C "$PD_WORK" commit -qm "$1" && git -C "$PD_WORK" tag "$1"
  git -C "$PD_WORK" push -q "$PANEL_REPO" main --tags
}
```

- [ ] **Step 4: Test che falliscono** — `tests/panel_deploy.bats`:

```bash
setup() {
  load test_helper
  load panel_helper
  setup_common
  pd_test_setup
}

@test "known_hosts di GitHub: le tre impronte pubblicate" {
  run ssh-keygen -lf "$REPO_ROOT/templates/github-known-hosts"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"* ]]
  [[ "$output" == *"SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM"* ]]
  [[ "$output" == *"SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s"* ]]
}

@test "pd_load legge dominio e radice dal manifest" {
  pd_load
  [ "$PANEL_DOMAIN" = panel.test ]
  [ "$PANEL_ROOT" = "$P" ]
  [ "$PD_ENV" = "$P/config/.env" ]
}

@test "pd_load senza pannello nel manifest" {
  jq -n '{installer_version:"1.1.0", panel:null}' >"$VPS_OPT/manifest.json"
  run pd_load
  [ "$status" -eq 1 ]
  [[ "$output" == *"non ha un pannello"* ]]
}

@test "pd_key_ensure crea la chiave una volta sola, 600" {
  pd_key_ensure
  [ "$(stat -c %a "$PD_KEY")" = 600 ]
  first="$(cat "$PD_KEY.pub")"
  pd_key_ensure
  [ "$(cat "$PD_KEY.pub")" = "$first" ]
}

@test "pd_latest_tag: ordine di versione, tag non conformi ignorati" {
  pd_test_tag v1.9.0
  pd_test_tag v1.10.0
  pd_test_tag v3.0
  pd_test_tag v3.0.0-rc1
  pd_test_tag latest
  pd_load
  pd_git init -q -b main
  pd_git remote add origin "$PANEL_REPO"
  pd_git fetch -q --tags origin
  [ "$(pd_latest_tag)" = v1.10.0 ]
}

@test "pd_latest_tag senza tag non stampa niente e non fallisce" {
  pd_load
  pd_git init -q -b main
  run pd_latest_tag
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pd_ver_gt" {
  pd_ver_gt 1.10.0 1.9.0
  ! pd_ver_gt 1.9.0 1.10.0
  ! pd_ver_gt 1.0.0 1.0.0
}

@test "pd_checkout porta al tag e non tocca config, logs, storage" {
  echo riga >"$P/logs/app.log"
  pd_test_installed v1.0.0
  [ "$(pd_current_tag)" = v1.0.0 ]
  [ ! -f "$P/install/migrations/1.1.0.sql" ]
  pd_checkout v1.1.0
  [ "$(pd_current_tag)" = v1.1.0 ]
  [ -f "$P/install/migrations/1.1.0.sql" ]
  grep -qx 'DB_PASS=segreto' "$P/config/.env"
  grep -qx riga "$P/logs/app.log"
}

@test "pd_env_merge aggiunge APP_KEY una volta e il token" {
  pd_load
  pd_env_merge "123456:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  key="$(env_get "$PD_ENV" APP_KEY)"
  [ "$(printf '%s' "$key" | base64 -d | wc -c)" -eq 32 ]
  pd_env_merge ""
  [ "$(env_get "$PD_ENV" APP_KEY)" = "$key" ]
  [ "$(grep -c '^APP_KEY=' "$PD_ENV")" -eq 1 ]
  [ "$(env_get "$PD_ENV" TELEGRAM_BOT_TOKEN)" = "123456:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" ]
  grep -qx 'DB_PASS=segreto' "$PD_ENV"
}

@test "pd_db_name rifiuta nomi non validi" {
  pd_load
  [ "$(pd_db_name)" = panel ]
  printf 'DB_NAME=pan;el\n' >"$PD_ENV"
  run pd_db_name
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 5: Esegui** — `wsl -d Debian -- bash -lc 'cd /mnt/c/Users/Manu/Documents/MEGAsync/progetti/pannello-vps/vps-installer && bash tests/run.sh tests/panel_deploy.bats'`. Expected: FAIL (funzioni inesistenti).

- [ ] **Step 6: Implementa `lib/panel_deploy.sh` (prima parte)**

```bash
# shellcheck shell=bash
# Installazione e aggiornamento di Plancia (vps-panel-install, vps-panel-update).
# Git lavora in place nella radice del pannello, come root, con una deploy key
# di sola lettura che l'utente panel non può leggere; i file restano di panel.
# Ogni funzione può essere chiamata in un `if`: dove errexit non vale, ogni
# comando che può fallire ha il suo `|| return 1`.

: "${PANEL_REPO:=git@github.com:IImanuII/vps-panel.git}"
: "${PD_REPO_WEB:=https://github.com/IImanuII/vps-panel}"
: "${PD_KEY:=$VPS_OPT/secrets/panel-deploy-key}"
: "${PD_KNOWN_HOSTS:=$VPS_TEMPLATES/github-known-hosts}"
: "${PD_BACKUPS:=$VPS_OPT/backups/panel}"
: "${PD_CRON:=/etc/cron.d/vps-panel}"
: "${PD_LOCK:=/run/vps-panel-update.lock}"
: "${PD_PHP:=php}"

# pd_load — dominio e radice del pannello dal manifest.
pd_load() {
  local m
  m="$(manifest_path)"
  [[ -f "$m" ]] || die "Manifest $m mancante: la VPS non è stata preparata da vps-installer"
  PANEL_DOMAIN="$(jq -r '.panel.domain // empty' "$m")"
  PANEL_ROOT="$(jq -r '.panel.path // empty' "$m")"
  [[ -n "$PANEL_DOMAIN" && -n "$PANEL_ROOT" ]] || die "Il manifest non ha un pannello (panel.domain, panel.path)"
  [[ -d "$PANEL_ROOT" ]] || die "Cartella del pannello mancante: $PANEL_ROOT"
  PD_ENV="$PANEL_ROOT/config/.env"
}

pd_git() {
  GIT_SSH_COMMAND="ssh -i $PD_KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$PD_KNOWN_HOSTS" \
    git -c safe.directory="$PANEL_ROOT" -c advice.detachedHead=false -C "$PANEL_ROOT" "$@"
}

pd_key_ensure() {
  [[ -f "$PD_KEY" ]] && return 0
  install -d -m 700 "$(dirname "$PD_KEY")" || return 1
  ssh-keygen -q -t ed25519 -N '' -C "vps-panel@$(hostname)" -f "$PD_KEY" || return 1
  chmod 600 "$PD_KEY"
}

pd_latest_tag() {
  pd_git tag -l 'v*' | { grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true; } | sort -V | tail -n 1
}

pd_current_tag() {
  pd_git describe --tags --exact-match HEAD 2>/dev/null || true
}

# pd_ver_gt A B — vero se la versione A (senza v) è maggiore di B.
pd_ver_gt() {
  [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]
}

# pd_checkout TAG — codice al rilascio TAG; config/.env, logs/ e storage/ sono
# ignorati da git e restano come sono. Tutto torna dell'utente panel.
pd_checkout() {
  pd_git checkout -q -f "$1" || return 1
  own -R panel:panel "$PANEL_ROOT" || return 1
}

# pd_env_merge TOKEN — APP_KEY solo se manca (cambiarla renderebbe illeggibili i
# segreti cifrati), TELEGRAM_BOT_TOKEN se TOKEN non è vuoto.
pd_env_merge() {
  local lines=""
  if [[ -z "$(env_get "$PD_ENV" APP_KEY)" ]]; then
    lines+="APP_KEY=$(openssl rand -base64 32)"$'\n'
  fi
  if [[ -n "$1" ]]; then
    lines+="TELEGRAM_BOT_TOKEN=$1"$'\n'
  fi
  [[ -n "$lines" ]] || return 0
  printf '%s' "$lines" | env_merge "$PD_ENV" 600 panel:panel
}

pd_db_name() {
  local db
  db="$(env_get "$PD_ENV" DB_NAME)"
  sql_ident_ok "$db" || return 1
  printf '%s\n' "$db"
}

# pd_as_panel CMD... — come utente panel (PD_AS_PANEL=0 solo nei test).
pd_as_panel() {
  if [[ "${PD_AS_PANEL:-1}" == 0 ]]; then
    "$@"
  else
    runuser -u panel -- "$@"
  fi
}
```

Nota: `sql_ident_ok` chiama… solo una regex, nessun `die`: va bene qui. `own` non fa niente con `VPS_NO_CHOWN=1` (test).

- [ ] **Step 7: Esegui** — come Step 5, poi la suite intera (`bash tests/run.sh`). Expected: verdi, shellcheck pulito.

- [ ] **Step 8: Commit**

```bash
git add lib/panel_deploy.sh templates/github-known-hosts tests/panel_helper.bash tests/panel_deploy.bats
git commit -m "feat(panel): deploy library, git with a root-only deploy key

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 5: `lib/panel_deploy.sh` — database, migrazioni, dump, health, manifest, cron

**Files:**
- Modify: `lib/panel_deploy.sh`
- Create: `templates/cron-vps-panel`
- Test: `tests/panel_deploy.bats`

**Interfaces:**
- Consumes: Task 4.
- Produces:
  - `pd_schema` → `mariadb DB < install/schema.sql`
  - `pd_migrations DA A` (con o senza `v`) → applica `install/migrations/X.Y.Z.sql` con `DA < X.Y.Z ≤ A`, in ordine
  - `pd_dump TAG` → stampa il percorso del dump creato; tiene gli ultimi 5
  - `pd_restore FILE` → ricrea il DB e carica il dump
  - `pd_reload_php`, `pd_php_lint`, `pd_health` → 0/1
  - `pd_super_admin_exists` → 0 sì, 1 no, 2 non leggibile
  - `pd_telegram_ok TOKEN` → 0/1
  - `pd_cron_install`, `pd_manifest TAG`

- [ ] **Step 1: Test che falliscono** — aggiungi a `tests/panel_deploy.bats`:

```bash
@test "pd_schema passa schema.sql al database del .env" {
  pd_test_installed v1.0.0
  pd_schema
  grep -qx -- '-- schema' "$BATS_TEST_TMPDIR/mariadb.sql"
  grep -qx panel "$BATS_TEST_TMPDIR/mariadb.args"
}

@test "pd_migrations: solo l'intervallo (DA, A], in ordine di versione" {
  pd_test_tag v1.10.0 install/migrations/1.10.0.sql '-- migrazione 1.10.0'
  printf -- '-- migrazione 1.2.0\n' >"$PD_WORK/install/migrations/1.2.0.sql"
  printf -- '-- migrazione 1.0.0\n' >"$PD_WORK/install/migrations/1.0.0.sql"
  printf 'non sql\n' >"$PD_WORK/install/migrations/note.txt"
  pd_test_tag v1.11.0
  pd_test_installed v1.11.0
  pd_migrations v1.0.0 v1.10.0
  run cat "$BATS_TEST_TMPDIR/mariadb.sql"
  [ "${lines[0]}" = "-- migrazione 1.1.0" ]
  [ "${lines[1]}" = "-- migrazione 1.2.0" ]
  [ "${lines[2]}" = "-- migrazione 1.10.0" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "pd_migrations si ferma alla prima che fallisce" {
  pd_test_installed v1.1.0
  MARIADB_RC=1 run pd_migrations v1.0.0 v1.1.0
  [ "$status" -eq 1 ]
}

@test "pd_dump scrive un gzip 600 e tiene gli ultimi 5" {
  pd_test_installed v1.0.0
  mkdir -p "$PD_BACKUPS"
  for i in 1 2 3 4 5 6; do
    : >"$PD_BACKUPS/vecchio-$i.sql.gz"
    touch -d "2020-01-0$i" "$PD_BACKUPS/vecchio-$i.sql.gz"
  done
  f="$(pd_dump v1.0.0)"
  [ -f "$f" ]
  [[ "$(basename "$f")" == v1.0.0-*.sql.gz ]]
  [ "$(stat -c %a "$f")" = 600 ]
  [ "$(stat -c %a "$PD_BACKUPS")" = 700 ]
  gunzip -c "$f" | grep -q -- '-- dump'
  [ "$(find "$PD_BACKUPS" -name '*.sql.gz' | wc -l)" -eq 5 ]
  [ ! -f "$PD_BACKUPS/vecchio-1.sql.gz" ]
  [ ! -f "$PD_BACKUPS/vecchio-2.sql.gz" ]
}

@test "pd_restore ricrea il database e carica il dump" {
  pd_test_installed v1.0.0
  printf -- '-- contenuto\n' | gzip >"$BATS_TEST_TMPDIR/d.sql.gz"
  pd_restore "$BATS_TEST_TMPDIR/d.sql.gz"
  grep -q 'DROP DATABASE IF EXISTS `panel`' "$BATS_TEST_TMPDIR/mariadb.args"
  grep -qx -- '-- contenuto' "$BATS_TEST_TMPDIR/mariadb.sql"
}

@test "pd_health: OK passa, altrimenti tre tentativi e fallisce" {
  pd_load
  pd_health
  rm -f "$BATS_TEST_TMPDIR/curl.calls"
  CURL_RC=22 run pd_health
  [ "$status" -eq 1 ]
  [ "$(wc -l <"$BATS_TEST_TMPDIR/curl.calls")" -eq 3 ]
  CURL_OUT=NO run pd_health
  [ "$status" -eq 1 ]
}

@test "pd_php_lint fallisce se un file non compila" {
  pd_test_installed v1.0.0
  pd_php_lint
  PHP_LINT_RC=255 run pd_php_lint
  [ "$status" -ne 0 ]
}

@test "pd_super_admin_exists: sì, no, prefisso non valido" {
  pd_load
  MARIADB_OUT=1 pd_super_admin_exists
  MARIADB_OUT=0 run pd_super_admin_exists
  [ "$status" -eq 1 ]
  grep -q 'vp_users' "$BATS_TEST_TMPDIR/mariadb.args"
  printf 'DB_PREFIX=x`;\n' >>"$PD_ENV"
  run pd_super_admin_exists
  [ "$status" -eq 2 ]
}

@test "pd_telegram_ok rifiuta un formato sbagliato senza chiamare Telegram" {
  PD_SKIP_TELEGRAM_CHECK=0 run pd_telegram_ok "corto"
  [ "$status" -eq 1 ]
  [ ! -f "$BATS_TEST_TMPDIR/curl.calls" ]
}

@test "pd_telegram_ok: il token non finisce negli argomenti di curl" {
  make_stub curl 'printf "%s\n" "$*" >"$BATS_TEST_TMPDIR/curl.argv"; cat >"$BATS_TEST_TMPDIR/curl.stdin"; echo "{\"ok\":true}"'
  PD_SKIP_TELEGRAM_CHECK=0 pd_telegram_ok "123456:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  ! grep -q AAAAAAAA "$BATS_TEST_TMPDIR/curl.argv"
  grep -q 'bot123456:AAAAAAAA' "$BATS_TEST_TMPDIR/curl.stdin"
}

@test "pd_cron_install e pd_manifest" {
  pd_load
  pd_cron_install
  grep -q "^0 3 \* \* \* panel /usr/bin/php $P/app/cron/maintenance.php" "$PD_CRON"
  [ "$(stat -c %a "$PD_CRON")" = 644 ]
  pd_manifest v2.1.0
  [ "$(jq -r .panel.version "$VPS_OPT/manifest.json")" = 2.1.0 ]
  [ "$(jq -r .panel.repo "$VPS_OPT/manifest.json")" = "$PANEL_REPO" ]
  [ "$(jq -r .panel.deployed_at "$VPS_OPT/manifest.json")" != null ]
  [ "$(jq -r .panel.domain "$VPS_OPT/manifest.json")" = panel.test ]
}
```

- [ ] **Step 2: Esegui** — Expected: FAIL.

- [ ] **Step 3: `templates/cron-vps-panel`**

```
# vps-installer: manutenzione notturna di Plancia (registri, tabelle di servizio)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 3 * * * panel /usr/bin/php ${PANEL_ROOT}/app/cron/maintenance.php >/dev/null 2>&1
```

- [ ] **Step 4: Implementa** — aggiungi in fondo a `lib/panel_deploy.sh`:

```bash
pd_schema() {
  local db
  db="$(pd_db_name)" || return 1
  mariadb "$db" <"$PANEL_ROOT/install/schema.sql" || return 1
}

# pd_migrations DA A — install/migrations/X.Y.Z.sql con DA < X.Y.Z ≤ A, in ordine.
pd_migrations() {
  local from="${1#v}" to="${2#v}" db f v
  db="$(pd_db_name)" || return 1
  while IFS= read -r f; do
    v="$(basename "$f" .sql)"
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    if pd_ver_gt "$v" "$from" && ! pd_ver_gt "$v" "$to"; then
      log "Plancia: migrazione $v"
      mariadb "$db" <"$f" || return 1
    fi
  done < <(find "$PANEL_ROOT/install/migrations" -maxdepth 1 -name '*.sql' 2>/dev/null | sort -V)
}

# pd_dump TAG — dump gzip del database del pannello; stampa il percorso.
pd_dump() {
  local db f
  db="$(pd_db_name)" || return 1
  install -d -m 700 "$PD_BACKUPS" || return 1
  f="$PD_BACKUPS/${1:-senza-tag}-$(date +%Y%m%d-%H%M%S).sql.gz"
  (
    set -o pipefail
    umask 077
    mariadb-dump --single-transaction --routines --events "$db" | gzip >"$f"
  ) || { rm -f "$f"; return 1; }
  find "$PD_BACKUPS" -maxdepth 1 -name '*.sql.gz' -printf '%T@ %p\n' | sort -rn | tail -n +6 \
    | cut -d' ' -f2- | xargs -r rm -f --
  printf '%s\n' "$f"
}

# pd_restore FILE — il database torna esattamente al dump (anche le tabelle create dopo spariscono).
pd_restore() {
  local db
  db="$(pd_db_name)" || return 1
  mariadb -e "DROP DATABASE IF EXISTS \`$db\`; CREATE DATABASE \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || return 1
  (set -o pipefail; gunzip -c "$1" | mariadb "$db") || return 1
}

pd_reload_php() {
  systemctl reload "php$PHP_VERSION-fpm" >>"$VPS_LOG" 2>&1 || return 1
}

pd_php_lint() {
  find "$PANEL_ROOT/app" "$PANEL_ROOT/public" -name '*.php' -print0 2>/dev/null \
    | xargs -0 -r -n 1 -P 4 "$PD_PHP" -l >>"$VPS_LOG" 2>&1 || return 1
}

# pd_health — /health del pannello in locale (Cloudflare e DNS non c'entrano).
pd_health() {
  local url="${PD_HEALTH_URL:-https://$PANEL_DOMAIN/health}"
  local resolve="${PD_CURL_RESOLVE-$PANEL_DOMAIN:443:127.0.0.1}" body
  for _ in 1 2 3; do
    body="$(curl -skf --max-time 5 ${resolve:+--resolve "$resolve"} "$url" 2>/dev/null)" && [[ "$body" == OK ]] && return 0
    sleep "${PD_HEALTH_SLEEP:-2}"
  done
  return 1
}

# pd_super_admin_exists — 0 sì, 1 no, 2 database o prefisso non leggibili.
pd_super_admin_exists() {
  local db prefix n
  db="$(pd_db_name)" || return 2
  prefix="$(env_get "$PD_ENV" DB_PREFIX)"
  prefix="${prefix:-vp_}"
  [[ "$prefix" =~ ^[a-z0-9_]{0,20}$ ]] || return 2
  n="$(mariadb -N -B -e "SELECT COUNT(*) FROM \`${prefix}users\` WHERE role = 'super_admin'" "$db")" || return 2
  [[ "$n" =~ ^[0-9]+$ ]] || return 2
  ((n > 0)) || return 1
}

# pd_telegram_ok TOKEN — formato, poi getMe. Il token passa a curl su stdin
# (file di configurazione), mai come argomento: gli argomenti si vedono in ps.
pd_telegram_ok() {
  [[ "$1" =~ ^[0-9]{5,15}:[A-Za-z0-9_-]{30,60}$ ]] || return 1
  [[ "${PD_SKIP_TELEGRAM_CHECK:-0}" == 1 ]] && return 0
  printf 'url = "https://api.telegram.org/bot%s/getMe"\n' "$1" \
    | curl -sf --max-time 10 -K - 2>/dev/null | jq -e '.ok == true' >/dev/null 2>&1 || return 1
}

pd_cron_install() {
  render_template "$VPS_TEMPLATES/cron-vps-panel" "$PD_CRON" 644 root:root PANEL_ROOT
}

pd_manifest() {
  manifest_set '.panel.version = $v | .panel.deployed_at = $t | .panel.repo = $r' \
    --arg v "${1#v}" --arg t "$(date -Iseconds)" --arg r "$PANEL_REPO"
}
```

Nota: `render_template` esporta `PANEL_ROOT`; se `tests/template.bats` controlla che ogni `${VAR}` dei template sia in `KNOWN_TEMPLATE_VARS`/`ANSWER_VARS`, `PANEL_ROOT` c'è già. `write_file` usa `own` (no-op nei test).

- [ ] **Step 5: Esegui** — `bash tests/run.sh` intera. Expected: verdi.

- [ ] **Step 6: Commit**

```bash
git add lib/panel_deploy.sh templates/cron-vps-panel tests/panel_deploy.bats
git commit -m "feat(panel): schema, migrations, dump/restore, health check helpers

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 6: `install.sh --tools-only` e manifest che conserva il pannello

**Files:**
- Create: `lib/opt.sh`, `tests/opt.bats`
- Modify: `steps/95-vps-tools.sh`, `lib/manifest.sh` (`manifest_write`), `run.sh` (`main`), `install.sh` (`usage`, `main`)
- Test: `tests/manifest.bats`

**Interfaces:**
- Produces: `opt_install_files` (copia `lib/`, `templates/`, `tools/vps-*` in `/opt/vps`); `opt_tools_only` (richiede il manifest, chiama `opt_install_files`, aggiorna `installer_version`); `run.sh --tools-only`; `install.sh --tools-only`.

- [ ] **Step 1: Test che falliscono**

`tests/opt.bats`:

```bash
setup() {
  load test_helper
  setup_common
  VPS_ROOT="$REPO_ROOT"
}

@test "opt_tools_only rifiuta una macchina mai installata" {
  run opt_tools_only
  [ "$status" -eq 1 ]
  [[ "$output" == *"mai installata"* ]]
}

@test "opt_tools_only ricopia gli script e conserva il manifest" {
  jq -n '{installer_version:"1.0.3", admin_user:"manu", panel:{domain:"p.test", path:"/var/www/p.test", version:"2.1.0"}}' >"$VPS_OPT/manifest.json"
  opt_tools_only
  [ -x "$VPS_OPT/bin/vps-panel-install" ]
  [ -x "$VPS_OPT/bin/vps-panel-update" ]
  [ -f "$VPS_OPT/lib/panel_deploy.sh" ]
  [ -f "$VPS_OPT/templates/github-known-hosts" ]
  [ "$(jq -r .installer_version "$VPS_OPT/manifest.json")" = "$VPS_INSTALLER_VERSION" ]
  [ "$(jq -r .admin_user "$VPS_OPT/manifest.json")" = manu ]
  [ "$(jq -r .panel.version "$VPS_OPT/manifest.json")" = 2.1.0 ]
}

@test "install.sh e run.sh conoscono --tools-only" {
  grep -q -- '--tools-only' "$REPO_ROOT/install.sh"
  grep -q -- '--tools-only' "$REPO_ROOT/run.sh"
}
```

Il test `-x vps-panel-install` passa solo dopo il Task 7: nel Task 6 scrivi il test con `vps-status` al posto dei due script nuovi, e il Task 7 lo aggiorna (Step 1 del Task 7).

In `tests/manifest.bats` aggiungi:

```bash
@test "manifest_write conserva version, deployed_at e repo del pannello" {
  manifest_write
  manifest_set '.panel.version = "2.1.0" | .panel.deployed_at = "2026-10-11T10:00:00+02:00" | .panel.repo = "git@github.com:IImanuII/vps-panel.git"'
  manifest_write
  [ "$(jq -r .panel.version "$VPS_OPT/manifest.json")" = 2.1.0 ]
  [ "$(jq -r .panel.repo "$VPS_OPT/manifest.json")" = "git@github.com:IImanuII/vps-panel.git" ]
  [ "$(jq -r .panel.domain "$VPS_OPT/manifest.json")" = panel.miosito.it ]
}

@test "manifest_write senza pannello non resuscita i campi vecchi" {
  manifest_write
  manifest_set '.panel.version = "2.1.0"'
  PANEL_ENABLED=no
  manifest_write
  [ "$(jq -r .panel "$VPS_OPT/manifest.json")" = null ]
}
```

- [ ] **Step 2: Esegui** — Expected: FAIL.

- [ ] **Step 3: `lib/opt.sh`**

```bash
# shellcheck shell=bash
# /opt/vps: script, librerie e template dell'installer.

opt_install_files() {
  install -d -m 755 "$VPS_OPT" "$VPS_OPT/bin" "$VPS_OPT/lib" "$VPS_OPT/templates"
  install -d -m 700 "$VPS_OPT/secrets"
  install -m 644 "$VPS_ROOT"/lib/*.sh "$VPS_OPT/lib/"
  install -m 644 "$VPS_ROOT"/templates/* "$VPS_OPT/templates/"
  install -m 755 "$VPS_ROOT"/tools/vps-* "$VPS_OPT/bin/"
}

# opt_tools_only — aggiorna gli script su una VPS già installata, senza procedura guidata.
opt_tools_only() {
  [[ -f "$(manifest_path)" ]] || die "Manifest assente: questa VPS non è mai stata installata. Lancia install.sh senza --tools-only."
  opt_install_files
  manifest_set '.installer_version = $v' --arg v "$VPS_INSTALLER_VERSION"
  log "Script di /opt/vps aggiornati alla versione $VPS_INSTALLER_VERSION."
}
```

`steps/95-vps-tools.sh`: sostituisci le cinque righe `install -d … install -m 755 … tools/vps-*` con `opt_install_files`.

`lib/manifest.sh`, `manifest_write`:

```bash
# I campi che scrive vps-panel-install (version, deployed_at, repo) non vengono
# dalla procedura guidata: si conservano quando il manifest si riscrive.
manifest_write() {
  local f old=null
  f="$(manifest_path)"
  if [[ -f "$f" ]]; then
    old="$(jq -c '.panel // null | if . == null then null else {version, deployed_at, repo} end' "$f" 2>/dev/null)" || old=null
  fi
  manifest_build \
    | jq --argjson old "${old:-null}" 'if .panel != null and $old != null then .panel += ($old | with_entries(select(.value != null))) else . end' \
    | write_file "$f" 640 "root:$(manifest_group)"
}
```

`run.sh`, in `main` subito dopo `chmod 600 "$VPS_LOG"`:

```bash
  if [[ "${1:-}" == "--tools-only" ]]; then
    opt_tools_only
    return
  fi
```

`install.sh`: in `usage` aggiungi la riga `  --tools-only      aggiorna solo gli script di /opt/vps (VPS già installata)`; nel `case` di `main`:

```bash
      --tools-only) run_args+=(--tools-only); tools_only=1; shift ;;
```

dichiara `tools_only=0` fra i `local` di `main`, e dopo `bash "$VPS_DEST/run.sh" "${run_args[@]}" || { … }` aggiungi:

```bash
  if ((tools_only)); then
    rm -rf "$VPS_DEST"
    echo "Script di /opt/vps aggiornati. Per il pannello: sudo vps-panel-install (prima volta) o sudo vps-panel-update."
  fi
```

(Con `--tools-only` non ci sono segreti in `VPS_DEST`: la cartella si toglie subito, come fa `99-finalize` a fine installazione.)

- [ ] **Step 4: Esegui** — `bash tests/run.sh`. Expected: verdi.

- [ ] **Step 5: Commit**

```bash
git add lib/opt.sh lib/manifest.sh steps/95-vps-tools.sh run.sh install.sh tests/opt.bats tests/manifest.bats
git commit -m "feat(install): --tools-only updates /opt/vps on an installed VPS

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 7: `tools/vps-panel-install`

**Files:**
- Create: `tools/vps-panel-install`, `tests/panel_install.bats`
- Modify: `tests/opt.bats` (il test che usava `vps-status` torna a `vps-panel-install`; aggiungi `-x vps-panel-update` solo nel Task 8)

**Interfaces:**
- Consumes: tutte le `pd_*` dei Task 4-5; `create-admin.php --dry-run` (Task 2).
- Produces: comando `vps-panel-install` (nessun argomento; `-h`). Uscita 0 riuscito, 1 errore. Input da stdin in quest'ordine: [Invio per la chiave, solo se GitHub non la accetta ancora] → token (solo se manca nel `.env`) → username → id Telegram → password → password ripetuta (solo se nessun super_admin esiste).

- [ ] **Step 1: Test che falliscono** — `tests/panel_install.bats`:

```bash
setup() {
  load test_helper
  load panel_helper
  setup_common
  pd_test_setup
  T="$REPO_ROOT/tools/vps-panel-install"
  TOKEN="123456:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
}

answers() { printf '%s\n' "$TOKEN" manu 123456789 'Una-Password-12!' 'Una-Password-12!'; }

@test "installa l'ultimo rilascio dall'inizio alla fine" {
  run bash -c "$(declare -f answers); TOKEN='$TOKEN'; answers | bash '$T'"
  [ "$status" -eq 0 ]
  [ "$(git -C "$P" describe --tags --exact-match)" = v1.1.0 ]
  [ ! -f "$P/public/index.html" ]
  [ -n "$(env_get "$P/config/.env" APP_KEY)" ]
  [ "$(env_get "$P/config/.env" TELEGRAM_BOT_TOKEN)" = "$TOKEN" ]
  grep -qx -- '-- schema' "$BATS_TEST_TMPDIR/mariadb.sql"
  grep -q -- '--username=manu --telegram-id=123456789' "$BATS_TEST_TMPDIR/php.args"
  grep -qx 'Una-Password-12!' "$BATS_TEST_TMPDIR/php.stdin"
  [ -f "$PD_CRON" ]
  grep -q 'reload php8.4-fpm' "$BATS_TEST_TMPDIR/systemctl.args"
  [ "$(jq -r .panel.version "$VPS_OPT/manifest.json")" = 1.1.0 ]
  [[ "$output" == *"https://panel.test/login"* ]]
  ! grep -q 'Una-Password-12!' "$VPS_LOG"
  ! grep -q AAAAAAAAAAAA "$VPS_LOG"
}

@test "rifiuta se Plancia è già installata" {
  manifest_set '.panel.version = "1.0.0"'
  run bash "$T" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"vps-panel-update"* ]]
}

@test "rilancio dopo un'interruzione: niente seconda APP_KEY, niente secondo super_admin, token non richiesto" {
  printf 'APP_KEY=chiave-esistente\nTELEGRAM_BOT_TOKEN=%s\n' "$TOKEN" >>"$P/config/.env"
  pd_key_ensure
  key="$(cat "$PD_KEY.pub")"
  MARIADB_OUT=1 run bash "$T" </dev/null
  [ "$status" -eq 0 ]
  [ "$(grep -c '^APP_KEY=' "$P/config/.env")" -eq 1 ]
  grep -qx 'APP_KEY=chiave-esistente' "$P/config/.env"
  [ "$(cat "$PD_KEY.pub")" = "$key" ]
  [ ! -f "$BATS_TEST_TMPDIR/php.args" ]
}

@test "dati del super_admin non validi: li richiede" {
  run bash -c "printf '%s\n' '$TOKEN' a 1 'x' 'x' manu 123456789 'Una-Password-12!' 'Una-Password-12!' | PHP_DRY_FAILS=1 bash '$T'"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/dry.n")" -eq 2 ]
  grep -q -- '--username=manu' "$BATS_TEST_TMPDIR/php.args"
}

@test "password ripetuta diversa: la richiede" {
  run bash -c "printf '%s\n' '$TOKEN' manu 123456789 'Una-Password-12!' 'Altra-Password-12!' manu 123456789 'Una-Password-12!' 'Una-Password-12!' | bash '$T'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"non coincidono"* ]]
}

@test "input finito a metà: esce con 1 e non resta in attesa" {
  run timeout 20 bash -c "printf '%s\n' '$TOKEN' manu | bash '$T'"
  [ "$status" -eq 1 ]
  [ "$(jq -r '.panel.version // empty' "$VPS_OPT/manifest.json")" = "" ]
}

@test "token Telegram non valido tre volte: esce senza toccare il codice" {
  run bash -c "printf 'corto\ncorto\ncorto\n' | bash '$T'"
  [ "$status" -eq 1 ]
  [ ! -d "$P/.git" ]
}

@test "repository senza rilasci: errore chiaro" {
  git init -q --bare "$BATS_TEST_TMPDIR/vuoto.git"
  run bash -c "$(declare -f answers); TOKEN='$TOKEN'; answers | PANEL_REPO='$BATS_TEST_TMPDIR/vuoto.git' bash '$T'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Nessun rilascio"* ]]
}

@test "/health che non risponde: uscita 1 e manifest senza versione" {
  run bash -c "$(declare -f answers); TOKEN='$TOKEN'; answers | CURL_RC=7 bash '$T'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"/health"* ]]
  [ "$(jq -r '.panel.version // empty' "$VPS_OPT/manifest.json")" = "" ]
}

@test "sotto sudo l'ambiente del chiamante non conta" {
  grep -q 'unset PANEL_REPO' "$T"
}
```

Nota sul test "repository senza rilasci": il repository vuoto rende `git ls-remote` riuscito (repository raggiungibile), quindi il flusso arriva al fetch e si ferma su "Nessun rilascio".

- [ ] **Step 2: Esegui** — `bash tests/run.sh tests/panel_install.bats`. Expected: FAIL (script inesistente).

- [ ] **Step 3: Implementa `tools/vps-panel-install`** (eseguibile, `chmod +x`; in git `git update-index --chmod=+x`)

```bash
#!/usr/bin/env bash
# vps-panel-install — prima installazione di Plancia nella radice del pannello.
# Interattivo: lo lancia l'amministratore con sudo, non il pannello. Si può
# rilanciare dopo un'interruzione: ogni passo salta ciò che è già fatto.
# Sotto sudo l'ambiente del chiamante non deve influenzare lo script.
if [[ -n "${SUDO_USER:-}" ]]; then
  VPS_OPT=/opt/vps
  VPS_LIB=$VPS_OPT/lib
  VPS_TEMPLATES=$VPS_OPT/templates
  VPS_LOG=/var/log/vps-tools.log
  unset PANEL_REPO PD_REPO_WEB PD_KEY PD_KNOWN_HOSTS PD_BACKUPS PD_CRON PD_LOCK PD_PHP PD_AS_PANEL \
    PD_HEALTH_URL PD_CURL_RESOLVE PD_HEALTH_SLEEP PD_SKIP_TELEGRAM_CHECK PD_TEST VPS_NO_CHOWN
  [[ -e "$VPS_LOG" ]] || install -m 640 /dev/null "$VPS_LOG"
  chmod 640 "$VPS_LOG"
fi
: "${VPS_OPT:=/opt/vps}" "${VPS_LOG:=/var/log/vps-tools.log}"
: "${VPS_TEMPLATES:=$VPS_OPT/templates}"
for _lib in "${VPS_LIB:-$VPS_OPT/lib}"/*.sh; do
  # shellcheck source=/dev/null
  source "$_lib"
done

say() {
  printf '%s\n' "$*"
  log "$*" 2>/dev/null
}

# ask VAR PROMPT [silent] — una riga da stdin; EOF = uscita con errore.
ask() {
  local __v
  if [[ "${3:-}" == silent ]]; then
    IFS= read -r -s -p "$2" __v || { echo; die "Input interrotto"; }
    echo
  else
    IFS= read -r -p "$2" __v || die "Input interrotto"
  fi
  printf -v "$1" '%s' "$(trim "$__v")"
}

install_key() {
  local n
  pd_key_ensure || die "Deploy key non creata"
  if pd_git ls-remote "$PANEL_REPO" >/dev/null 2>>"$VPS_LOG"; then
    return 0
  fi
  for n in 1 2 3 4 5; do
    cat <<EOF

Aggiungi questa deploy key al repository, SENZA "Allow write access":
  $PD_REPO_WEB/settings/keys/new
  Titolo: $(hostname)
  Chiave: $(cat "$PD_KEY.pub")

EOF
    ask _ "Premi Invio quando l'hai aggiunta... "
    if pd_git ls-remote "$PANEL_REPO" >/dev/null 2>>"$VPS_LOG"; then
      return 0
    fi
    say "GitHub non accetta ancora la chiave (tentativo $n di 5)."
  done
  die "Deploy key non accettata: rilancia sudo vps-panel-install dopo averla aggiunta"
}

install_token() {
  local n t
  TOKEN=""
  [[ -z "$(env_get "$PD_ENV" TELEGRAM_BOT_TOKEN)" ]] || return 0
  for n in 1 2 3; do
    ask t "Token del bot Telegram (da @BotFather): " silent
    if pd_telegram_ok "$t"; then
      TOKEN="$t"
      return 0
    fi
    say "Token non valido o rifiutato da Telegram (tentativo $n di 3)."
  done
  die "Token Telegram non valido"
}

install_code() {
  if [[ ! -d "$PANEL_ROOT/.git" ]]; then
    pd_git init -q -b main || die "git init non riuscito in $PANEL_ROOT"
  fi
  pd_git remote remove origin >/dev/null 2>&1 || true
  pd_git remote add origin "$PANEL_REPO" || die "Remote non impostato"
  pd_git fetch -q --tags origin 2>>"$VPS_LOG" || die "Download del codice non riuscito"
  TAG="$(pd_latest_tag)"
  [[ -n "$TAG" ]] || die "Nessun rilascio vX.Y.Z nel repository"
  say "Plancia: scarico $TAG"
  pd_checkout "$TAG" || die "Checkout di $TAG non riuscito"
  rm -f "$PANEL_ROOT/public/index.html"
}

install_admin() {
  local rc=0 n u id p p2 cli="$PANEL_ROOT/app/cli/create-admin.php"
  pd_super_admin_exists || rc=$?
  if ((rc == 0)); then
    say "Super admin già presente: salto."
    return 0
  fi
  ((rc == 1)) || die "Non riesco a leggere gli utenti dal database"
  for n in 1 2 3 4 5; do
    ask u "Username del super_admin: "
    ask id "Il tuo id Telegram (numerico, lo dice @userinfobot): "
    ask p "Password (almeno 12 caratteri, maiuscola, cifra, carattere speciale): " silent
    ask p2 "Ripeti la password: " silent
    if [[ "$p" != "$p2" ]]; then
      say "Le password non coincidono (tentativo $n di 5)."
      continue
    fi
    if printf '%s\n' "$p" | pd_as_panel "$PD_PHP" "$cli" --dry-run --username="$u" --telegram-id="$id"; then
      printf '%s\n' "$p" | pd_as_panel "$PD_PHP" "$cli" --username="$u" --telegram-id="$id" \
        || die "Super admin non creato"
      return 0
    fi
    say "Dati non validi (tentativo $n di 5)."
  done
  die "Super admin non creato: troppi tentativi"
}

main() {
  local c v
  enable_error_trap
  case "${1:-}" in
    -h | --help) echo "Uso: sudo vps-panel-install   (prima installazione di Plancia)"; exit 0 ;;
    "") ;;
    *) die "Opzione sconosciuta: $1" ;;
  esac
  ((EUID == 0)) || [[ "${PD_TEST:-}" == 1 ]] || die "Esegui con: sudo vps-panel-install"
  pd_load
  for c in git curl jq mariadb mariadb-dump ssh-keygen "$PD_PHP"; do
    command -v "$c" >/dev/null 2>&1 || die "Manca il comando $c"
  done
  v="$(jq -r '.panel.version // empty' "$(manifest_path)")"
  [[ -z "$v" ]] || die "Plancia è già installata (v$v): usa sudo vps-panel-update"

  install_key
  install_token
  install_code
  pd_env_merge "$TOKEN" || die ".env non aggiornato"
  TOKEN=""
  pd_schema || die "Schema del database non applicato"
  install_admin
  pd_cron_install
  pd_reload_php || die "Reload di PHP-FPM non riuscito"
  pd_health || die "Il pannello non risponde su /health: guarda $PANEL_ROOT/logs/ e $VPS_LOG"
  pd_manifest "$TAG"
  say "Plancia $TAG installata: https://$PANEL_DOMAIN/login"
}

main "$@"
```

Note per l'implementatore:
- `ask _ "..."` assegna a `_`: va bene (`printf -v _`), ma se shellcheck o bash protestano usa una variabile `invio`.
- `die` di `common.sh` scrive nel log e su stderr; in bats `run` cattura entrambi (`$output`).
- Il token non è mai esportato: `TOKEN` è una variabile di shell, passata come argomento a **funzioni** (non a processi), poi azzerata.

- [ ] **Step 4: Aggiorna `tests/opt.bats`** — nel test "ricopia gli script", controlla `-x "$VPS_OPT/bin/vps-panel-install"`.

- [ ] **Step 5: Esegui** — `bash tests/run.sh`. Expected: verdi.

- [ ] **Step 6: Commit**

```bash
git add tools/vps-panel-install tests/panel_install.bats tests/opt.bats
git commit -m "feat(panel): vps-panel-install, first deploy of Plancia

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 8: `tools/vps-panel-update`

**Files:**
- Create: `tools/vps-panel-update`, `tests/panel_update.bats`
- Modify: `tests/opt.bats` (aggiungi `[ -x "$VPS_OPT/bin/vps-panel-update" ]`)

**Interfaces:**
- Consumes: `pd_*` dei Task 4-5.
- Produces: comando `vps-panel-update [--ref vX.Y.Z]`. Uscite: 0 aggiornata o già aggiornata; 1 errore con ritorno alla versione precedente riuscito (o nessuna modifica fatta); 2 ritorno indietro fallito.

- [ ] **Step 1: Test che falliscono** — `tests/panel_update.bats`:

```bash
setup() {
  load test_helper
  load panel_helper
  setup_common
  pd_test_setup
  T="$REPO_ROOT/tools/vps-panel-update"
}

@test "aggiorna all'ultimo rilascio con migrazione e manifest" {
  pd_test_installed v1.0.0
  run bash "$T"
  [ "$status" -eq 0 ]
  [ "$(git -C "$P" describe --tags --exact-match)" = v1.1.0 ]
  grep -qx -- '-- schema' "$BATS_TEST_TMPDIR/mariadb.sql"
  grep -qx -- '-- migrazione 1.1.0' "$BATS_TEST_TMPDIR/mariadb.sql"
  [ "$(jq -r .panel.version "$VPS_OPT/manifest.json")" = 1.1.0 ]
  [ "$(find "$PD_BACKUPS" -name 'v1.0.0-*.sql.gz' | wc -l)" -eq 1 ]
  [[ "$output" == *"v1.0.0 → v1.1.0"* ]]
}

@test "già aggiornata: uscita 0, niente dump" {
  pd_test_installed v1.1.0
  run bash "$T"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Già aggiornata"* ]]
  [ ! -d "$PD_BACKUPS" ]
}

@test "non installata: rimanda a vps-panel-install" {
  run bash "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"vps-panel-install"* ]]
}

@test "/health rotto: torna alla versione di prima, codice e database" {
  pd_test_installed v1.0.0
  CURL_RC=22 run bash "$T"
  [ "$status" -eq 1 ]
  [ "$(git -C "$P" describe --tags --exact-match)" = v1.0.0 ]
  grep -q 'DROP DATABASE IF EXISTS `panel`' "$BATS_TEST_TMPDIR/mariadb.args"
  [ "$(jq -r .panel.version "$VPS_OPT/manifest.json")" = 1.0.0 ]
  [[ "$output" == *"/health"* ]]
  [[ "$output" == *".sql.gz"* ]]
}

@test "php -l fallito: rollback" {
  pd_test_installed v1.0.0
  PHP_LINT_RC=255 run bash "$T"
  [ "$status" -eq 1 ]
  [ "$(git -C "$P" describe --tags --exact-match)" = v1.0.0 ]
}

@test "ritorno indietro impossibile (database giù): uscita 2 col percorso del dump" {
  pd_test_installed v1.0.0
  MARIADB_RC=1 run bash "$T"
  [ "$status" -eq 2 ]
  [[ "$output" == *"$PD_BACKUPS/v1.0.0-"* ]]
  [ "$(jq -r .panel.version "$VPS_OPT/manifest.json")" = 1.0.0 ]
}

@test "dump fallito: nessuna modifica" {
  pd_test_installed v1.0.0
  make_stub mariadb-dump 'exit 1'
  run bash "$T"
  [ "$status" -eq 1 ]
  [ "$(git -C "$P" describe --tags --exact-match)" = v1.0.0 ]
}

@test "--ref: formato e esistenza" {
  pd_test_installed v1.0.0
  run bash "$T" --ref v1.1
  [ "$status" -eq 1 ]
  run bash "$T" --ref v9.9.9
  [ "$status" -eq 1 ]
  [[ "$output" == *"non esiste"* ]]
  run bash "$T" --ref
  [ "$status" -eq 1 ]
}

@test "--ref a una versione più vecchia: solo codice, avviso, niente migrazioni" {
  pd_test_installed v1.1.0
  run bash "$T" --ref v1.0.0
  [ "$status" -eq 0 ]
  [ "$(git -C "$P" describe --tags --exact-match)" = v1.0.0 ]
  [[ "$output" == *"ATTENZIONE"* ]]
  [ ! -f "$BATS_TEST_TMPDIR/mariadb.sql" ]
  [ "$(jq -r .panel.version "$VPS_OPT/manifest.json")" = 1.0.0 ]
}

@test "un secondo aggiornamento in corso: esce subito" {
  pd_test_installed v1.0.0
  exec 8>"$PD_LOCK"
  flock 8
  run bash "$T"
  exec 8>&-
  [ "$status" -eq 1 ]
  [[ "$output" == *"in corso"* ]]
  [ "$(git -C "$P" describe --tags --exact-match)" = v1.0.0 ]
}

@test "checkout attuale non su un rilascio: rifiuta" {
  pd_test_installed v1.0.0
  # Un commit senza tag: HEAD su v1.1.0 o su main (= v1.1.0) avrebbe comunque un tag esatto.
  echo x >"$PD_WORK/extra"
  git -C "$PD_WORK" add -A && git -C "$PD_WORK" commit -qm extra && git -C "$PD_WORK" push -q "$PANEL_REPO" main
  git -C "$P" -c safe.directory="$P" fetch -q origin
  git -C "$P" -c safe.directory="$P" checkout -q origin/main
  run bash "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"non è un rilascio"* ]]
}
```

- [ ] **Step 2: Esegui** — Expected: FAIL.

- [ ] **Step 3: Implementa `tools/vps-panel-update`** (eseguibile)

```bash
#!/usr/bin/env bash
# vps-panel-update [--ref vX.Y.Z] — porta Plancia all'ultimo rilascio (o a uno preciso).
# Prima un dump del database; se un passo fallisce torna alla versione di prima,
# codice e database. Uscita: 0 ok o già aggiornata, 1 errore (versione di prima
# ripristinata o nessuna modifica), 2 ritorno indietro fallito.
# Sotto sudo l'ambiente del chiamante non deve influenzare lo script.
if [[ -n "${SUDO_USER:-}" ]]; then
  VPS_OPT=/opt/vps
  VPS_LIB=$VPS_OPT/lib
  VPS_TEMPLATES=$VPS_OPT/templates
  VPS_LOG=/var/log/vps-tools.log
  unset PANEL_REPO PD_REPO_WEB PD_KEY PD_KNOWN_HOSTS PD_BACKUPS PD_CRON PD_LOCK PD_PHP PD_AS_PANEL \
    PD_HEALTH_URL PD_CURL_RESOLVE PD_HEALTH_SLEEP PD_SKIP_TELEGRAM_CHECK PD_TEST VPS_NO_CHOWN
  [[ -e "$VPS_LOG" ]] || install -m 640 /dev/null "$VPS_LOG"
  chmod 640 "$VPS_LOG"
fi
: "${VPS_OPT:=/opt/vps}" "${VPS_LOG:=/var/log/vps-tools.log}"
: "${VPS_TEMPLATES:=$VPS_OPT/templates}"
for _lib in "${VPS_LIB:-$VPS_OPT/lib}"/*.sh; do
  # shellcheck source=/dev/null
  source "$_lib"
done

say() {
  printf '%s\n' "$*"
  log "$*" 2>/dev/null
}

STAGE=""
TOUCHED_DB=0

# apply CUR TARGET — ogni passo imposta STAGE; ritorna 1 al primo che fallisce.
apply() {
  STAGE="checkout di $2"
  pd_checkout "$2" || return 1
  if pd_ver_gt "${2#v}" "${1#v}"; then
    STAGE="schema.sql"
    TOUCHED_DB=1
    pd_schema || return 1
    STAGE="migrazioni"
    pd_migrations "$1" "$2" || return 1
  else
    say "ATTENZIONE: $2 è più vecchia di $1: cambio solo il codice, lo schema del database resta quello di $1."
  fi
  STAGE="controllo della sintassi PHP"
  pd_php_lint || return 1
  STAGE="reload di PHP-FPM"
  pd_reload_php || return 1
  STAGE="/health"
  pd_health || return 1
}

main() {
  local ref="" cur target dump ok=1
  enable_error_trap
  while (($#)); do
    case "$1" in
      --ref) [[ -n "${2:-}" ]] || die "--ref vuole un rilascio vX.Y.Z"; ref="$2"; shift 2 ;;
      -h | --help) echo "Uso: sudo vps-panel-update [--ref vX.Y.Z]"; exit 0 ;;
      *) die "Opzione sconosciuta: $1" ;;
    esac
  done
  ((EUID == 0)) || [[ "${PD_TEST:-}" == 1 ]] || die "Esegui con: sudo vps-panel-update"
  pd_load
  exec 9>"$PD_LOCK"
  flock -n 9 || die "Un altro aggiornamento è in corso"
  [[ -n "$(jq -r '.panel.version // empty' "$(manifest_path)")" && -d "$PANEL_ROOT/.git" ]] \
    || die "Plancia non è installata: usa sudo vps-panel-install"

  pd_git fetch -q --tags origin 2>>"$VPS_LOG" || die "Download dei rilasci non riuscito"
  cur="$(pd_current_tag)"
  [[ "$cur" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Il checkout attuale non è un rilascio vX.Y.Z: sistemalo a mano"
  if [[ -n "$ref" ]]; then
    [[ "$ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--ref deve essere nella forma vX.Y.Z"
    pd_git rev-parse -q --verify "refs/tags/$ref" >/dev/null || die "Il rilascio $ref non esiste"
    target="$ref"
  else
    target="$(pd_latest_tag)"
  fi
  if [[ "$target" == "$cur" ]]; then
    say "Già aggiornata ($cur)."
    exit 0
  fi

  dump="$(pd_dump "$cur")" || die "Backup del database non riuscito: nessuna modifica fatta"
  say "Plancia: $cur → $target (backup: $dump)"
  if ! apply "$cur" "$target"; then
    log "Aggiornamento a $target fallito durante: $STAGE. Torno a $cur."
    pd_checkout "$cur" || ok=0
    if ((TOUCHED_DB)); then
      pd_restore "$dump" || ok=0
    fi
    pd_reload_php || ok=0
    if ((ok)); then
      die "Aggiornamento a $target fallito ($STAGE): ripristinata $cur. Backup del database: $dump"
    fi
    log "ERRORE: aggiornamento fallito ($STAGE) e ritorno a $cur NON riuscito. Backup del database: $dump"
    exit 2
  fi
  pd_manifest "$target"
  say "Plancia aggiornata: $cur → $target"
}

main "$@"
```

Nota: nel test "ritorno indietro impossibile" `MARIADB_RC=1` fa fallire `pd_schema` (stage) **e** `pd_restore` → uscita 2. Il messaggio di `log` va su stderr: `run` lo cattura. Il checkout di ritorno avviene comunque (git non dipende dal DB).

- [ ] **Step 4: Aggiorna `tests/opt.bats`** con `[ -x "$VPS_OPT/bin/vps-panel-update" ]`.

- [ ] **Step 5: Esegui** — `bash tests/run.sh`. Expected: verdi.

- [ ] **Step 6: Commit**

```bash
git add tools/vps-panel-update tests/panel_update.bats tests/opt.bats
git commit -m "feat(panel): vps-panel-update with dump and rollback

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 9: End-to-end in WSL con Plancia vera

**Files:**
- Create: `tests/e2e/panel-e2e.sh`, `tests/e2e/router.php`
- Modify: `tests/run.sh` (shellcheck già prende `*.sh`: niente da fare se `find` include `tests/e2e`; verifica), `.github/workflows/release.yml` solo se l'archivio di release include `tests/` (il test `release.bats` dice di no: verifica e basta)

**Interfaces:**
- Consumes: tag locale `v2.1.0` nel repository `vps-panel` (Task 3, creato dal controller), i due script.
- Produces: `sudo bash tests/e2e/panel-e2e.sh /percorso/vps-panel` → stampa `E2E OK` e esce 0, oppure il primo controllo fallito e 1. Non gira in `tests/run.sh` (serve root e MariaDB).

- [ ] **Step 1: `tests/e2e/router.php`**

```php
<?php
// Router per `php -S`: file statici di public/ come sono, il resto a index.php.
// Prima del checkout public/index.php non esiste ancora: 503.
$public = getenv('E2E_PUBLIC');
$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
if ($path !== '/' && is_file($public . $path)) {
    return false;
}
if (!is_file($public . '/index.php')) {
    http_response_code(503);
    exit;
}
chdir($public);
require $public . '/index.php';
```

- [ ] **Step 2: `tests/e2e/panel-e2e.sh`**

```bash
#!/usr/bin/env bash
# End-to-end di vps-panel-install / vps-panel-update con la Plancia vera, in WSL.
# Uso: sudo bash tests/e2e/panel-e2e.sh /mnt/c/.../vps-panel
# Serve: root, MariaDB in esecuzione, php (8.4, pdo_mysql), git. Il repository
# di Plancia deve avere il tag v2.1.0. Lascia la macchina come l'ha trovata.
set -Eeuo pipefail
((EUID == 0)) || { echo "Esegui con sudo" >&2; exit 1; }
SRC="$(readlink -f "${1:?percorso del repository vps-panel}")"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
W="$(mktemp -d /tmp/plancia-e2e.XXXXXX)"
DB=plancia_e2e
DBPASS="$(openssl rand -hex 16)"
PORT=8199
SERVER_PID=""

cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  mariadb -e "DROP DATABASE IF EXISTS \`$DB\`; DROP USER IF EXISTS '$DB'@'localhost';" || true
  rm -rf "$W"
}
trap cleanup EXIT

fail() { echo "E2E FALLITO: $*" >&2; exit 1; }
check() { local m="$1"; shift; "$@" || fail "$m"; }

service mariadb status >/dev/null 2>&1 || service mariadb start >/dev/null
# Il repository sorgente è dell'utente Windows, non di root: senza questo git
# rifiuta di leggerlo ("dubious ownership"). Vale anche per i processi figli.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
git -C "$SRC" rev-parse -q --verify refs/tags/v2.1.0 >/dev/null || fail "manca il tag v2.1.0 in $SRC"

# Repository "remoto": solo v2.1.0, come GitHub al primo deploy.
git clone -q --bare --no-local "$SRC" "$W/repo.git"
git -C "$W/repo.git" for-each-ref --format='%(refname)' refs/tags | { grep -vx refs/tags/v2.1.0 || true; } \
  | xargs -r -n1 git -C "$W/repo.git" update-ref -d
export GIT_AUTHOR_NAME=e2e GIT_AUTHOR_EMAIL=e2e@example.invalid GIT_COMMITTER_NAME=e2e GIT_COMMITTER_EMAIL=e2e@example.invalid

# Radice del pannello come la lascia l'installer.
P="$W/panel"
mkdir -p "$P/config" "$P/public" "$P/logs" "$P/storage/sessions" "$P/storage/tmp" "$W/opt" "$W/bin"
echo segnaposto >"$P/public/index.html"
printf 'DB_HOST=localhost\nDB_NAME=%s\nDB_USER=%s\nDB_PASS=%s\nDBADMIN_USER=x\nDBADMIN_PASS=y\n' "$DB" "$DB" "$DBPASS" >"$P/config/.env"
mariadb -e "CREATE DATABASE \`$DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  CREATE USER '$DB'@'localhost' IDENTIFIED BY '$DBPASS'; GRANT ALL ON \`$DB\`.* TO '$DB'@'localhost';"
jq -n --arg p "$P" '{installer_version:"1.1.0", panel:{domain:"panel.e2e", path:$p}}' >"$W/opt/manifest.json"
printf '#!/bin/sh\nexit 0\n' >"$W/bin/systemctl"
chmod +x "$W/bin/systemctl"

E2E_PUBLIC="$P/public" php -S 127.0.0.1:$PORT "$HERE/tests/e2e/router.php" >"$W/server.log" 2>&1 &
SERVER_PID=$!
sleep 1

run_tool() {
  env -u SUDO_USER PATH="$W/bin:$PATH" VPS_OPT="$W/opt" VPS_LIB="$HERE/lib" VPS_TEMPLATES="$HERE/templates" \
    VPS_LOG="$W/tools.log" PANEL_REPO="$W/repo.git" PD_AS_PANEL=0 VPS_NO_CHOWN=1 PD_SKIP_TELEGRAM_CHECK=1 \
    PD_HEALTH_URL="http://127.0.0.1:$PORT/health" PD_CURL_RESOLVE="" PD_HEALTH_SLEEP=1 \
    PD_BACKUPS="$W/backups" PD_CRON="$W/cron-vps-panel" PD_LOCK="$W/update.lock" PD_PHP=php \
    bash "$HERE/tools/$1" "${@:2}"
}
tag_of() { git -c safe.directory="$P" -C "$P" describe --tags --exact-match; }
q() { mariadb -N -B -e "$1" "$DB"; }

echo "== install"
printf '%s\n' '123456:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' e2e_admin 424242 'E2e-Password-123!' 'E2e-Password-123!' \
  | run_tool vps-panel-install || fail "install"
check "tag dopo install" [ "$(tag_of)" = v2.1.0 ]
check "super_admin" [ "$(q "SELECT role FROM vp_users WHERE username='e2e_admin'")" = super_admin ]
check "APP_KEY unica" [ "$(grep -c '^APP_KEY=' "$P/config/.env")" -eq 1 ]
check "manifest" [ "$(jq -r .panel.version "$W/opt/manifest.json")" = 2.1.0 ]
check "segnaposto tolto" [ ! -e "$P/public/index.html" ]
check "health" [ "$(curl -sf "http://127.0.0.1:$PORT/health")" = OK ]
if run_tool vps-panel-install </dev/null; then fail "il secondo install doveva rifiutare"; fi

echo "== rilasci rotti e uno buono"
git clone -q "$W/repo.git" "$W/work"
git -C "$W/work" checkout -q -b rel v2.1.0
mk_tag() {  # mk_tag TAG FILE CONTENUTO
  mkdir -p "$(dirname "$W/work/$2")"
  printf '%s\n' "$3" >"$W/work/$2"
  git -C "$W/work" add -A && git -C "$W/work" commit -qm "$1" && git -C "$W/work" tag "$1"
}
mk_tag v2.1.1 public/rotto.php '<?php function (' 
git -C "$W/work" rm -q public/rotto.php && git -C "$W/work" commit -qm pulizia
mk_tag v2.1.2 public/index.php '<?php http_response_code(500);'
git -C "$W/work" checkout -q v2.1.0 -- public/index.php && git -C "$W/work" commit -qm ripristino
mk_tag v2.1.3 install/migrations/2.1.3.sql 'CREATE TABLE IF NOT EXISTS vp_e2e_probe (id INT); SELECT * FROM tabella_che_non_esiste;'
git -C "$W/work" rm -q install/migrations/2.1.3.sql && git -C "$W/work" commit -qm pulizia
mk_tag v2.2.0 install/migrations/2.2.0.sql 'CREATE TABLE IF NOT EXISTS vp_e2e_ok (id INT);'
git -C "$W/work" push -q origin --tags

for t in v2.1.1 v2.1.2 v2.1.3; do
  echo "== update --ref $t (deve tornare a v2.1.0)"
  rc=0
  run_tool vps-panel-update --ref "$t" || rc=$?
  check "$t: uscita 1 (era $rc)" [ "$rc" -eq 1 ]
  check "$t: codice tornato" [ "$(tag_of)" = v2.1.0 ]
  check "$t: health" [ "$(curl -sf "http://127.0.0.1:$PORT/health")" = OK ]
  check "$t: manifest" [ "$(jq -r .panel.version "$W/opt/manifest.json")" = 2.1.0 ]
done
check "migrazione fallita annullata" [ -z "$(q "SHOW TABLES LIKE 'vp_e2e_probe'")" ]
check "utente sopravvissuto ai ripristini" [ "$(q "SELECT COUNT(*) FROM vp_users WHERE username='e2e_admin'")" = 1 ]

echo "== update all'ultimo"
run_tool vps-panel-update || fail "update a v2.2.0"
check "tag v2.2.0" [ "$(tag_of)" = v2.2.0 ]
check "migrazione 2.2.0" [ -n "$(q "SHOW TABLES LIKE 'vp_e2e_ok'")" ]
check "manifest 2.2.0" [ "$(jq -r .panel.version "$W/opt/manifest.json")" = 2.2.0 ]
out="$(run_tool vps-panel-update)" || fail "secondo update"
check "già aggiornata" grep -q "Già aggiornata" <<<"$out"
check "backup tenuti al massimo 5" [ "$(find "$W/backups" -name '*.sql.gz' | wc -l)" -le 5 ]

echo "E2E OK"
```

- [ ] **Step 3: Esegui** (dopo che il controller ha creato il tag `v2.1.0` in `vps-panel`):

```bash
wsl -d Debian -- sudo bash /mnt/c/Users/Manu/Documents/MEGAsync/progetti/pannello-vps/vps-installer/tests/e2e/panel-e2e.sh /mnt/c/Users/Manu/Documents/MEGAsync/progetti/pannello-vps/vps-panel
```

Expected: ultima riga `E2E OK`, uscita 0. Se fallisce: correggi la causa negli script o nella libreria (con un test bats che riproduce il caso nel task giusto), **non** nello script e2e, salvo errori dello script stesso. Poi `bash tests/run.sh` (shellcheck copre anche `tests/e2e/panel-e2e.sh`).

- [ ] **Step 4: Commit**

```bash
git add tests/e2e
git commit -m "test(e2e): install and update the real Plancia in WSL, with rollbacks

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 10: Documenti e versione 1.1.0

**Files:**
- Modify: `lib/common.sh` (`VPS_INSTALLER_VERSION="1.1.0"`), `docs/PANEL-HANDOFF.md`, `README.md`, `docs/specs/2026-10-11-vps-installer-v1.1-design.md` (Stato)
- Create: `docs/collaudo-v1.0.0.md`

**Interfaces:**
- Consumes: tutto il resto. Nessun codice nuovo.

- [ ] **Step 1: Versione** — `lib/common.sh`: `VPS_INSTALLER_VERSION="1.1.0"`. Spec: `- **Stato:** implementata (v1.1.0)`.

- [ ] **Step 2: `docs/PANEL-HANDOFF.md`**

§ 2 "Del pannello": riga `logs/` → `| /var/www/<pannello>/logs/ | panel:panel 750 | log applicativi di Plancia e php-error.log del pool |`; aggiungi `| /var/www/<pannello>/.git/ | panel:panel | checkout del rilascio (lo gestiscono vps-panel-install/update come root) |`.

§ 2 "Di root": aggiungi
`| /opt/vps/secrets/panel-deploy-key | root:root 600 | deploy key GitHub di sola lettura per IImanuII/vps-panel |` e
`| /opt/vps/backups/panel/ | root:root 700 / file 600 | dump del DB del pannello prima di ogni aggiornamento (ultimi 5) |`.

§ 2 "File di sistema": aggiungi `| /etc/cron.d/vps-panel | manutenzione notturna di Plancia (utente panel) |`.

§ 3: nell'esempio JSON aggiungi in `panel` i campi `"version": "2.1.0", "deployed_at": "2026-10-11T18:00:00+02:00", "repo": "git@github.com:IImanuII/vps-panel.git"`; `installer_version` → `"1.1.0"`. Sotto: "`version`, `deployed_at`, `repo` li scrivono `vps-panel-install`/`vps-panel-update`; una riscrittura del manifest da parte dell'installer li conserva."

§ 4: dopo la tabella "Forniti dall'installer (v1)" aggiungi:

```markdown
Forniti dall'installer v1.1, **eseguiti dall'amministratore** (non dal pannello, non in sudoers):

| Script | Uso | Cosa fa |
|---|---|---|
| `vps-panel-install` | interattivo | deploy key, token Telegram, checkout dell'ultimo tag `vX.Y.Z`, `APP_KEY` se manca, `schema.sql`, primo super_admin, `/etc/cron.d/vps-panel`, controllo `/health` |
| `vps-panel-update` | `[--ref vX.Y.Z]` | dump del DB, checkout, `schema.sql` + `install/migrations/X.Y.Z.sql`, `php -l`, reload PHP-FPM, `/health`; se fallisce torna alla versione di prima (codice e DB) |

Regole per il pannello: i rilasci sono tag annotati `vX.Y.Z`; le modifiche allo schema di
un'installazione esistente vanno in `install/migrations/X.Y.Z.sql`, idempotenti.
```

- [ ] **Step 3: `README.md`** — dopo "## Dopo l'installazione" aggiungi:

````markdown
## Installare il pannello (Plancia)

Il pannello sta in un repository privato: serve una deploy key, che lo script crea e stampa.

```bash
sudo vps-panel-install     # la prima volta
sudo vps-panel-update      # poi, per ogni nuovo rilascio
```

Su una VPS installata con una versione precedente alla 1.1, prima:

```bash
curl -fsSLO https://github.com/IImanuII/vps-installer/releases/download/v1.1.0/install.sh
sudo bash install.sh --tools-only
```
````

In "## Sviluppo" aggiungi: `- End-to-end del pannello (WSL, root): sudo bash tests/e2e/panel-e2e.sh <percorso vps-panel>.` e `- Spec v1.1: [docs/specs/2026-10-11-vps-installer-v1.1-design.md](docs/specs/2026-10-11-vps-installer-v1.1-design.md)`.

- [ ] **Step 4: `docs/collaudo-v1.0.0.md`** — resoconto del collaudo reale. Leggi `git log --oneline v1.0.0..v1.0.3` e i messaggi dei commit `e715211`, `116ac8c`, `d3eda6c` per i dettagli, poi scrivi:

```markdown
# Collaudo v1.0.0 → v1.0.3

- **Data:** 2026-10-07/08
- **Macchina:** VPS OVH, Debian 13; pannello su `mami2.arcomy.com`, Cloudflare attivo.
- **Esito:** installazione completata con la v1.0.3; sul dominio del pannello la pagina segnaposto.
  Plancia non ancora installata (lo farà `vps-panel-install`, v1.1).

## Problemi trovati e correzioni

| Versione | Problema | Correzione |
|---|---|---|
| 1.0.1 | (dal commit e715211) un CNAME già presente su Cloudflare per il dominio del pannello bloccava la creazione del record A | si tiene il CNAME esistente; record invariati non si riscrivono |
| 1.0.2 | (dal commit 116ac8c) la prima installazione si fermava leggendo una `config.inc.php` di phpMyAdmin non ancora esistente | lettura tollerante al file mancante |
| 1.0.3 | (dal commit d3eda6c) record DNS del pannello che puntavano altrove sovrascritti senza chiedere | domanda nella procedura guidata: sostituire o lasciare, con nota nel riepilogo |

## Da ricordare per il prossimo collaudo

- Controllare prima su Cloudflare i record del dominio del pannello.
- Dopo l'installer: `sudo vps-panel-install` (v1.1) e la checklist "Verifica manuale" di
  `vps-panel/Documenti/deploy/README.md`; esito in `docs/collaudo-v1.1.0.md`.
```

Adatta le tre righe della tabella a ciò che dicono davvero i commit (versione esatta di ogni correzione compresa: verifica con `git tag --contains <commit>`); togli i riferimenti "(dal commit …)" una volta riscritte le frasi.

- [ ] **Step 5: Suite** — `bash tests/run.sh`. Expected: verdi (il test di release controlla che `VPS_INSTALLER_VERSION` sia coerente con il workflow: se fallisce per la versione, leggi `tests/release.bats` e adegua).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "docs: installer 1.1.0, panel handoff for vps-panel-install/update, v1.0 field test

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Chiusura (controller, con l'ok dell'utente)

1. `vps-panel`: merge `v2.1-deploy` → `master` (fatto dopo il Task 3), tag `v2.1.0` (fatto dopo il Task 3), `git push origin master v2.1.0`.
2. `vps-installer`: review finale del ramo `v1.1`, merge in `main`, `git push origin main`, poi `git tag v1.1.0 && git push origin v1.1.0` (la GitHub Action pubblica la release).
3. Aggiornare la memoria `project-plancia-status.md`.
4. Collaudo reale (utente): sulla VPS `install.sh --tools-only` → `sudo vps-panel-install` → deploy key su GitHub → login Telegram → checklist "Verifica manuale"; esito in `docs/collaudo-v1.1.0.md`.

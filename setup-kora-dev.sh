#!/usr/bin/env bash
set -e

# --- config ---
org="https://github.com/KoraFiveM"
orgName="KoraFiveM"
artifactsApi="https://artifacts.jgscripts.com/json"

die() { echo "ERROR: $*" >&2; exit 1; }

# --- GitHub rate limiting ---
# Wait (up to 15 min) if the API quota is nearly used up.
waitForRateLimit() {
  local info remaining reset now wait
  info=$(gh api rate_limit --jq '.resources.core | "\(.remaining) \(.reset)"' 2>/dev/null) || return 0
  remaining=${info% *}; reset=${info#* }
  [ "${remaining:-100}" -ge 20 ] && return 0
  now=$(date +%s); wait=$(( reset - now + 5 ))
  [ "$wait" -gt 0 ] || return 0
  [ "$wait" -le 900 ] || die "GitHub rate limit exhausted; resets in $((wait/60)) min. Try again later."
  echo "GitHub rate limit nearly exhausted ($remaining left). Waiting ${wait}s for reset..."
  sleep "$wait"
}

# git clone with retries and exponential backoff (handles 429 / rate-limit / flaky network)
gitClone() {
  local attempt delay=5 max=5 out
  for ((attempt=1; attempt<=max; attempt++)); do
    out=$(git clone "$@" 2>&1) && { [ -n "$out" ] && echo "$out"; return 0; }
    if [ "$attempt" -eq "$max" ]; then
      echo "$out" >&2
      die "git clone failed after $max attempts: ${*: -2}"
    fi
    if grep -qiE 'rate limit|429|abuse|secondary' <<<"$out"; then
      echo "GitHub rate limit hit (attempt $attempt/$max). Waiting ${delay}s..."
      waitForRateLimit
    else
      echo "Clone failed (attempt $attempt/$max): $(tail -n1 <<<"$out"). Retrying in ${delay}s..."
    fi
    sleep "$delay"; delay=$((delay * 2))
  done
}

# --- OS detection ---
case "$(uname -s)" in
  Linux*)                os="linux" ;;
  MINGW*|MSYS*|CYGWIN*)  os="windows" ;;
  Darwin*)               die "FXServer has no macOS build. Use Linux, WSL or Windows (Git Bash)." ;;
  *)                     die "Unsupported OS: $(uname -s)" ;;
esac
echo "Detected OS: $os"

# --- preflight checks ---
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed. $2"; }
need git  "Install git."
need curl "Install curl."
need gh   "Install GitHub CLI: https://cli.github.com"
if [ "$os" = "linux" ]; then
  need tar "Install tar."
  need xz  "Install xz (e.g. 'sudo apt install xz-utils')."
else
  need unzip "Install unzip."
fi

need mysql "Install the MySQL/MariaDB client."
gh auth status >/dev/null 2>&1 || die "GitHub CLI is not logged in. Run 'gh auth login' first."
gh auth setup-git >/dev/null 2>&1 || true   # let git use the gh token for private repos
waitForRateLimit
git ls-remote "$org/server_cfg_test.git" >/dev/null 2>&1 \
  || die "Cannot access $orgName repos. Check your gh login has access to the $orgName organization."

mysql_running() {
  if command -v mysqladmin >/dev/null 2>&1 && mysqladmin ping --silent >/dev/null 2>&1; then return 0; fi
  if command -v systemctl >/dev/null 2>&1 \
     && { systemctl is-active --quiet mysql || systemctl is-active --quiet mysqld || systemctl is-active --quiet mariadb; }; then return 0; fi
  if command -v pgrep >/dev/null 2>&1 && pgrep -x -f 'mysqld|mariadbd' >/dev/null 2>&1; then return 0; fi
  # generic TCP probe (also covers Windows / Git Bash and Docker)
  (exec 3<>/dev/tcp/127.0.0.1/3306) >/dev/null 2>&1 && return 0
  return 1
}
mysql_running || die "MySQL/MariaDB does not appear to be running on 127.0.0.1:3306. Start it and re-run."

free_kb=$(df -Pk . | awk 'NR==2{print $4}')
[ "${free_kb:-0}" -ge 5242880 ] || die "Less than 5 GB free disk space here."

# --- prompts ---
read -rp "Enter server name: " serverName
[[ "$serverName" =~ ^[A-Za-z0-9_-]+$ ]] || die "Server name may only contain letters, numbers, '-' and '_'."
if [ -d "$serverName" ]; then
  read -rp "Folder '$serverName' already exists. Continue and reuse it? [y/N] " yn
  [[ "$yn" =~ ^[Yy]$ ]] || die "Aborted."
fi

# ports (defaults suggest the first free one, so a second server just works)
portInUse() {
  local p=$1
  if command -v ss >/dev/null 2>&1 && ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -qE "[:.]$p$"; then return 0; fi
  (exec 3<>/dev/tcp/127.0.0.1/"$p") >/dev/null 2>&1
}
askPort() {   # askPort "label" basePort -> sets REPLY_PORT
  local label=$1 def=$2 input
  while portInUse "$def" && [ "$def" -lt 65535 ]; do def=$((def + 1)); done
  while true; do
    read -rp "$label port [$def]: " input; input=${input:-$def}
    if ! [[ "$input" =~ ^[0-9]+$ ]] || [ "$input" -lt 1024 ] || [ "$input" -gt 65535 ]; then
      echo "Enter a number between 1024 and 65535."; continue
    fi
    if [ -n "${takenPort:-}" ] && [ "$input" = "$takenPort" ]; then echo "That port is already used by the other service."; continue; fi
    if portInUse "$input"; then
      read -rp "Port $input is already in use (another server running?). Use it anyway? [y/N] " yn
      [[ "$yn" =~ ^[Yy]$ ]] || continue
    fi
    REPLY_PORT=$input; return
  done
}
takenPort=""; askPort "txAdmin web" 40120; txPort=$REPLY_PORT
takenPort=$txPort; askPort "Game server" 30120; gamePort=$REPLY_PORT; takenPort=""

read -rp "Database name [kora_dev] (use a different name for a second server): " dbName
dbName=${dbName:-kora_dev}
[[ "$dbName" =~ ^[A-Za-z0-9_]+$ ]] || die "Database name may only contain letters, numbers and '_'."

read -rp "MySQL user [root]: " dbUser; dbUser=${dbUser:-root}
read -rsp "MySQL password: " dbPass; echo
[ -n "$dbPass" ] || die "A MySQL password is required."
mysqlCmd() { MYSQL_PWD="$dbPass" mysql -u"$dbUser" -h127.0.0.1 "$@"; }
mysqlCmd -e "SELECT 1" >/dev/null 2>&1 || die "Could not log in to MySQL as '$dbUser'. Check the credentials."

read -rsp "Enter server licence key (same key from portal.cfx.re, also used for resources): " licenseKey; echo
[ -n "$licenseKey" ] || die "A licence key is required."
read -rp "Cfx.re forum username for txAdmin admin (blank to skip): " adminName
adminId=""
if [ -n "$adminName" ]; then
  [[ "$adminName" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Invalid Cfx.re username."
  # look up the numeric forum ID (= fivem:<id>) from the public profile endpoint
  for attempt in 1 2 3 4; do
    resp=$(curl -fsSL -m 20 -A "Mozilla/5.0" "https://forum.cfx.re/u/$adminName.json" 2>/dev/null) || resp=""
    adminId=$(printf '%s' "$resp" | grep -o '"user":{"id":[0-9]*' | head -n1 | grep -o '[0-9]*$' || true)
    [ -n "$adminId" ] && break
    [ "$attempt" -lt 4 ] && { echo "Lookup failed (attempt $attempt/4), retrying in $((attempt * 3))s..."; sleep $((attempt * 3)); }
  done
  if [ -n "$adminId" ]; then
    echo "Found FiveM ID for $adminName: $adminId"
  else
    echo "Could not look up '$adminName' on forum.cfx.re (wrong username or rate limited)."
    read -rp "Enter your FiveM ID manually (number from 'fivem:<id>'): " adminId
    [[ "$adminId" =~ ^[0-9]+$ ]] || die "FiveM ID must be numeric."
  fi
fi

# --- create folders ---
mkdir -p "$serverName/server"
cd "$serverName/server"
serverRoot="$(pwd)"

# --- download recommended artifacts ---
if [ -e run.sh ] || [ -e FXServer.exe ]; then
  echo "skip artifacts (already present)"
else
  echo "Fetching recommended artifacts..."
  json=$(curl -fsSL "$artifactsApi") || die "Could not reach $artifactsApi"
  build=$(printf '%s' "$json" | grep -o '"recommendedArtifact":"[^"]*"' | cut -d'"' -f4)
  if [ "$os" = "linux" ]; then
    url=$(printf '%s' "$json" | grep -o '"linuxDownloadLink":"[^"]*"' | cut -d'"' -f4)
    archive="fx.tar.xz"
  else
    url=$(printf '%s' "$json" | grep -o '"windowsDownloadLink":"[^"]*"' | cut -d'"' -f4)
    archive="server.zip"
  fi
  [ -n "$url" ] || die "Could not parse artifact download link."
  echo "Downloading build $build ($os)..."
  trap 'rm -f "$archive"' EXIT           # never leave the archive behind, even on failure
  curl -fL --progress-bar -o "$archive" "$url"
  if [ "$os" = "linux" ]; then tar -xJf "$archive"; else unzip -q "$archive"; fi
  rm -f "$archive"
  trap - EXIT
fi

# clone [-b branch] url [dest]  (skips if the folder already exists)
# dest is optional; when given it is the last argument and is what gets checked.
clone() {
  local last="${*: -1}"
  local name
  if [[ "$last" == *://* ]]; then
    name=$(basename "$last" .git)      # no dest: folder is named after the repo
  else
    name="$last"                       # dest given: that is the folder
  fi
  if [ -d "$name" ]; then
    echo "skip $name (already exists)"
    return
  fi
  gitClone "$@"
}

# cloneAll repoName...  (clones each from the org)
cloneAll() {
  for repo in "$@"; do
    clone "$org/$repo.git"
  done
}

# --- repo lists ---
preRepos=(
  kora_lib kora_sql kora_inventory kora_core
)

koraRepos=(
  kora_jewellery kora_drugs kora_cards kora_utils kora_doorlock kora_businesses
  kora_admin kora_multijob kora_bossmenu kora_multichar kora_loading kora_hud
  kora_clothing kora_banking kora_dispatch kora_fuel kora_target kora_interior
  kora_scrapyard kora_weathersync kora_phone-stevie kora_police kora_garages kora_diving
  kora_skills kora_dealership kora_jobcreator kora_crafting
  kora_ambulance kora_truckerjob kora_newsjob kora_truckrobbery kora_cityhall
  kora_customs kora_crypto kora_consumables kora_scoreboard kora_pawnshop
  kora_fishing kora_vehiclekeys kora_metaldetecting kora_mdt kora_mining
)

standaloneRepos=(
  kora_queue kora_chat PolyZone kora_voice kora_theme kora_emotemenu
  kora_lib-playground props kora_sound kora_phoneshop_demo
)

# --- directory layout ---
mkdir -p txData
cd txData
mkdir -p "kora dev"
cd "kora dev"

# server.cfg
cfgTmp=$(mktemp -d)
gitClone --depth 1 "$org/server_cfg_test.git" "$cfgTmp/server_cfg_test"
cp "$cfgTmp/server_cfg_test/server.cfg" server.cfg
rm -rf "$cfgTmp"

# inject keys (escape sed-special chars in the values)
esc() { printf '%s' "$1" | sed -e 's/[\\&#]/\\&/g'; }
if grep -qE '^[[:space:]]*sv_licenseKey' server.cfg; then
  sed -i.bak -E "s#^[[:space:]]*sv_licenseKey.*#sv_licenseKey \"$(esc "$licenseKey")\"#" server.cfg
else
  printf '\nsv_licenseKey "%s"\n' "$licenseKey" >> server.cfg
fi
# mysql connection string (user/password are URL-encoded)
urlenc() {
  local i c out="" str="$1"
  for ((i=0; i<${#str}; i++)); do
    c="${str:i:1}"
    case "$c" in [A-Za-z0-9._~-]) out+="$c" ;; *) out+=$(printf '%%%02X' "'$c") ;; esac
  done
  printf '%s' "$out"
}
cred="$(urlenc "$dbUser"):$(urlenc "$dbPass")"
connStr="mysql://$cred@localhost/$dbName?charset=utf8mb4"
if grep -qE '^[[:space:]]*set[[:space:]]+mysql_connection_string' server.cfg; then
  sed -i.bak -E "s#^[[:space:]]*set[[:space:]]+mysql_connection_string.*#set mysql_connection_string \"$(esc "$connStr")\"#" server.cfg
else
  printf 'set mysql_connection_string "%s"\n' "$connStr" >> server.cfg
fi
# game server port (also enforced by TXHOST_FXS_PORT)
sed -i.bak -E "s#^([[:space:]]*endpoint_add_(tcp|udp)[[:space:]]+\"[^\":]*:)[0-9]+#\\1$gamePort#" server.cfg
rm -f server.cfg.bak

# database: kora_sql creates every table (and the starter content) on first start, so an empty database is all we need
createDb() {
  mysqlCmd -e "CREATE DATABASE IF NOT EXISTS \`$dbName\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci" \
    || die "Could not create the $dbName database (does '$dbUser' have CREATE privileges?)."
}
dbExisted=$(mysqlCmd -N -e "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='$dbName'")
tables=0; oldTables=0
if [ "${dbExisted:-0}" -gt 0 ]; then
  tables=$(mysqlCmd -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$dbName'")
  # tables not using the collation the Kora schema expects (kora_sql warns about these but never alters them)
  oldTables=$(mysqlCmd -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$dbName' AND table_collation <> 'utf8mb4_unicode_ci'")
fi
if [ "${tables:-0}" -eq 0 ]; then
  createDb
  echo "Created empty database $dbName; the tables are created on first start."
else
  echo "Database $dbName already exists ($tables tables)."
  if [ "${oldTables:-0}" -gt 0 ]; then
    echo "WARNING: $oldTables table(s) use an older collation/definition than Kora expects."
    echo "         Using it will work but kora_sql will log 'differs from its schema (not altered)' warnings."
  fi
  read -rp "[U]se existing database or [D]rop it and start fresh? [U/d] " dbChoice
  if [[ "$dbChoice" =~ ^[Dd]$ ]]; then
    read -rp "This permanently deletes ALL data in $dbName. Type '$dbName' to confirm: " confirm
    [ "$confirm" = "$dbName" ] || die "Aborted: database not dropped."
    mysqlCmd -e "DROP DATABASE \`$dbName\`"
    createDb
    echo "Recreated empty database $dbName; the tables are created on first start."
  else
    echo "Using existing $dbName database (missing tables and columns are added on start; nothing is changed or dropped)."
  fi
fi

# resources
mkdir -p resources
cd resources

clone "$org/-cfx-default-.git" "[cfx-default]"
clone "$org/-default-maps-.git" "[default-maps]"

mkdir -p "[pre]" "[kora]" "[standalone]"

cd "[pre]"
cloneAll "${preRepos[@]}"
cd ..

cd "[kora]"
cloneAll "${koraRepos[@]}"
clone "$org/kora_robberies.git"
cd ..

cd "[standalone]"
cloneAll "${standaloneRepos[@]}"
clone https://github.com/Bob74/bob74_ipl.git
cd ..

cd ..   # back to "kora dev"

# --- txAdmin pre-seed: env file + start script (deployer defaults, data path, admin) ---
cd "$serverRoot"   # env/start files and txData live in the server root
txDataAbs="$(pwd)/txData"
[ "$os" = "windows" ] && txDataAbs="$(cygpath -m "$serverRoot" 2>/dev/null || pwd -W)/txData"
envLines=(
  "TXHOST_DATA_PATH=$txDataAbs"
  "TXHOST_DEFAULT_CFXKEY=$licenseKey"
  "TXHOST_DEFAULT_DBHOST=127.0.0.1"
  "TXHOST_DEFAULT_DBPORT=3306"
  "TXHOST_DEFAULT_DBUSER=$dbUser"
  "TXHOST_DEFAULT_DBPASS=$dbPass"
  "TXHOST_DEFAULT_DBNAME=$dbName"
  "TXHOST_TXA_PORT=$txPort"
  "TXHOST_FXS_PORT=$gamePort"
  "TXHOST_GAME_NAME=fivem"
)
[ -n "$adminName" ] && envLines+=("TXHOST_DEFAULT_ACCOUNT=$adminName:$adminId")
# pre-create the txAdmin profile so the setup wizard is skipped
# (txAdmin uses <txData>/default/config.json; it only creates its own if this folder is missing)
profileDir="txData/default"
mkdir -p "$profileDir/data" "$profileDir/logs"
if [ -e "$profileDir/config.json" ]; then
  echo "skip txAdmin config.json (already exists)"
else
  cat > "$profileDir/config.json" <<JSON
{
  "version": 2,
  "general": { "serverName": "$serverName" },
  "server": {
    "dataPath": "$txDataAbs/kora dev",
    "cfgPath": "server.cfg",
    "onesync": "on",
    "autoStart": true
  }
}
JSON
fi

umask 077   # env file holds secrets: owner-only
if [ "$os" = "linux" ]; then
  { echo "#!/usr/bin/env bash"; for l in "${envLines[@]}"; do printf 'export %s=%q\n' "${l%%=*}" "${l#*=}"; done; } > env.sh
  printf '#!/usr/bin/env bash\ncd "$(dirname "$0")"\nsource ./env.sh\nexec ./run.sh\n' > start.sh
  chmod 700 env.sh start.sh
else
  { echo "@echo off"; for l in "${envLines[@]}"; do echo "set $l"; done; } > env.bat
  printf '@echo off\r\ncd /d "%%~dp0"\r\ncall env.bat\r\nFXServer.exe\r\n' > start.bat
fi
echo "Created start script with txAdmin defaults (keys/db are pre-filled in the deployer)."
echo "done"
# --- launch ---
cd "$serverRoot"
echo "Starting txAdmin at http://localhost:$txPort (game server on port $gamePort). Press Ctrl+C to stop."
if [ "$os" = "linux" ]; then
  exec ./start.sh
else
  exec cmd //c start.bat
fi

#!/usr/bin/env bash
#
# Kora FiveM framework installer
# Supports Linux and Windows through Git Bash.
#
# Windows users:
#   1. Install Git for Windows and GitHub CLI.
#   2. Open Git Bash.
#   3. Run: bash ./install.sh
#
# Do not run this script by double-clicking it if you need to diagnose errors.
#

set -Eeuo pipefail

# --- configuration ---
org="https://github.com/KoraFiveM"
orgName="KoraFiveM"
artifactsApi="https://artifacts.jgscripts.com/json"
minimumFreeKb=5242880 # 5 GiB

# Temporary paths are tracked so they can be removed on both success and failure.
temporaryPaths=()

# The MySQL password may be empty (common for local dev databases).
dbPass=""

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

on_error() {
  local status="$1"
  local command="$2"
  local line="$3"

  trap - ERR
  printf '\nERROR: Command failed at line %s (exit code %s).\n' "$line" "$status" >&2
  printf 'Command: %s\n' "$command" >&2
  exit "$status"
}

cleanup() {
  local path
  for path in "${temporaryPaths[@]:-}"; do
    [[ -n "$path" && -e "$path" ]] && rm -rf -- "$path"
  done
}

on_exit() {
  local status=$?
  trap - EXIT
  cleanup

  if (( status != 0 )); then
    printf '\nInstaller exited with an error (code %s).\n' "$status" >&2
    if [[ -t 0 || -t 1 ]]; then
      read -r -p "Press Enter to close this window..." _ || true
    fi
  fi

  exit "$status"
}

trap 'on_error "$?" "$BASH_COMMAND" "${BASH_LINENO[0]:-?}"' ERR
trap on_exit EXIT

# --- operating system detection ---
unameValue="$(uname -s)"
case "$unameValue" in
  Linux*)
    os="linux"
    ;;
  MINGW*|MSYS*)
    os="windows"
    ;;
  CYGWIN*)
    die "Cygwin is not supported. Please use Git Bash from Git for Windows."
    ;;
  Darwin*)
    die "FXServer has no macOS build. Use Linux, WSL or Windows (Git Bash)."
    ;;
  *)
    die "Unsupported OS: $unameValue"
    ;;
esac

printf 'Detected OS: %s\n' "$os"

# --- dependency checks ---
need() {
  local commandName="$1"
  local installHint="$2"
  command -v "$commandName" >/dev/null 2>&1 \
    || die "'$commandName' is required but was not found. $installHint"
}

need git "Install Git for Windows: https://git-scm.com/download/win"
need curl "Install Git for Windows (curl is included with current releases) or install curl separately."
need gh "Install GitHub CLI: https://cli.github.com"

if [[ "$os" == "linux" ]]; then
  need tar "Install tar."
  need xz "Install xz (for example: sudo apt install xz-utils)."
else
  need cygpath "Git Bash must include cygpath. Reinstall or update Git for Windows."
  need powershell.exe "Windows PowerShell was not found."
  need cmd.exe "Windows Command Prompt was not found."
  # Prefer unzip when available; PowerShell's Expand-Archive is used as a fallback.
fi

find_mysql() {
  if command -v mysql >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$os" == "windows" ]]; then
    local mysqlExe mysqlDir

    for mysqlExe in \
      "/c/Program Files/MariaDB"*/bin/mysql.exe \
      "/c/Program Files/MySQL"*/bin/mysql.exe \
      "/c/Program Files (x86)/MariaDB"*/bin/mysql.exe
    do
      [[ -f "$mysqlExe" ]] || continue

      mysqlDir="$(dirname "$mysqlExe")"
      export PATH="$mysqlDir:$PATH"
      hash -r

      if command -v mysql >/dev/null 2>&1; then
        printf 'Found MariaDB/MySQL client: %s\n' "$mysqlExe"
        return 0
      fi
    done
  fi

  return 1
}

find_mysql || die "MySQL/MariaDB client not found. Install MariaDB and ensure mysql.exe is available."

if ! gh auth status >/dev/null 2>&1; then
  die "GitHub CLI is not logged in. Run 'gh auth login' in Git Bash, then re-run this installer."
fi

gh auth setup-git >/dev/null 2>&1 || true

# --- GitHub rate limiting ---
waitForRateLimit() {
  local info remaining reset now wait

  info="$(gh api rate_limit --jq '.resources.core | "\(.remaining) \(.reset)"' 2>/dev/null)" || return 0
  remaining="${info% *}"
  reset="${info#* }"

  [[ "$remaining" =~ ^[0-9]+$ ]] || return 0
  [[ "$reset" =~ ^[0-9]+$ ]] || return 0
  (( remaining >= 20 )) && return 0

  now="$(date +%s)"
  wait=$(( reset - now + 5 ))
  (( wait > 0 )) || return 0

  (( wait <= 900 )) \
    || die "GitHub rate limit exhausted; resets in approximately $((wait / 60)) minutes. Try again later."

  printf 'GitHub rate limit nearly exhausted (%s requests left). Waiting %ss for reset...\n' "$remaining" "$wait"
  sleep "$wait"
}

# git clone with retries and exponential backoff.
gitClone() {
  local attempt delay=5 max=5 output

  for (( attempt=1; attempt<=max; attempt++ )); do
    if output="$(git clone "$@" 2>&1)"; then
      [[ -n "$output" ]] && printf '%s\n' "$output"
      return 0
    fi

    if (( attempt == max )); then
      printf '%s\n' "$output" >&2
      die "git clone failed after $max attempts."
    fi

    if grep -qiE 'rate limit|429|abuse|secondary' <<<"$output"; then
      printf 'GitHub rate limit encountered (attempt %s/%s). Waiting %ss...\n' "$attempt" "$max" "$delay"
      waitForRateLimit
    else
      printf 'Clone failed (attempt %s/%s): %s\n' "$attempt" "$max" "$(tail -n 1 <<<"$output")"
      printf 'Retrying in %ss...\n' "$delay"
    fi

    sleep "$delay"
    delay=$(( delay * 2 ))
  done
}

waitForRateLimit

git ls-remote "$org/server_cfg_test.git" >/dev/null 2>&1 \
  || die "Cannot access $orgName repositories. Confirm that the GitHub account used by 'gh auth login' has access to the organization."

# --- MySQL checks ---
mysql_running() {
  if command -v mysqladmin >/dev/null 2>&1 \
      && mysqladmin ping --silent >/dev/null 2>&1; then
    return 0
  fi

  # systemctl and pgrep are useful on Linux, but are not available in every
  # Git Bash installation. Windows uses the TCP check below.
  if [[ "$os" == "linux" ]]; then
    if command -v systemctl >/dev/null 2>&1 \
        && { systemctl is-active --quiet mysql \
          || systemctl is-active --quiet mysqld \
          || systemctl is-active --quiet mariadb; }; then
      return 0
    fi

    if command -v pgrep >/dev/null 2>&1 \
        && pgrep -x -f 'mysqld|mariadbd' >/dev/null 2>&1; then
      return 0
    fi
  fi

  # A TCP connection verifies that something is listening on the default
  # local MySQL port. It works in current Git Bash releases.
  (exec 3<>/dev/tcp/127.0.0.1/3306) >/dev/null 2>&1 && return 0
  return 1
}

mysql_running || die "MySQL/MariaDB does not appear to be listening on 127.0.0.1:3306. Start the database service and confirm it uses port 3306."

# --- free disk space ---
get_free_kb() {
  if [[ "$os" == "windows" ]]; then
    local windowsPath drive freeBytes
    windowsPath="$(cygpath -aw .)" || return 1
    drive="${windowsPath:0:2}"

    # Query the Windows drive using PowerShell. The result is bytes.
    freeBytes="$(powershell.exe -NoProfile -NonInteractive -Command \
      "\$d = Get-CimInstance Win32_LogicalDisk -Filter \"DeviceID='$drive'\"; if (\$null -eq \$d) { exit 1 }; [Console]::WriteLine(\$d.FreeSpace)" \
      2>/dev/null | tr -d '\r')" || return 1

    [[ "$freeBytes" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$(( freeBytes / 1024 ))"
  else
    df -Pk . | awk 'NR==2 {print $4}'
  fi
}

freeKb="$(get_free_kb)" || die "Could not determine available disk space on the installation drive."
[[ "$freeKb" =~ ^[0-9]+$ ]] || die "Could not interpret the available disk-space result."
(( freeKb >= minimumFreeKb )) \
  || die "Less than 5 GiB of free disk space is available on the installation drive."

printf 'Available disk space: %s GiB\n' "$(( freeKb / 1024 / 1024 ))"

# --- prompts ---
read -r -p "Enter server name: " serverName
serverNameRegex='^[a-zA-Z0-9_ -]+$'

if [[ ! "$serverName" =~ $serverNameRegex ]]; then
  die "Server name may only contain letters, numbers, spaces, '-' and '_'."
fi

if [[ -d "$serverName" ]]; then
  read -r -p "Folder '$serverName' already exists. Continue and reuse it? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || die "Aborted."
fi

# Find a suggested port, then allow the user to override it.
portInUse() {
  local port="$1"

  if [[ "$os" == "linux" ]] && command -v ss >/dev/null 2>&1 \
      && ss -H -lntu 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${port}$"; then
    return 0
  fi

  (exec 3<>/dev/tcp/127.0.0.1/"$port") >/dev/null 2>&1
}

askPort() {
  local label="$1"
  local defaultPort="$2"
  local input

  while portInUse "$defaultPort" && (( defaultPort < 65535 )); do
    defaultPort=$(( defaultPort + 1 ))
  done

  while true; do
    read -r -p "$label port [$defaultPort] (press Enter to use default): " input
    input="${input:-$defaultPort}"

    if [[ ! "$input" =~ ^[0-9]+$ ]] || (( input < 1024 || input > 65535 )); then
      printf 'Enter a number between 1024 and 65535.\n'
      continue
    fi

    if [[ -n "${takenPort:-}" && "$input" == "$takenPort" ]]; then
      printf 'That port is already assigned to the other service.\n'
      continue
    fi

    if portInUse "$input"; then
      read -r -p "Port $input is already in use (another server may be running). Use it anyway? [y/N] " answer
      [[ "$answer" =~ ^[Yy]$ ]] || continue
    fi

    REPLY_PORT="$input"
    return 0
  done
}

takenPort=""
askPort "txAdmin web" 40120
txPort="$REPLY_PORT"
takenPort="$txPort"
askPort "Game server" 30120
gamePort="$REPLY_PORT"
takenPort=""

read -r -p "Database name [kora_dev] (use a different name for a second server): " dbName
dbName="${dbName:-kora_dev}"
[[ "$dbName" =~ ^[A-Za-z0-9_]+$ ]] \
  || die "Database name may only contain letters, numbers and '_'."

read -r -p "MySQL user [root]: " dbUser
dbUser="${dbUser:-root}"

# Runs the mysql client against the local server. An empty password is sent as
# "no password" instead of an empty MYSQL_PWD value.
mysqlCmd() {
  if [[ -n "$dbPass" ]]; then
    MYSQL_PWD="$dbPass" mysql -u"$dbUser" -h127.0.0.1 "$@"
  else
    env -u MYSQL_PWD mysql -u"$dbUser" -h127.0.0.1 "$@"
  fi
}

read_mysql_password() {
  local attempt

  for (( attempt=1; attempt<=3; attempt++ )); do
    read -r -s -p "MySQL password (leave blank if none): " dbPass
    printf '\n'

    [[ "$dbPass" != *$'\n'* && "$dbPass" != *$'\r'* ]] \
      || die "MySQL password cannot contain newline characters."

    if mysqlCmd -e "SELECT 1" >/dev/null 2>&1; then
      return 0
    fi

    printf "Could not log in as '%s' (attempt %s/3). Check the password, or press Enter if the account has none.\n" "$dbUser" "$attempt"
  done

  die "Could not log in to MySQL as '$dbUser' after 3 attempts."
}

read_mysql_password

read -r -s -p "Enter server licence key (from portal.cfx.re; also used for resources): " licenseKey
printf '\n'
[[ -n "$licenseKey" ]] || die "A licence key is required."
[[ "$licenseKey" != *$'\n'* && "$licenseKey" != *$'\r'* ]] \
  || die "The licence key cannot contain newline characters."

read -r -p "Cfx.re forum username for txAdmin admin (blank to skip): " adminName
adminId=""

if [[ -n "$adminName" ]]; then
  [[ "$adminName" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Invalid Cfx.re username."

  # Look up the numeric forum ID (= fivem:<id>) from the public profile endpoint.
  for attempt in 1 2 3 4; do
    response="$(curl -fsSL -m 20 -A "Mozilla/5.0" "https://forum.cfx.re/u/$adminName.json" 2>/dev/null)" || response=""
    adminId="$(printf '%s' "$response" \
      | grep -o '"user":{"id":[0-9]*' \
      | head -n 1 \
      | grep -o '[0-9]*$' || true)"

    [[ -n "$adminId" ]] && break

    if (( attempt < 4 )); then
      printf "Lookup failed (attempt %s/4); retrying in %ss...\n" "$attempt" "$(( attempt * 3 ))"
      sleep $(( attempt * 3 ))
    fi
  done

  if [[ -n "$adminId" ]]; then
    printf 'Found FiveM ID for %s: %s\n' "$adminName" "$adminId"
  else
    printf "Could not look up '%s' on forum.cfx.re (incorrect username, network issue, or rate limit).\n" "$adminName"
    read -r -p "Enter your FiveM ID manually (number from 'fivem:<id>'): " adminId
    [[ "$adminId" =~ ^[0-9]+$ ]] || die "FiveM ID must be numeric."
  fi
fi

# --- create folders ---
mkdir -p "$serverName/server"
cd "$serverName/server"
serverRoot="$(pwd -P)"

# --- download recommended FXServer artifacts ---
if { [[ "$os" == "linux" && -f run.sh ]] || [[ "$os" == "windows" && -f FXServer.exe ]]; }; then
  printf 'Skipping FXServer artifacts (the expected server executable already exists).\n'
else
  printf 'Fetching recommended FXServer artifacts...\n'
  artifactJson="$(curl -fsSL "$artifactsApi")" \
    || die "Could not reach the FXServer artifacts API: $artifactsApi"

  build="$(printf '%s' "$artifactJson" \
    | grep -o '"recommendedArtifact":"[^"]*"' \
    | cut -d'"' -f4)"
  [[ -n "$build" ]] || die "Could not determine the recommended FXServer artifact build."

  if [[ "$os" == "linux" ]]; then
    downloadUrl="$(printf '%s' "$artifactJson" \
      | grep -o '"linuxDownloadLink":"[^"]*"' \
      | cut -d'"' -f4)"
    archive="fx.tar.xz"
  else
    downloadUrl="$(printf '%s' "$artifactJson" \
      | grep -o '"windowsDownloadLink":"[^"]*"' \
      | cut -d'"' -f4)"
    archive="server.zip"
  fi

  [[ -n "$downloadUrl" ]] || die "Could not parse the $os FXServer artifact download link."

  printf 'Downloading FXServer build %s (%s)...\n' "$build" "$os"
  temporaryPaths+=("$archive")
  curl -fL --progress-bar -o "$archive" "$downloadUrl" \
    || die "FXServer artifact download failed."

  printf 'Extracting FXServer artifacts...\n'
  if [[ "$os" == "linux" ]]; then
    tar -xJf "$archive" || die "Could not extract the FXServer tar.xz archive."
  elif command -v unzip >/dev/null 2>&1; then
    unzip -q "$archive" || die "Could not extract the FXServer ZIP archive."
  else
    KORA_ARCHIVE_PATH="$(cygpath -aw "$archive")" \
      KORA_EXTRACT_PATH="$(cygpath -aw .)" \
      powershell.exe -NoProfile -NonInteractive -Command \
        'Expand-Archive -LiteralPath $env:KORA_ARCHIVE_PATH -DestinationPath $env:KORA_EXTRACT_PATH -Force' \
      || die "PowerShell could not extract the FXServer ZIP archive."
  fi

  rm -f "$archive"
  temporaryPaths=("${temporaryPaths[@]/$archive}")

  if [[ "$os" == "windows" && ! -f FXServer.exe ]]; then
    die "Extraction completed, but FXServer.exe was not found in the server directory."
  elif [[ "$os" == "linux" && ! -f run.sh ]]; then
    die "Extraction completed, but run.sh was not found in the server directory."
  fi
fi

# --- repository cloning helpers ---
# clone [-b branch] URL [destination]
# If destination is omitted, Git uses the repository name as the folder.
clone() {
  local last="${*: -1}"
  local folderName

  if [[ "$last" == *://* ]]; then
    folderName="$(basename "$last" .git)"
  else
    folderName="$last"
  fi

  if [[ -d "$folderName" ]]; then
    printf 'Skipping %s (already exists).\n' "$folderName"
    return 0
  fi

  gitClone "$@"
}

cloneAll() {
  local repository
  for repository in "$@"; do
    clone "$org/$repository.git"
  done
}

# --- repository lists ---
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

# --- txAdmin data and server configuration ---
mkdir -p txData
cd txData
mkdir -p "kora dev"
cd "kora dev"

cfgTmp="$(mktemp -d)"
temporaryPaths+=("$cfgTmp")
gitClone --depth 1 "$org/server_cfg_test.git" "$cfgTmp/server_cfg_test"
[[ -f "$cfgTmp/server_cfg_test/server.cfg" ]] \
  || die "The server_cfg_test repository did not contain server.cfg."
cp "$cfgTmp/server_cfg_test/server.cfg" server.cfg
rm -rf "$cfgTmp"
temporaryPaths=("${temporaryPaths[@]/$cfgTmp}")

# Escape values for use in the server.cfg double-quoted strings.
esc() {
  printf '%s' "$1" | sed -e 's/[\\&#]/\\&/g'
}

if grep -qE '^[[:space:]]*sv_licenseKey' server.cfg; then
  sed -i.bak -E "s#^[[:space:]]*sv_licenseKey.*#sv_licenseKey \"$(esc "$licenseKey")\"#" server.cfg
else
  printf '\nsv_licenseKey "%s"\n' "$(esc "$licenseKey")" >> server.cfg
fi

# URL-encode database credentials for the mysql connection string.
urlenc() {
  local index character output="" value="$1"

  for (( index=0; index<${#value}; index++ )); do
    character="${value:index:1}"
    case "$character" in
      [A-Za-z0-9._~-])
        output+="$character"
        ;;
      *)
        printf -v encoded '%%%02X' "'$character"
        output+="$encoded"
        ;;
    esac
  done

  printf '%s' "$output"
}

# With an empty password the connection string omits the ":password" part.
if [[ -n "$dbPass" ]]; then
  credentialString="$(urlenc "$dbUser"):$(urlenc "$dbPass")"
else
  credentialString="$(urlenc "$dbUser")"
fi
connectionString="mysql://$credentialString@127.0.0.1/$dbName?charset=utf8mb4"

if grep -qE '^[[:space:]]*set[[:space:]]+mysql_connection_string' server.cfg; then
  sed -i.bak -E "s#^[[:space:]]*set[[:space:]]+mysql_connection_string.*#set mysql_connection_string \"$(esc "$connectionString")\"#" server.cfg
else
  printf 'set mysql_connection_string "%s"\n' "$(esc "$connectionString")" >> server.cfg
fi

# Update configured endpoint ports, preserving the rest of each endpoint.
sed -i.bak -E "s#^([[:space:]]*endpoint_add_(tcp|udp)[[:space:]]+\"[^\":]*:)[0-9]+#\\1$gamePort#" server.cfg
rm -f server.cfg.bak

# --- database ---
createDb() {
  mysqlCmd -e "CREATE DATABASE IF NOT EXISTS \`$dbName\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci" \
    || die "Could not create database '$dbName'. Does '$dbUser' have CREATE privileges?"
}

databaseExists="$(mysqlCmd -N -e "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='$dbName'")"
tableCount=0
oldTableCount=0

if [[ "${databaseExists:-0}" -gt 0 ]]; then
  tableCount="$(mysqlCmd -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$dbName'")"
  oldTableCount="$(mysqlCmd -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$dbName' AND table_collation <> 'utf8mb4_unicode_ci'")"
fi

if [[ "${tableCount:-0}" -eq 0 ]]; then
  createDb
  printf "Created empty database '%s'; kora_sql creates the tables on first start.\n" "$dbName"
else
  printf "Database '%s' already exists (%s tables).\n" "$dbName" "$tableCount"

  if [[ "${oldTableCount:-0}" -gt 0 ]]; then
    printf 'WARNING: %s table(s) use a collation other than utf8mb4_unicode_ci.\n' "$oldTableCount"
    printf "         kora_sql may report schema/collation warnings for these tables.\n"
  fi

  read -r -p "[U]se existing database or [D]rop it and start fresh? [U/d] " databaseChoice
  if [[ "$databaseChoice" =~ ^[Dd]$ ]]; then
    read -r -p "This permanently deletes ALL data in '$dbName'. Type '$dbName' to confirm: " confirmation
    [[ "$confirmation" == "$dbName" ]] || die "Aborted: database was not dropped."

    mysqlCmd -e "DROP DATABASE \`$dbName\`" || die "Could not drop database '$dbName'."
    createDb
    printf "Recreated empty database '%s'; kora_sql creates the tables on first start.\n" "$dbName"
  else
    printf "Using existing database '%s'. Existing data will not be dropped.\n" "$dbName"
  fi
fi

# --- resources ---
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
clone "https://github.com/Bob74/bob74_ipl.git"
cd ..

cd .. # back to txData/kora dev

# --- txAdmin pre-seed and launch files ---
cd "$serverRoot"

if [[ "$os" == "windows" ]]; then
  txDataAbs="$(cygpath -m "$serverRoot")/txData"
else
  txDataAbs="$serverRoot/txData"
fi

profileDirectory="txData/default"
mkdir -p "$profileDirectory/data" "$profileDirectory/logs"

if [[ -e "$profileDirectory/config.json" ]]; then
  printf 'Skipping txAdmin config.json (already exists).\n'
else
  cat > "$profileDirectory/config.json" <<JSON
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

# Reject newline characters before embedding values in generated launch scripts.
for valueName in txDataAbs licenseKey dbUser dbPass dbName txPort gamePort adminName adminId; do
  value="${!valueName}"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] \
    || die "$valueName cannot contain newline characters."
done

if [[ "$os" == "linux" ]]; then
  envLines=(
    "TXHOST_DATA_PATH=$txDataAbs"
    "TXHOST_DEFAULT_CFXKEY=$licenseKey"
    "TXHOST_DEFAULT_DBHOST=127.0.0.1"
    "TXHOST_DEFAULT_DBPORT=3306"
    "TXHOST_DEFAULT_DBUSER=$dbUser"
    "TXHOST_DEFAULT_DBNAME=$dbName"
    "TXHOST_TXA_PORT=$txPort"
    "TXHOST_FXS_PORT=$gamePort"
    "TXHOST_GAME_NAME=fivem"
  )

  # Only set a database password when there is one.
  [[ -n "$dbPass" ]] && envLines+=("TXHOST_DEFAULT_DBPASS=$dbPass")
  [[ -n "$adminName" ]] && envLines+=("TXHOST_DEFAULT_ACCOUNT=$adminName:$adminId")

  {
    printf '#!/usr/bin/env bash\n'
    for line in "${envLines[@]}"; do
      printf 'export %s=%q\n' "${line%%=*}" "${line#*=}"
    done
  } > env.sh

  cat > start.sh <<'SH'
#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
source ./env.sh
exec ./run.sh
SH

  chmod 700 env.sh start.sh

else
  # A PowerShell launcher avoids cmd.exe batch parsing problems with %, &, !,
  # quotes, carets and other characters in passwords and licence keys.
  # Values are emitted as PowerShell single-quoted strings; embedded single
  # quotes are doubled by psQuote().
  psQuote() {
    local value="$1"
    value="${value//\'/\'\'}"
    printf "'%s'" "$value"
  }

  startPowerShell="$serverRoot/start.ps1"

  {
    cat <<'PS'
$ErrorActionPreference = 'Stop'
$serverRoot = $PSScriptRoot
Set-Location -LiteralPath $serverRoot
PS
    printf '$env:TXHOST_DATA_PATH = %s\n' "$(psQuote "$txDataAbs")"
    printf '$env:TXHOST_DEFAULT_CFXKEY = %s\n' "$(psQuote "$licenseKey")"
    printf '$env:TXHOST_DEFAULT_DBHOST = %s\n' "$(psQuote "127.0.0.1")"
    printf '$env:TXHOST_DEFAULT_DBPORT = %s\n' "$(psQuote "3306")"
    printf '$env:TXHOST_DEFAULT_DBUSER = %s\n' "$(psQuote "$dbUser")"
    printf '$env:TXHOST_DEFAULT_DBNAME = %s\n' "$(psQuote "$dbName")"
    printf '$env:TXHOST_TXA_PORT = %s\n' "$(psQuote "$txPort")"
    printf '$env:TXHOST_FXS_PORT = %s\n' "$(psQuote "$gamePort")"
    printf '$env:TXHOST_GAME_NAME = %s\n' "$(psQuote "fivem")"

    # Only set a database password when there is one.
    if [[ -n "$dbPass" ]]; then
      printf '$env:TXHOST_DEFAULT_DBPASS = %s\n' "$(psQuote "$dbPass")"
    fi

    if [[ -n "$adminName" ]]; then
      printf '$env:TXHOST_DEFAULT_ACCOUNT = %s\n' "$(psQuote "$adminName:$adminId")"
    fi

    cat <<'PS'
$fxServer = Join-Path $serverRoot 'FXServer.exe'
if (-not (Test-Path -LiteralPath $fxServer -PathType Leaf)) {
    throw "FXServer.exe was not found at $fxServer"
}
& $fxServer
exit $LASTEXITCODE
PS
  } > "$startPowerShell"

  cat > start.bat <<'BAT'
@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1"
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" (
  echo.
  echo FXServer exited with code %RESULT%.
  pause
)
exit /b %RESULT%
BAT

  # Restrict the generated launcher file because it contains server secrets.
  # If icacls is unavailable, the installer still completes and warns the user.
  if command -v icacls.exe >/dev/null 2>&1; then
    windowsStartPs="$(cygpath -w "$startPowerShell")"
    windowsUser="$(whoami.exe 2>/dev/null | tr -d '\r')"
    if [[ -n "$windowsUser" ]]; then
      icacls.exe "$windowsStartPs" /inheritance:r /grant:r "$windowsUser:(R,W)" >/dev/null 2>&1 \
        || printf 'WARNING: Could not restrict permissions on start.ps1. Check its Windows file permissions.\n'
    else
      printf 'WARNING: Could not determine the Windows account for file permissions. Check permissions on start.ps1.\n'
    fi
  else
    printf 'WARNING: icacls.exe was not found. Check Windows permissions on start.ps1; it contains server credentials.\n'
  fi
fi

printf 'Created the txAdmin launch files and pre-filled txAdmin defaults.\n'
printf 'Installation files are located in: %s\n' "$serverRoot"
printf 'txAdmin URL: http://localhost:%s\n' "$txPort"
printf 'Game server port: %s\n' "$gamePort"

# --- launch ---
printf '\nStarting txAdmin. Press Ctrl+C in this terminal to stop the server.\n'

if [[ "$os" == "linux" ]]; then
  exec "$serverRoot/start.sh"
else
  startPowerShellWindows="$(cygpath -w "$serverRoot/start.ps1")"
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$startPowerShellWindows"
  exit "$?"
fi

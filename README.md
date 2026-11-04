# Kora Dev Setup

`setup-kora-dev.sh` builds a complete Kora development server in one run: it creates your server folder, downloads the latest **recommended** FXServer artifacts for your OS, asks for your keys, copies the dev `server.cfg` and clones every resource repo into the right category folder.

## Before you run

You need:

- **bash**: Linux, WSL, or Git Bash on Windows (macOS is not supported by FXServer).
- **git**, **curl**, and **tar + xz** (Linux/WSL) or **unzip** (Windows).
- **GitHub CLI (`gh`)**, signed in with an account that has access to the KoraFiveM organization (most repos are private):
  ```
  gh auth login
  ```
- **MySQL / MariaDB running** on `127.0.0.1:3306`, with the `mysql` client installed and a user that can create databases.
- ~5 GB free disk space.
- Your **Cfx.re licence key** from <https://portal.cfx.re/>. This is the same key used for resources, so there is only one key to enter.

The script checks all of the above and stops with a message if something is missing.

## Run the setup

Run it from the folder where you want your server folder to be created. **Make the script executable first:**

```
chmod +x setup-kora-dev.sh
./setup-kora-dev.sh
```

You will be asked for:

1. **Server name** (letters, numbers, `-`, `_`). A folder with this name is created.
2. **txAdmin port** (default `40120`) and **game server port** (default `30120`). If a port is already in use, the next free one is suggested, so a second server on the same machine just works.
3. **Database name** (default `kora_dev`). Give a second server its own name so the two don't share data.
4. **MySQL user** (press Enter for the default, `root`) and **MySQL password** (required, hidden input).
5. **Server licence key** (hidden input).
6. *(Optional)* **Cfx.re forum username**, to pre-create your txAdmin admin account. The script looks up your FiveM ID automatically from `forum.cfx.re` (and asks you to type it only if the lookup fails). You then log in with the Cfx.re button.

To run a second server on the same machine, just run the script again with a different server name, and accept the suggested free ports and a new database name.

The script then detects your OS, downloads the recommended artifacts from <https://artifacts.jgscripts.com/>, extracts them and deletes the downloaded archive, copies `server.cfg` (with your keys filled in) and clones all resources. The first run takes a while because of the cloning. It prints `done` when finished.

## What gets cloned

| Folder | Contents |
| --- | --- |
| `[cfx-default]` | Default FiveM resources (`-cfx-default-` repo) |
| `[default-maps]` | Default maps (`-default-maps-` repo) |
| `[pre]` | Core dependencies: kora_lib, kora_sql, kora_inventory, kora_core |
| `[kora]` | All Kora gameplay resources, plus kora_robberies |
| `[standalone]` | Standalone resources such as kora_queue, kora_chat, PolyZone, and bob74_ipl |

## Resulting layout

```
my-server/
└── server/
    ├── <FXServer artifacts>, run.sh
    ├── start.sh / env.sh          (start.bat / env.bat on Windows; env holds secrets)
    └── txData/
        ├── default/config.json    (txAdmin settings, pre-seeded)
        └── kora dev/
            ├── server.cfg
            └── resources/
                ├── [cfx-default]/
                ├── [default-maps]/
                ├── [pre]/
                ├── [kora]/
                └── [standalone]/
```

## Configuration

The only setting you might change is at the top of `setup-kora-dev.sh`:

| Variable | Default | Meaning |
| --- | --- | --- |
| `org` | `https://github.com/KoraFiveM` | GitHub organization the repos are cloned from |

## After setup

1. The script starts the server for you when it finishes (via `start.sh`, or `start.bat` on Windows) and txAdmin runs in that terminal until you press Ctrl+C. To start it again later, run `./start.sh` from the `server` folder. On a VPS, run the setup inside `screen` or `tmux` so closing your SSH session doesn't stop it. The start script loads `env.sh`/`env.bat`, which pre-fills txAdmin with your licence key, database login and admin account. These files contain secrets, so keep them private (they are created owner-only).
2. The script creates an empty database (default `kora_dev`) if it doesn't exist; `kora_sql` creates the tables on first start. If it already exists you are asked whether to use it (default) or drop it and start fresh (you must type the database name to confirm). You are warned if its tables use an older collation than Kora expects, which causes `differs from its schema (not altered)` messages in the console. Your MySQL login is written into `mysql_connection_string` in `server.cfg`.
3. txAdmin is pre-configured (`txData/default/config.json`) to use `txData/kora dev` as the server data folder, so there is no "Use existing data" step. If txAdmin still shows the setup wizard, choose **Use existing data** and point it at `txData/kora dev`.
4. **Server list metadata:** Cfx.re no longer reads `sv_projectName`, `sv_projectDesc`, tags or banners from `server.cfg`. Set them at <https://portal.cfx.re/>, otherwise the server is listed as "Missing server data".

## Running under pm2 (VPS)

The setup script launches the server in your terminal. To keep it running after you log out, stop that and run it under pm2 instead:

```
chmod +x start.sh            # only if it is not already executable
cd my-server/server
pm2 start start.sh --name my-server --interpreter bash
pm2 save
```

Logs: `pm2 logs my-server`. Restart: `pm2 restart my-server`.

## Troubleshooting

- `Permission denied` when running a script: run `chmod +x setup-kora-dev.sh` (or `chmod +x start.sh`).
- `differs from its schema (not altered)` in the console: the database has tables from an older import. Re-run the setup and choose to drop and start fresh.
- Port already in use: re-run the setup and pick different ports, or stop the other server.

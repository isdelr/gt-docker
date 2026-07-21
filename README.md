# GTNH Docker Compose for Coolify

This stack runs GregTech New Horizons on top of [`itzg/minecraft-server`](https://github.com/itzg/docker-minecraft-server) with `TYPE=GTNH`, so the container handles downloading and installing the GTNH server pack for you.

By default it is configured to:

- pin GTNH `2.9.0-beta-2` and its matching Java 25 client pack
- pin known `itzg/minecraft-server` and `itzg/mc-backup` image releases
- allocate `12G` of Java heap so the 22 GiB host retains native-memory headroom
- keep RCON private and share the image-generated credential through the data volume
- allow nine minutes for Minecraft and ten minutes for Docker shutdown
- keep verified, deduplicated Restic snapshots at 12-hour intervals
- keep claimed-region ServerUtilities backups within a 20 GB cap
- never auto-restore backup archives, and disable Forge query confirmation by default
- limit automatic Minecraft restart attempts to three
- keep the whitelist enabled from first boot
- bridge GTNH download metadata gaps for pinned releases
- install tested DreamAssemblerXXL daily server artifacts with digest checks and transactional rollback
- cache verified server artifacts and resume interrupted update work across redeploys

## Official GTNH links

- Homepage: [https://www.gtnewhorizons.com/](https://www.gtnewhorizons.com/)
- Downloads page: [https://www.gtnewhorizons.com/downloads/](https://www.gtnewhorizons.com/downloads/)
- Stable mirror alias: [https://downloads.gtnewhorizons.com/Latest/Stable/](https://downloads.gtnewhorizons.com/Latest/Stable/)
- Direct latest stable Java 17-25 server archive alias: [https://downloads.gtnewhorizons.com/Latest/Stable/Latest%20stable%20Java%2017-25%20server%20archive%20%28recommended%29.zip](https://downloads.gtnewhorizons.com/Latest/Stable/Latest%20stable%20Java%2017-25%20server%20archive%20%28recommended%29.zip)


## Files

- `docker-compose.yml`: the deployable Coolify/Compose stack
- `Dockerfile`: wrapper around `itzg/minecraft-server` with Restic and the GTNH resolver override
- `docker/gtnh-entrypoint.sh`: prepares shared Restic ownership and credentials before normal startup
- `docker/gtnh-restic.sh`: shared Restic snapshot, verification, and progress logging functions
- `docker/gtnhctl`: terminal utility for status, logs, snapshots, checks, cache management, and staged restores
- `docker/start-deployGTNH`: resolves releases/dailies, validates server archives, updates transactionally, and applies bounded backup settings
- `ops/gtnh-graceful-shutdown*`: host shutdown hook and Docker stop helper
- `.env.example`: envs you can copy into Coolify or a local `.env`

## Deploying in Coolify

1. Create a new Docker Compose resource that points at this folder/repository.
2. Paste the values from `.env.example` into Coolify's environment UI.
3. Deploy the stack.

Coolify treats `docker-compose.yml` as the source of truth, and it auto-detects `${VAR}` placeholders so those settings appear in the UI.

## Default behavior

- Production is pinned to `GTNH_PACK_VERSION=2.9.0-beta-2`; clients must use the matching pack.
- For predictable updates, pin `GTNH_PACK_VERSION` to a specific version. Exact pinned versions are first resolved through GTNH's official metadata; if missing, the image tries the standard official server archive URL.
- `GTNH_PACK_URL` is optional. Set it only when a pinned version exists but the archive filename or location does not follow the standard GTNH pattern.
- Tested daily builds use identifiers such as `daily-2026-07-19+630`. They come from DreamAssemblerXXL Actions, not the config-only nightly release ZIP.
- Daily artifact downloads require `GTNH_GITHUB_TOKEN`, stored as a Coolify secret with read-only GitHub Actions access.
- `ENABLE_WHITELIST=true` and `ENFORCE_WHITELIST=true` means nobody can join until you add them.
- The Minecraft TCP port is mapped with `MC_PORT`, while the in-game server binds to `SERVER_PORT`.
- Query is off by default. If you enable it, the compose file already maps the configured UDP query port.

## GTNH release pinning

For normal stable tracking, leave:

```text
GTNH_PACK_VERSION=2.9.0-beta-2
GTNH_PACK_URL=
```

For a pinned beta or other exact version, set the version and leave `GTNH_PACK_URL` blank first:

```text
GTNH_PACK_VERSION=2.9.0-beta-2
GTNH_PACK_URL=
```

The custom GTNH deploy script preserves the upstream cleanup update flow, including replacing `libraries`, `mods`, `resources`, `scripts`, server launch files, backing up `config`, restoring `JourneyMapServer`, and updating `/data/.gtnh-version`. The only intentional difference is download resolution: when `versions.json` does not list an exact pinned version, the script tries the standard official server archive URL, such as:

```text
https://downloads.gtnewhorizons.com/ServerPacks/betas/GT_New_Horizons_2.9.0-beta-2_Server_Java_17-25.zip
```

If a release uses a non-standard archive name or location, set the direct server archive URL:

```text
GTNH_PACK_VERSION=2.9.0-beta-2
GTNH_PACK_URL=https://downloads.gtnewhorizons.com/ServerPacks/betas/GT_New_Horizons_2.9.0-beta-2_Server_Java_17-25.zip
```

For a custom direct URL, `GTNH_PACK_SHA256` can pin its expected SHA-256 digest. Daily artifacts obtain and verify their digest from GitHub automatically.

## Tested daily builds

Do not use the ZIP attached to a `GT-New-Horizons-Modpack` nightly release as a server archive. GTNH's release workflow describes that ZIP as the modpack config/script bundle, and it does not contain the server libraries, runtime launcher, or assembled mod JAR set.

Use the matching successful `DreamAssemblerXXL` daily workflow instead. For the config release `2.9.0-nightly-2026-07-19`, the official daily manifest identifies build `daily-2026-07-19+630`; workflow run 630 produced and tested these matching artifacts:

- `GTNH-daily-2026-07-19+630-server-java17-25.zip` for this server
- `GTNH-daily-2026-07-19+630-mmcprism-java17-25.zip` for Java 17-25 clients

Set these Coolify variables and redeploy:

```text
GTNH_PACK_VERSION=daily-2026-07-19+630
GTNH_PACK_URL=
GTNH_GITHUB_TOKEN=<Coolify secret with read-only Actions access>
```

`latest-daily` is also supported, but an exact daily ID is safer for production because server and clients remain pinned together. GitHub Actions artifacts eventually expire. Once this stack has verified an artifact, it keeps the ZIP under `/data/packs/artifacts/<sha256>.zip`, so ordinary redeploys and interrupted extraction do not depend on GitHub still serving it. Keep client and server artifacts somewhere outside the VPS as well.

The daily updater fails before changing `/data` unless the artifact:

- exists and is not expired
- matches GitHub's byte size and SHA-256 digest
- contains the complete server runtime, including `config`, `mods`, `libraries`, Forge, and the Java 17+ launcher
- contains a plausible assembled server set rather than the config-only nightly's seven mod metadata entries and zero mod JARs

Updates replace only pack-managed runtime paths. Worlds, player data, `server.properties`, whitelist/ops/ban files, `serverutilities`, custom server icon, backups, and other unrelated `/data` content are not touched. Existing `config/JourneyMapServer` data is restored into the new config.

The update manager journals each operation under `/data/.gtnh-manager/state.json`. Downloads use a resumable `.part` file, verified artifacts are addressed by SHA-256, and validated extracted staging survives a canceled deployment. On restart it resumes the latest valid stage and reuses an already committed pre-upgrade snapshot. The two most recently used artifacts and two managed-file rollback directories are retained by default.

Immediately before files move, the stopped server creates and reopens a Restic snapshot on `/backups`. The first Restic snapshot is a one-time baseline and still must read and store the persistent data. Later snapshots use content deduplication and file metadata to avoid recompressing unchanged world data. Progress is logged every ten seconds, and the latest two pre-upgrade snapshots are retained by default. The previous managed runtime and prior config also remain under `/data/gtnh-upgrade-*`; an interrupted file transaction is rolled back on the next startup before Minecraft launches.

## Graceful shutdown

The stack sets both sides of the shutdown timeout:

- `STOP_DURATION=540` gives the Minecraft wrapper nine minutes.
- `stop_grace_period=10m` gives Docker one additional minute.
- The installed systemd hook stops the labeled server container before Docker during normal reboot.

An OVH hard reset can bypass userspace shutdown hooks, so verified backups remain mandatory.

## Backups

The `gtnh-backups` service waits for Minecraft health, loads the image-generated RCON credential from the shared `/data/.rcon-cli.env`, then coordinates `save-off`, `save-all flush`, and `save-on`. It creates a deduplicated Restic snapshot every 12 hours. The storage-conscious default keeps snapshots from the last 24 hours, seven daily, four weekly, and three monthly restore points. Policies overlap, so Restic does not retain a separate duplicate for every rule. Internal backup trees, recovery snapshots, upgrade snapshots, logs, caches, jars, and downloaded packs are excluded.

Pre-upgrade and scheduled snapshots share `/backups/restic`. Successful snapshots are reopened by ID before `/backups/.last-verified` is updated, and the backup container becomes unhealthy when that marker is older than 13 hours. New snapshots are refused when less than 20 GiB remains free. Retention cannot guarantee a fixed repository size because world churn varies, so keep the health check and `gtnhctl doctor` monitored.

Set only `GTNH_RESTIC_PASSWORD` to a long Coolify secret before the first deployment. The repository is deliberately fixed at `/backups/restic` in both containers and unsafe overrides are rejected without logging their value. If the password is blank, the entrypoint generates `/backups/.gtnh-restic-password`; preserve that file separately because snapshots cannot be opened without it. Changing the configured password later does not rotate an initialized repository key and is intentionally rejected.

If an older deployment accidentally used the password as `GTNH_RESTIC_REPOSITORY`, treat that password as compromised. Rotate `GTNH_RESTIC_PASSWORD`, remove the obsolete repository variable from Coolify, and redeploy. Startup recognizes the misplaced repository under `/data`, excludes it from both backup paths, and permits the new password file because `/backups/restic` is still uninitialized. After the scheduled startup snapshot succeeds, run:

```bash
gtnhctl doctor
gtnhctl snapshots
gtnhctl cleanup-misplaced-restic --confirm
gtnhctl doctor
```

Cleanup remains blocked until `/backups/.last-restic-snapshot` identifies a snapshot that can be reopened from the fixed repository and was verified within the last 13 hours. It never prints the misplaced directory name and redacts that name from the manager event logs as it removes the repository. Existing external container logs must be removed through the logging platform separately if they captured the old value.

ServerUtilities supplies the faster tier every 30 minutes using complete region files containing claimed chunks. It retains up to 24 archives within a 20 GB cap. Restic snapshots and the VPS Backblaze snapshots protect unclaimed areas.

The retired tar/ZIP backup path is not scanned, adapted, or restored automatically, and there is no environment variable that re-enables it. Existing archives are left untouched so they can be inspected manually. After verifying a Restic baseline, remove obsolete archives yourself if their disk usage is no longer justified. Do not enable automatic Forge query confirmation in production; missing block or item mappings require operator review.

## Terminal utility

Run `gtnhctl` from the `gtnh` service terminal in Coolify. It is non-interactive and emits colored output only when attached to a terminal.

```bash
gtnhctl status
gtnhctl logs 100 --follow
gtnhctl snapshots
gtnhctl backup
gtnhctl check
gtnhctl cache
gtnhctl cache prune 3
gtnhctl doctor
```

Restores are staged and verified away from live data. This command restores only `World` into a new recovery directory and prints the resulting path:

```bash
gtnhctl restore <snapshot-id> --world World
gtnhctl legacy-restore /backups/<old-archive>.tar.gz --dry-run
```

Inspect the staged copy before replacing any live world. `legacy-restore` only reads the exact old archive you name and never participates in startup recovery. For a Restic preview, append `--dry-run`. `gtnhctl` refuses `/` and `/data` as restore targets.

## Storage controls

The default storage limits for a 256 GB host are:

```text
BACKUP_INTERVAL=12h
PRUNE_RESTIC_RETENTION=--keep-within 24h --keep-daily 7 --keep-weekly 4 --keep-monthly 3
GTNH_BACKUP_MIN_FREE_GB=20
GTNH_PRE_UPDATE_SNAPSHOTS_KEEP=2
GTNH_ARTIFACT_CACHE_KEEP=2
GTNH_TRANSACTION_BACKUPS_KEEP=2
GTNH_INTERNAL_BACKUPS_TO_KEEP=24
GTNH_INTERNAL_BACKUP_MAX_GB=20
```

## Whitelist and admin commands

RCON stays enabled, but the compose file does not publish the RCON port to the host. In Coolify, use the service terminal/console to run server commands directly.

Useful commands:

```text
whitelist add PlayerName
whitelist remove PlayerName
whitelist list
whitelist reload
op PlayerName
save-all
stop
```

## Best-practice notes for this stack

- Keep `/data` and `/backups` on persistent named volumes.
- Preserve the Restic password outside those volumes.
- Treat a missing or stale `.last-verified` marker as backup failure.
- The backup volume shares the VPS disk; Backblaze B2 provides the off-site tier.
- Leave RCON enabled for controlled administration and backup coordination, but do not expose its port publicly.
- Keep host RAM free above the Java heap. `MEMORY=12G` is not the container's total use.
- Leave GTNH defaults in place unless you have a specific reason to change them: `LEVEL_TYPE=rwg`, `DIFFICULTY=hard`, `ALLOW_FLIGHT=true`, and `ENABLE_COMMAND_BLOCK=true`.
- Upgrade the complete GTNH server and matching clients together; do not replace individual mod jars.
- Expect first boot and some later startups to take a while; the healthcheck uses a long `start_period` to avoid false failures during install and mod loading.

## Local validation

You can validate the compose file locally with:

```powershell
docker compose --env-file .env.example config
docker compose --env-file .env.example build gtnh
docker run --rm --entrypoint bash --tmpfs /data --tmpfs /backups --mount "type=bind,src=$((Resolve-Path tests).Path),dst=/tests,readonly" gtnh-minecraft-server:2026.5.3-java25 /tests/test-gtnh-deploy.sh
docker run --rm --entrypoint bash --tmpfs /data --tmpfs /backups --mount "type=bind,src=$((Resolve-Path tests).Path),dst=/tests,readonly" gtnh-minecraft-server:2026.5.3-java25 /tests/test-gtnhctl.sh
docker run --rm --entrypoint bash --tmpfs /data --tmpfs /backups --mount "type=bind,src=$((Resolve-Path tests).Path),dst=/tests,readonly" gtnh-minecraft-server:2026.5.3-java25 /tests/test-gtnh-entrypoint.sh
```

## Sources

- GTNH homepage: [https://www.gtnewhorizons.com/](https://www.gtnewhorizons.com/)
- GTNH downloads: [https://www.gtnewhorizons.com/downloads/](https://www.gtnewhorizons.com/downloads/)
- GTNH stable mirror: [https://downloads.gtnewhorizons.com/Latest/Stable/](https://downloads.gtnewhorizons.com/Latest/Stable/)
- GTNH versions metadata: [https://downloads.gtnewhorizons.com/versions.json](https://downloads.gtnewhorizons.com/versions.json)
- GTNH nightly config release example: [https://github.com/GTNewHorizons/GT-New-Horizons-Modpack/releases/tag/2.9.0-nightly-2026-07-19](https://github.com/GTNewHorizons/GT-New-Horizons-Modpack/releases/tag/2.9.0-nightly-2026-07-19)
- DreamAssemblerXXL tested daily run 630: [https://github.com/GTNewHorizons/DreamAssemblerXXL/actions/runs/29675980744](https://github.com/GTNewHorizons/DreamAssemblerXXL/actions/runs/29675980744)
- GitHub Actions artifact API: [https://docs.github.com/en/rest/actions/artifacts](https://docs.github.com/en/rest/actions/artifacts)
- GTNH in the Docker image docs: [https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/mod-platforms/gtnh/](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/mod-platforms/gtnh/)
- Server properties and whitelist docs: [https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)
- JVM/memory docs: [https://docker-minecraft-server.readthedocs.io/en/latest/configuration/jvm-options/](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/jvm-options/)
- Healthcheck docs: [https://docker-minecraft-server.readthedocs.io/en/latest/misc/healthcheck/](https://docker-minecraft-server.readthedocs.io/en/latest/misc/healthcheck/)
- Data directory docs: [https://docker-minecraft-server.readthedocs.io/en/latest/data-directory/](https://docker-minecraft-server.readthedocs.io/en/latest/data-directory/)
- Restic backup docs: [https://restic.readthedocs.io/en/stable/040_backup.html](https://restic.readthedocs.io/en/stable/040_backup.html)
- Restic restore docs: [https://restic.readthedocs.io/en/stable/050_restore.html](https://restic.readthedocs.io/en/stable/050_restore.html)
- `itzg/mc-backup` Restic docs: [https://github.com/itzg/docker-mc-backup#restic](https://github.com/itzg/docker-mc-backup#restic)
- Coolify Docker Compose docs: [https://coolify.io/docs/knowledge-base/docker/compose](https://coolify.io/docs/knowledge-base/docker/compose)

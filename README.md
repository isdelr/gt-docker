# GTNH Docker Compose for Coolify

This stack runs GregTech New Horizons on top of [`itzg/minecraft-server`](https://github.com/itzg/docker-minecraft-server) with `TYPE=GTNH`, so the container handles downloading and installing the GTNH server pack for you.

By default it is configured to:

- pin GTNH `2.9.0-beta-2` and its matching Java 25 client pack
- pin known `itzg/minecraft-server` and `itzg/mc-backup` image releases
- allocate `12G` of Java heap so the 22 GiB host retains native-memory headroom
- keep RCON private and share the image-generated credential through the data volume
- allow nine minutes for Minecraft and ten minutes for Docker shutdown
- keep 14 verified full backups at 12-hour intervals without recursively archiving backups
- keep claimed-region ServerUtilities backups within a 35 GB cap
- stop and quarantine the server when chunk-corruption signatures appear
- disable automatic full-world restores and Forge query confirmation by default
- disable optimized chunk compression and zlib pooling while chunk-save diagnostics are enabled
- limit automatic Minecraft restart attempts to three
- keep the whitelist enabled from first boot
- bridge GTNH download metadata gaps for pinned releases

## Official GTNH links

- Homepage: [https://www.gtnewhorizons.com/](https://www.gtnewhorizons.com/)
- Downloads page: [https://www.gtnewhorizons.com/downloads/](https://www.gtnewhorizons.com/downloads/)
- Stable mirror alias: [https://downloads.gtnewhorizons.com/Latest/Stable/](https://downloads.gtnewhorizons.com/Latest/Stable/)
- Direct latest stable Java 17-25 server archive alias: [https://downloads.gtnewhorizons.com/Latest/Stable/Latest%20stable%20Java%2017-25%20server%20archive%20%28recommended%29.zip](https://downloads.gtnewhorizons.com/Latest/Stable/Latest%20stable%20Java%2017-25%20server%20archive%20%28recommended%29.zip)


## Files

- `docker-compose.yml`: the deployable Coolify/Compose stack
- `Dockerfile`: tiny wrapper around `itzg/minecraft-server` for startup recovery and the GTNH resolver override
- `docker/gtnh-entrypoint.sh`: enforces corruption quarantine and retains opt-in level.dat recovery
- `docker/gtnh-corruption-guard.sh`: records evidence and stops Minecraft on corruption
- `docker/start-deployGTNH`: resolves releases and reapplies operational safety settings after upgrades
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
- `ENABLE_WHITELIST=true` and `ENFORCE_WHITELIST=true` means nobody can join until you add them.
- The Minecraft TCP port is mapped with `MC_PORT`, while the in-game server binds to `SERVER_PORT`.
- Query is off by default. If you enable it, the compose file already maps the configured UDP query port.

## GTNH version pinning

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

## Graceful shutdown

The stack sets both sides of the shutdown timeout:

- `STOP_DURATION=540` gives the Minecraft wrapper nine minutes.
- `stop_grace_period=10m` gives Docker one additional minute.
- The installed systemd hook stops the labeled server container before Docker during normal reboot.

An OVH hard reset can bypass userspace shutdown hooks, so verified backups remain mandatory.

## Backups

The `gtnh-backups` service waits for Minecraft health, loads the image-generated RCON credential from the shared `/data/.rcon-cli.env`, then coordinates `save-off`, `save-all`, and `save-on`. It runs every 12 hours and retains no more than 14 archives or seven days. Internal backup trees, recovery snapshots, upgrade snapshots, logs, caches, jars, and downloaded packs are excluded.

Each archive must pass `gzip -t`. Successful verification updates `/backups/.last-verified`, and the backup container becomes unhealthy when that marker is older than 13 hours.

ServerUtilities supplies the faster tier every 30 minutes using complete region files containing claimed chunks. It retains up to 48 archives within a 35 GB cap. Full sidecar archives and the VPS Backblaze snapshots protect unclaimed areas.

Automatic full-world restoration is disabled by default because an unreviewed restore can erase unrelated progress. The prior implementation remains opt-in:

```env
AUTO_RESTORE_ON_CORRUPT_LEVELDAT=true
AUTO_RESTORE_ON_FML_LEVELDAT_WARNING=true
```

Do not enable automatic Forge query confirmation in production. Missing block or item mappings require operator review.

## Corruption quarantine

The runtime guard watches only new log lines for missing Level data, rejected chunk roots, malformed UTF, null chunks, and save failures. On detection it:

1. copies the current log under `/data/.gtnh-recovery/`
2. writes `corruption-detected.marker` atomically
3. sends Minecraft a normal RCON `stop`
4. blocks later startup until the affected chunk is inspected and restored

After recovery, set `CORRUPTION_GUARD_CLEAR=true` for one start and then return it to `false`.

Useful operational controls:

```text
CORRUPTION_GUARD_ENABLED=true
GTNH_DISABLE_OPTIMIZED_CHUNK_COMPRESSION=true
GTNH_CHUNK_SAVE_DEBUG=true
BACKUP_INTERVAL=12h
PRUNE_BACKUPS_COUNT=14
PRUNE_BACKUPS_DAYS=7
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
```

## Sources

- GTNH homepage: [https://www.gtnewhorizons.com/](https://www.gtnewhorizons.com/)
- GTNH downloads: [https://www.gtnewhorizons.com/downloads/](https://www.gtnewhorizons.com/downloads/)
- GTNH stable mirror: [https://downloads.gtnewhorizons.com/Latest/Stable/](https://downloads.gtnewhorizons.com/Latest/Stable/)
- GTNH versions metadata: [https://downloads.gtnewhorizons.com/versions.json](https://downloads.gtnewhorizons.com/versions.json)
- GTNH in the Docker image docs: [https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/mod-platforms/gtnh/](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/mod-platforms/gtnh/)
- Server properties and whitelist docs: [https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)
- JVM/memory docs: [https://docker-minecraft-server.readthedocs.io/en/latest/configuration/jvm-options/](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/jvm-options/)
- Healthcheck docs: [https://docker-minecraft-server.readthedocs.io/en/latest/misc/healthcheck/](https://docker-minecraft-server.readthedocs.io/en/latest/misc/healthcheck/)
- Data directory docs: [https://docker-minecraft-server.readthedocs.io/en/latest/data-directory/](https://docker-minecraft-server.readthedocs.io/en/latest/data-directory/)
- Coolify Docker Compose docs: [https://coolify.io/docs/knowledge-base/docker/compose](https://coolify.io/docs/knowledge-base/docker/compose)

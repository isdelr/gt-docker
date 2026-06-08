# GTNH Docker Compose for Coolify

This stack runs GregTech New Horizons on top of [`itzg/minecraft-server`](https://github.com/itzg/docker-minecraft-server) with `TYPE=GTNH`, so the container handles downloading and installing the GTNH server pack for you.

By default it is configured to:

- track the latest full stable GTNH release with `GTNH_PACK_VERSION=latest`
- use Java 25 (`MC_IMAGE_TAG=java25`), which the GTNH container docs recommend for GTNH `2.8.0+`
- bridge GTNH download metadata gaps for pinned versions such as beta releases
- allocate `16G` of Java heap
- keep the whitelist enabled from first boot
- keep RCON enabled for terminal-based administration without publishing the RCON port externally
- give the server up to five minutes to stop cleanly when Docker or the VPS shuts down
- take RCON-coordinated sidecar backups every two hours
- auto-cancel the Forge `backup level.dat` warning, restore the newest backup, and start again

## Official GTNH links

- Homepage: [https://www.gtnewhorizons.com/](https://www.gtnewhorizons.com/)
- Downloads page: [https://www.gtnewhorizons.com/downloads/](https://www.gtnewhorizons.com/downloads/)
- Stable mirror alias: [https://downloads.gtnewhorizons.com/Latest/Stable/](https://downloads.gtnewhorizons.com/Latest/Stable/)
- Direct latest stable Java 17-25 server archive alias: [https://downloads.gtnewhorizons.com/Latest/Stable/Latest%20stable%20Java%2017-25%20server%20archive%20%28recommended%29.zip](https://downloads.gtnewhorizons.com/Latest/Stable/Latest%20stable%20Java%2017-25%20server%20archive%20%28recommended%29.zip)

As of April 9, 2026, the GTNH downloads page and stable mirror both indicate `2.8.4` as the latest stable release. The stable Java 17-25 server archive on the official mirror is dated December 23, 2025.

## Files

- `docker-compose.yml`: the deployable Coolify/Compose stack
- `Dockerfile`: tiny wrapper around `itzg/minecraft-server` for startup recovery and the GTNH resolver override
- `docker/gtnh-entrypoint.sh`: detects the Forge `backup level.dat` warning and restores a backup before launching Minecraft
- `docker/start-deployGTNH`: keeps the GTNH cleanup update flow and adds fallback URL resolution for versions missing from GTNH metadata
- `.env.example`: envs you can copy into Coolify or a local `.env`

## Deploying in Coolify

1. Create a new Docker Compose resource that points at this folder/repository.
2. Paste the values from `.env.example` into Coolify's environment UI.
3. Set a strong `RCON_PASSWORD` before deploying.
4. Deploy the stack.

Coolify treats `docker-compose.yml` as the source of truth, and it auto-detects `${VAR}` placeholders so those settings appear in the UI.

## Default behavior

- `GTNH_PACK_VERSION=latest` means the container will install the latest full stable GTNH release and can update to newer stable releases on subsequent starts.
- For predictable updates, pin `GTNH_PACK_VERSION` to a specific version. Exact pinned versions are first resolved through GTNH's official metadata; if missing, the image tries the standard official server archive URL.
- `GTNH_PACK_URL` is optional. Set it only when a pinned version exists but the archive filename or location does not follow the standard GTNH pattern.
- `ENABLE_WHITELIST=true` and `ENFORCE_WHITELIST=true` means nobody can join until you add them.
- The Minecraft TCP port is mapped with `MC_PORT`, while the in-game server binds to `SERVER_PORT`.
- Query is off by default. If you enable it, the compose file already maps the configured UDP query port.

## GTNH version pinning

For normal stable tracking, leave:

```text
GTNH_PACK_VERSION=latest
GTNH_PACK_URL=
```

For a pinned beta or other exact version, set the version and leave `GTNH_PACK_URL` blank first:

```text
GTNH_PACK_VERSION=2.9.0-beta-1
GTNH_PACK_URL=
```

The custom GTNH deploy script preserves the upstream cleanup update flow, including replacing `libraries`, `mods`, `resources`, `scripts`, server launch files, backing up `config`, restoring `JourneyMapServer`, and updating `/data/.gtnh-version`. The only intentional difference is download resolution: when `versions.json` does not list an exact pinned version, the script tries the standard official server archive URL, such as:

```text
https://downloads.gtnewhorizons.com/ServerPacks/betas/GT_New_Horizons_2.9.0-beta-1_Server_Java_17-25.zip
```

If a release uses a non-standard archive name or location, set the direct server archive URL:

```text
GTNH_PACK_VERSION=2.9.0-beta-1
GTNH_PACK_URL=https://downloads.gtnewhorizons.com/ServerPacks/betas/GT_New_Horizons_2.9.0-beta-1_Server_Java_17-25.zip
```

## Graceful shutdown

The stack now sets both sides of the shutdown timeout:

- `STOP_DURATION=300` tells the `itzg/minecraft-server` process wrapper to wait up to five minutes after sending the server `stop` command.
- `stop_grace_period=6m` gives Docker longer than that before it sends a hard kill.

On VPS reboot, Docker should signal the container, the wrapper should send a normal Minecraft stop, and Forge/GTNH should flush world data before the container exits.

## Backups and auto-recovery

The `gtnh-backups` service uses `itzg/mc-backup` and RCON, so backups are coordinated with `save-off`, `save-all`, and `save-on` rather than copying a hot world without warning. It writes tar backups to the `gtnh-backups` Docker volume, mounted read-only into the Minecraft container at `/backups`.

The startup wrapper checks the active world's `level.dat` before Java starts, then also scans the previous startup log. It restores from GTNH's existing zip backups under `/data/backups`, such as:

```text
/data/backups/2026-04-21-23-04-53.zip
```

If `World/level.dat` is empty/unreadable, or if the previous startup log contains:

```text
Forge Mod Loader detected that the backup level.dat is being used
```

then the next container start restores the newest usable backup from `/backups` or `/data/backups`. The suspect world is moved to `/data/.gtnh-recovery/failed-worlds/`, and the triggering log is moved to `/data/.gtnh-recovery/` so the server does not keep restoring from the same old warning.

The compose file also sets `JVM_DD_OPTS=fml.queryResult:cancel`. That makes Forge stop instead of waiting forever at the prompt or continuing against a possibly damaged world. With `restart: unless-stopped`, Docker starts the container again; the wrapper sees the corrupt `level.dat` or warning, restores a backup, and then launches normally.

Useful recovery knobs:

```text
AUTO_RESTORE_ON_FML_LEVELDAT_WARNING=true
AUTO_RESTORE_ON_CORRUPT_LEVELDAT=true
AUTO_RESTORE_BACKUP_DIRS=/backups /data/backups
AUTO_RESTORE_BACKUP_MAX_DEPTH=4
BACKUP_INTERVAL=2h
PRUNE_BACKUPS_DAYS=14
```

If the newest backup also triggers the same Forge warning, the wrapper skips that already-restored archive on the following restart and tries the next newest backup.

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

- Keep `/data` on a persistent named volume so worlds and configs survive redeploys.
- Keep the `gtnh-backups` volume persistent too; it is separate from the Minecraft data volume on purpose.
- Leave RCON enabled for controlled administration, but do not expose `25575` publicly unless you have a specific need and a strong password.
- Keep some host RAM free above the Java heap. `MEMORY=16G` sets only the JVM heap, not the total container footprint.
- Leave GTNH defaults in place unless you have a specific reason to change them: `LEVEL_TYPE=rwg`, `DIFFICULTY=hard`, `ALLOW_FLIGHT=true`, and `ENABLE_COMMAND_BLOCK=true`.
- If you want predictable updates, replace `GTNH_PACK_VERSION=latest` with a pinned version such as `2.8.4` or `2.9.0-beta-1`.
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

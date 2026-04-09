# GTNH Docker Compose for Coolify

This stack runs GregTech New Horizons on top of [`itzg/minecraft-server`](https://github.com/itzg/docker-minecraft-server) with `TYPE=GTNH`, so the container handles downloading and installing the GTNH server pack for you.

By default it is configured to:

- track the latest full stable GTNH release with `GTNH_PACK_VERSION=latest`
- use Java 25 (`MC_IMAGE_TAG=java25`), which the GTNH container docs recommend for GTNH `2.8.0+`
- allocate `16G` of Java heap
- keep the whitelist enabled from first boot
- keep RCON enabled for terminal-based administration without publishing the RCON port externally

## Official GTNH links

- Homepage: [https://www.gtnewhorizons.com/](https://www.gtnewhorizons.com/)
- Downloads page: [https://www.gtnewhorizons.com/downloads/](https://www.gtnewhorizons.com/downloads/)
- Stable mirror alias: [https://downloads.gtnewhorizons.com/Latest/Stable/](https://downloads.gtnewhorizons.com/Latest/Stable/)
- Direct latest stable Java 17-25 server archive alias: [https://downloads.gtnewhorizons.com/Latest/Stable/Latest%20stable%20Java%2017-25%20server%20archive%20%28recommended%29.zip](https://downloads.gtnewhorizons.com/Latest/Stable/Latest%20stable%20Java%2017-25%20server%20archive%20%28recommended%29.zip)

As of April 9, 2026, the GTNH downloads page and stable mirror both indicate `2.8.4` as the latest stable release. The stable Java 17-25 server archive on the official mirror is dated December 23, 2025.

## Files

- `docker-compose.yml`: the deployable Coolify/Compose stack
- `.env.example`: envs you can copy into Coolify or a local `.env`

## Deploying in Coolify

1. Create a new Docker Compose resource that points at this folder/repository.
2. Paste the values from `.env.example` into Coolify's environment UI.
3. Set a strong `RCON_PASSWORD` before deploying.
4. Deploy the stack.

Coolify treats `docker-compose.yml` as the source of truth, and it auto-detects `${VAR}` placeholders so those settings appear in the UI.

## Default behavior

- `GTNH_PACK_VERSION=latest` means the container will install the latest full stable GTNH release and can update to newer stable releases on subsequent starts.
- `ENABLE_WHITELIST=true` and `ENFORCE_WHITELIST=true` means nobody can join until you add them.
- The Minecraft TCP port is mapped with `MC_PORT`, while the in-game server binds to `SERVER_PORT`.
- Query is off by default. If you enable it, the compose file already maps the configured UDP query port.

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
- Leave RCON enabled for controlled administration, but do not expose `25575` publicly unless you have a specific need and a strong password.
- Keep some host RAM free above the Java heap. `MEMORY=16G` sets only the JVM heap, not the total container footprint.
- Leave GTNH defaults in place unless you have a specific reason to change them: `LEVEL_TYPE=rwg`, `DIFFICULTY=hard`, `ALLOW_FLIGHT=true`, and `ENABLE_COMMAND_BLOCK=true`.
- If you want predictable updates, replace `GTNH_PACK_VERSION=latest` with a pinned version such as `2.8.4`.
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
- GTNH in the Docker image docs: [https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/mod-platforms/gtnh/](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/mod-platforms/gtnh/)
- Server properties and whitelist docs: [https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/server-properties/)
- JVM/memory docs: [https://docker-minecraft-server.readthedocs.io/en/latest/configuration/jvm-options/](https://docker-minecraft-server.readthedocs.io/en/latest/configuration/jvm-options/)
- Healthcheck docs: [https://docker-minecraft-server.readthedocs.io/en/latest/misc/healthcheck/](https://docker-minecraft-server.readthedocs.io/en/latest/misc/healthcheck/)
- Data directory docs: [https://docker-minecraft-server.readthedocs.io/en/latest/data-directory/](https://docker-minecraft-server.readthedocs.io/en/latest/data-directory/)
- Coolify Docker Compose docs: [https://coolify.io/docs/knowledge-base/docker/compose](https://coolify.io/docs/knowledge-base/docker/compose)

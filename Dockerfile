ARG MC_IMAGE_TAG=2026.5.3-java25
FROM itzg/minecraft-server:${MC_IMAGE_TAG}

COPY docker/gtnh-entrypoint.sh /usr/local/bin/gtnh-entrypoint.sh
COPY docker/gtnh-corruption-guard.sh /usr/local/bin/gtnh-corruption-guard.sh
COPY docker/start-deployGTNH /image/scripts/start-deployGTNH

RUN apt-get update \
    && apt-get install -y --no-install-recommends pigz \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i 's/\r$//' /usr/local/bin/gtnh-entrypoint.sh /usr/local/bin/gtnh-corruption-guard.sh /image/scripts/start-deployGTNH \
    && chmod +x /usr/local/bin/gtnh-entrypoint.sh /usr/local/bin/gtnh-corruption-guard.sh /image/scripts/start-deployGTNH \
    && grep -Fq 'custom-gtnh-resolver-20260720' /image/scripts/start-deployGTNH

ENTRYPOINT ["/bin/sh", "/usr/local/bin/gtnh-entrypoint.sh"]

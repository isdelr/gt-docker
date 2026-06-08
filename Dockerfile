ARG MC_IMAGE_TAG=java25
FROM itzg/minecraft-server:${MC_IMAGE_TAG}

COPY docker/gtnh-entrypoint.sh /usr/local/bin/gtnh-entrypoint.sh
COPY docker/start-deployGTNH /image/scripts/start-deployGTNH

RUN sed -i 's/\r$//' /usr/local/bin/gtnh-entrypoint.sh /image/scripts/start-deployGTNH \
    && chmod +x /usr/local/bin/gtnh-entrypoint.sh /image/scripts/start-deployGTNH \
    && grep -Fq 'custom-gtnh-resolver-20260608' /image/scripts/start-deployGTNH

ENTRYPOINT ["/bin/sh", "/usr/local/bin/gtnh-entrypoint.sh"]

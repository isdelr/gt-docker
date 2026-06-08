ARG MC_IMAGE_TAG=java25
FROM itzg/minecraft-server:${MC_IMAGE_TAG}

COPY docker/gtnh-entrypoint.sh /usr/local/bin/gtnh-entrypoint.sh
COPY docker/start-deployGTNH /start-deployGTNH

RUN chmod +x /usr/local/bin/gtnh-entrypoint.sh /start-deployGTNH

ENTRYPOINT ["/bin/sh", "/usr/local/bin/gtnh-entrypoint.sh"]

ARG MC_IMAGE_TAG=java25
FROM itzg/minecraft-server:${MC_IMAGE_TAG}

COPY docker/gtnh-entrypoint.sh /usr/local/bin/gtnh-entrypoint.sh
COPY docker/start-deployGTNH /tmp/start-deployGTNH

RUN sed -i 's/\r$//' /usr/local/bin/gtnh-entrypoint.sh /tmp/start-deployGTNH \
    && cp /tmp/start-deployGTNH /start-deployGTNH \
    && cp /tmp/start-deployGTNH /usr/local/bin/start-deployGTNH \
    && chmod +x /usr/local/bin/gtnh-entrypoint.sh /start-deployGTNH /usr/local/bin/start-deployGTNH \
    && grep -Fq 'custom-gtnh-resolver-20260608' /start-deployGTNH \
    && grep -Fq 'custom-gtnh-resolver-20260608' /usr/local/bin/start-deployGTNH

ENTRYPOINT ["/bin/sh", "/usr/local/bin/gtnh-entrypoint.sh"]

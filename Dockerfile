ARG MC_IMAGE_TAG=2026.5.3-java25
ARG MC_BACKUP_IMAGE_TAG=2026.7.1
FROM itzg/mc-backup:${MC_BACKUP_IMAGE_TAG} AS backup-tools

FROM itzg/minecraft-server:${MC_IMAGE_TAG}

COPY --from=backup-tools /usr/bin/restic /usr/local/bin/restic
COPY docker/gtnh-entrypoint.sh /usr/local/bin/gtnh-entrypoint.sh
COPY docker/gtnh-restic.sh /usr/local/lib/gtnh-restic.sh
COPY docker/gtnhctl /usr/local/bin/gtnhctl
COPY docker/start-deployGTNH /image/scripts/start-deployGTNH

RUN sed -i 's/\r$//' /usr/local/bin/gtnh-entrypoint.sh /usr/local/lib/gtnh-restic.sh /usr/local/bin/gtnhctl /image/scripts/start-deployGTNH \
    && chmod +x /usr/local/bin/gtnh-entrypoint.sh /usr/local/bin/gtnhctl /image/scripts/start-deployGTNH \
    && grep -Fq 'custom-gtnh-resolver-20260720' /image/scripts/start-deployGTNH

ENTRYPOINT ["/bin/sh", "/usr/local/bin/gtnh-entrypoint.sh"]

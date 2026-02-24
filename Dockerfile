FROM bitnamilegacy/openldap:latest

USER root

# Upgrade Debian from Bookworm to Trixie for security updates
RUN sed -i 's/bookworm/trixie/g' /etc/apt/sources.list && \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y gosu && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Create the initialization directory and custom entrypoint directory
RUN mkdir -p /docker-entrypoint-initdb.d /exec /opt/bitnami/openldap/certs && \
    chown -R root:root /docker-entrypoint-initdb.d /exec && \
    chown -R 1001:1001 /opt/bitnami/openldap/certs

# Copy our custom entrypoint wrapper
COPY --chown=1001:1001 bin/custom-entrypoint.sh /exec/custom-entrypoint.sh
RUN chmod +x /exec/custom-entrypoint.sh

# The default Bitnami ENTRYPOINT is ["/opt/bitnami/scripts/openldap/entrypoint.sh"]
# We replace it with our wrapper which then calls Bitnami's entrypoint.
ENTRYPOINT [ "/exec/custom-entrypoint.sh" ]

# The default Bitnami CMD is:
CMD [ "/opt/bitnami/scripts/openldap/run.sh" ]

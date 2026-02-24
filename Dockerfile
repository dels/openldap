FROM bitnamilegacy/openldap:latest

USER root

# Upgrade to Trixie
RUN sed -i 's/bookworm/trixie/g' /etc/apt/sources.list && \
    apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Create certs directory and generate a snakeoil cert.
# The certs will be owned by root, but readable by all.
RUN mkdir -p /opt/bitnami/openldap/certs && \
    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
        -subj "/CN=default-snakeoil-cert" \
        -keyout /opt/bitnami/openldap/certs/openldap.key \
        -out /opt/bitnami/openldap/certs/openldap.crt && \
    cp /opt/bitnami/openldap/certs/openldap.crt /opt/bitnami/openldap/certs/openldapCA.crt && \
    chown -R 1001:root /opt/bitnami/openldap/certs && \
    chmod -R a+r /opt/bitnami/openldap/certs

# Copy our custom initialization script.
# Bitnami's entrypoint will automatically execute this at the right time.
COPY bin/99-custom-setup.sh /docker-entrypoint-initdb.d/99-custom-setup.sh
RUN chmod +x /docker-entrypoint-initdb.d/99-custom-setup.sh

# Revert to the default non-root user for the final image state
USER 1001

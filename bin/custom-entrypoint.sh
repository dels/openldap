#!/bin/bash
# /exec/custom-entrypoint.sh
set -e

# This script runs as root. Bitnami's entrypoint will handle permissions and the final privilege drop.

# Generate snakeoil TLS certificate if enabled and missing
if [ "${LDAP_ENABLE_TLS:-no}" = "yes" ]; then
    CERT_FILE="${LDAP_TLS_CERT_FILE:-/opt/bitnami/openldap/certs/openldap.crt}"
    KEY_FILE="${LDAP_TLS_KEY_FILE:-/opt/bitnami/openldap/certs/openldap.key}"
    CA_FILE="${LDAP_TLS_CA_FILE:-/opt/bitnami/openldap/certs/openldapCA.crt}"
    CERT_DIR=$(dirname "$CERT_FILE")
    mkdir -p "$CERT_DIR"

    if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
        echo "TLS enabled but certificates not found. Generating self-signed (snakeoil) certificates..."
        openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
            -subj "/CN=${LDAP_DOMAIN:-localhost}" \
            -keyout "$KEY_FILE" \
            -out "$CERT_FILE"
        cp "$CERT_FILE" "$CA_FILE"
        echo "Certificates generated successfully."
    fi
    # The slapd process runs as user 1001, so it needs to be able to read the certs.
    chown -R 1001:1001 "$CERT_DIR"
fi

# Map generic LDAP variables to Bitnami-specific variables
if [ -n "$LDAP_BASE_DN" ]; then export LDAP_ROOT="$LDAP_BASE_DN"; fi
if [ -n "$LDAP_DOMAIN" ] && [ -z "$LDAP_ROOT" ]; then export LDAP_ROOT=$(echo "$LDAP_DOMAIN" | sed 's/\./,dc=/g' | sed 's/^/dc=/'); fi
if [ -n "$LDAP_ADMIN_DN" ]; then
    EXTRACTED_USER=$(echo "$LDAP_ADMIN_DN" | sed -n 's/^cn=\([^,]*\).*$/\1/p')
    if [ -n "$EXTRACTED_USER" ]; then export LDAP_ADMIN_USERNAME="$EXTRACTED_USER"; fi
fi

# Create init script to set organization name
if [ -n "$LDAP_ORGANIZATION" ]; then
    # This script will be executed by Bitnami's entrypoint
    cat << EOF > /docker-entrypoint-initdb.d/99-set-org.sh
#!/bin/bash
. /opt/bitnami/scripts/libopenldap.sh
ldap_start_bg
ldapmodify -Y EXTERNAL -H ldapi:/// <<LDIF
dn: \${LDAP_ROOT}
changetype: modify
replace: o
o: ${LDAP_ORGANIZATION}
LDIF
ldap_stop
EOF
fi

# Prepare LDAP_ADMIN_PASSWORD for Bitnami's entrypoint if LDAP_ADMIN_PASSWORD_FILE is used
if [ -n "$LDAP_ADMIN_PASSWORD_FILE" ] && [ -f "$LDAP_ADMIN_PASSWORD_FILE" ]; then
    export LDAP_ADMIN_PASSWORD="$(cat "$LDAP_ADMIN_PASSWORD_FILE")"
fi

# Background task to check/update TLS config and password
(
    while ! ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config -s base >/dev/null 2>&1; do sleep 2; done
    
    if [ "${LDAP_ENABLE_TLS:-no}" = "yes" ]; then
        if ! ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config "(olcTLSCertificateFile=*)" | grep -q "olcTLSCertificateFile"; then
            ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
dn: cn=config
changetype: modify
add: olcTLSCACertificateFile
olcTLSCACertificateFile: ${LDAP_TLS_CA_FILE}
-
add: olcTLSCertificateFile
olcTLSCertificateFile: ${LDAP_TLS_CERT_FILE}
-
add: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: ${LDAP_TLS_KEY_FILE}
EOF
        fi
    fi

    if [ -n "$LDAP_ADMIN_PASSWORD_FILE" ] && [ -f "$LDAP_ADMIN_PASSWORD_FILE" ]; then
        DB_DN=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config "(olcRootDN=*)" dn -LLL | awk '/^dn: / {print $2}')
        ADMIN_DN=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config "(olcRootDN=*)" olcRootDN -LLL | awk -F': ' '/^olcRootDN: / {print $2}')
        if [ -n "$DB_DN" ] && [ -n "$ADMIN_DN" ]; then
            if ! ldapwhoami -x -D "$ADMIN_DN" -y "$LDAP_ADMIN_PASSWORD_FILE" -H ldapi:/// >/dev/null 2>&1; then
                NEW_HASH=$(slappasswd -h {SSHA} -y "$LDAP_ADMIN_PASSWORD_FILE")
                ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
dn: $DB_DN
changetype: modify
replace: olcRootPW
olcRootPW: $NEW_HASH
EOF
            fi
        fi
    fi
) &

exec /opt/bitnami/scripts/openldap/entrypoint.sh "$@"

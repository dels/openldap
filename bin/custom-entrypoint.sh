#!/bin/bash
# /exec/custom-entrypoint.sh
set -e

# This script now runs entirely as root.
# Bitnami's entrypoint will handle the final privilege drop for the slapd process.

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
        # The CA is self-signed in this case
        cp "$CERT_FILE" "$CA_FILE"
        echo "Certificates generated successfully at $CERT_DIR"
    fi
    # Ensure final ownership is correct for the slapd process
    chown -R 1001:1001 "$CERT_DIR"
fi

# Map generic LDAP variables to Bitnami-specific variables
if [ -n "$LDAP_BASE_DN" ]; then
    export LDAP_ROOT="$LDAP_BASE_DN"
fi

if [ -n "$LDAP_DOMAIN" ] && [ -z "$LDAP_ROOT" ]; then
    export LDAP_ROOT=$(echo "$LDAP_DOMAIN" | sed 's/\./,dc=/g' | sed 's/^/dc=/')
fi

if [ -n "$LDAP_ADMIN_DN" ]; then
    EXTRACTED_USER=$(echo "$LDAP_ADMIN_DN" | sed -n 's/^cn=\([^,]*\).*$/\1/p')
    if [ -n "$EXTRACTED_USER" ]; then
        export LDAP_ADMIN_USERNAME="$EXTRACTED_USER"
    fi
fi

# Create init script to set organization name
if [ -n "$LDAP_ORGANIZATION" ]; then
    cat << EOF > /docker-entrypoint-initdb.d/99-set-org.sh
#!/bin/bash
. /opt/bitnami/scripts/libopenldap.sh
ldap_start_bg
LDAPTLS_REQCERT=never ldapmodify -x -D "cn=\${LDAP_ADMIN_USERNAME:-admin},\${LDAP_ROOT:-dc=example,dc=org}" -y "\${LDAP_ADMIN_PASSWORD_FILE}" -H "ldaps://localhost:\${LDAP_LDAPS_PORT_NUMBER:-636}" <<LDIF
dn: \${LDAP_ROOT:-dc=example,dc=org}
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
        DB_DN=\$(ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config "(olcRootDN=*)" dn -LLL | grep ^dn: | head -n 1 | awk '{print \$2}')
        ADMIN_DN=\$(ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config "(olcRootDN=*)" olcRootDN -LLL | grep ^olcRootDN: | head -n 1 | awk -F": " '{print \$2}')
        if [ -n "$DB_DN" ] && [ -n "$ADMIN_DN" ]; then
            if ! ldapwhoami -x -D "$ADMIN_DN" -y "$LDAP_ADMIN_PASSWORD_FILE" -H ldapi:/// >/dev/null 2>&1; then
                NEW_HASH=\$(slappasswd -h {SSHA} -s "$(cat "$LDAP_ADMIN_PASSWORD_FILE")")
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

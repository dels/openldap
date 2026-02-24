#!/bin/bash
# /exec/custom-entrypoint.sh
set -e

# Map generic LDAP variables to Bitnami-specific variables
if [ -n "$LDAP_BASE_DN" ]; then
    export LDAP_ROOT="$LDAP_BASE_DN"
fi

if [ -n "$LDAP_DOMAIN" ] && [ -z "$LDAP_ROOT" ]; then
    # Convert "example.com" -> "dc=example,dc=com"
    export LDAP_ROOT=$(echo "$LDAP_DOMAIN" | sed 's/\./,dc=/g' | sed 's/^/dc=/')
fi

if [ -n "$LDAP_ADMIN_DN" ]; then
    # e.g., "cn=admin,dc=example,dc=com"
    # Bitnami uses LDAP_ADMIN_USERNAME to construct the 'cn' of the admin DN.
    # Extract the 'cn=' value
    EXTRACTED_USER=$(echo "$LDAP_ADMIN_DN" | sed -n 's/^cn=\([^,]*\).*$/\1/p')
    if [ -n "$EXTRACTED_USER" ]; then
        export LDAP_ADMIN_USERNAME="$EXTRACTED_USER"
    else
        echo "Warning: LDAP_ADMIN_DN should start with cn=. Using Bitnami default username."
    fi
fi

# Bitnami doesn't natively support setting the organization name via an environment variable.
# We create a script in /docker-entrypoint-initdb.d/ to set it if LDAP_ORGANIZATION is provided.
if [ -n "$LDAP_ORGANIZATION" ]; then
    cat << EOF > /docker-entrypoint-initdb.d/99-set-org.sh
#!/bin/bash
echo "Updating Organization to: ${LDAP_ORGANIZATION}"

# Load Bitnami's library to get access to start/stop functions
. /opt/bitnami/scripts/libopenldap.sh

# Start the LDAP server in the background
ldap_start_bg

# Execute ldapmodify to change the organization attribute using local socket authentication
ldapmodify -Y EXTERNAL -H "ldapi:///" <<LDIF
dn: ${LDAP_ROOT:-dc=example,dc=org}
changetype: modify
replace: o
o: ${LDAP_ORGANIZATION}
LDIF

if [ \$? -eq 0 ]; then
    echo "Organization successfully updated to ${LDAP_ORGANIZATION}"
else
    echo "Warning: Failed to update Organization to ${LDAP_ORGANIZATION}"
fi

# Stop the LDAP server again so Bitnami's initialization script can continue cleanly
ldap_stop
EOF
    chmod +x /docker-entrypoint-initdb.d/99-set-org.sh
fi

# Generate snakeoil TLS certificate if enabled and missing
if [ "${LDAP_ENABLE_TLS:-no}" = "yes" ]; then
    CERT_FILE="${LDAP_TLS_CERT_FILE:-/opt/bitnami/openldap/certs/openldap.crt}"
    KEY_FILE="${LDAP_TLS_KEY_FILE:-/opt/bitnami/openldap/certs/openldap.key}"
    CA_FILE="${LDAP_TLS_CA_FILE:-/opt/bitnami/openldap/certs/openldapCA.crt}"
    
    CERT_DIR=$(dirname "$CERT_FILE")
    mkdir -p "$CERT_DIR"

    if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then
        echo "TLS enabled but certificates not found. Generating self-signed (snakeoil) certificates..."
        # Generate CA
        openssl req -new -x509 -nodes -days 3650 -subj "/CN=LDAP-Local-CA" -keyout "$CA_FILE" -out "$CA_FILE"
        # Generate Server Cert
        openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
            -subj "/CN=${LDAP_DOMAIN:-localhost}" \
            -keyout "$KEY_FILE" \
            -out "$CERT_FILE"
        echo "Certificates generated successfully at $CERT_DIR"
    else
        echo "TLS certificates already exist at $CERT_DIR"
    fi
fi

# Background task to check and update the admin password on startup if it diverges
if [ -n "$LDAP_ADMIN_PASSWORD_FILE" ] && [ -f "$LDAP_ADMIN_PASSWORD_FILE" ]; then
    CURRENT_PASSWORD=$(cat "$LDAP_ADMIN_PASSWORD_FILE")
elif [ -n "$LDAP_ADMIN_PASSWORD" ]; then
    CURRENT_PASSWORD="$LDAP_ADMIN_PASSWORD"
fi

# Background task to check and update TLS configuration and admin password on startup if they diverge
(
    # Wait until ldap is ready on ldapi:///
    while ! ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config -s base >/dev/null 2>&1; do
        sleep 2
    done
    
    # Check and configure TLS if missing
    if [ "${LDAP_ENABLE_TLS:-no}" = "yes" ]; then
        CERT_FILE="${LDAP_TLS_CERT_FILE:-/opt/bitnami/openldap/certs/openldap.crt}"
        KEY_FILE="${LDAP_TLS_KEY_FILE:-/opt/bitnami/openldap/certs/openldap.key}"
        CA_FILE="${LDAP_TLS_CA_FILE:-/opt/bitnami/openldap/certs/openldapCA.crt}"
        
        # Check if TLS is already configured
        if ! ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config -s base "(olcTLSCertificateFile=*)" olcTLSCertificateFile | grep -q "^olcTLSCertificateFile:"; then
            echo "TLS enabled but not configured in database. Updating cn=config..."
            ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
dn: cn=config
changetype: modify
replace: olcTLSCACertificateFile
olcTLSCACertificateFile: $CA_FILE
-
replace: olcTLSCertificateFile
olcTLSCertificateFile: $CERT_FILE
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: $KEY_FILE
EOF
            echo "TLS configuration updated in database."
        fi
    fi

    if [ -n "$CURRENT_PASSWORD" ]; then
        # Extract the DB DN and Admin DN from the live configuration
        DB_DN=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config "(olcRootDN=*)" dn -LLL | grep ^dn: | head -n 1 | awk '{print $2}')
        ADMIN_DN=$(ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config "(olcRootDN=*)" olcRootDN -LLL | grep ^olcRootDN: | head -n 1 | awk -F": " '{print $2}')
        
        if [ -n "$DB_DN" ] && [ -n "$ADMIN_DN" ]; then
            # Check if the current environment password works against the server
            if ! ldapwhoami -x -D "$ADMIN_DN" -w "$CURRENT_PASSWORD" -H ldapi:/// >/dev/null 2>&1; then
                echo "Admin password changed. Updating database configuration..."
                NEW_HASH=$(slappasswd -h {SSHA} -s "$CURRENT_PASSWORD")
                ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
dn: $DB_DN
changetype: modify
replace: olcRootPW
olcRootPW: $NEW_HASH
EOF
                if [ $? -eq 0 ]; then
                    echo "Admin password successfully updated in database."
                else
                    echo "Warning: Failed to update admin password in database."
                fi
            fi
        fi
    fi
) &

# Execute Bitnami's entrypoint which handles the rest, passing all arguments
exec /opt/bitnami/scripts/openldap/entrypoint.sh "$@"

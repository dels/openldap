#!/bin/bash
# /docker-entrypoint-initdb.d/99-custom-setup.sh

# This script is executed by the official Bitnami entrypoint after the server
# is initially configured but before it's finalized.

# The Bitnami scripts have already started slapd in the background.
# We can now apply our custom configurations.

# Set Organization Name
if [ -n "$LDAP_ORGANIZATION" ]; then
    ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
dn: ${LDAP_ROOT}
changetype: modify
replace: o
o: ${LDAP_ORGANIZATION}
EOF
fi

# Inject a security rule to allow local, unencrypted admin access via the socket,
# while still requiring TLS for all network connections. This must be done
# *before* the main process starts and the background tasks kick off.
if [ "${LDAP_REQUIRE_TLS:-no}" = "yes" ]; then
    ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
dn: cn=config
changetype: modify
add: olcSecurity
olcSecurity: ssf=0
-
add: olcSecurity
olcSecurity: tls=1
EOF
fi

# Background task to check/update TLS config and password
# This will start after the container is fully up.
(
    # Give slapd a moment to apply the main config and restart.
    sleep 5
    
    # Ensure TLS is configured in the database if enabled
    if [ "${LDAP_ENABLE_TLS:-no}" = "yes" ]; then
        if ! ldapsearch -Y EXTERNAL -H ldapi:/// -b cn=config "(olcTLSCertificateFile=*)" | grep -q "olcTLSCertificateFile"; then
            ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
dn: cn=config
changetype: modify
add: olcTLSCACertificateFile
olcTLSCACertificateFile: ${LDAP_TLS_CA_FILE:-/opt/bitnami/openldap/certs/openldapCA.crt}
-
add: olcTLSCertificateFile
olcTLSCertificateFile: ${LDAP_TLS_CERT_FILE:-/opt/bitnami/openldap/certs/openldap.crt}
-
add: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: ${LDAP_TLS_KEY_FILE:-/opt/bitnami/openldap/certs/openldap.key}
EOF
        fi
    fi

    # Check if the admin password diverges and update if necessary
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

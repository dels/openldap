#!/bin/bash
# /docker-entrypoint-initdb.d/99-custom-setup.sh

# Load Bitnami OpenLDAP library so we can manage the daemon
. /opt/bitnami/scripts/libopenldap.sh

# Start the daemon in the background to apply custom configs
ldap_start_bg

# Create the root DN using the EXTERNAL mechanism, which has superuser privileges
DC_NAME=$(echo "$LDAP_ROOT" | awk -F'[,=]' '{print $2}')
ldapadd -Y EXTERNAL -H ldapi:/// <<EOF
dn: ${LDAP_ROOT}
objectClass: dcObject
objectClass: organization
dc: $DC_NAME
o: ${LDAP_ORGANIZATION:-$DC_NAME}
EOF

# Now, create the OUs as the admin user
ldapadd -x -H ldapi:/// -D "${LDAP_ADMIN_DN}" -y "$LDAP_ADMIN_PASSWORD_FILE" <<EOF
dn: ou=${LDAP_USER_OU:-users},${LDAP_ROOT}
objectClass: organizationalUnit
ou: ${LDAP_USER_OU:-users}

dn: ou=${LDAP_GROUP_OU:-groups},${LDAP_ROOT}
objectClass: organizationalUnit
ou: ${LDAP_GROUP_OU:-groups}
EOF


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

# Inject a security rule to require TLS for all network connections,
# but allow local unencrypted admin access via the socket.
ldapmodify -Y EXTERNAL -H ldapi:/// <<EOF
dn: cn=config
changetype: modify
replace: olcSecurity
olcSecurity: ssf=1
EOF

# Stop the daemon so the main entrypoint can resume safely
ldap_stop

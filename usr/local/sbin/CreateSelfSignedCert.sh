#!/bin/bash
################################################################
# (c) Copyright 2014 B-LUC Consulting and Thomas Bullinger
################################################################

#--------------------------------------------------------------------
# Set a sensible path for executables
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
PROG=${0##*/}

#--------------------------------------------------------------------
# Ensure that only one instance is running
LOCKFILE=/tmp/$PROG.lock
if [ -f $LOCKFILE ]
then
    # The file exists so read the PID
    MYPID=$(< $LOCKFILE)
    [ -z "$(ps h -p $MYPID)" ] || exit 0
fi

# Make sure we remove the lock file at exit
trap "rm -f $LOCKFILE /tmp/$$*" EXIT
echo "$$" > $LOCKFILE            

# Define the editor
if [ -z "$EDITOR" ]
then
    # Use a flavor of "vi"
    if [ -x /usr/bin/vim.tiny ]
    then
        M_EDITOR=vim.tiny
    else
        M_EDITOR=vi
    fi
else
    # Use the editor specified in the environment variable
    M_EDITOR=$EDITOR
fi

# Define some parameters for openssl cert
CN=$(hostname)
[[ $CN = *.* ]] || CN=$(hostname -f)
ORG=${CN#*.}
DURATION=$((5 * 366))

# Create a temporary directory for this process
TEMPDIR=$(mktemp -d)
cd $TEMPDIR

# Create a private key for the CA
echo '01' > serial
yes "" | openssl genrsa -out ca.key 2048 &> /dev/null

# Create CA signing request
sed -e "s/@TBD@/Technical Operations/" -e "s/@ORG@/$ORG/" -e "s/@CN@/$CN/" << EOT > .config
HOME                    = .
RANDFILE                = /dev/urandom
oid_section             = new_oids
[ new_oids ]
[ ca ]
[ CA_default ]
policy          = policy_match
[ policy_match ]
countryName             = match
stateOrProvinceName     = match
organizationName        = match
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional
[ policy_anything ]
countryName             = optional
stateOrProvinceName     = optional
localityName            = optional
organizationName        = optional
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional
[ req ]
default_bits            = 2048
default_keyfile         = privkey.pem
distinguished_name      = req_distinguished_name
attributes              = req_attributes
string_mask             = nombstr
[ req_distinguished_name ]
countryName                     = Country Name (2 letter code)
countryName_default             = US
countryName_min                 = 2
countryName_max                 = 2
stateOrProvinceName             = State or Province Name (full name)
stateOrProvinceName_default     = New York
localityName                    = Locality Name (eg, city)
localityName_default            = Rochester
0.organizationName              = Organization Name (eg, company)
0.organizationName_default      = @ORG@
organizationalUnitName          = Organizational Unit Name (eg, section)
# For an authority certificate use: Technical Operations
# For a server certificate use: External Support
organizationalUnitName_default  = @TBD@
commonName                      = Common Name (eg, YOUR name)
commonName_max                  = 64
commonName_default              = @CN@
emailAddress                    = Email Address
emailAddress_max                = 40
[ req_attributes ]
challengePassword               = A challenge password
challengePassword_min           = 4
challengePassword_max           = 20
unstructuredName                = An optional company name
[ usr_cert ]
basicConstraints=CA:FALSE
nsComment                       = "OpenSSL Generated Certificate"
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer:always
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
[ v3_ca ]
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always,issuer:always
basicConstraints = CA:true
[ crl_ext ]
authorityKeyIdentifier=keyid:always,issuer:always
EOT
$M_EDITOR .config
yes "" | openssl req -config .config -new -key ca.key -out ca.csr &> /dev/null

# Create X.509 certificate for CA signed by itself
cat <<EOT > .config
#extensions = x509v3
#[ x509v3 ]
#subjectAltName   = email:copy
#basicConstraints = CA:true,pathlen:0
#nsComment        = "Custom CA certificate"
#nsCertType       = sslCA
EOT
yes "" | openssl x509 -extfile .config -req -days $DURATION -signkey ca.key -in ca.csr -out ca.crt &> /dev/null

# Create private key for a server
yes "" | openssl genrsa -out server.key 2048 &> /dev/null

# Create server signing request
sed -e "s/@TBD@/External support/" -e "s/@ORG@/$ORG/" -e "s/@CN@/$CN/" << EOT > .config
HOME                    = .
RANDFILE                = /dev/urandom
oid_section             = new_oids
[ new_oids ]
[ ca ]
[ CA_default ]
policy          = policy_match
[ policy_match ]
countryName             = match
stateOrProvinceName     = match
organizationName        = match
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional
[ policy_anything ]
countryName             = optional
stateOrProvinceName     = optional
localityName            = optional
organizationName        = optional
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional
[ req ]
default_bits            = 2048
default_keyfile         = privkey.pem
distinguished_name      = req_distinguished_name
attributes              = req_attributes
string_mask             = nombstr
[ req_distinguished_name ]
countryName                     = Country Name (2 letter code)
countryName_default             = US
countryName_min                 = 2
countryName_max                 = 2
stateOrProvinceName             = State or Province Name (full name)
stateOrProvinceName_default     = New York
localityName                    = Locality Name (eg, city)
localityName_default            = Rochester
0.organizationName              = Organization Name (eg, company)
0.organizationName_default      = @ORG@
organizationalUnitName          = Organizational Unit Name (eg, section)
# For an authority certificate use: Technical Operations
# For a server certificate use: External Support
organizationalUnitName_default  = @TBD@
commonName                      = Common Name (eg, YOUR name)
commonName_max                  = 64
commonName_default              = @CN@
emailAddress                    = Email Address
emailAddress_max                = 40
[ req_attributes ]
challengePassword               = A challenge password
challengePassword_min           = 4
challengePassword_max           = 20
unstructuredName                = An optional company name
[ usr_cert ]
basicConstraints=CA:FALSE
nsComment                       = "OpenSSL Generated Certificate"
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer:always
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
[ v3_ca ]
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always,issuer:always
basicConstraints = CA:true
[ crl_ext ]
authorityKeyIdentifier=keyid:always,issuer:always
EOT
$M_EDITOR .config
yes "" | openssl req -config .config -new -key server.key -out server.csr &> /dev/null

# Create X.509 certificate for server signed by CA
cat <<EOT > .config
#extensions = x509v3
#[ x509v3 ]
#subjectAltName   = email:copy
#basicConstraints = CA:false,pathlen:0
#nsComment        = "Client certificate"
#nsCertType       = client
EOT
yes "" | openssl x509 -extfile .config -days $DURATION -CAserial serial -CA ca.crt -CAkey ca.key -in server.csr -req -out server.crt &> /dev/null

# Show the new cert
openssl x509 -in server.crt -noout -text

read -p 'Activate the new certificate [y/N] ? ' YN
if [ ! -z "$YN" -a "T${YN^^}" = 'TY' ]
then
    # Save the certificates and the key
    install -m 0400 -o root -g root server.key /etc/ssl/private/ssl-cert-snakeoil.key
    install -m 0644 -o root -g root server.crt /etc/ssl/certs/ssl-cert-snakeoil.pem
    #install -m 0600 -o root -g root ca.crt /etc/ssl/certs/mdf_ca.crt
fi
rm -rf $TEMPDIR

# We are done
exit 0

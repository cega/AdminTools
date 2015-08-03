#!/bin/bash
################################################################
# (c) Copyright 2015 B-LUC Consulting and Thomas Bullinger
#
# Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
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

#--------------------------------------------------------------------
# Specifying "-x" to the bash invocation = DEBUG
DEBUG=''
[[ $- = *x* ]] && DEBUG='-x'

#--------------------------------------------------------------------
# This host and domain
THISHOST=$(hostname)
[[ $THISHOST = *.* ]] || THISHOST=$(hostname -f)
THISDOMAIN=${THISHOST#*.}

#--------------------------------------------------------------------
# Install stunnel4 package
apt-get install stunnel4

#--------------------------------------------------------------------
read -p 'Is this a stunnel server [y/n] ? ' SC
if [ "T${SC^^}" = 'TY' ]
then
    # Create the SSL cert (valid for 3 years)
    if [ ! -s /etc/stunnel/stunnel.pem ]
    then
        openssl genrsa -out key.pem 2048
        openssl req -new -x509 -key key.pem -out cert.pem -days 1095
        cat key.pem cert.pem >> /etc/stunnel/stunnel.pem
    fi

    # Adapt the config file
    cat << EOT >> /etc/stunnel/stunnel.conf
client = no
[ldap]
accept = 8389
connect = 127.0.0.1:389
EOT
elif [ "T${SC^^}" = 'TN' ]
then
    if [ ! -s /etc/stunnel/stunnel.pem ]
    then
        echo "Please copy the file '/etc/stunnel/stunnel.pem' from the stunnel server"
        sleep 5
    fi

    # Adapt the config file
    read -p 'IP address of stunnel server: ' SSERVER
    cat << EOT >> /etc/stunnel/stunnel.conf
client = yes
[ldap]
connect = ${SSERVER}:8389
accept = 389
EOT
else
    echo "Please restart this script and say 'Y' or 'N'"
    exit 1
fi

if [ -z "$(grep pem /etc/stunnel/stunnel.pem 2>/dev/null)" ]
then
   echo 'cert = /etc/stunnel/stunnel.pem' >> /etc/stunnel/stunnel.conf
else
    sed -i 's/^cert.*/cert = \/etc\/stunnel\/stunnel.pem/' /etc/stunnel/stunnel.conf
fi
vi /etc/stunnel/stunnel.conf

#--------------------------------------------------------------------
# Enable and restart stunnel4
sed -i 's/^ENABLED.*/ENABLED=1/' /etc/default/stunnel4
service stunnel4 restart

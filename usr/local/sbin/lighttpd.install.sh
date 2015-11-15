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
# Setup lighttpd PLUS PHP
# See https://wiki.ubuntu.com/Lighttpd+PHP
apt-get install lighttpd php5-cgi
lighty-enable-mod fastcgi
lighty-enable-mod fastcgi-php

#--------------------------------------------------------------------
# Setup SSL - create the (self-signed) SSL cert first
openssl req -new -x509 -keyout /etc/lighttpd/server.pem -out /etc/lighttpd/server.pem \
  -days $((365 * 3)) -nodes -newkey rsa:2048

# See https://raymii.org/s/tutorials/Strong_SSL_Security_On_lighttpd.html
cat << EOT > /etc/lighttpd/conf-enabled/10-ssl.conf
# /usr/share/doc/lighttpd/ssl.txt
# See also https://raymii.org/s/tutorials/Strong_SSL_Security_On_lighttpd.html

$SERVER["socket"] == "0.0.0.0:443" {
        ssl.engine  = "enable"
        ssl.pemfile = "/etc/lighttpd/server.pem"

        ssl.cipher-list = "EECDH+AESGCM:EDH+AESGCM:AES128+EECDH:AES128+EDH"
        ssl.honor-cipher-order = "enable"

        # Disable weak protocols
        ssl.use-sslv2 = "disable"
        ssl.use-sslv3 = "disable"

        # Protect against CRIME attack
        ssl.use-compression = "disable"

        # Protect against LogJam
        ssl.dh-file = "/etc/lighttpd/dhparam.pem"
        ssl.ec-curve = "secp384r1"
}
EOT
# This takes quite some time:
openssl dhparam -out /etc/lighttpd/dhparam.pem 4096
lighty-enable-mod ssl

#--------------------------------------------------------------------
# Restart lighttpd to activate changes
service lighttpd restart

#--------------------------------------------------------------------
# We are done
exit 0

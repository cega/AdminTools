#!/bin/bash
################################################################
# (c) Copyright 2016 B-LUC Consulting and Thomas Bullinger
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
# Based on: https://easyengine.io/tutorials/mail/dkim-postfix-ubuntu/

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
DEBUG='-q'
[[ $- = *x* ]] && DEBUG='-v'

#--------------------------------------------------------------------
# This host and domain
THISHOST=$(hostname)
[[ $THISHOST = *.* ]] || THISHOST=$(hostname -f)
THISDOMAIN=${THISHOST#*.}

read -p "Domain to use DKIM for [default='$THISDOMAIN'] ? " D
if [ -z "$D" ]
then
    DOMAIN=$THISDOMAIN
else
    DOMAIN="$D"
fi

# The current date and time
NOW=$(date "+%F %T")

#--------------------------------------------------------------------
# Install the necessary packages
apt-get install opendkim opendkim-tools

if [ -z "$(grep ^Domain /etc/opendkim.conf)" ]
then
    # Specify the domain to use dkim for
    cat << EOT >> /etc/opendkim.conf
## $NOW
Domain                  $DOMAIN
KeyFile                 /etc/postfix/dkim.key
Selector                mail
SOCKET                  inet:8891@localhost
EOT
fi

#--------------------------------------------------------------------
if [ -z "$(grep ^SOCKET /etc/default/opendkim)" ]
then
    # Make sure that we listen on the correct socket
    cat << EOT >> /etc/default/opendkim
## $NOW
SOCKET="inet:8891@127.0.0.1"
EOT
fi

#--------------------------------------------------------------------
if [ ! -s /etc/postfix/dkim.key ]
then
    # Create the correct keys
    cd /tmp
    opendkim-genkey -t -s mail -d $DOMAIN
    cp mail.private /etc/postfix/dkim.key

    echo "Copy the following into your domain's DNS:"
    cat mail.txt
fi

#--------------------------------------------------------------------
# Enable dkim-milter in postfix
postconf -e 'milter_default_action = accept'
postconf -e 'milter_protocol = 2'
postconf -e 'smtpd_milters = inet:127.0.0.1:8891'
postconf -e 'non_smtpd_milters = inet:127.0.0.1:8891'

#--------------------------------------------------------------------
# Restart the affected services
service opendkim restart
service postfix restart

#--------------------------------------------------------------------
# We are done
exit 0

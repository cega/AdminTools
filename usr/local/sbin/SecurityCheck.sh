#!/bin/bash
###############################################################
# (c) Copyright 2014 B-LUC Consulting and Thomas Bullinger
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

# We need to be "root" to execute this script
if [ $EUID -ne 0 ]
then
    echo "You need to be 'root' to execute this script"
    exit 1
fi

#--------------------------------------------------------------------
# LYNIS

# Check whether lynis is installed
LYNIS=$(which lynis)
if [ $? -eq 0 ]
then
    # Check the installed version of lynis
    CURRENT=$($LYNIS --check-update | grep 'Up-to-date')
else
     if [ ! -x /usr/local/sbin/lynis.install.sh ]
     then
         # Download the install script
         wget -q --no-check-certificate -O /usr/local/sbin/lynis.install.sh \
           'https://raw.githubusercontent.com/B-LUC/AdminTools/master/usr/local/sbin/lynis.install.sh'
         if [ $? -ne 0 ]
         then
              cat << EOT
ERROR: Couldn't download lynis installation script!

Please download 'https://raw.githubusercontent.com/B-LUC/AdminTools/master/usr/local/sbin/lynis.install.sh'
into /usr/local/sbin and execute it.
EOT
              exit 1
         fi
         chmod 744 /usr/local/sbin/lynis.install.sh
         CURRENT=''
     fi
fi

if [ -z "$CURRENT" ]
then
    # Install/update lynis
    /usr/local/sbin/lynis.install.sh
    LYNIS=$(which lynis)
    if [ -z "$LYNIS" ]
    then
        echo "'lynis' didn't install"
    fi
fi

if [ ! -z "$LYNIS" ]
then
    # Adapt the profile and run the test
    sed -e 's/# plugin/plugin/' /usr/local/etc/lynis/default.prf > /tmp/LocalVA.prf
    $LYNIS --profile /tmp/LocalVA.prf --cronjob &> /dev/null
    if [ $? -eq 0 ]
    then
        if [ -s /var/log/lynis.log ]
        then
            echo '==> Overall hardening strength <=='
            awk '/Hardening strength/ {$1="";$2="";$3="";print}' /var/log/lynis.log
        fi
        if [ -s /var/log/lynis-report.dat ]
        then
            if [ $(grep -c '^warning' /var/log/lynis-report.dat) -ne 0 ]
            then
                echo '==> WARNINGS <=='
                awk -F\| '/^warning/ {$1="";print}' /var/log/lynis-report.dat
            fi
            if [ $(grep -c '^suggestion' /var/log/lynis-report.dat) -ne 0 ]
            then
                echo '==> Suggestions <=='
                awk -F\| '/^suggestion/ {$1="";print}' /var/log/lynis-report.dat
            fi
        fi
    else
        echo "'lynis' didn't run successfully"
    fi
fi
    
#--------------------------------------------------------------------
# CHKROOTKIT

# Check whether "chkrootkit" is installed
CKR=$(which chkrootkit)
if [ $? -ne 0 ]
then
    apt-get -y install chkrootkit
    if [ $? -ne 0 ]
    then
        cat << EOT
ERROR: Couldn't install chkrootkit!

Please run (as root): apt-get install chkrootkit
EOT
        exit 1
    fi
fi

chkrootkit -q -n &> /tmp/$$
egrep -v '(init INFECTED|dhclient|p0f)' /tmp/$$ > /tmp/$$.report
echo '==> ROOTKIT report <=='
if [ -s /tmp/$$.report ]
then
    sed -e 's/^/ /' /tmp/$$.report
else
    echo ' clean'
fi

# We are done
exit 0

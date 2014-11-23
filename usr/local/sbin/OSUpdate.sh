#!/bin/bash
################################################################
# (c) Copyright 2013 B-LUC Consulting and Thomas Bullinger
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

DEBUG=0
[[ $- = *x* ]] && DEBUG=1
trap "rm -f /tmp/$$" EXIT

THISHOST=$(hostname)
[[ $THISHOST = *.* ]] || THISHOST=$(hostname -f)
THISDOMAIN=$(hostname -d)
NOW="$(date -R)"

FORCE=0
while getopts hf OPTION
do
    case ${OPTION} in
    h)  echo "Usage: $PROG [h|f]"
        echo "       -f   Force update [default=simulate]"
        echo "       -h   This help"
        exit 0
        ;;
    f)  FORCE=1
        ;;
    esac
done
shift $((OPTIND - 1))

#==============================================================================
# Update the packages
echo "$NOW: Results of 'apt-get update'" > /tmp/$$
apt-get update >> /tmp/$$ 2> /dev/null
if [ $? -ne 0 ]
then
    # We had a problem updating
    cat /tmp/$$
    exit 1
fi

# Remove any package via "autoremove"
echo "$NOW: Results of 'apt-get autoremove'" > /tmp/$$
apt-get autoremove >> /tmp/$$ 2> /dev/null
if [ $? -ne 0 ]
then
    # We had a problem "autoremoving"
    cat /tmp/$$
    exit 1
fi

# Remove any leftover packages in "rc" state
echo "$NOW: Results of 'dpkg -P'" > /tmp/$$
dpkg -l | awk '/^rc/ {print $2}' | xargs -r dpkg -P  >> /tmp/$$ 2> /dev/null
if [ $? -ne 0 ]
then
    # We had a problem removing leftover packages
    cat /tmp/$$
    exit 1
fi

# This MUST be interactive!
[ $FORCE -ne 0 ] && apt-get dist-upgrade

# Simulate a full upgrade
apt-get -s dist-upgrade > /var/log/DistUpgradeList 2> /dev/null
if [ $? -ne 0 ]
then
    # We had a problem updating
    echo 'Could not create a list of package that need to be updated'
    exit 1
fi

# Extract the list of upgraded and new packages
NUP=$(awk '/upgraded, .* newly/ {print $1+$3}' /var/log/DistUpgradeList)
if [ $NUP -gt 25 ]
then
    # New and upgraded packages exceed a combined 25
    sendemail -q -f root@$THISHOST -u "Outdated packages on $THISHOST" \
        -t root@$THISDOMAIN -s mail -o tls=no << EOT
$NUP new or upgradable packages on $THISHOST
See /var/log/DistUpgradeList for details

To install the newer versions, type (as root):
apt-get autoremove; apt-get update; apt-get upgrade

If a new kernel gets installed, the system will reboot anytime
before 6:00am.
EOT
fi

if [ $DEBUG -ne 0 ]
then
    cat /tmp/$$
    echo 'List of packages that can be upgraded:'
    cat /var/log/DistUpgradeList
fi

#==============================================================================
# Reboot the server if needed (but only before 6am)
if [ $(date +%-H) -lt 6 ]
then
    # Get the running and newest installed kernels
    CURRENT_KERNEL=$(uname -r)
    NEWEST_KERNEL=$(ls -t1 /boot/vmlinuz* | head -n 1)
    logger -i -p info -t kernel -- Checking kernel versions

    if [[ ! $NEWEST_KERNEL =~ $CURRENT_KERNEL ]]
    then
        echo 'Rebooting to activate newest kernel'
        logger -i -p crit -t kernel -- Rebooting to activate newest kernel
        shutdown -r +2 'Rebooting to activate newest kernel'
    elif [ -s /var/log/dmesg ]
    then
        if [ $NEWEST_KERNEL -nt /var/log/dmesg ]
        then
            echo 'Rebooting to activate newer kernel'
            logger -i -p crit -t kernel -- Rebooting to activate newer kernel
            shutdown -r +2 'Rebooting to activate newer kernel'
        fi
    fi
fi

#==============================================================================
# We are done
exit 0

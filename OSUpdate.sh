#!/bin/bash
################################################################
# (c) Copyright 2013 B-LUC Consulting and Thomas Bullinger
################################################################

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# This must run as "root"
[ "T$EUID" = 'T0' ] || exit

DEBUG=0
[[ $- = *x* ]] && DEBUG=1
trap "rm -f /tmp/$$" EXIT

THISHOST=$(hostname)
[[ $THISHOST = *.* ]] || THISHOST=$(hostname -f)
THISDOMAIN=$(hostname -d)
NOW="$(date -R)"

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
    sendmail -t << EOT
Subject: Outdated packages on $THISHOST
From: root@THISDOMAIN
To: root@$THISDOMAIN
Date: $NOW
Importance: Medium
X-Priority: Medium
X-Alert-Priority: Medium
X-Alert-Host: $THISHOST

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

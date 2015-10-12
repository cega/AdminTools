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

# Current hour and minute
set $(date '+%-H %-M')
HR_NOW=$1
MIN_NOW=$2

if [ $MIN_NOW -eq 27 ]
then
    # Set real-world based TCP receive window sizes
    DEF_GW=$(route -n | awk '/^0.0.0.0/ {print $2}')
    LAN_SETTINGS=$(ping -q -s 1400 -c 6 $DEF_GW | \
      awk -F/ '/^rtt/{print int(1000000 * $5 / 8)}')
    if [ -z "$LAN_SETTINGS" ]
    then
        LAN_SETTINGS=$((256 * 1024))
    elif [ $LAN_SETTINGS -lt 1 ]
    then
        LAN_SETTINGS=$((256 * 1024))
    fi
    WAN_SETTINGS=$(ping -q -s 1400 -c 6 www.google.com | \
      awk -F/ '/^rtt/{print int(1000000 * $5 / 8)}')
    if [ -z "$WAN_SETTINGS" ]
    then
        WAN_SETTINGS=$((8 * 1024 * 1024))
    elif [ $WAN_SETTINGS -lt 1 ]
    then
        WAN_SETTINGS=$((8 * 1024 * 1024))
    fi

    # Allow for twice the buffer space
    DEF_RMEM=$(($(($LAN_SETTINGS / 1024 + 1)) * 2048))
    MAX_RMEM=$(($(($WAN_SETTINGS / 1024 + 1)) * 2048))
    sysctl -q -w "net.ipv4.tcp_rmem=8192 $DEF_RMEM $MAX_RMEM"
    sysctl -q -w "net.core.rmem_max=$MAX_RMEM"
    sysctl -q -w "net.core.rmem_default=$DEF_RMEM"
fi

# We are done
exit 0

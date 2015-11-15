#!/bin/bash
#--------------------------------------------------------------------
# (c) CopyRight 2015 B-LUC Consulting and Thomas Bullinger
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

ETH=${1-eth0}
if [ ! -s /sys/class/net/$ETH/statistics/rx_dropped ]
then
    echo "ERROR: Ethernet interface '$ETH' does not exist"
    exit 1
fi
D=$(< /sys/class/net/$ETH/statistics/rx_dropped)
T=$(< /sys/class/net/$ETH/statistics/rx_packets)

# Use awk to do the calculations and display
awk -v dropped=$D -v total=$T -v ETH=$ETH '
BEGIN {
 printf "%s dropped packets: %3.2f%%\n", ETH, dropped / total * 100
 exit
}'

#--------------------------------------------------------------------
# We are done
exit 0

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

#--------------------------------------------------------------------
# Specifying "-x" to the bash invocation = DEBUG
DEBUG=''
[[ $- = *x* ]] && DEBUG='-x'

#--------------------------------------------------------------------
# This host and domain
THISHOST=$(hostname)
[[ $THISHOST = *.* ]] || THISHOST=$(hostname -f)
THISDOMAIN=${THISHOST#*.}

# Current hour and minute
set $(date '+%-H %-M')
HR_NOW=$1
MIN_NOW=$2

#--------------------------------------------------------------------
if [ $(($MIN_NOW % 5)) -eq 2 ]
then
    if [ -d /etc/update-motd.d ]
    then
        # Disable MOST of the motd updater
        cd /etc/update-motd.d
        chmod -x *
        chmod +x 99-footer
        [ -x /usr/bin/linux_logo ] && linux_logo -ys -L 26 > /etc/motd.tail
    fi
elif [ ! -f /etc/motd.tail ]
then
    [ -x /usr/bin/linux_logo ] && linux_logo -ys -L 26 > /etc/motd.tail
fi

#--------------------------------------------------------------------
# Actions to be done all the time

# Once an hour sync time
[ $MIN_NOW -eq 3 ] && ntpdate -us 0.debian.pool.ntp.org 1.debian.pool.ntp.org 2.debian.pool.ntp.org 3.debian.pool.ntp.org

# Apply sysctl changes if not yet done
if [ -s /etc/sysctl.d/90-bluc.conf ]
then
    [ $(sysctl -n kernel.sched_min_granularity_ns) -ne 10000000  ] && sysctl -q -p /etc/sysctl.d/90-bluc.conf
fi

#--------------------------------------------------------------------
# We are done
exit 0

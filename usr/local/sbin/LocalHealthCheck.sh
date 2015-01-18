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
# Once a day:
if [ "T$HR_NOW:$MIN_NOW" = 'T 3:33' ]
then
    # Update the GEOIP databases for iptables
    # Requires: libtext-csv-perl unzip
    XTP=/usr/lib/xtables-addons
    if [ -d $XTP ]
    then
        mkdir -p /usr/share/xt_geoip
        cd /tmp
        sed -i -e 's/gzip -d/gzip -fd/' $XTP/xt_geoip_dl
        [ -x $XTP/xt_geoip_dl ] && $XTP/xt_geoip_dl &> /dev/null
        [ -x $XTP/xt_geoip_build ] && $XTP/xt_geoip_build -D /usr/share/xt_geoip GeoIP*.csv &> /dev/null
    fi
fi

#--------------------------------------------------------------------
# Every five minutes:
if [ $(($MIN_NOW % 5)) -eq 2 ]
then
    if [ -d /etc/update-motd.d ]
    then
        # Disable MOST of the motd updater
        cd /etc/update-motd.d
        chmod -x *
        [ -s 99-footer ] && chmod +x 99-footer
        [ -x /usr/bin/linux_logo ] && linux_logo -ys -L 27 > /etc/motd.tail
    fi
elif [ ! -f /etc/motd.tail ]
then
    [ -x /usr/bin/linux_logo ] && linux_logo -ys -L 27 > /etc/motd.tail
fi

#--------------------------------------------------------------------
# Actions done once an hour
if [ $MIN_NOW -eq 3 ]
then
    # Sync time
    ntpdate -us 0.debian.pool.ntp.org 1.debian.pool.ntp.org 2.debian.pool.ntp.org 3.debian.pool.ntp.org

    # Is this a virtual guest?
    IS_VIRTUAL=0
    if [ ! -z "$(grep '^flags[[:space:]]*.*hypervisor' /proc/cpuinfo)" ]
    then
        IS_VIRTUAL=1
    elif [ ! -z "$(grep -m1 VMware /proc/scsi/scsi)" ]
    then
        IS_VIRTUAL=2
    elif [ ! -z "$(grep QEMU /proc/cpuinfo)" -a ! -z "$(grep Bochs /sys/class/dmi/id/bios_vendor)" ]
    then
        IS_VIRTUAL=3
    fi

    if [ $IS_VIRTUAL -ne 0 ]
    then
        # Disable some kernel modules at runtime
        cat << EOT > /tmp/$$
# See http://www.linux.com/community/forums/debian/disable-ipv6-in-debian-lenny
blacklist ipv6
# See http://linuxpoison.blogspot.com/2009/06/how-to-disable-loading-of-unnecessary.html
blacklist floppy
blacklist ppdev 
blacklist lp    
blacklist parport_pc
blacklist parport   
blacklist serio_raw 
blacklist psmouse   
blacklist pcspkr    
blacklist snd_pcm   
blacklist snd_timer 
blacklist snd
blacklist soundcore
blacklist snd_page_alloc
EOT
        diff /etc/modprobe.d/blacklist.local /tmp/$$ &> /dev/null
        if [ $? -ne 0 ]
        then
            cat /tmp/$$ > /etc/modprobe.d/blacklist.local
            for M in $(awk '/^blacklist/ {print $NF}' /etc/modprobe.d/blacklist.local)
            do
                modprobe -r $M &> /dev/null
            done
        fi
        rm -f /tmp/$$
    fi
fi

#--------------------------------------------------------------------
# Actions to be done all the time

# Apply sysctl changes if not yet done
if [ -s /etc/sysctl.d/90-bluc.conf ]
then
    [ $(sysctl -n kernel.sched_min_granularity_ns) -ne 10000000  ] && sysctl -q -p /etc/sysctl.d/90-bluc.conf
fi

#--------------------------------------------------------------------
# We are done
exit 0

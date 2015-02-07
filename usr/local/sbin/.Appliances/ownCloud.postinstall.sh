#!/bin/bash
################################################################
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

#--------------------------------------------------------------------
# Specifying "-x" to the bash invocation = DEBUG
DEBUG=''
[[ $- = *x* ]] && DEBUG='-x'

#--------------------------------------------------------------------
# This host and domain
THISHOST=$(hostname)
[[ $THISHOST = *.* ]] || THISHOST=$(hostname -f)
THISDOMAIN=${THISHOST#*.}

# Function to convert netmasks into CIDR notation and back
# See: https://forums.gentoo.org/viewtopic-t-888736-start-0.html
function mask2cdr ()
{
   # Assumes there's no "255." after a non-255 byte in the mask
   local x=${1##*255.}
   set -- 0^^^128^192^224^240^248^252^254^ $(( (${#1} - ${#x})*2 )) ${x%%.*}
   x=${1%%$3*}
   echo $(( $2 + (${#x}/4) ))
}
function cdr2mask ()
{
   # Number of args to shift, 255..255, first non-255 byte, zeroes
   set -- $(( 5 - ($1 / 8) )) 255 255 255 255 $(( (255 << (8 - ($1 % 8))) & 255 )) 0 0 0
   [ $1 -gt 1 ] && shift $1 || shift
   echo ${1-0}.${2-0}.${3-0}.${4-0}
}

#--------------------------------------------------------------------
# Determine the Linux distribution
LINUX_DIST=''
INSTALL_PROG=''
if [ -s /etc/debian_version ]
then
    LINUX_DIST='DEBIAN'
    INSTALL_PROG='apt-get'
elif [ -s /etc/redhat-release ]
then
    LINUX_DIST='REDHAT'
    INSTALL_PROG='yum'

    # Install the necessary redhat packages
    $INSTALL_PROG list > /tmp/redhat.packages.list
    SRV_ARCH=$(uname -i)
    if [ -z "$(grep '^rpmforge-release.'$SRV_ARCH /tmp/redhat.packages.list)" ]
    then
        # Get "rpmforge" repository and install it
        curl -L 'http://pkgs.repoforge.org/rpmforge-release/rpmforge-release-0.5.3-1.el6.rf.x86_64.rpm' \
            > /tmp/rpmforge-release-0.5.3-1.el6.rf.x86_64.rpm	
        rpm --import http://apt.sw.be/RPM-GPG-KEY.dag.txt
        $INSTALL_PROG install /tmp/rpmforge-release-0.5.3-1.el6.rf.x86_64.rpm
        # Reget the list of install packages
        $INSTALL_PROG list > /tmp/redhat.packages.list
    fi
else
    echo "Unsupported Linux distribution"
    exit 1
fi

# Is this a virtual guest?
#IS_VIRTUAL=0
#if [ ! -z "$(grep -m1 VMware /proc/scsi/scsi)" ]
#then
#    IS_VIRTUAL=1
#elif [ ! -z "$(grep QEMU /proc/cpuinfo)" -a ! -z "$(grep Bochs /sys/class/dmi/id/bios_vendor)" ]
#then
#    IS_VIRTUAL=2
#elif [ ! -z "$(grep '^flags[[:space:]]*.*hypervisor' /proc/cpuinfo)" ]
#then
#    IS_VIRTUAL=3
#fi

#--------------------------------------------------------------------
if [ "T$LINUX_DIST" = 'TDEBIAN' ]
then
    # See https://www.howtoforge.com/how-to-install-owncloud-7-on-ubuntu-14.04

    # Install the database server
    $INSTALL_PROG install mariadb-server

    # Configure the ownCloud database access (if necessary)
    HAVE_DB=0
    mysql -AB owncloud -e 'exit' &> /dev/null
    if [ $? -ne 0 ]
    then
        OC_PASSWD=$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-16})
        mysql mysql << EOT
CREATE DATABASE IF NOT EXISTS owncloud;
GRANT ALL ON owncloud.* to 'owncloud'@'localhost' IDENTIFIED BY '$OC_PASSWD';
EOT
        HAVE_DB=1
    fi

    # Install the ownCloud packages
    wget -q http://download.opensuse.org/repositories/isv:ownCloud:community/xUbuntu_14.04/Release.key -O - | \
      apt-key add -
    source /etc/lsb-release
    echo "deb http://download.opensuse.org/repositories/isv:/ownCloud:/community/x${DISTRIB_ID}_${DISTRIB_RELEASE}/ /" > /etc/apt/sources.list.d/owncloud.list
    $INSTALL_PROG install owncloud
fi

# Update and upgrade
$INSTALL_PROG update
if [ "T$LINUX_DIST" = 'TDEBIAN' ]
then
    $INSTALL_PROG autoremove
    $INSTALL_PROG dist-upgrade
fi

# Enhance the web server security
cat << EOT > /etc/apache2/conf-enabled/security2.conf
ServerTokens Prod
ServerSignature Off
EOT
service apache2 restart

# Give instructions for the next step
if [ $HAVE_DB -eq 0 ]
then
    LOCALIP=$(ifconfig eth0 | sed -n "s/.*inet addr:\([0-9.]*\).*/\1/p")
    cat << EOT
Once this installation step is done, point your browser to
http://${LOCALIP}/owncloud

Select "MySQL/MariaDB" under "Storage & database" and use these credentials:
username: owncloud
password: $OC_PASSWD

Create a new administrative account

In the lower tab below "MySQL/MariaDB" input:
username=owncloud
password=$OC_PASSWD
databasename=owncloud
EOT
fi

# We are done
exit 0

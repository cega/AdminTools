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

#--------------------------------------------------------------------
# Install some pre-requisites
apt-get install libavahi-core7 avahi-daemon avahi-utils

# Extract the download link for the Ubuntu package
# Eg.: plexmediaserver_0.9.15.2.1663-7efd046_amd64.deb
wget -q -O /tmp/$$ https://plex.tv/downloads
PLEX_LINK=$(awk -F\" '/Ubuntu..64-bit/ {print $2}' /tmp/$$)

#--------------------------------------------------------------------
# Download the package
rm -f /tmp/$$
wget -q -O /tmp/$$ $PLEX_LINK
if [ -s /tmp/$$ ]
then
    cmp /tmp/$$ /usr/local/src/plexmediaserver_amd64.deb &> /dev/null
    [ $? -ne 0 ] && mv /tmp/$$ /usr/local/src/plexmediaserver_amd64.deb
fi

# And install it
[ -s /usr/local/src/plexmediaserver_amd64.deb ] && dpkg -i /usr/local/src/plexmediaserver_amd64.deb

#--------------------------------------------------------------------
# Get the Discover Channel plugin
wget -q -O /tmp/$$ https://github.com/meriko/Discovery.bundle/archive/master.zip
cd /tmp
unzip -o $$
PLEX_HOME=$(getent passwd plex | cut -d: -f6)
mv Discovery.bundle-master $PLEX_HOME/Library/Application\ Support/Plex\ Media\ Server/Plug-ins/Discover.bundle
chown -R plex: $PLEX_HOME/Library/Application\ Support/Plex\ Media\ Server/Plug-ins/Discover.bundle
service plexmediaserver restart

#--------------------------------------------------------------------
# We are done
exit 0


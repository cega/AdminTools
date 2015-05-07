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

# Set the correct path for commands
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Get the currenty active kernel
CURKV=$(uname -r)
echo "Currently active kernel version: $CURKV"

if [ $EUID -ne 0 ]
then
    echo 'You must be root to continue'
    exit 0
fi

# Ask the user whether to remove/purge other kernel versions
# Remove temp files at exit
trap "rm -f /tmp/$$" EXIT

# Get list of installed kernels
dpkg-query --show 'linux-image-?.*.*' > /tmp/$$
dpkg-query --show 'pve-kernel-*' >> /tmp/$$
[ -s /tmp/$$ ] || exit 0

# Ask the user whether to remove/purge other kernel versions
for OK in $(awk '{print $1}' /tmp/$$ | grep -v "$CURKV")
do
    OKS=$(dpkg-query --show --showformat='${Status}\n' $OK)
    echo "Kernel '$OK' status: $OKS"
    [[ $OKS = *not-installed* ]] && continue

    read -p "Leave/remove/purge old kernel $OK [L/r/p] ?" ROK
    [ -z "$ROK" ] && continue
    if [ "T${ROK^^}" = 'TP' ]
    then
        apt-get --purge remove ${OK}*
    elif [ "T${ROK^^}" = 'TR' ]
    then
        apt-get remove ${OK}*
    fi
done

# Remove any old kernel headers
# Based on http://ubuntugenius.wordpress.com/2011/01/08/ubuntu-cleanup-how-to-remove-all-unused-linux-kernel-headers-images-and-modules/
read -p "Leave/purge old kernel header files [L/p] ?" ROK
if [ "T${ROK^^}" = 'TP' ]
then
    dpkg -l 'linux-*' | \
      sed '/^ii/!d;/'"$(uname -r | sed "s/\(.*\)-\([^0-9]\+\)/\1/")"'/d;s/^[^ ]* [^ ]* \([^ ]*\).*/\1/;/[0-9]/!d' | \
      grep headers | xargs -r apt-get -y purge
fi

# We are done
exit 0

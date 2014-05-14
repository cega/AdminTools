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
for OK in $(dpkg-query --show  'linux-image-?.*.*' | awk '{print $1}' | grep -v "$CURKV")
do
    OKS=$(dpkg-query --show --showformat='${Status}\n' $OK)
    echo "Kernel '$OK' status: $OKS"
    [[ $OKS = *not-installed* ]] && continue

    read -p "Remove/Purge/Leave old kernel $OK [R/P/L] ?" ROK
    [ -z "$ROK" ] && continue
    if [ "T${ROK^^}" = 'TP' ]
    then
        dpkg -P $OK
    elif [ "T${ROK^^}" = 'TR' ]
    then
        dpkg -r $OK
    fi
done

# We are done
exit 0

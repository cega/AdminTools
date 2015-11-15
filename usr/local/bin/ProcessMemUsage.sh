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

# Get all running processes (filter by argument if present)
ps -eo pid,user,comm | grep "$1" | while read P_PID P_USER P_CMD
do
    # Get the total and detailed memory stats
    P_TOTAL=$(pmap $P_PID 2> /dev/null | grep total)
    P_DETAIL=" "$(pmap -d $P_PID 2> /dev/null | grep mapped)

    # Show what we found
    cat << EOT
$P_PID ($P_CMD) run by '$P_USER' memory usage:
$P_TOTAL $P_DETAIL
EOT
done

#--------------------------------------------------------------------
# We are done
exit 0

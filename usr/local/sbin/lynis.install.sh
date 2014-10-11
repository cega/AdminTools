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
DEBUG='-q'
[[ $- = *x* ]] && DEBUG='-v'

echo 'Determine newest version'
#NEWEST=$(host -t txt -W 3 lynis-lv.rootkit.nl | awk '{gsub(/"/,"");print $NF}')
wget $DEBUG 'http://cisofy.com/downloads/' -O /tmp/$$
URL='http://cisofy.com'$(grep 'tar\.gz' /tmp/$$ | sed -e 's/^.*href="//;s/\.gz.*//').gz
cd /usr/local/src
rm -rf lynis*

echo "Downloading newest version from '$URL'"
wget $DEBUG "$URL"
TARDEBUG="$DEBUG"
[ "T$DEBUG" = 'T-q' ] && TARDEBUG=''
tar $TARDEBUG -xzf lynis*
cd lynis

echo 'Installing/updating lynis'
# Executables
cat lynis > /usr/local/bin/lynis
chmod 755 /usr/local/bin/lynis
# Include/test files
mkdir -p /usr/local/include/lynis
cp -a include/* /usr/local/include/lynis
# Default profile
mkdir -p /usr/local/etc/lynis
cat default.prf > /usr/local/etc/lynis/default.prf
# Man pages
for MS in {1..9}
do
    [ -s lynis.$MS ] || continue
    cat lynis.$MS > /usr/local/man/man${MS}/lynis.$MS
done

# We are done
exit 0

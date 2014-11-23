#!/bin/bash -e
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

#-------------------------------------------------------------------------
# Globals
#-------------------------------------------------------------------------
# This must run as "root"
[ "T$EUID" = 'T0' ] || exit

PROG=${0##*/}

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
DEBUG=''
[[ $- = *x* ]] && DEBUG='-v'

# Ensure that only one instance is running
LOCKFILE=/tmp/$PROG.lock
if [ -f $LOCKFILE ]
then
    # The file exists so read the PID
    MYPID=$(< $LOCKFILE)
    [ -z "$(ps h -p $MYPID)" ] || exit 0
fi
trap "rm -f $LOCKFILE /tmp/$$*" EXIT
echo "$$" > $LOCKFILE            

THISHOST=$(hostname)
[[ $THISHOST = *.* ]] || THISHOST=$(hostname -f)
THISDOMAIN=${THISHOST#*.}
TH_SHORT=${THISHOST%%.*}

# Define all important system configs
# -> Can be overwritten/expanded in "filelist" (see below)
FILELIST='/etc/firehol/firehol.conf /etc/network/interfaces
          /etc/hosts /etc/hostname /etc/rc.local
          /etc/cron.d/*'
for SUB in /usr/local/*
do
    [[ $SUB =~ LiSysCo ]] && continue
    FILELIST="$FILELIST $SUB"
done
FILELIST='/etc/firehol/firehol.conf /etc/network/interfaces
          /etc/hosts /etc/hostname /etc/rc.local

# RSYNC share to upload backup to
# -> if empty, no upload happens
# -> Can be set in "filelist" (see below)
RSYNC_SHARE=''

# To run the rsync upload through a SSH tunnel,
#  assign values to ALL FOUR variables below
# -> Should really be done in "filelist" (see below)
# -> After being set, run this script by hand once
SSH_SERVER=''	# The SSH server
REAL_SERVER=''	# The real server behind the SSH server
SSH_USERID=''	# The userid on the SSH server
SSH_PASSWD=''	# The password for the SSH server

# Get possible program options
VERBOSE=0
REVERSE=0
while getopts rv OPTION
do
    case ${OPTION} in
    r)  REVERSE=1
        ;;
    v)  VERBOSE=1
        ;;
    *)  echo "Usage: $0 [options]"
        echo "         -v              Show progress messages"
        echo "         -r              Restore files"
        echo "         Example: -R 'rhost::upload'"
        ;;
    esac
done
shift $((OPTIND - 1))

# Allow local hosts to overwrite or expand the FILELIST
if [ -s /usr/local/etc/LiSysCo.filelist ]
then
    source /usr/local/etc/LiSysCo.filelist
else
    cat << EOT > /usr/local/etc/LiSysCo.filelist
# Allow local hosts to overwrite or expand the FILELIST
# Examples:

#EX## Get nginx confs if present
#EX#[ -d /etc/nginx ] && FILELIST="\$FILELIST /etc/nginx/*"

#EX## Get dovecot confs if present
#EX#[ -d /etc/dovecot ] && FILELIST="\$FILELIST /etc/dovecot/*"

#EX## Get postfix confs if present
#EX#[ -d /etc/postfix ] && FILELIST="\$FILELIST /etc/postfix/*"

# Define the rsync fileshare (overwrites the command line option)
# Format "host::share"
# Can use these variables:
# THISHOST, THISDOMAIN, TH_SHORT
#RSYNC_SHARE=host::share

# To run the rsync upload through a SSH tunnel,
#  assign values to ALL FOUR variables below
# -> After being set, run this script by hand once
#SSH_SERVER='1.2.3.4'		# The SSH server
#REAL_SERVER='127.0.0.1'	# The real server behind the SSH server
#SSH_USERID='joe'		# The userid on the SSH server
#SSH_PASSWD='J03_pw'		# The password for the SSH server
EOT
fi

# Create the directory for the system config backup
LSC=/usr/local/LiSysCo
mkdir -p $LSC

if [ $REVERSE -eq 0 ]
then
    #-----------------------------------------------------------
    # Create the system config backup
    #-----------------------------------------------------------

    # Get a list of installed packages
    dpkg --get-selections > /tmp/Installed.Packages.txt

    # Detect backups created by zos-backup.sh
    if [ -s /backup/zos-backup.log ]
    then
        # Also capture the zimbra backup files
        if [[ $(tail -n 1 /backup/zos-backup.log) = *done:* ]]
        then
            ZIMBRA_BACKUPS='/backup/*t[ag][zr]'
        fi
    else
        ZIMBRA_BACKUPS=''
    fi

    # Save all relevant system configs
    rm -f $LSC/*tar.bz2
    cd /
    TARTOTALS=''
    if [ $VERBOSE -ne 0 ]
    then
        echo ' -> Saving important configuration infos'
        TARTOTALS='--totals'
    fi

    # Use multi-core bzip2 if possible
    if [ -x /usr/bin/pbzip2 ]
    then
        COMP='--use-compress-program="/usr/bin/pbzip2"'
    else
        export BZIP2='-5'
        COMP='--bzip2'
    fi
    nice tar --create --preserve-permissions $COMP \
        --absolute-names $TARTOTALS --ignore-failed-read \
        --exclude=/usr/local/LiSysCo/* \
        --file $LSC/${THISHOST}.LiSysCo.tar.bz2 $FILELIST /tmp/Installed.Packages.txt
    if [ $? -eq 0 ] 
    then
        LISYSCO_BACKUPS='/usr/local/LiSysCo/*'
    else
        LISYSCO_BACKUPS=''
    fi
    if [ ! -z "$RSYNC_SHARE" ] 
    then
        # Only upload files if we have at least one
        if [ ! -z "$ZIMBRA_BACKUPS" -o ! -z "$LISYSCO_BACKUPS" ]
        then
            # Upload the backup file(s)
            if [ -z "$DEBUG" ]
            then
                ST=$(($RANDOM % 1800))
                [ $ST -lt 600 ] && ST=$(($ST + 600))
                sleep $ST
            fi

            if [ ! -z "$SSH_SERVER" -a ! -z "$REAL_SERVER" -a ! -z "$SSH_USERID" -a ! -z "$SSH_PASSWD" ]
            then
                # Create the local SSH key
                mkdir -p $HOME/.ssh
                LOCAL_KEY_FILE=$HOME/.ssh/rsync_id
                if [ ! -s $LOCAL_KEY_FILE ]
                then
                    ssh-keygen -q -t rsa -b 2048 -f $LOCAL_KEY_FILE -N ''
                    cat << EOT
Run this command as "root" now:
ssh-copy-id -i $LOCAL_KEY_FILE "$SSH_USERID@$SSH_SERVER"
EOT
                    exit 1
                fi

                # Set up SSH tunnel
                RSYNC_PORT=2873
                if [ -s $LOCAL_KEY_FILE ]
                then
                    ssh $DEBUG -N -p 22 -i $LOCAL_KEY_FILE "$SSH_USERID@$SSH_SERVER" -L $RSYNC_PORT:127.0.0.1:873 &
                else
                    echo "No way to set up SSH tunnel"
                    exit 1
                fi
                sleep 10
                SSHPID=$(ps -wefH  | awk "/ss[h].*$SSH_SERVER/"' {print $2}')
            else
                # no SSH tunnel
                SSHPID=''
                RSYNC_PORT=873
            fi

            TRY=0
            while [ 1 ]
            do
                # Add 30 seconds per try to the timeout
                nice rsync $DEBUG --timeout=$((180 + $TRY * 30)) -rlptD --ipv4 \
                  --port $RSYNC_PORT --bwlimit 1000 \
                  $LISYSCO_BACKUPS $ZIMBRA_BACKUPS $RSYNC_SHARE
                RETCODE=$?
                [ $RETCODE -eq 0 ] && break
                # Try up to 3 times
                TRY=$(($TRY + 1))
                [ $TRY -gt 2 ] && break
            done

            # Tear down the SSH tunnel (if present)
            [ -z "$SSHPID" ] || kill $SSHPID
        fi
    fi
else
    #-----------------------------------------------------------
    # Restore the system config backup
    #-----------------------------------------------------------
    read -p "Name of host to restore [default=$THISHOST] ? "
    [ -z "$REPLY" ] || THISHOST=$REPLY
    if [ ! -f $LSC/${THISHOST}.LiSysCo.tar.bz2 ]
    then
        echo "ERROR: System config backup '$LSC/${THISHOST}.LiSysCo.tar.bz2' does not exist"
        exit 1
    fi

    cd /
    TARTOTALS=''
    if [ $VERBOSE -ne 0 ]
    then
        echo ' -> Restoring important configuration infos'
        TARTOTALS='--totals'
    fi
    tar --extract --preserve-permissions --bzip2 --absolute-names $TARTOTALS \
        --file $LSC/${THISHOST}.LiSysCo.tar.bz2
    RETCODE=$?
    if [ $RETCODE -ne 0 ]
    then
        echo "ERROR: System config restoration failed: $RETCODE"
        exit 1
    fi
fi

[ $VERBOSE -ne 0 ] && echo " -> Ending with exit code $RETCODE"
exit $RETCODE

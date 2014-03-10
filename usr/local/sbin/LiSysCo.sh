#!/bin/bash -e
################################################################
# (c) Copyright 2013 B-LUC Consulting and Thomas Bullinger
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
          /etc/cron.d/* /usr/local/*'

# RSYNC share to upload backup to
# -> if empty, no upload happens
# -> Can be set in "filelist" (see below)
RSYNC_SHARE=''

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
# RSYNC_SHARE=host::share
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

    # Save all relevant system configs
    rm -f $LSC/*tar.bz2
    cd /
    TARTOTALS=''
    if [ $VERBOSE -ne 0 ]
    then
        echo ' -> Saving important configuration infos'
        TARTOTALS='--totals'
    fi
    export BZIP2='-s'
    nice tar --create --preserve-permissions --bzip2 \
        --absolute-names $TARTOTALS --ignore-failed-read \
        --exclude=/usr/local/LiSysCo/* \
        --file $LSC/${THISHOST}.LiSysCo.tar.bz2 $FILELIST /tmp/Installed.Packages.txt
    RETCODE=$?
    if [ $RETCODE -eq 0 -a ! -z "$RSYNC_SHARE" ] 
    then
        # Upload the backup file
        if [ -z "$DEBUG" ]
        then
            ST=$(($RANDOM % 1800))
            [ $ST -lt 600 ] && ST=$(($ST + 600))
            sleep $ST
        fi
        TRY=0
        while [ 1 ]
        do
            # Add 30 seconds per try to the timeout
            rsync --timeout=$((180 + $TRY * 30)) -a4 /usr/local/LiSysCo/* $RSYNC_SHARE
            RETCODE=$?
            [ $RETCODE -eq 0 ] && break
            # Try up to 3 times
            TRY=$(($TRY + 1))
            [ $TRY -gt 2 ] && break
        done
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

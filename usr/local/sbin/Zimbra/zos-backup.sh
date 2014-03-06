#!/bin/bash
################################################################
# (c) Copyright 2012 Thomas Bullinger
################################################################

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/zimbra/bin

# We must have a valid account 'zimbra'
[ -z "$(getent passwd zimbra)" ] && exit 0

#==============================================================================
# Don't run several instances
PROG=${0##*/}
LOCKFILE=/tmp/${PROG}.lock
if [ -s $LOCKFILE ]
then
        # The file exists so read the PID
        MYPID=$(< $LOCKFILE)
        [ -z "$(ps -p $MYPID | grep $MYPID)" ] || exit 0
fi

# The process is not running (or no lockfile exists)
echo $$ > $LOCKFILE
trap "rm -f $LOCKFILE /tmp/$$*; exit 0" 1 2 3 15 EXIT

DEBUG=0
[[ $- = *x* ]] && DEBUG=1

# Get the full hostname
THISHOST=$(hostname)
[[ $THISHOST = *.* ]] || THISHOST=$(hostname -f)
ZIMBRA_HOSTNAME=$(zmhostname)

# Run the whole script in "ionice" mode
ionice -c2 -n7 -p $$

# Determine whether we are on a "Network Edition" server or not
if [ -x /opt/zimbra/bin/zmlicense -a -x /opt/zimbra/bin/zmrestore -a -s /opt/zimbra/backup/accounts.xml ]
then
        ZIMBRA_NE=1
else
        ZIMBRA_NE=0
fi

# The list of system config files
FILELIST='/etc/firehol/firehol.conf /etc/network/interfaces
          /etc/hosts /etc/hostname /etc/resolv.conf
          /opt/zimbra/ssl/zimbra/commercial'

TODAY=$(date '+%F')

# Create a directory for all backups
BKP_DIR='/backup/backups'
rm -rf $BKP_DIR
mkdir -p $BKP_DIR

LOGFILE='/backup/zos-backup.log'
(echo "$0 starting: "$(date '+%D %T')', l'$(uptime | cut -dl -f2-)) > $LOGFILE

# Get the number of CPU cores in the system
CPUs=$(grep -c CPU /proc/cpuinfo)
MAXLOAD=$(($(($CPUs + 1)) * 2))

##################
# Subroutines
##################
function LoadCheck() {

    # Wait until the load average settled somewhat
    (echo "Checking system load against $MAXLOAD "$(date '+%D %T')', l'$(uptime | cut -dl -f2-)) >> $LOGFILE
    until [ $(awk '{print int($1)}' /proc/loadavg) -lt $MAXLOAD ]
    do
        sleep 4
    done
    (echo "System load after check "$(date '+%D %T')', l'$(uptime | cut -dl -f2-)) >> $LOGFILE
}

function BkpAccount() {
    local BKP_DIR="$1"
    local ACCOUNT="$2"
    local TOTAL_USERS=$3
    local CUR_USER_NUM=$4

    (echo "Backing up account $ACCOUNT ($CUR_USER_NUM of $TOTAL_USERS)"$(date '+%D %T')', l'$(uptime | cut -dl -f2-)) >> $LOGFILE

    # Save the account's metadata (incl. password)
    nice zmprov -l ga $ACCOUNT >> $BKP_DIR/account.$ACCOUNT 2>> $LOGFILE

    # Save the account's filters
    nice zmmailbox -z -m $ACCOUNT getFilterRules >> $BKP_DIR/account.filters.$ACCOUNT 2>> $LOGFILE

    local LASTFULL=''
    if [ $ZIMBRA_NE -ne 0 ]
    then
        # On "Network Edition" servers do an incremental backup
        #  since the last full regular backup
        if [ -d /opt/zimbra/backup/sessions ]
        then
            # Get the day BEFORE the last full backup
            local RFB=$(ls -1t /opt/zimbra/backup/sessions/ | grep -m 1 full-)
            [ -z "$RFB" ] || LASTFULL=$(date +%D -d "${RFB:5:8} - 1 day")
        fi
    else
        # Is there a full backup for that account already?
#        local BKPDAY=$(($(/sbin/ifconfig eth0 | sed -n "s/.*inet addr:\([0-9.]*\).*/\1/p" | awk -F. '{print $NF}') % 7))
        # Full backups happen on Sundays
        local BKPDAY=0
        if [ $(date +%w) -ne $BKPDAY ]
        then
            # Get the date of the last backup
            # Note: Run full backups on the backup day
            [ -s /var/tmp/${ACCOUNT}.lastbkp ] && LASTFULL=$(< /var/tmp/${ACCOUNT}.lastbkp)
        fi
    fi

    # Wait until the load average settled somewhat
    LoadCheck

    # Get the account's data
    if [ -z "$LASTFULL" ]
    then
        # Save everything
        (echo "Full backup for account $ACCOUNT "$(date '+%D %T')', l'$(uptime | cut -dl -f2-)) >> $LOGFILE
        su - zimbra -c "nice zmmailbox -z -m $ACCOUNT getRestURL '//?fmt=tgz'" > $BKP_DIR/account-data.${ACCOUNT}.f${TODAY}.tgz 2>> $LOGFILE
    else
        # Save only from a last backup date on (incremental)
        (echo "Incremental backup for account $ACCOUNT "$(date '+%D %T')', l'$(uptime | cut -dl -f2-)) >> $LOGFILE
        su - zimbra -c "nice zmmailbox -z -m $ACCOUNT getRestURL '//?fmt=tgz&query=after:$LASTFULL'" > $BKP_DIR/account-data.${ACCOUNT}.i${TODAY}.tgz 2>> $LOGFILE
    fi

    # Save the (previous) day of this backup
    date '+%D' > /var/tmp/${ACCOUNT}.lastbkp
}

##################
# Main program
##################
if [ $DEBUG -eq 0 ]
then
    # Wait between 3 and 20 minutes
    ST=$(($RANDOM % 1200))
    [ $ST -lt 180 ] && ST=$(($ST + 180))
    (echo "Waiting $ST seconds "$(date '+%D %T')', l'$(uptime | cut -dl -f2-)) >> $LOGFILE
    sleep $ST
fi

# Local config
LoadCheck
(echo "Backing up localconfig "$(date '+%D %T')', l'$(uptime | cut -dl -f2-)) >> $LOGFILE
echo "# Zimbra Local Configuration (incl. passwords)" > $BKP_DIR/localconfig
nice zmlocalconfig -s >> $BKP_DIR/localconfig 2>> $LOGFILE

# Backup all databases
LoadCheck
(echo "Backing up all databases "$(date '+%D %T')', l'$(uptime | cut -dl -f2-)) >> $LOGFILE
ROOT_SQL_PASSWORD=$(awk '/^mysql_root_password/ {print $NF}' $BKP_DIR/localconfig)
nice /opt/zimbra/mysql/bin/mysqldump -S /opt/zimbra/db/mysql.sock \
  -u root --password=$ROOT_SQL_PASSWORD -A | gzip -c > $BKP_DIR/fullzimbra.sql.gz
 
# Backups
grep pass $BKP_DIR/localconfig > $BKP_DIR/passwords

# All COS data (sorted by name)
INDEX=0
LoadCheck
nice zmprov gac | sort > /tmp/$$
TOTAL_COSS=$(sed -n '$=' /tmp/$$)
CUR_COS_NUM=1
for COS in $(< /tmp/$$)
do
    LoadCheck
    (echo "Backing up COS '$COS' ($CUR_COS_NUM of $TOTAL_COSS) "$(date '+%D %T')', l'$(uptime | cut -dl -f2-)) >> $LOGFILE
    echo "# Zimbra Class of Service: $COS" > $BKP_DIR/cos.$COS
    nice zmprov gc $COS >> $BKP_DIR/cos.$COS 2>> $LOGFILE &
    CUR_COS_NUM=$(($CUR_COS_NUM + 1))
    INDEX=$(($INDEX + 1))
    if [ $INDEX -gt 1 ]
    then
        # Only two COSes in parallel at any time
        wait
        INDEX=0
    fi
done
wait

# All servers (sorted by name)
INDEX=0
LoadCheck
nice zmprov gas | sort > /tmp/$$
TOTAL_SRVS=$(sed -n '$=' /tmp/$$)
CUR_SRV_NUM=1
for SERVER in $(< /tmp/$$)
do
    LoadCheck
    (echo "Backing up server '$SERVER' ($CUR_SRV_NUM of $TOTAL_SRVS) "$(date '+%D %T')', l'$(uptime | cut -dl -f2-)) >> $LOGFILE
    echo "# Zimbra Server: $SERVER" > $BKP_DIR/server.$SERVER
    nice zmprov gs $SERVER >> $BKP_DIR/server.$SERVER 2>> $LOGFILE &
    CUR_SRV_NUM=$(($CUR_SRV_NUM + 1))
    INDEX=$(($INDEX + 1))
    if [ $INDEX -gt 1 ]
    then
        # Only two servers in parallel at any time
        wait
        INDEX=0
    fi
done
wait

# All domains (sorted by name)
INDEX=0
LoadCheck
nice zmprov gad | sort > /tmp/$$
TOTAL_DOMS=$(sed -n '$=' /tmp/$$)
CUR_DOM_NUM=1
for DOMAIN in $(< /tmp/$$)
do
    LoadCheck
    (echo "Backing up domain '$DOMAIN' ($CUR_DOM_NUM of $TOTAL_DOMS) "$(date '+%D %T')', l'$(uptime | cut -dl -f2-)) >> $LOGFILE
    echo "# Zimbra Domain: $DOMAIN" > $BKP_DIR/domain.$DOMAIN
    nice zmprov gd $DOMAIN >> $BKP_DIR/domain.$DOMAIN 2>> $LOGFILE &
    CUR_DOM_NUM=$(($CUR_DOM_NUM + 1))
    INDEX=$(($INDEX + 1))
    if [ $INDEX -gt 1 ]
    then
        # Only two domains in parallel at any time
        wait
        INDEX=0
    fi
done
wait

# All accounts (sorted by size in descending order)
INDEX=0
LoadCheck
nice zmprov gqu $ZIMBRA_HOSTNAME | cut -d' ' -f1,3 | sort -k 2 -rn | cut -d' ' -f1 > /tmp/$$
TOTAL_USERS=$(sed -n '$=' /tmp/$$)
CUR_USER_NUM=1
for ACCOUNT in $(< /tmp/$$)
do
    [[ $ACCOUNT = ham.* ]] && continue
    [[ $ACCOUNT = spam.* ]] && continue
    [[ $ACCOUNT = virus-quarantine.* ]] && continue
    BkpAccount $BKP_DIR $ACCOUNT $TOTAL_USERS $CUR_USER_NUM &
    CUR_USER_NUM=$(($CUR_USER_NUM + 1))
    INDEX=$(($INDEX + 1))
    if [ $INDEX -gt 1 ]
    then
        # Only two accounts in parallel at any time
        wait
        INDEX=0
    fi
done
wait

# All distribution lists (sorted by name)
INDEX=0
LoadCheck
nice zmprov gadl | sort > /tmp/$$
TOTAL_LISTS=$(sed -n '$=' /tmp/$$)
CUR_LIST_NUM=1
for LIST in $(< /tmp/$$)
do
    LoadCheck
    (echo "Backing up list '$LIST' ($CUR_LIST_NUM of $TOTAL_LISTS) "$(date '+%D %T')', l'$(uptime | cut -dl -f2-)) >> $LOGFILE
    echo "# Zimbra Distribution List: $LIST" > $BKP_DIR/list.$LIST
    nice zmprov gdl $LIST >> $BKP_DIR/list.$LIST 2>> $LOGFILE &
    CUR_LIST_NUM=$(($CUR_LIST_NUM + 1))
    INDEX=$(($INDEX + 1))
    if [ $INDEX -gt 1 ]
    then
        # Only two lists in parallel at any time
        wait
        INDEX=0
    fi
done
wait

# All calendars (sorted by name)
INDEX=0
LoadCheck
nice zmprov gacr | sort > /tmp/$$
TOTAL_CALS=$(sed -n '$=' /tmp/$$)
CUR_CAL_NUM=1
for CAL in $(< /tmp/$$)
do
    LoadCheck
    (echo "Backing up calendar '$CAL' ($CUR_CAL_NUM of $TOTAL_CALS) "$(date '+%D %T')', l'$(uptime | cut -dl -f2-)) >> $LOGFILE
    echo "# Zimbra Calendar: $CAL" > $BKP_DIR/calendar.$CAL
    nice zmprov gcr $CAL >> $BKP_DIR/calendar.$CAL 2>> $LOGFILE &
    CUR_CAL_NUM=$(($CUR_CAL_NUM + 1))
    INDEX=$(($INDEX + 1))
    if [ $INDEX -gt 1 ]
    then
        # Only two calendars in parallel at any time
        wait
        INDEX=0
    fi
done
wait

# Some misc. files
LoadCheck
(echo "Backing up misc files "$(date '+%D %T')', l'$(uptime | cut -dl -f2-)) >> $LOGFILE
[ -f /usr/local/sbin/LocalHealthCheck.sh ] && cp /usr/local/sbin/LocalHealthCheck.sh $BKP_DIR
[ -f /usr/local/etc/zos-MailRouting.cfg ] && cp /usr/local/etc/zos-MailRouting.cfg $BKP_DIR

# Delete any backups older than 8 days
LoadCheck
(echo "Deleting old backups "$(date '+%D %T')', l'$(uptime | cut -dl -f2-)) >> $LOGFILE
nice find /backup -maxdepth 1 -type f \( -name "${THISHOST}.backup.*.tgz" -o -name "${THISHOST}.backup.*.tar" \) -mtime +7 -delete >> $LOGFILE 2>&1 &

# Gzip all file not yet compressed
LoadCheck
nice find $BKP_DIR -type f '!' -name "*gz" -print0 | xargs -0rI XXX -n 40 gzip -9f XXX

# Tar up the whole backup directory and delete it
LoadCheck
(echo "Tarring up backups "$(date '+%D %T')', l'$(uptime | cut -dl -f2-)) >> $LOGFILE
nice tar cf /backup/${THISHOST}'.backup.'$(date '+%Y-%m-%d')'.tar' $BKP_DIR >> $LOGFILE 2>&1
RETCODE=$?
if [ $RETCODE -eq 0 ]
then
    nice rm -rf $BKP_DIR &
#	if [ $DEBUG -eq 0 ]
#	then
#                su - zimbra -c 'zmcontrol stop'
#                sleep 2
#                [ -x /usr/local/sbin/KillOldZimbraProcs.pl ] && KillOldZimbraProcs.pl
#                su - zimbra -c 'zmcontrol start'
#        fi
fi

#==============================================================================
# Create an archive of essential config files
(echo ' => Creating archive: '$(date '+%D %T')', l'$(uptime | cut -dl -f2-)) >> $LOGFILE
nice chown -R zimbra:zimbra /backup &> /dev/null
nice tar -cvz -f /backup/${THISHOST}.zosss.tgz $FILELIST >> $LOGFILE 2>&1

#==============================================================================
# Copy files to backup server (if possible)
DB1_BKP=
if [ ! -z "$DB1_BKP" ]
then
    ping -qc 3 $DB1_BKP &> /dev/null
    if [ $? -eq 0 -a -x /usr/bin/pscp ]
    then
        U=  # Username for pscp
        P=  # Password for pscp
        LoadCheck
        pscp -q -batch -4 -l $U -pw $P /backup/${THISHOST}.zosss.tgz $DB1_BKP:
    fi
fi

#==============================================================================
# Upgrade OS and reboot if necessary
[ -x /usr/local/sbin/OSUpdate.sh ] && /usr/local/sbin/OSUpdate.sh

#==============================================================================
# We are done
(echo -n "$0 done: "; date) >> $LOGFILE
exit 0

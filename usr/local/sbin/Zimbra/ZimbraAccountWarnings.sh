#!/bin/bash
################################################################
# (c) Copyright 2013 B-LUC Consulting and Thomas Bullinger
################################################################

#--------------------------------------------------------------------
# Set a sensible path for executables
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/zimbra/bin
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

# Get the current date in RFC822 format (for the emails below)
RFC822DATE=$(date -R)

# Get possible program options
TESTMODE=0
while getopts ht OPTION
do
    case ${OPTION} in
    t)  TESTMODE=1
        ;;
    *)  cat << EOT
Usage: $0 [-h|-t]
       -t   Don't send emails, just show them
       -h   Show this text
EOT
        exit 0
        ;;
    esac
done
shift $((OPTIND - 1))

# Get all accounts and their attributes
nice zmprov -l gaa -v > /tmp/$$.accounts
[ $? -ne 0 ] && exit 1
[ -s /tmp/$$.accounts ] || exit 1

# We want every account which hasn't logged in for 90 days or more
# Note: "zimbraLastLogonTimestamp" only updates every x days, so take that in account
MAX_UNUSED_DAYS=$(nice zmprov gcf zimbraLastLogonTimestampFrequency | awk '{print 90+int($2)}')
[ -z "$MAX_UNUSED_DAYS" ] && exit 2
[ $MAX_UNUSED_DAYS -eq 0 ] && exit 2
MAX_UNUSED_SEC=$(($MAX_UNUSED_DAYS * 24 * 60 *60))

# Get all accounts and their last login time
awk '/^mail:/{M=$2};/^zimbraLastLogonTimestamp:/{print M" "$2}' /tmp/$$.accounts > /tmp/$$.accounts.lastlogin

# Get the reference time and start a new log
NOW=$(date --utc +%s)
> /var/log/zimbra-inactive-accounts
sort /tmp/$$.accounts.lastlogin | while read LINE
do
    # Seperate the account and the last login time
    set $LINE
    ACCT="$1"
    LAST="$2"

    # Exclude system accounts from this list
    [[ $ACCT =~ (ham\.|spam\.|galsync\.|virus-quarantine|admin@) ]] && continue

    # Determine the last login time
    LAST_YY=${LAST:0:4}
    LAST_MM=${LAST:4:2}
    LAST_DD=${LAST:6:2}
    LAST_hh=${LAST:8:2}
    LAST_mm=${LAST:10:2}
    LAST_ss=${LAST:12:2}
    LAST_LOGIN=$(date +%s --utc --date "$LAST_YY-$LAST_MM-$LAST_DD $LAST_hh:$LAST_mm:$LAST_ss")

    # Check how long ago the account last logged in
    UNUSED_SEC=$(($NOW - $LAST_LOGIN))
    if [ $UNUSED_SEC -gt $MAX_UNUSED_SEC ]
    then
        echo -n "Account '$ACCT' did not login for more than 90 days: " >> /var/log/zimbra-inactive-accounts
        date --date "$LAST_YY-$LAST_MM-$LAST_DD $LAST_hh:$LAST_mm:$LAST_ss" >> /var/log/zimbra-inactive-accounts
    fi
done
if [ -s /var/log/zimbra-inactive-accounts ]
then
    cat << EOT > /tmp/$$.mail
From: admin@$THISDOMAIN 
To: admin@$THISDOMAIN
Subject: Zimbra inactive accounts on $THISHOST
Date: $RFC822DATE
X-Mailer: $PROG

EOT
    # Sort the entries by domain
    for D in $(awk -F@ '{print $2}' /var/log/zimbra-inactive-accounts | cut -d\' -f1 | sort -u)
    do
        grep "$D" /var/log/zimbra-inactive-accounts >> /tmp/$$.mail
        echo >> /tmp/$$.mail
    done
    if [ $TESTMODE -eq 0 ]
    then
        sendmail -t < /tmp/$$.mail
    else
        less /tmp/$$.mail
    fi
fi

# Get the list of locked or closed accounts
awk '/^mail:/{M=$2};/^zimbraAccountStatus: (lockout|closed)/{print $2": "M}' /tmp/$$.accounts | \
  sort > /tmp/$$.accounts.lockedORclosed

YESTERDAY=$(date -d yesterday '+%Y-%m-%d')
egrep "$YESTERDAY.*(re.activ|lockout due)" /opt/zimbra/log/audit.log > /tmp/$$.account.log
[ -s /opt/zimbra/log/audit.log.$YESTERDAY.gz ] && zegrep "$YESTERDAY.*(re.activ|lockout due)" /opt/zimbra/log/audit.log.$YESTERDAY.gz >> /tmp/$$.account.log

if [ -s /tmp/$$.accounts.lockedORclosed ]
then
    cat << EOT > /tmp/$$.mail
From: admin@$THISDOMAIN 
To: admin@$THISDOMAIN
Subject: Zimbra locked or closed accounts on $THISHOST
Date: $RFC822DATE
X-Mailer: $PROG

EOT
    if [ -s /tmp/$$.accounts.lockedORclosed ]
    then
        echo 'Currently locked out or closed accounts:' >> /tmp/$$.mail
        echo >> /tmp/$$.mail
        grep 'lockout' /tmp/$$.accounts.lockedORclosed | sed  's/^/  /' >> /tmp/$$.mail
        echo >> /tmp/$$.mail
        grep 'closed' /tmp/$$.accounts.lockedORclosed | sed  's/^/  /' >> /tmp/$$.mail
        echo >> /tmp/$$.mail
    fi
    if [ -s /tmp/$$.account.log ]
    then
        echo "Logs for yesterday's account lockouts and re-activations:" >> /tmp/$$.mail
        echo >> /tmp/$$.mail
        sed  's/^/  /' /tmp/$$.account.log >> /tmp/$$.mail
    fi
    if [ $TESTMODE -eq 0 ]
    then
        sendmail -t < /tmp/$$.mail
    else
        less /tmp/$$.mail
    fi
fi

# Get the "diskhogs"
cat << EOT > /tmp/$$.mail
From: admin@$THISDOMAIN
To: admin@$THISDOMAIN
Subject: Zimbra "diskhogs"
Date: $RFC822DATE
X-Mailer: $PROG

This list below shows the Zimbra accounts which occupy 2 GB or more space.

EOT
# Get the size of EACH mailbox in one command, sort it by size,
nice zmprov gqu $(zmhostname) | sort -rn -k3 > /tmp/$$.mailbox-sizes
[ $? -ne 0 ] && exit 3
if [ -s /tmp/$$.mailbox-sizes ]
then
    # Commify the numbers and create a log file
    awk '{print "Mailbox size of "$1" = "$3" bytes"}' /tmp/$$.mailbox-sizes | \
      sed ":a;s/\B[0-9]\{3\}\>/,&/;ta" > /var/log/zimbra-mailbox-sizes.log

    # Get the accounts with 2GB or more
    awk '$3 > 2147483648 {print "Mailbox size of "$1" = "$3" bytes"}' /tmp/$$.mailbox-sizes | \
      sed ":a;s/\B[0-9]\{3\}\>/,&/;ta" >> /tmp/$$.zms
    for D in $(awk -F@ '{print $2}' /tmp/$$.zms | cut -d' ' -f1 | sort -u)
    do
        grep "$D" /tmp/$$.zms >> /tmp/$$.mail
        echo >> /tmp/$$.mail
    done
    cat << EOT >> /tmp/$$.mail

FYI: A list for ALL accounts can be found at /var/log/zimbra-mailbox-sizes.log
EOT
    if [ $TESTMODE -eq 0 ]
    then
        sendmail -t < /tmp/$$.mail
    else
        less /tmp/$$.mail
    fi
fi

# We are done
exit 0

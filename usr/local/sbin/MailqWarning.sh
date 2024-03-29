#!/bin/bash
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

# Set the correct path for commands
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
DEBUG='-q'
[[ $- = *x* ]] && DEBUG='-v'

# The script's basename
PROG=${0##*/}

# This host and domain
THISHOST=$(hostname)
[[ $THISHOST = *.* ]] || THISHOST=$(hostname -f)
THISDOMAIN=${THISHOST#*.}

# Default setting for options
M_TOTAL_DEF=1000
M_TOTAL=$M_TOTAL_DEF
M_SINGLE_DEF=500
M_SINGLE=$M_SINGLE_DEF
W_INTERVAL_DEF=300
W_INTERVAL=$W_INTERVAL_DEF
# NOTE: Do not use the following defaults - since the mail queue
#       is usually already full, using the local server might not
#       deliver the warning in the first place!
M_SERVER=''
M_RECIPIENT="root@$THISDOMAIN"

# Cleanup at the end of the script
trap "rm -f /tmp/$$" EXIT

# Get the location of postfix's queue directory
QDIR=''
if [ -x /opt/zimbra/postfix/sbin/postconf ]
then
    QDIR=$(/opt/zimbra/postfix/sbin/postconf -h queue_directory)
elif [ -x /usr/sbin/postconf ]
then
    QDIR=$(/usr/sbin/postconf -h queue_directory)
else
    echo 'ERROR: Not a postfix server'
    exit 1
fi

if [ ! -x /usr/bin/sendemail ]
then
    cat << EOT
ERROR: Can not find 'sendemail' executable
       You can get it using one of the other method below:
       1. via 'apt-get install sendemail'
       2. from http://caspian.dotconf.net/menu/Software/SendEmail/sendEmail-v1.56.tar.gz
EOT
    exit 1
fi

# Get possible program options
FORCE_ALERT=0
while getopts hs:t:C:c:i:f OPTION
do
    case ${OPTION} in
    s)  M_SERVER="$OPTARG"
        ;;
    t)  M_RECIPIENT="$OPTARG"
        ;;
    c)  if [[ $OPTARG != *[!0-9]* ]]
        then
            M_SINGLE=$OPTARG
        else
            echo "-c '$OPTARG' is not an integer - using default '$M_SINGLE_DEF'"
            M_SINGLE=$M_SINGLE_DEF
        fi
        if [ $M_SINGLE -le 0 ]
        then
            echo "-c '$OPTARG' is '0' - using default '$M_SINGLE_DEF'"
            M_SINGLE=$M_SINGLE_DEF
        fi
        ;;
    C)  if [[ $OPTARG != *[!0-9]* ]]
        then
            M_TOTAL=$OPTARG
        else
            echo "-C '$OPTARG' is not an integer - using default '$M_TOTAL_DEF'"
            M_TOTAL=$M_TOTAL_DEF
        fi
        if [ $M_TOTAL -le 0 ]
        then
            echo "-C '$OPTARG' is '0' - using default '$M_TOTAL_DEF'"
            M_TOTAL=$M_TOTAL_DEF
        fi
        ;;
    i)  if [[ $OPTARG != *[!0-9]* ]]
        then
            W_INTERVAL=$OPTARG
        else
            echo "-i '$OPTARG' is not an integer - using default '$W_INTERVAL_DEF'"
            W_INTERVAL=$W_INTERVAL_DEF
        fi
        if [ $W_INTERVAL -le 0 ]
        then
            echo "-i '$OPTARG' is '0' - using default '$W_INTERVAL_DEF'"
            W_INTERVAL=$W_INTERVAL_DEF
        fi
        ;;
    f)  FORCE_ALERT=1
        ;;
    *)  cat << EOT
Usage: $PROG options
       -s server  Specify the mail server to use [default=MX hosts for recipient's domain]
       -t email   Specify the email recipient [default=$M_RECIPIENT]
       -C number  Specify the total threshold for ALL queues [default=$M_TOTAL_DEF]
       -c number  Specify the threshold for any single queue [default=$M_SINGLE_DEF]
       -i number  Specify the warning interval in seconds [default=$W_INTERVAL_DEF]
       -f         Force alert regardless of thresholds
EOT
        exit 0
        ;;
    esac
done
shift $((OPTIND - 1))

# Don't run several instances
LOCKFILE=/tmp/${PROG}.lock
if [ -s $LOCKFILE ]
then
    # The file exists so read the PID
    MYPID=$(< $LOCKFILE)
    if [ ! -z "$(ps -p $MYPID | grep $MYPID)" ]
    then
        # The old process still runs - find out how long
        OLDPID_START=$(date +%s -r $LOCKFILE)
        if [ $(($(date +%s) - 7200)) -gt $OLDPID_START ]
        then
            # The old process runs for at least 2 hours - kill it
            kill $MYPID
            # And try again later
            exit 1
        fi
    fi
fi

if [ -z "$M_SERVER" ]
then
    # No mail server specified - determine the MX host(s) for the email recipient
    M_RECIP_MX=$(host -t mx ${M_RECIPIENT##*@} | awk '/handled/ {sub(/\.$/,"",$NF);printf("%s ",$NF)}END{printf("\n")}')
    if [ -z "$M_RECIP_MX" ]
    then
        echo "ERROR: No MX host found for '$M_RECIPIENT', please use the '-s' option"
        exit 1
    fi
    # Use the first (or only) host in the list
    M_SERVER="${M_RECIP_MX%% *}"
fi

# Determine the port for mail server
M_SERVER_PORT=':25'
if [ "T$M_SERVER" = 'Tlocalhost' ]
then
    [[ $QDIR =~ *zimbra* ]] && M_SERVER_PORT=':10025'
fi

# Get the sizes of the relevant queues
Q_ACTIVE=$(find ${QDIR}/active -type f | wc -l)
Q_INCOMING=$(find ${QDIR}/incoming -type f | wc -l)
Q_DEFERRED=$(find ${QDIR}/deferred -type f | wc -l)
Q_MAILDROP=$(find ${QDIR}/maildrop -type f | wc -l)
Q_TOTAL=$(($Q_ACTIVE + $Q_INCOMING + $Q_DEFERRED + $Q_MAILDROP))

# In "FORCE_ALERT" mode reset ALL "send last" indicators
[ $FORCE_ALERT -ne 0 ] && rm -f /var/tmp/MailqWarning.*.last

# Send warning for total queue size
if [ $Q_TOTAL -ge $M_TOTAL -o $FORCE_ALERT -ne 0 ]
then
    logger -i -p err -t mail -- Large TOTAL mail queue $Q_TOTAL

    LAST_WARNING=0
    NOW=$(date +%s)
    if [ -s /tmp/MailqWarning.TOTAL.last ]
    then
        # When was the last warning sent?
        LAST_WARNING=$(date +%s -r /tmp/MailqWarning.TOTAL.last)
    fi
    if [ $(($NOW - $LAST_WARNING)) -gt $W_INTERVAL ]
    then
        # Last warning was more than 5 minutes ago
        #  - try up to 3 times to send email using
        #    the MX host(s) or specified mail server(s)
        TRY=0
        SENT_EMAIL=1
        while [ $SENT_EMAIL -ne 0 -a $TRY -lt 3 ]
        do
            for MS in $M_SERVER
            do
                echo "TOTAL mail queue size = $Q_TOTAL" | \
                  sendemail -f root@$THISDOMAIN -t $M_RECIPIENT $DEBUG \
                    -u "$THISHOST: Large TOTAL mail queue" -s ${MS}${M_SERVER_PORT}
                if [ $? -eq 0 ]
                then
                    # Email was sent successfully
                    SENT_EMAIL=0
                    break
                fi
            done
            # Try again unless the email was successfully sent
            [ $SENT_EMAIL -ne 0 ] && TRY=$(($TRY + 1))
        done
        [ $SENT_EMAIL -eq 0 ] && date > /tmp/MailqWarning.TOTAL.last
    fi
else
    # Remove the "last warning" file
    rm -f /tmp/MailqWarning.TOTAL.last
fi

# Send warnings for single queues
if [ $Q_ACTIVE -ge $M_SINGLE -o $FORCE_ALERT -ne 0 ]
then
    LAST_WARNING=0
    NOW=$(date +%s)
    if [ -s /tmp/MailqWarning.ACTIVE.last ]
    then
        # When was the last warning sent?
        LAST_WARNING=$(date +%s -r /tmp/MailqWarning.ACTIVE.last)
    fi
    if [ $(($NOW - $LAST_WARNING)) -gt $W_INTERVAL ]
    then
        # Last warning was more than 5 minutes ago
        #  - try up to 3 times to send email using
        #    the MX host(s) or specified mail server(s)
        TRY=0
        SENT_EMAIL=1
        while [ $SENT_EMAIL -ne 0 -a $TRY -lt 3 ]
        do
            for MS in $M_SERVER
            do
                echo "ACTIVE mail queue size = $Q_ACTIVE" | \
                  sendemail -f root@$THISDOMAIN -t $M_RECIPIENT $DEBUG \
                    -u "$THISHOST: Large ACTIVE mail queue" -s ${MS}${M_SERVER_PORT}
                if [ $? -eq 0 ]
                then
                    # Email was sent successfully
                    SENT_EMAIL=0
                    break
                fi
            done
            # Try again unless the email was successfully sent
            [ $SENT_EMAIL -ne 0 ] && TRY=$(($TRY + 1))
        done
        [ $SENT_EMAIL -eq 0 ] && date > /tmp/MailqWarning.ACTIVE.last
    fi
else
    # Remove the "last warning" file
    rm -f /tmp/MailqWarning.ACTIVE.last
fi
if [ $Q_DEFERRED -ge $M_SINGLE -o $FORCE_ALERT -ne 0  ]
then
    LAST_WARNING=0
    NOW=$(date +%s)
    if [ -s /tmp/MailqWarning.DEFERRED.last ]
    then
        # When was the last warning sent?
        LAST_WARNING=$(date +%s -r /tmp/MailqWarning.DEFERRED.last)
    fi
    if [ $(($NOW - $LAST_WARNING)) -gt $W_INTERVAL ]
    then
        # Last warning was more than 5 minutes ago
        #  - try up to 3 times to send email using
        #    the MX host(s) or specified mail server(s)
        TRY=0
        SENT_EMAIL=1
        while [ $SENT_EMAIL -ne 0 -a $TRY -lt 3 ]
        do
            for MS in $M_SERVER
            do
                echo "DEFERRED mail queue size = $Q_DEFERRED" | \
                  sendemail -f root@$THISDOMAIN -t $M_RECIPIENT $DEBUG \
                    -u "$THISHOST: Large DEFERRED mail queue" -s ${MS}${M_SERVER_PORT}
                if [ $? -eq 0 ]
                then
                    # Email was sent successfully
                    SENT_EMAIL=0
                    break
                fi
            done
            # Try again unless the email was successfully sent
            [ $SENT_EMAIL -ne 0 ] && TRY=$(($TRY + 1))
        done
        [ $SENT_EMAIL -eq 0 ] && date > /tmp/MailqWarning.DEFERRED.last
    fi
else
    # Remove the "last warning" file
    rm -f /tmp/MailqWarning.DEFERRED.last
fi
if [ $Q_INCOMING -ge $M_SINGLE -o $FORCE_ALERT -ne 0  ]
then
    LAST_WARNING=0
    NOW=$(date +%s)
    if [ -s /tmp/MailqWarning.INCOMING.last ]
    then
        # When was the last warning sent?
        LAST_WARNING=$(date +%s -r /tmp/MailqWarning.INCOMING.last)
    fi
    if [ $(($NOW - $LAST_WARNING)) -gt $W_INTERVAL ]
    then
        # Last warning was more than 5 minutes ago
        #  - try up to 3 times to send email using
        #    the MX host(s) or specified mail server(s)
        TRY=0
        SENT_EMAIL=1
        while [ $SENT_EMAIL -ne 0 -a $TRY -lt 3 ]
        do
            for MS in $M_SERVER
            do
                echo "INCOMING mail queue size = $Q_INCOMING" | \
                  sendemail -f root@$THISDOMAIN -t $M_RECIPIENT $DEBUG \
                    -u "$THISHOST: Large INCOMING mail queue" -s ${MS}${M_SERVER_PORT}
                if [ $? -eq 0 ]
                then
                    # Email was sent successfully
                    SENT_EMAIL=0
                    break
                fi
            done
            # Try again unless the email was successfully sent
            [ $SENT_EMAIL -ne 0 ] && TRY=$(($TRY + 1))
        done
        [ $SENT_EMAIL -eq 0 ] && date > /tmp/MailqWarning.INCOMING.last
    fi
else
    # Remove the "last warning" file
    rm -f /tmp/MailqWarning.INCOMING.last
fi
if [ $Q_MAILDROP -ge $M_SINGLE -o $FORCE_ALERT -ne 0  ]
then
    LAST_WARNING=0
    NOW=$(date +%s)
    if [ -s /tmp/MailqWarning.MAILDROP.last ]
    then
        # When was the last warning sent?
        LAST_WARNING=$(date +%s -r /tmp/MailqWarning.MAILDROP.last)
    fi
    if [ $(($NOW - $LAST_WARNING)) -gt $W_INTERVAL ]
    then
        # Last warning was more than 5 minutes ago
        #  - try up to 3 times to send email using
        #    the MX host(s) or specified mail server(s)
        TRY=0
        SENT_EMAIL=1
        while [ $SENT_EMAIL -ne 0 -a $TRY -lt 3 ]
        do
            for MS in $M_SERVER
            do
                echo "MAILDROP mail queue size = $Q_MAILDROP" | \
                  sendemail -f root@$THISDOMAIN -t $M_RECIPIENT $DEBUG \
                    -u "$THISHOST: Large MAILDROP mail queue" -s ${MS}${M_SERVER_PORT}
                if [ $? -eq 0 ]
                then
                    # Email was sent successfully
                    SENT_EMAIL=0
                    break
                fi
            done
            # Try again unless the email was successfully sent
            [ $SENT_EMAIL -ne 0 ] && TRY=$(($TRY + 1))
        done
        [ $SENT_EMAIL -eq 0 ] && date > /tmp/MailqWarning.MAILDROP.last
    fi
else
    # Remove the "last warning" file
    rm -f /tmp/MailqWarning.MAILDROP.last
fi

# We are done
exit 0

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

#--------------------------------------------------------------------
# Set a sensible path for executables
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

#--------------------------------------------------------------------
# Ensure that only one instance is running
LOCKFILE=/tmp/$PROG.lock
if [ -f $LOCKFILE ]
then
    # The file exists so read the PID
    MYPID=$(< $LOCKFILE)
    [ -z "$(ps h -p $MYPID)" ] || exit 0
fi

ARE_ZIMBRA=0
dpkg -l zimbra-store &> /dev/null
if [ $? -eq 0 ]
then
    # We must have a valid account 'zimbra'
    [ -z "$(getent passwd zimbra)" ] && exit 0

    # We are on a Zimbra store server - expand the path
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/zimbra/bin
    ARE_ZIMBRA=1
fi

function Usage()
{
    if [ $ARE_ZIMBRA -ne 0 ]
    then
        cat << EOT
Usage: $0 [options]
         -i filename   Specify input file with usernames and password
EOT
else
        cat << EOT
Usage: $0 [options] [account[[,account]...]]
         -i filename   Specify input file with usernames and password

         On a Zimbra server the input will be created from the list of accounts
          given as arguments - or for ALL accounts on the server
         
EOT
fi
        cat << EOT

 Format for input file (one entry per line):
IMAP-Username,Password
EOT

    exit 0
}

# Get possible program options
INFILE=''
while getopts hi: OPTION
do
    case ${OPTION} in
    i)  INFILE=$OPTARG
        ;;
    *)  Usage
        ;;
    esac
done
shift $((OPTIND - 1))

# Create a temp directory for all work files
TMP_DIR=$(mktemp -d DDXXXXXXXX -p "${TMPDIR:-.}" )
# and ensure it gets removed when this script ends
trap "rm -rf $TMP_DIR" EXIT

cd $TMP_DIR
if [ $ARE_ZIMBRA -ne 0 ]
then
    # Create the list of accounts and their passwords
    if [ ! -z "$INFILE" ]
    then
        if [ ! -s "$INFILE" ]
        then
            INFILE='AccountPasswords.csv'
            > "$INFILE"
            if [ $# -gt 0 ]
            then
                # Process only the users listed in the arguments
                for ACCT in $@
                do
                    PASS=$(nice zmprov -l ga $ACCT userPassword 2> /dev/null | awk '/^userPassword:/ {print $NF}')
                    [ -z "$PASS" ] && continue
                    echo "$ACCT,$PASS" >> $INFILE
                done
            else
                # Process all users
                for ACCT in $(zmprov -l gaa)
                do
                    PASS=$(nice zmprov -l ga $ACCT userPassword 2> /dev/null | awk '/^userPassword:/ {print $NF}')
                    [ -z "$PASS" ] && continue
                    echo "$ACCT,$PASS" >> $INFILE
                done
            fi
        fi
    fi
fi

# Show the usage if we don't have an input file
if [ -z "$INFILE" ]
then
    Usage
fi
if [ ! -f "$INFILE" ]
then
    echo "Input file '$INFILE' is not a regular file or does not exist"
    exit 0
fi
if [ ! -s "$INFILE" ]
then
    echo "Input file '$INFILE' is empty"
    exit 0
fi

# Get the dedup script
wget -q 'https://raw.github.com/quentinsf/IMAPdedup/master/imapdedup.py' -O imapdedup.py
# We are done unless we have the script
[ -s imapdedup.py ] || exit
chmod 700 imapdedup.py

# We are done unless we have accounts with passwords
[ -s $INFILE ] || exit

for LINE in $(< $INFILE)
do
    set ${LINE//,/ }
    ACCOUNT="$1"
    PASSWD="$2"
    echo
    echo "=> Checking '$ACCOUNT' <="
  
    if [ $ARE_ZIMBRA -ne 0 ]
    then
        # On Zimbra servers empty these two folders
        echo " =>  Emptying Trash and Junk folder"
        zmmailbox -z -m $ACCOUNT emptyFolder /Trash &
        zmmailbox -z -m $ACCOUNT emptyFolder /Junk &
        wait

        # Give the account a temporary password
        # (this make it unaccessible for the duration)
        TMP_PASSWD=$(tr -dc A-Za-z0-9_ < /dev/urandom | dd bs=16 count=1 2> /dev/null)
        su - zimbra -c "zmprov sp $ACCOUNT $TMP_PASSWD"
    else
        TMP_PASSWD="$PASSWD"
    fi

    # Now delete duplicates
    echo " =>  Delete duplicates"
    # Get all mail folders for account
    nice ./imapdedup.py -l -s localhost -p 143 -u $ACCOUNT -w $TMP_PASSWD > $$
    cat $$ | while read M_FOLDER
    do
        # Delete duplicates in one mail folder at a time
        nice ./imapdedup.py -s localhost -p 143 -u $ACCOUNT -w $TMP_PASSWD $M_FOLDER
    done
    rm -f $$

    # Reset the password
    [ $ARE_ZIMBRA -ne 0 ] && su - zimbra -c "zmprov ma $ACCOUNT userPassword '$PASSWD'"
done

# We are done
exit 0

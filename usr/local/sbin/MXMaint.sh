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

# Ensure we use the correct postfix config_directory
PF_CD=$(postconf -h config_directory)

# Define some colours
RED='\e[00;31m'
BLUE='\e[01;34m'
CYAN='\e[01;36m'
NC='\e[0m' # No Color

# Sanity checks
if [[ $(postconf -h local_transport) != error:* ]]
then
    echo 'This is NOT a backup MX server'
    exit 1
fi
if [ ! -z "$(postconf -h mydestination)" ]
then
    echo 'This is NOT a backup MX server'
    exit 1
fi

# Define the editor
if [ -z "$EDITOR" ]
then
    # Use a flavor of "vi"
    if [ -x /usr/bin/vim.tiny ]
    then
        M_EDITOR=vim.tiny
    else
        M_EDITOR=vi
    fi
else
    # Use the editor specified in the environment variable
    M_EDITOR=$EDITOR
fi

#####################################################################
# Check whether argument is a valid IP address
#####################################################################
is_validip()
{
    case "$*" in
    ""|*[!0-9.]*|*[!0-9]) return 1 ;;
    esac

    local IFS=.  ## local is bash-specific
    set -- $*
    [ $# -eq 4 ] &&
        [ ${1:-666} -le 255 ] && [ ${2:-666} -le 255 ] &&
        [ ${3:-666} -le 255 ] && [ ${4:-666} -le 254 ]
}

#####################################################################
# Add a new MX domain
#####################################################################
M_AddMX() {
    echo
    echo -ne " ${BLUE}What is the name of the new MX domain${NC}"
    read -p '? ' MXD
    [ -z "$MXD" ] && return

    if [ -z "$(grep ^$MXD $PF_CD/relays)" ]
    then
        local NOW=$(date)

        echo "# $MXD added ${NOW}:" >> $PF_CD/relays
        echo "$MXD OK" >> $PF_CD/relays

        echo "# $MXD added ${NOW}:" >> $PF_CD/relay_recipients
        echo "@${MXD} OK" >> $PF_CD/relay_recipients

        read -p "Real mail server for '$MXD' ? " RS
        if [ ! -z "$RS" ]
        then
            is_validip $RS
            if [ $? -eq 0 ]
            then
                echo "# $MXD added ${NOW}:" >> $PF_CD/transport
                echo "$MXD smtp:[$RS]:25" >> $PF_CD/transport
            fi
        fi

        (cd $PF_CD; ./make)
    else
        echo -e "${RED}Domain '$MXD' already exists${NC}"
    fi
    read -p 'Press <ENTER> to continue'
}

#####################################################################
# Delete a new MX domain
#####################################################################
M_DelMX() {
    echo
    echo -ne " ${BLUE}What is the name of the MX domain to delete${NC}"
    read -p '? ' MXD
    [ -z "$MXD" ] && return
    if [ -z "$(grep ^$MXD $PF_CD/relays)" ]
    then
        echo -e "${RED}Domain '$MXD' does not exist${NC}"
    else
        for F in relays relay_recipients transport
        do
            sed -e "/$MXD/d" $PF_CD/$F > /tmp/$$
            cat /tmp/$$ > $PF_CD/$F
        done
        [ -f /tmp/$$ ] && rm -f /tmp/$$
        (cd $PF_CD; ./make)
    fi
        
    read -p 'Press <ENTER> to continue'
}

#####################################################################
# List MX domains
#####################################################################
M_ListMX() {
    echo
    echo -e "${BLUE}List of defined MX email domains:${NC}"
    echo
    for D in $(grep '^[^#].*OK' $PF_CD/relays)
    do
        [ "T$D" = 'TOK' ] && continue

        # Show the domain and possible specific mail routing
        echo "Domain '$D':"
        MR=$(awk "/$D.*smtp/"'{print $2}' $PF_CD/transport | sort -u)
        if [ -z "$MR" ]
        then
            # Show the specific mail routing
            host -t mx $D
        else
            # Look up the MX record(s) for the domain
            echo "$D mail is forced to use $MR"
        fi
        echo
    done
    read -p 'Press <ENTER> to continue'
}

#####################################################################
# Manage SMTP TLS settings
#####################################################################
M_smtp_tls() {
    cp $PF_CD/smtp_tls_per_site /tmp/$$
    $M_EDITOR /tmp/$$

    echo 'Changed settings:'
    diff -wu /tmp/$$ $PF_CD/smtp_tls_per_site
    [ $? -eq 0 ] && return

    read -p 'Apply the changes [y/N] ? ' YN
    [ -z "$YN" ] && return
    [ "T${YN^^}" = 'TY' ] || return

    cat /tmp/$$ > $PF_CD/smtp_tls_per_site
    (cd $PF_CD; ./make; postfix reload)
    read -p 'Press <ENTER> to continue'
}

#####################################################################
# Renew self-signed certificate
#####################################################################
Renew_SSL_cert() {

    CreateSelfSignedCert.sh
    (cd $PF_CD; ./make; postfix reload)
    read -p 'Press <ENTER> to continue'
}

#####################################################################
# Manage ALL postfix settings
#####################################################################
M_main() {
    read -p 'This dangerous - are you sure you want to continue [y/N] ? ' YN
    [ -z "$YN" ] && return
    [ "T${YN^^}" = 'TY' ] || return

    cp $PF_CD/main.cf /tmp/$$
    $M_EDITOR /tmp/$$

    echo 'Changed settings:'
    diff -wu /tmp/$$ $PF_CD/main.cf
    [ $? -eq 0 ] && return

    read -p 'Apply the changes [y/N] ? ' YN
    [ -z "$YN" ] && return
    [ "T${YN^^}" = 'TY' ] || return

    cat /tmp/$$ > $PF_CD/main.cf
    (cd $PF_CD; ./make; postfix reload)
    read -p 'Press <ENTER> to continue'
}

#####################################################################
# Execute given option
#####################################################################
ExecOption() {
    UI=$1

    case $UI in
    0)     exit 0
           ;;
    11)    M_AddMX
           ;;
    12)    M_DelMX
           ;;
    13)    M_ListMX
           ;;
    21)    Renew_SSL_cert
           ;;
    22)    M_smtp_tls
           ;;
    31)    M_main
           ;;
    esac
}

#####################################################################
# Main loop
#####################################################################
# Create the "make" file in the postfix config directory
cat << EOT > $PF_CD/make
#!/bin/bash
cd $PF_CD
RELOAD=0
# Process databases
for DBF in \$(awk -F: '/hash:/ {print \$2}' main.cf | sed -e 's/,/ /g')
do
        [ -f \$DBF ] || touch \$DBF
        [ "T\$DBF" = 'T/etc/aliases' ] && continue
        if [ \$DBF -nt \${DBF}.db ]
        then
                postmap \$DBF
                RELOAD=\$((\$RELOAD + 1))
        fi
done
# Process aliases
if [ /etc/aliases -nt /etc/aliases.db ]
then
        postalias /etc/aliases
        RELOAD=\$((\$RELOAD + 1))
fi
[ \$RELOAD -gt 0 ] && postfix reload 2> /dev/null
# We are done
exit 0
EOT
chmod 755 $PF_CD/make

while [ 1 ]
do
    clear
    echo
    echo -e "      ${BLUE}MX Maintenance${NC}"
    echo
    echo -e "   ${CYAN}0${NC} - Exit program"
    echo
    echo -e "   ${CYAN}11${NC} - Add MX domain"
    echo -e "   ${CYAN}12${NC} - Delete MX domain"
    echo -e "   ${CYAN}13${NC} - List MX domains"
    echo
    echo -e "   ${CYAN}21${NC} - Renew self-signed SSL certificate"
    echo -e "   ${CYAN}22${NC} - Manage outbound encryption"
    echo
    echo -e "   ${CYAN}31${NC} - Manage ALL postfix settings"
    echo
    read -p '  Please select your choice : ' UI
    echo
    ExecOption $UI
done

# We are done
exit 0

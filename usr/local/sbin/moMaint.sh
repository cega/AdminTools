#!/bin/bash
################################################################
# (c) Copyright 2014 B-LUC Consulting and Thomas Bullinger
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
# Manage email clients
#####################################################################
M_mynetworks() {
    cp $PF_CD/mynetworks /tmp/$$
    $M_EDITOR /tmp/$$

    echo 'Changed settings:'
    diff -wu /tmp/$$ $PF_CD/mynetworks
    [ $? -eq 0 ] && return

    read -p 'Apply the changes [y/N] ? ' YN
    [ -z "$YN" ] && return
    [ "T${YN^^}" = 'TY' ] || return

    cat /tmp/$$ > $PF_CD/mynetworks
    (cd $PF_CD; ./make; postfix reload)
    read -p 'Press <ENTER> to continue'
}

#####################################################################
# Manage destination based mail routing
#####################################################################
M_transport() {
    cp $PF_CD/transport /tmp/$$
    $M_EDITOR /tmp/$$

    echo 'Changed settings:'
    diff -wu /tmp/$$ $PF_CD/transport
    [ $? -eq 0 ] && return

    read -p 'Apply the changes [y/N] ? ' YN
    [ -z "$YN" ] && return
    [ "T${YN^^}" = 'TY' ] || return

    cat /tmp/$$ > $PF_CD/transport
    (cd $PF_CD; ./make; postfix reload)
    read -p 'Press <ENTER> to continue'
}

#####################################################################
# Manage sender based mail routing
#####################################################################
M_sender_mail_routing() {
    cp $PF_CD/sender_mail_routing /tmp/$$
    $M_EDITOR /tmp/$$

    echo 'Changed settings:'
    diff -wu /tmp/$$ $PF_CD/sender_mail_routing
    [ $? -eq 0 ] && return

    read -p 'Apply the changes [y/N] ? ' YN
    [ -z "$YN" ] && return
    [ "T${YN^^}" = 'TY' ] || return

    cat /tmp/$$ > $PF_CD/sender_mail_routing
    (cd $PF_CD; ./make; postfix reload)
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
    1)     M_mynetworks
           ;;
    11)    M_transport
           ;;
    12)    M_sender_mail_routing
           ;;
    21)    M_smtp_tls
           ;;
    22)    Renew_SSL_cert
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
    echo -e "      ${BLUE}MailRelay Maintenance${NC}"
    echo
    echo -e "   ${CYAN}0${NC} - Exit program"
    echo
    echo -e "   ${CYAN}1${NC} - Manage email clients"
    echo
    echo -e "   ${CYAN}11${NC} - Manage destination based email routing" 
    echo -e "   ${CYAN}12${NC} - Manage source based email routing"
    echo
    echo -e "   ${CYAN}21${NC} - Manage outbound encryption"
    echo -e "   ${CYAN}22${NC} - Renew self-signed SSL certificate"
    echo
    echo -e "   ${CYAN}31${NC} - Manage ALL postfix settings"
    echo
    read -p '  Please select your choice : ' UI
    ExecOption $UI
done

# We are done
exit 0

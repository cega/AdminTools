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
DEBUG=''
[[ $- = *x* ]] && DEBUG='-x'

#--------------------------------------------------------------------
# This host and domain
THISHOST=$(hostname)
[[ $THISHOST = *.* ]] || THISHOST=$(hostname -f)
THISDOMAIN=${THISHOST#*.}

#--------------------------------------------------------------------
if [ ! -z "$DEBUG" -o "T$(date '+%-H %-M')" = "T4 40" ]
then
        # Check once a day or when running in debug mode
        if [ -d /etc/apache2 ]
        then
            NOW=$(date +%s)
            for CERT in $(grep -h -r '^[[:space:]]*SSLCertificateFile' /etc/apache2/* | awk '{print $2}' | sort -u)
            do
                if [ ! -s $CERT ]
                then
                    [ -z "$DEBUG" ] || echo "Apache SSL certificate '$CERT' does not exist"
                    logger -i -p err -t SSLCERT -- Apache SSL certificate "$CERT" does not exist
                    continue
                fi
                CERT_END=$(openssl x509 -in $CERT -enddate -noout | cut -d= -f2-)
                CERT_ED=$(date +%s -d "$CERT_END")
                if [ $(($NOW + 86400)) -gt $CERT_ED ]
                then
                    [ -z "$DEBUG" ] || echo "Apache SSL certificate '$CERT' expires in less than a day: $CERT_END"
                    logger -i -p crit -t SSLCERT -- Apache SSL certificate "$CERT" expires in less than a day: $CERT_END
                elif [ $(($NOW + 604800)) -gt $CERT_ED ]
                then
                    [ -z "$DEBUG" ] || echo "Apache SSL certificate '$CERT' expires in less than a week: $CERT_END"
                    logger -i -p err -t SSLCERT -- Apache SSL certificate "$CERT" expires in less than a week: $CERT_END
                elif [ $(($NOW + 2592000)) -gt $CERT_ED ]
                then
                    [ -z "$DEBUG" ] || echo "Apache SSL certificate '$CERT' expires in less than 30 days: $CERT_END"
                    logger -i -p warn -t SSLCERT -- Apache SSL certificate "$CERT" expires in less than 30 days: $CERT_END
                else
                    [ -z "$DEBUG" ] || echo "Apache SSL certificate '$CERT' is valid for more than 30 days: $CERT_END"
                    logger -i -p notice -t SSLCERT -- Apache SSL certificate "$CERT" is valid for more than 30 days: $CERT_END
                fi
            done
        fi
        if [ -d /etc/nginx ]
        then
            NOW=$(date +%s)
            for CERT in $(grep -h -r '^[[:space:]]*ssl_certificate ' /etc/nginx/* | awk '{sub(/;/,"",$2);print $2}' | sort -u)
            do
                if [ ! -s $CERT ]
                then
                    [ -z "$DEBUG" ] || echo "nginx SSL certificate '$CERT' does not exist"
                    logger -i -p err -t SSLCERT -- nginx SSL certificate "$CERT" does not exist
                    continue
                fi
                CERT_END=$(openssl x509 -in $CERT -enddate -noout | cut -d= -f2-)
                CERT_ED=$(date +%s -d "$CERT_END")
                if [ $(($NOW + 86400)) -gt $CERT_ED ]
                then
                    [ -z "$DEBUG" ] || echo "nginx SSL certificate '$CERT' expires in less than a day: $CERT_END"
                    logger -i -p crit -t SSLCERT -- nginx SSL certificate "$CERT" expires in less than a day: $CERT_END
                elif [ $(($NOW + 604800)) -gt $CERT_ED ]
                then
                    [ -z "$DEBUG" ] || echo "nginx SSL certificate '$CERT' expires in less than a week: $CERT_END"
                    logger -i -p err -t SSLCERT -- nginx SSL certificate "$CERT" expires in less than a week: $CERT_END
                elif [ $(($NOW + 2592000)) -gt $CERT_ED ]
                then
                    [ -z "$DEBUG" ] || echo "nginx SSL certificate '$CERT' expires in less than 30 days: $CERT_END"
                    logger -i -p warn -t SSLCERT -- nginx SSL certificate "$CERT" expires in less than 30 days: $CERT_END
                else
                    [ -z "$DEBUG" ] || echo "nginx SSL certificate '$CERT' is valid for more than 30 days: $CERT_END"
                    logger -i -p notice -t SSLCERT -- nginx SSL certificate "$CERT" is valid for more than 30 days: $CERT_END
                fi
            done
        fi
        if [ -x /usr/sbin/postconf ]
        then
            NOW=$(date +%s)
            for CERT in $(postconf -h smtpd_tls_cert_file)
            do
                if [ ! -s $CERT ]
                then
                    [ -z "$DEBUG" ] || echo "Postfix SSL certificate '$CERT' does not exist"
                    logger -i -p err -t SSLCERT -- Postfix SSL certificate "$CERT" does not exist
                    continue
                fi
                CERT_END=$(openssl x509 -in $CERT -enddate -noout | cut -d= -f2-)
                CERT_ED=$(date +%s -d "$CERT_END")
                if [ $(($NOW + 86400)) -gt $CERT_ED ]
                then
                    [ -z "$DEBUG" ] || echo "Postfix SSL certificate '$CERT' expires in less than a day: $CERT_END"
                    logger -i -p crit -t SSLCERT -- Postfix SSL certificate "$CERT" expires in less than a day: $CERT_END
                elif [ $(($NOW + 604800)) -gt $CERT_ED ]
                then
                    [ -z "$DEBUG" ] || echo "Postfix SSL certificate '$CERT' expires in less than a week: $CERT_END"
                    logger -i -p err -t SSLCERT -- Postfix SSL certificate "$CERT" expires in less than a week: $CERT_END
                elif [ $(($NOW + 2592000)) -gt $CERT_ED ]
                then
                    [ -z "$DEBUG" ] || echo "Postfix SSL certificate '$CERT' expires in less than 30 days: $CERT_END"
                    logger -i -p warn -t SSLCERT -- Postfix SSL certificate "$CERT" expires in less than 30 days: $CERT_END
                else
                    [ -z "$DEBUG" ] || echo "Postfix SSL certificate '$CERT' is valid for more than 30 days: $CERT_END"
                    logger -i -p notice -t SSLCERT -- Postfix SSL certificate "$CERT" is valid for more than 30 days: $CERT_END
                fi
            done
        fi
fi

#--------------------------------------------------------------------
# We are done
exit 0

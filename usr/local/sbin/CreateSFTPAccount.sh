#!/bin/bash
################################################################
# (c) Copyright 2016 B-LUC Consulting and Thomas Bullinger
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
# Based on http://www.thegeekstuff.com/2012/03/chroot-sftp-setup/

USERNAME=${1-guest}
USERPASS=$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c16)

#--------------------------------------------------------------------
# Setup sftp only account with chroot
groupadd sftpusers
useradd -g sftpusers -d /incoming -s /sbin/nologin $USERNAME
echo $USERNAME:$USERPASS | chpasswd

cat << EOT
The 'sftp-only' account '$USERNAME' is setup.
The password is '$USERPASS'.

EOT

#--------------------------------------------------------------------
# Create the correct sftp directory for the new user
mkdir -p /export/sftp/$USERNAME/incoming
chown $USERNAME:sftpusers /export/sftp/$USERNAME/incoming

#--------------------------------------------------------------------
# Instruct ssh to use the internal sftp server
RESTART_SSH=0
if [ ! -z "$(grep '/usr/lib/openssh/sftp-server' /etc/ssh/sshd_config)" ]
then
    sed -i -e 's/Subsystem sftp.*/Subsystem sftp internal-sftp/' /etc/ssh/sshd_config
    RESTART_SSH=1
fi
if [ -z "$(grep '^Match Group sftpusers' /etc/ssh/sshd_config)" ]
then
    cat << EOT >> /etc/ssh/sshd_config
Match Group sftpusers
  ChrootDirectory /export/sftp/%u
  ForceCommand internal-sftp
EOT
    RESTART_SSH=2
fi
[ $RESTART_SSH -ne 0 ] && service ssh restart

#--------------------------------------------------------------------
# We are done 
exit 0

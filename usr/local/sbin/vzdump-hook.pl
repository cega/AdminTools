#!/usr/bin/perl -w
#--------------------------------------------------------------------
# (c) CopyRight 2014 B-LUC Consulting and Thomas Bullinger
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
#--------------------------------------------------------------------
# Based on https://gist.githubusercontent.com/bitcloud/4ac52586334a2ddc54ff/raw/f282cad9032416d79fa9d1b9fe4b7ed6e0f87ec2/backup-hook.pl
# hook script for vzdump (--script option)

=begin comment

backuphook for Proxmox
Email the log file once it is available

=end comment

=cut

use 5.0010;

# Constants
my $ProgName = '';
( $ProgName = $0 ) =~ s%.*/%%;

# Common sense options:
use strict qw(vars subs);
no warnings;
use warnings qw(FATAL closed threads internal debugging pack
    portable prototype inplace io pipe unpack malloc
    glob digit printf layer reserved taint closure
    semicolon);
no warnings qw(exec newline unopened);

#--------------------------------------------------------------------
# Needed packages
#--------------------------------------------------------------------
use Sys::Hostname;
use Getopt::Std;
use Net::SMTP;

#--------------------------------------------------------------------
# Globals
#--------------------------------------------------------------------
$ENV{PATH} = '/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin';
# Show the date and all program arguments
my $RFC822Date = localtime;
print "HOOK: $RFC822Date " . join( ' ', @ARGV ) . "\n";

# Globals needed available different vzdump phases
my $phase    = shift;
my $mode     = shift;            # stop/suspend/snapshot
my $vmid     = shift;
my $vmtype   = $ENV{VMTYPE};     # openvz/qemu
my $dumpdir  = $ENV{DUMPDIR};
my $hostname = $ENV{HOSTNAME};
my $tarfile  = $ENV{TARFILE};
my $logfile  = $ENV{LOGFILE};

my $ThisHost = hostname;
unless ( $ThisHost =~ /\./ )
{

    if ( open( HOSTNAME, 'hostname -f |' ) )
    {
        $ThisHost = <HOSTNAME>;
        close(HOSTNAME);
        chomp($ThisHost);
    } ## end if ( open( HOSTNAME, 'hostname -f |'...))
} ## end unless ( $ThisHost =~ /\./...)

# SMTP parameters
my $SMTP_Host = 'localhost';
my $SMTP_To   = 'consult@btoy1.net';
my $SMTP_From = 'backup@btoy1.net';

# Other globals
my $ProgName = '';
( $ProgName = $0 ) =~ s%.*/%%;

my %dispatch = (
    'job-start'    => \&nop,
    'job-end'      => \&nop,
    'job-abort'    => \&nop,
    'backup-start' => \&nop,
    'backup-end'   => \&nop,
    'backup-abort' => \&nop,
    'log-end'      => \&log_end,
    'pre-stop'     => \&nop,
    'pre-restart'  => \&nop,
);

# Program options
our $opt_d = 0;

#-------------------------------------------------------------------------
# Send an email (simple SMTP client)
#-------------------------------------------------------------------------
sub SendEmail ($$)
{
    my ( $Subject, $MsgText ) = @_;
    warn "DBG: Sending email '$MsgText'\n" if ($opt_d);

    my $Try = 0;
    while ( $Try < 3 )
    {
        my $smtp = Net::SMTP->new( "$SMTP_Host", Debug => $opt_d );
        unless ( defined $smtp )
        {
            $Try++;
            next;
        } ## end unless ( defined $smtp )

        # The envelope
        my $res = $smtp->mail("$SMTP_From");
        unless ($res)
        {
            $Try++;
            next;
        } ## end unless ($res)
        $res = $smtp->to("$SMTP_To");
        unless ($res)
        {
            $Try++;
            next;
        } ## end unless ($res)

        # The real email
        $res = $smtp->data();
        unless ($res)
        {
            $Try++;
            next;
        } ## end unless ($res)

        # The email body
        my $Msg
            = "From: $SMTP_From\n"
            . "To: $SMTP_To\n"
            . "Subject: $Subject\n"
            . "Date: $RFC822Date\n"
            . "Mime-Version: 1.0\n"
            . "Comments: $ProgName $SMTP_Host\n"
            . "X-Mailer: $ProgName $SMTP_Host\n\n"
            . "$MsgText\n";

        $res = $smtp->datasend("$Msg");
        unless ($res)
        {
            $Try++;
            next;
        } ## end unless ($res)

        # End the SMTP session
        $res = $smtp->dataend();
        unless ($res)
        {
            $Try++;
            next;
        } ## end unless ($res)
        $res = $smtp->quit;
        unless ($res)
        {
            $Try++;
            next;
        } ## end unless ($res)
        last;
    } ## end while ( $Try < 3 )
    if ( $Try >= 3 )
    {

        # Could not open connection to mail server
        # (tried 3 times!)
        warn "critical %s %s Could not send email '%s'", POSIX::ctime(time),
            $SMTP_Host, $MsgText;
    } ## end if ( $Try >= 3 )
} ## end sub SendEmail ($$)

#-------------------------------------------------------------------------
# Do nothing
#-------------------------------------------------------------------------
sub nop
{

    # Do nothing
    return;
} ## end sub nop

#-------------------------------------------------------------------------
# Actions to be done when the logfile is present
#-------------------------------------------------------------------------
sub log_end
{

    # Get the contents of the log file
    my $LF;
    if ( open( $LF, '<', $logfile ) )
    {
        my @LogFileContents;
        while (<$LF>)
        {
            unless (/status: /o)
            {
                # Weed out status lines
                push( @LogFileContents, "$_" );
            } ## end unless (/status: /o)
        } ## end while (<$LF>)
        close($LF);

        # Email the log file to the specified recipient
        SendEmail( "vzdump backup log for '$vmid' ($hostname) on '$ThisHost'",
            join( "", @LogFileContents ) );
    } ## end if ( open( $LF, '<', $logfile...))
} ## end sub log_end

#-------------------------------------------------------------------------
# Main function
#-------------------------------------------------------------------------

# Run the correct function for the specified phase
exists $dispatch{$phase}
    ? $dispatch{$phase}()
    : die "ERROR: Got unknown phase '$phase'\n";

exit(0);
__END__

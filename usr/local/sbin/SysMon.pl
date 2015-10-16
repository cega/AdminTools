#!/usr/bin/perl -Tw
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
use 5.0010;

# Constants
my $ProgName = '';
( $ProgName = $0 ) =~ s%.*/%%;
my $CopyRight = "(c) CopyRight 2014 B-LUC Consulting Thomas Bullinger";

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
use Sys::Syslog qw(:macros :standard);
use Sys::Hostname;
use Net::SMTP;
use POSIX qw(setsid strftime);
use Getopt::Std;

#--------------------------------------------------------------------
# Globals
#--------------------------------------------------------------------
$ENV{PATH} = '/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin';

# Host to monitor
my $MHOST = hostname;
unless ( $MHOST =~ /\./ )
{
    if ( open( HOSTNAME, '-|', 'hostname -f' ) )
    {
        $MHOST = <HOSTNAME>;
        close(HOSTNAME);
        chomp($MHOST);
    } ## end if ( open( HOSTNAME, '-|'...))
} ## end unless ( $MHOST =~ /\./ )

# Program options
our $opt_a = '';
our $opt_d = 0;
our $opt_D = 0;
our $opt_h = 0;
our $opt_o = '';
our $opt_Q = '';
our $opt_s = 'syslog';

# These are in seconds:
our $opt_i = 5;
our $opt_I = 3 * 60;

# External programs
my $VMSTAT = '/usr/bin/vmstat';

# Other internal globals
my $CPUNo = 0;

# The running tallies from "vmstat"
# 1. for the standard logging interval
my $VMLNo_Interval       = 0;
my $RunQueue_Interval    = 0;
my $BlockedP_Interval    = 0;
my $PageIn_Interval      = 0;
my $CPUWait_Interval     = 0;
my %TXPrevBytes_Interval = ();
my %RXPrevBytes_Interval = ();
my %ReadBytes_Interval   = ();
my %WriteBytes_Interval  = ();
# 2. for the hourly report
my $VMLNo_Hourly       = 0;
my $RunQueue_Hourly    = 0;
my $BlockedP_Hourly    = 0;
my $PageIn_Hourly      = 0;
my $CPUWait_Hourly     = 0;
my %TXPrevBytes_Hourly = ();
my %RXPrevBytes_Hourly = ();
my %ReadBytes_Hourly   = ();
my %WriteBytes_Hourly  = ();
# 3. for the daily report
my $VMLNo_Daily       = 0;
my $RunQueue_Daily    = 0;
my $BlockedP_Daily    = 0;
my $PageIn_Daily      = 0;
my $CPUWait_Daily     = 0;
my %TXPrevBytes_Daily = ();
my %RXPrevBytes_Daily = ();
my %ReadBytes_Daily   = ();
my %WriteBytes_Daily  = ();

# The footer for the report
my $ReportTail = '';

# 'Quiet' hours
my @QuietHours = ();

#--------------------------------------------------------------------
# Become a daemon process
#--------------------------------------------------------------------
sub Daemonize()
{

    # pretty command line in ps
    $0 = join( ' ', $0, @ARGV ) unless ($opt_d);

    chdir '/' or die "Can't chdir to '/': $!";

    # Redirect STDIN and STDOUT
    open( STDIN,  '<', '/dev/null' ) or die "Can't read '/dev/null': $!";
    open( STDOUT, '>', '/dev/null' ) or die "Can't write '/dev/null': $!";
    defined( my $pid = fork ) or die "Can't fork: $!";

    if ($pid)
    {

        # The parent can die now
        print "DEBUG: Parent dies" if ($opt_d);
        exit;
    } ## end if ($pid)

    setsid or die "Can't start new session: $!";
    open STDERR, '>&STDOUT' or die "Can't duplicate stdout: $!";
} ## end sub Daemonize

#--------------------------------------------------------------------
# Commify a number
# See: http://www.perlmonks.org/index.pl?node_id=435729
#--------------------------------------------------------------------
sub commify
{
    my ( $sign, $int, $frac ) = ( $_[0] =~ /^([+-]?)(\d*)(.*)/ );
    my $commified
        = ( reverse scalar join ',', unpack '(A3)*', scalar reverse $int );
    return $sign . $commified . $frac;
} ## end sub commify

#-------------------------------------------------------------------------
# Send an alert email (simple SMTP client)
#-------------------------------------------------------------------------
sub SendEmail ($)
{
    my ($MsgText) = @_;

    my $Recipient = "$opt_a";
    $Recipient =~ s/@/\\@/g;
    warn "DBG: Sending email '$MsgText' to '$Recipient'\n" if ($opt_d);

    if ( scalar(@QuietHours) )
    {
        my ( undef, undef, $CurHour ) = localtime;
        # See http://www.perlmonks.org/?node_id=2482
        if ( exists { map { $_ => 1 } @QuietHours }->{$CurHour} )
        {
            # No email during 'quiet' hours
            syslog 5,
                "info %s %s Email sending supressed during quiet hour '%d'",
                POSIX::ctime(time), $MHOST, $CurHour;

            return;
        } ## end if ( exists { map { $_...}})
    } ## end if ( scalar(@QuietHours...))

    my $Try = 0;
    while ( $Try < 3 )
    {
        my $smtp = Net::SMTP->new( 'localhost', Debug => $opt_d );
        unless ( defined $smtp )
        {
            $Try++;
            next;
        } ## end unless ( defined $smtp )

        # The envelope
        my $res = $smtp->mail('root');
        unless ($res)
        {
            $Try++;
            next;
        } ## end unless ($res)
        $res = $smtp->to("$Recipient");
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
            = "From: root <root\@$MHOST>\n"
            . "To: $Recipient\n"
            . "Subject: SysMon alert on $MHOST\n"
            . "Date: "
            . localtime . "\n"
            . "Mime-Version: 1.0\n"
            . "X-Mailer: $ProgName $MHOST\n\n"
            . "The system monitoring script on the server '$MHOST' detected this potentially critical issue:\n"
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
        syslog 3,
            "critical %s %s Could not send email '%s'",
            POSIX::ctime(time), $MHOST, $MsgText;
    } ## end if ( $Try >= 3 )
} ## end sub SendEmail ($)

#--------------------------------------------------------------------
# Display the usage
#--------------------------------------------------------------------
sub ShowUsage()
{

    print "Usage: $ProgName [options]\n",
        "       -a address         Specify email address for alerts [default=none]\n",
        "       -o path            Specify path for '.csv' files [default=none]\n",
        "       -D                 Run as daemon [default=no]\n",
        "       -i seconds         Specify wait interval for vmstat in seconds [default=$opt_i]\n",
        "       -I seconds         Specify reporting interval in seconds [default=$opt_I]\n",
        "       -s path            Log to logfile [default=$opt_s]\n",
        "       -Q hour[,hour...]  Specifiy 'quiet' hour(s) [default=none]\n",
        "       -h                 Show this help [default=no]\n",
        "       -d                 Show some debug info on STDERR [default=no]\n\n",
        "       NOTES:\n",
        "        Alerts are disabled unless an email is specified\n",
        "        Alerts are not sent during 'quiet' hours\n",
        "        Alerting requires an email listener running on the local host\n",
        "        Alerts are sent for any of these conditions:\n",
        "          CPU usage is high (error)\n",
        "          I/O usage is high (error)\n",
        "          Memory usage is high (error)\n",
        "          A partition usage exceeds 75% percent (error)\n",
        "          A partition usage exceeds 85% percent (critical)\n\n",
        "        '.csv' files are only written if the path is given\n",
        "        If the path does not exist, no '.csv' is not written\n",
        "        There will be individual '.csv' files for data:\n",
        "          CPU, I/O, Memory, Disk, Partition\n",
        "          MySQL (if running on the local host)\n";

    exit 0;
} ## end sub ShowUsage

#--------------------------------------------------------------------
# Get some MySQL stats
# See http://ronaldbradford.com/blog/are-you-monitoring-rss-vsz-2009-03-08/
#--------------------------------------------------------------------
sub GetMysqldStats()
{
    my $RSS      = 0;
    my $VSZ      = 0;
    my $TotalRam = 0;
    if ( open( PSL, '-|', 'ps -o rss,vsz,command -C mysqld' ) )
    {
        while (<PSL>)
        {
            if (/(\d+)\s+(\d+).+\/mysqld/o)
            {
                $RSS = $1;
                $VSZ = $2;

                # Get the total memory on this server
                if ( open( MEM, '<', '/proc/meminfo' ) )
                {
                    while (<MEM>)
                    {
                        if (/^MemTotal:\s+(\d+)/o)
                        {
                            $TotalRam = $1;
                            last;
                        } ## end if (/^MemTotal:\s+(\d+)/o...)
                    } ## end while (<MEM>)
                    close(MEM);
                } ## end if ( open( MEM, '<', '/proc/meminfo'...))
                last;
            } ## end if (/(\d+)\s+(\d+).+\/mysqld/o...)
        } ## end while (<PSL>)
        close(PSL);
    } ## end if ( open( PSL, '-|', ...))
    if ($TotalRam)
    {
        # Calculate the percentage of total RAM
        my $RSS_percent = $RSS * 100 / $TotalRam;
        my $VSZ_percent = $VSZ * 100 / $TotalRam;
        return
            sprintf
            "Mysql resident memory = %s KB (%.f%%), virtual memory = %s KB (%.2f%%)",
            commify($RSS), $RSS_percent, commify($VSZ), $VSZ_percent;
    } else
    {
        # Show the absolute numbers
        return
            sprintf "Mysql resident memory = %s KB, virtual memory = %s KB",
            commify($RSS), commify($VSZ);
    } ## end else [ if ($TotalRam) ]
} ## end sub GetMysqldStats

#--------------------------------------------------------------------
# Log the report per specified interval
#--------------------------------------------------------------------
sub ReportInterval()
{
    my $Now = localtime;

    # Write a syslog entry with the correct severity
    my $Avg = $RunQueue_Interval / ( $VMLNo_Interval - 3 );
    my $Report
        = sprintf "Running process average (CPU usage) = %0.2f %s",
        $Avg,
        $ReportTail;
    if ($opt_o)
    {
        # Also write data into corresponding '.csv' file
        my ($outfile) = "$opt_o/CPU.csv" =~ /^([^\0]+)$/;
        if ( open( CSV, '>>', $outfile ) )
        {
            printf CSV '"' . "%s" . '"' . ",%0.2f\n", $Now, $Avg;
            close(CSV);
        } ## end if ( open( CSV, '>>', ...))
    } ## end if ($opt_o)
    if ( $Avg > ( ( $CPUNo + 1 ) * 2 ) )
    {
        $Report =~ s/HHMMLL/high/;
        if ( $opt_s eq 'syslog' )
        {
            syslog 3, "error %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": ERROR: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
        if ($opt_a)
        {
            # Also send an alert
            SendEmail("ERROR: $Report");
        } ## end if ($opt_a)
    } elsif ( $Avg > $CPUNo )
    {
        $Report =~ s/HHMMLL/medium/;
        if ( $opt_s eq 'syslog' )
        {
            syslog 4, "warning %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": WARNING: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
    } else
    {
        $Report =~ s/HHMMLL/low/;
        if ( $opt_s eq 'syslog' )
        {
            syslog 6, "info %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": INFO: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
    } ## end else [ if ( $Avg > ( ( $CPUNo...)))]
    warn "DEBUG: " . strftime( "%Y-%m-%d %H:%M:%S", localtime ) . " $Report"
        if ($opt_d);

    $Avg = $BlockedP_Interval / ( $VMLNo_Interval - 3 );
    $Report = sprintf "Blocked process average (I/O usage) = %0.2f %s",
        $Avg, $ReportTail;
    if ($opt_o)
    {
        # Also write data into corresponding '.csv' file
        my ($outfile) = "$opt_o/IO.csv" =~ /^([^\0]+)$/;
        if ( open( CSV, '>>', $outfile ) )
        {
            printf CSV '"' . "%s" . '"' . ",%0.2f\n", $Now, $Avg;
            close(CSV);
        } ## end if ( open( CSV, '>>', ...))
    } ## end if ($opt_o)
    if ( $Avg > ( ( $CPUNo + 1 ) * 2 ) )
    {
        $Report =~ s/HHMMLL/high/;
        if ( $opt_s eq 'syslog' )
        {
            syslog 3, "error %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": ERROR: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
        if ($opt_a)
        {
            # Also send an alert
            SendEmail("ERROR: $Report");
        } ## end if ($opt_a)
    } elsif ( $Avg > $CPUNo )
    {
        $Report =~ s/HHMMLL/medium/;
        if ( $opt_s eq 'syslog' )
        {
            syslog 4, "warning %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": WARNING: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
    } else
    {
        $Report =~ s/HHMMLL/low/;
        if ( $opt_s eq 'syslog' )
        {
            syslog 6, "info %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": INFO: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
    } ## end else [ if ( $Avg > ( ( $CPUNo...)))]
    warn "DEBUG: " . strftime( "%Y-%m-%d %H:%M:%S", localtime ) . " $Report"
        if ($opt_d);

    $Avg = $PageIn_Interval / ( $VMLNo_Interval - 3 );
    $Report = sprintf "Paged-in memory average (Mem usage) = %0.2f %s",
        $Avg, $ReportTail;
    if ($opt_o)
    {
        # Also write data into corresponding '.csv' file
        my ($outfile) = "$opt_o/Memory.csv" =~ /^([^\0]+)$/;
        if ( open( CSV, '>>', $outfile ) )
        {
            printf CSV '"' . "%s" . '"' . ",%0.2f\n", $Now, $Avg;
            close(CSV);
        } ## end if ( open( CSV, '>>', ...))
    } ## end if ($opt_o)
    if ( $Avg > 50 )
    {
        $Report =~ s/HHMMLL/high/;
        if ( $opt_s eq 'syslog' )
        {
            syslog 3, "error %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": ERROR: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
        if ($opt_a)
        {
            # Also send an alert
            SendEmail("ERROR: $Report");
        } ## end if ($opt_a)
    } elsif ( $Avg > 20 )
    {
        $Report =~ s/HHMMLL/medium/;
        if ( $opt_s eq 'syslog' )
        {
            syslog 4, "warning %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": WARNING: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
    } else
    {
        $Report =~ s/HHMMLL/low/;
        if ( $opt_s eq 'syslog' )
        {
            syslog 6, "info %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": INFO: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
    } ## end else [ if ( $Avg > 50 ) ]
    warn "DEBUG: " . strftime( "%Y-%m-%d %H:%M:%S", localtime ) . " $Report"
        if ($opt_d);

    #-------------------------------------------------
    # Also get partition infos
    if ( open( PARTINFO, '-|', "df -TP" ) )
    {
        while ( my $PartLine = <PARTINFO> )
        {
            chomp($PartLine);
            # We are only interested in ext2, ext3 and ext4 partitions
            next
                unless ( $PartLine
                =~ /^(\S+)\s+ext[2-4]\s+[0-9]+\s+[0-9]+\s+[0-9]+\s+([0-9]+)%\s+(\S+)/o
                );
            my $FileSystem = "$1";
            my $PercUsed   = $2;
            my $MountPoint = "$3";
            warn
                "DEBUG: FileSystem '$FileSystem' mounted on '$MountPoint' usage is $PercUsed%\n"
                if ($opt_d);
            if ($opt_o)
            {
                # Also write data into corresponding '.csv' file
                my $FileSystem_Sanitized = $FileSystem;
                $FileSystem_Sanitized =~ s@/@#@g;
                my ($outfile)
                    = "$opt_o/$FileSystem_Sanitized.csv" =~ /^([^\0]+)$/;
                if ( open( CSV, '>>', $outfile ) )
                {
                    printf CSV '"' . "%s" . '"' . ",%d\n", $Now, $PercUsed;
                    close(CSV);
                } ## end if ( open( CSV, '>>', ...))
            } ## end if ($opt_o)

            # Issue error/critical messages based on the percentage used
            if ( $PercUsed > 75 )
            {
                if ( $PercUsed > 85 )
                {
                    if ( $opt_s eq 'syslog' )
                    {
                        syslog 6,
                            "crit FileSystem '%s' mounted on '%s' usage is %d%%",
                            $FileSystem, $MountPoint, $PercUsed;
                    } else
                    {
                        print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                            ": CRITICAL: FileSystem '$FileSystem' mounted on '$MountPoint' usage is $PercUsed%\n";
                    } ## end else [ if ( $opt_s eq 'syslog'...)]
                    if ($opt_a)
                    {
                        # Also send an email alert
                        SendEmail(
                            "CRITICAL: FileSystem '$FileSystem' mounted on '$MountPoint' usage is $PercUsed%"
                        );
                    } ## end if ($opt_a)
                } else
                {
                    if ( $opt_s eq 'syslog' )
                    {
                        syslog 6,
                            "err FileSystem '%s' mounted on '%s' usage is %d%%",
                            $FileSystem, $MountPoint, $PercUsed;
                    } else
                    {
                        print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                            ": ERROR: FileSystem '$FileSystem' mounted on '$MountPoint' usage is $PercUsed%\n";
                    } ## end else [ if ( $opt_s eq 'syslog'...)]
                } ## end else [ if ( $PercUsed > 85 ) ]
                if ($opt_a)
                {
                    # Also send an email alert
                    SendEmail(
                        "ERROR: FileSystem '$FileSystem' mounted on '$MountPoint' usage is $PercUsed%"
                    );
                } ## end if ($opt_a)
            } else
            {
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6,
                        "info FileSystem '%s' mounted on '%s' usage is %d%%",
                        $FileSystem, $MountPoint, $PercUsed;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: FileSystem '$FileSystem' mounted on '$MountPoint' usage is $PercUsed%\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
            } ## end else [ if ( $PercUsed > 75 ) ]
        } ## end while ( my $PartLine = <PARTINFO>...)
        close(PARTINFO);
    } ## end if ( open( PARTINFO, '-|'...))

    #-------------------------------------------------
    # Also compute network interface errors and speeds
    if ( open( DEVSTAT, '<', '/proc/net/dev' ) )
    {
        while ( my $DEVLine = <DEVSTAT> )
        {
            next unless ( $DEVLine =~ /^\s*(\S+):\s*(.*)/o );
            my $IFName = "$1";
            my $IFData = "$2";
            next if ( $IFName eq 'lo' );
            chomp($IFData);

            warn "DEBUG: "
                . strftime( "%Y-%m-%d %H:%M:%S", localtime )
                . " $IFData"
                if ($opt_d);
            my ($RXbytes, $RXpkts,  $RXerr,   $RXdrop, $RXfifo, $RXframe,
                $RXcomp,  $RXmulti, $TXbytes, $TXpkts, $TXerr,  $TXdrop,
                $TXfifo,  $TXframe, $TXcomp,  $TXmulti
            ) = split( /\s+/, $IFData );
            warn "DEBUG: "
                . strftime( "%Y-%m-%d %H:%M:%S", localtime )
                . " $RXbytes, $RXpkts,  $RXerr,  $RXdrop, $RXfifo,  $RXframe, $RXcomp, $RXmulti,"
                . " $TXbytes, $TXpkts,  $TXerr,  $TXdrop, $TXfifo,  $TXframe, $TXcomp, $TXmulti"
                if ($opt_d);

            if ($opt_o)
            {
                # Also write data into corresponding '.csv' file
                my ($outfile) = "$opt_o/$IFName.csv" =~ /^([^\0]+)$/;
                if ( open( CSV, '>>', $outfile ) )
                {
                    printf CSV '"' . "%s" . '"'
                        . ",%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d\n",
                        $Now,    $RXbytes, $RXpkts, $RXerr,   $RXdrop,
                        $RXfifo, $RXframe, $RXcomp, $RXmulti, $TXbytes,
                        $TXpkts, $TXerr, $TXdrop, $TXfifo, $TXframe, $TXcomp,
                        $TXmulti;
                    close(CSV);
                } ## end if ( open( CSV, '>>', ...))
            } ## end if ($opt_o)

            my $RX_percent
                = ( $RXpkts > 0 )
                ? ( $RXerr + $RXdrop + $RXfifo + $RXcomp ) * 100 / $RXpkts
                : 0;
            $Report = sprintf "Receive errors for %s = %0.2f%% ",
                $IFName, $RX_percent;
            if ( $RX_percent < 0.3 )
            {
                $Report .= '(low)';
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
            } elsif ( $RX_percent < 1 )
            {
                $Report .= '(medium)';
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
            } else
            {
                $Report .= '(high)';
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
            } ## end else [ if ( $RX_percent < 0.3...)]
            warn "DEBUG: "
                . strftime( "%Y-%m-%d %H:%M:%S", localtime )
                . " $Report"
                if ($opt_d);

            # Calculate the receive speed
            if ( $RXPrevBytes_Interval{"$IFName"} )
            {
                my $Speed = 0;
                if ( $RXPrevBytes_Interval{"$IFName"} > $RXbytes )
                {

                    # Deal with the 4GB counter limitation of the Linux kernel
                    $Speed = (
                        (   ( 4294967296 - $RXPrevBytes_Interval{"$IFName"} )
                            + $RXbytes
                        ) / $opt_I
                    ) * 8;
                } else
                {
                    $Speed = ( ( $RXbytes - $RXPrevBytes_Interval{"$IFName"} )
                        / $opt_I ) * 8;
                } ## end else [ if ( $RXPrevBytes_Interval...)]
                $Report = sprintf "Receive speed for %s = %s bits/s ",
                    $IFName, commify( sprintf "%.2f", $Speed );
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
                warn "DEBUG: "
                    . strftime( "%Y-%m-%d %H:%M:%S", localtime )
                    . " $Report"
                    if ($opt_d);
            } ## end if ( $RXPrevBytes_Interval...)
            $RXPrevBytes_Interval{"$IFName"} = $RXbytes;

            my $TX_percent
                = ( $TXpkts > 0 )
                ? ( $TXerr + $TXdrop + $TXfifo + $TXcomp ) * 100 / $TXpkts
                : 0;
            $Report = sprintf "Transmit errors for %s = %0.2f%% ",
                $IFName, $TX_percent;
            if ( $TX_percent < 0.3 )
            {
                $Report .= '(low)';
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
            } elsif ( $TX_percent < 1 )
            {
                $Report .= '(medium)';
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
            } else
            {
                $Report .= '(high)';
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
            } ## end else [ if ( $TX_percent < 0.3...)]
            warn "DEBUG: "
                . strftime( "%Y-%m-%d %H:%M:%S", localtime )
                . " $Report"
                if ($opt_d);

            # Calculate the transmit speed
            if ( $TXPrevBytes_Interval{"$IFName"} )
            {
                my $Speed = 0;
                if ( $TXPrevBytes_Interval{"$IFName"} > $TXbytes )
                {

                    # Deal with the 4GB counter limitation of the Linux kernel
                    $Speed = (
                        (   ( 4294967296 - $TXPrevBytes_Interval{"$IFName"} )
                            + $TXbytes
                        ) / $opt_I
                    ) * 8;
                } else
                {
                    $Speed = ( ( $TXbytes - $TXPrevBytes_Interval{"$IFName"} )
                        / $opt_I ) * 8;
                } ## end else [ if ( $TXPrevBytes_Interval...)]
                $Report = sprintf "Transmit speed for %s = %s bits/s ",
                    $IFName, commify( sprintf "%.2f", $Speed );
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
                warn "DEBUG: "
                    . strftime( "%Y-%m-%d %H:%M:%S", localtime )
                    . " $Report"
                    if ($opt_d);
            } ## end if ( $TXPrevBytes_Interval...)
            $TXPrevBytes_Interval{"$IFName"} = $TXbytes;
        } ## end while ( my $DEVLine = <DEVSTAT>...)
        close(DEVSTAT);
    } ## end if ( open( DEVSTAT, '<'...))

    #-------------------------
    # Also compute disk speeds
    # See: http://ubuntuforums.org/showthread.php?t=31213
    if ( open( DEVSTAT, '<', '/proc/diskstats' ) )
    {
        while ( my $DEVLine = <DEVSTAT> )
        {
            # See: http://www.mjmwired.net/kernel/Documentation/iostats.txt

            my $DiskPart   = '';
            my $DiskReads  = 0;
            my $DiskWrites = 0;
            if ( $DEVLine
                =~ /^\s*\d+\s+\d+\s+([a-z]d[a-z]\d+)\s+\d+\s+\d+\s+(\d+)\s+\d+\s+\d+\s+\d+\s+(\d+)/o
                )
            {
                # [a-z]d[a-z][0-9], eg. sda1
                $DiskPart   = "$1";
                $DiskReads  = $2 * 512;
                $DiskWrites = $3 * 512;

            } elsif ( $DEVLine
                =~ /^\s*\d+\s+\d+\s+(dm\-\d+)\s+\d+\s+\d+\s+(\d+)\s+\d+\s+\d+\s+\d+\s+(\d+)/o
                )
            {
                # dm-[0-9], eg. dm-0
                $DiskPart   = "$1";
                $DiskReads  = $2 * 512;
                $DiskWrites = $3 * 512;
            } elsif ( $DEVLine
                =~ /^\s*\d+\s+\d+\s+(cciss\/c\dd\dp\d)\s+\d+\s+\d+\s+(\d+)\s+\d+\s+\d+\s+\d+\s+(\d+)/o
                )
            {
                # cciss/c?d?p?, eg. cciss/c0d0p1
                $DiskPart   = "$1";
                $DiskReads  = $2 * 512;
                $DiskWrites = $3 * 512;
            } ## end elsif ( $DEVLine =~ ...)

            # No need to continue if we don't have a disk partition
            next unless ( length($DiskPart) );

            warn "DEBUG: "
                . strftime( "%Y-%m-%d %H:%M:%S", localtime )
                . " $DiskPart $DiskReads $DiskWrites"
                if ($opt_d);
            if ($opt_o)
            {
                # Also write data into corresponding '.csv' file
                my ($outfile) = "$opt_o/$DiskPart.csv" =~ /^([^\0]+)$/;
                if ( open( CSV, '>>', $outfile ) )
                {
                    printf CSV '"' . "%s" . '"' . ",%d,%d\n", $Now,
                        $DiskReads, $DiskWrites;
                    close(CSV);
                } ## end if ( open( CSV, '>>', ...))
            } ## end if ($opt_o)

            # Calculate the read speed for the partition
            if ( $ReadBytes_Interval{"$DiskPart"} )
            {
                my $Speed = 0;
                if ( $ReadBytes_Interval{"$DiskPart"} > $DiskReads )
                {

                    # Deal with the 4GB counter limitation of the Linux kernel
                    $Speed
                        = ( ( 4294967296 - $ReadBytes_Interval{"$DiskPart"} )
                        + $DiskReads ) / $opt_I;
                } else
                {
                    $Speed = ( $DiskReads - $ReadBytes_Interval{"$DiskPart"} )
                        / $opt_I;
                } ## end else [ if ( $ReadBytes_Interval...)]
                $Report = sprintf "Disk read speed for %s = %s bytes/s ",
                    $DiskPart, commify( sprintf "%.2f", $Speed );
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
                warn "DEBUG: "
                    . strftime( "%Y-%m-%d %H:%M:%S", localtime )
                    . " $Report"
                    if ($opt_d);
            } ## end if ( $ReadBytes_Interval...)
            $ReadBytes_Interval{"$DiskPart"} = $DiskReads;

            # Calculate the write speed for the partition
            if ( $WriteBytes_Interval{"$DiskPart"} )
            {
                my $Speed = 0;
                if ( $WriteBytes_Interval{"$DiskPart"} > $DiskWrites )
                {

                    # Deal with the 4GB counter limitation of the Linux kernel
                    $Speed
                        = ( ( 4294967296 - $WriteBytes_Interval{"$DiskPart"} )
                        + $DiskWrites ) / $opt_I;
                } else
                {
                    $Speed
                        = ( $DiskWrites - $WriteBytes_Interval{"$DiskPart"} )
                        / $opt_I;
                } ## end else [ if ( $WriteBytes_Interval...)]
                $Report = sprintf "Disk write speed for %s = %s bytes/s ",
                    $DiskPart, commify( sprintf "%.2f", $Speed );
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
                warn "DEBUG: "
                    . strftime( "%Y-%m-%d %H:%M:%S", localtime )
                    . " $Report"
                    if ($opt_d);
            } ## end if ( $WriteBytes_Interval...)
            $WriteBytes_Interval{"$DiskPart"} = $DiskWrites;
        } ## end while ( my $DEVLine = <DEVSTAT>...)
        close(DEVSTAT);
    } ## end if ( open( DEVSTAT, '<'...))

    unless ( system('pgrep mysqld > /dev/null 2>&1') )
    {
        $Report = GetMysqldStats();
        if ( $opt_s eq 'syslog' )
        {
            syslog 6, "info %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": INFO: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
        warn "DEBUG: "
            . strftime( "%Y-%m-%d %H:%M:%S", localtime )
            . " $Report"
            if ($opt_d);
        if ($opt_o)
        {
            # Also write data into corresponding '.csv' file
            my ($outfile) = "$opt_o/MySQL.csv" =~ /^([^\0]+)$/;
            if ( open( CSV, '>>', $outfile ) )
            {
                printf CSV '"' . "%s" . '"' . "\n", $Now;
                close(CSV);
            } ## end if ( open( CSV, '>>', ...))
        } ## end if ($opt_o)
    } ## end unless ( system('pgrep mysqld > /dev/null 2>&1'...))

    # Start the next reporting cycle
    $VMLNo_Interval    = 3;
    $RunQueue_Interval = 0;
    $BlockedP_Interval = 0;
    $PageIn_Interval   = 0;
    $CPUWait_Interval  = 0;
} ## end sub ReportInterval

#--------------------------------------------------------------------
# Create an hourly report
#--------------------------------------------------------------------
sub ReportHourly()
{
    # Write a syslog entry with the correct severity
    my $Avg = $RunQueue_Hourly / ( $VMLNo_Hourly - 3 );
    my $Report
        = sprintf "HOURLY: Running process average (CPU usage) = %0.2f %s",
        $Avg,
        $ReportTail;
    if ( $Avg > ( ( $CPUNo + 1 ) * 2 ) )
    {
        $Report =~ s/HHMMLL/high/;
        if ( $opt_s eq 'syslog' )
        {
            syslog 3, "error %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": ERROR: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
    } elsif ( $Avg > $CPUNo )
    {
        $Report =~ s/HHMMLL/medium/;
        if ( $opt_s eq 'syslog' )
        {
            syslog 4, "warning %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": WARNING: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
    } else
    {
        $Report =~ s/HHMMLL/low/;
        if ( $opt_s eq 'syslog' )
        {
            syslog 6, "info %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": INFO: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
    } ## end else [ if ( $Avg > ( ( $CPUNo...)))]
    warn "DEBUG: " . strftime( "%Y-%m-%d %H:%M:%S", localtime ) . " $Report"
        if ($opt_d);

    $Avg = $BlockedP_Hourly / ( $VMLNo_Hourly - 3 );
    $Report
        = sprintf "HOURLY: Blocked process average (I/O usage) = %0.2f %s",
        $Avg, $ReportTail;
    if ( $Avg > ( ( $CPUNo + 1 ) * 2 ) )
    {
        $Report =~ s/HHMMLL/high/;
        if ( $opt_s eq 'syslog' )
        {
            syslog 3, "error %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": ERROR: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
    } elsif ( $Avg > $CPUNo )
    {
        $Report =~ s/HHMMLL/medium/;
        if ( $opt_s eq 'syslog' )
        {
            syslog 4, "warning %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": WARNING: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
    } else
    {
        $Report =~ s/HHMMLL/low/;
        if ( $opt_s eq 'syslog' )
        {
            syslog 6, "info %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": INFO: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
    } ## end else [ if ( $Avg > ( ( $CPUNo...)))]
    warn "DEBUG: " . strftime( "%Y-%m-%d %H:%M:%S", localtime ) . " $Report"
        if ($opt_d);

    $Avg = $PageIn_Hourly / ( $VMLNo_Hourly - 3 );
    $Report
        = sprintf "HOURLY: Paged-in memory average (Mem usage) = %0.2f %s",
        $Avg, $ReportTail;
    if ( $Avg > 50 )
    {
        $Report =~ s/HHMMLL/high/;
        if ( $opt_s eq 'syslog' )
        {
            syslog 3, "error %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": ERROR: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
    } elsif ( $Avg > 20 )
    {
        $Report =~ s/HHMMLL/medium/;
        if ( $opt_s eq 'syslog' )
        {
            syslog 4, "warning %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": WARNING: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
    } else
    {
        $Report =~ s/HHMMLL/low/;
        if ( $opt_s eq 'syslog' )
        {
            syslog 6, "info %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": INFO: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
    } ## end else [ if ( $Avg > 50 ) ]
    warn "DEBUG: " . strftime( "%Y-%m-%d %H:%M:%S", localtime ) . " $Report"
        if ($opt_d);

    #-------------------------------------------------
    # Also compute network interface errors and speeds
    if ( open( DEVSTAT, '<', '/proc/net/dev' ) )
    {
        while ( my $DEVLine = <DEVSTAT> )
        {
            next unless ( $DEVLine =~ /^\s*(\S+):\s*(.*)/o );
            my $IFName = "$1";
            my $IFData = "$2";
            next if ( $IFName eq 'lo' );
            chomp($IFData);

            warn "DEBUG: "
                . strftime( "%Y-%m-%d %H:%M:%S", localtime )
                . " $IFData"
                if ($opt_d);
            my ($RXbytes, $RXpkts,  $RXerr,   $RXdrop, $RXfifo, $RXframe,
                $RXcomp,  $RXmulti, $TXbytes, $TXpkts, $TXerr,  $TXdrop,
                $TXfifo,  $TXframe, $TXcomp,  $TXmulti
            ) = split( /\s+/, $IFData );
            warn "DEBUG: "
                . strftime( "%Y-%m-%d %H:%M:%S", localtime )
                . " $RXbytes, $RXpkts,  $RXerr,  $RXdrop, $RXfifo,  $RXframe, $RXcomp, $RXmulti,"
                . " $TXbytes, $TXpkts,  $TXerr,  $TXdrop, $TXfifo,  $TXframe, $TXcomp, $TXmulti"
                if ($opt_d);

            my $RX_percent
                = ( $RXpkts > 0 )
                ? ( $RXerr + $RXdrop + $RXfifo + $RXcomp ) * 100 / $RXpkts
                : 0;
            $Report = sprintf "HOURLY: Receive errors for %s = %0.2f%% ",
                $IFName, $RX_percent;
            if ( $RX_percent < 0.3 )
            {
                $Report .= '(low)';
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
            } elsif ( $RX_percent < 1 )
            {
                $Report .= '(medium)';
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
            } else
            {
                $Report .= '(high)';
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
            } ## end else [ if ( $RX_percent < 0.3...)]
            warn "DEBUG: "
                . strftime( "%Y-%m-%d %H:%M:%S", localtime )
                . " $Report"
                if ($opt_d);

            # Calculate the receive speed
            if ( $RXPrevBytes_Hourly{"$IFName"} )
            {
                my $Speed = 0;
                if ( $RXPrevBytes_Hourly{"$IFName"} > $RXbytes )
                {

                    # Deal with the 4GB counter limitation of the Linux kernel
                    $Speed = (
                        (   ( 4294967296 - $RXPrevBytes_Hourly{"$IFName"} )
                            + $RXbytes
                        ) / $opt_I
                    ) * 8;
                } else
                {
                    $Speed
                        = (
                        ( $RXbytes - $RXPrevBytes_Hourly{"$IFName"} ) / 3600 )
                        * 8;
                } ## end else [ if ( $RXPrevBytes_Hourly...)]
                $Report = sprintf "HOURLY: Receive speed for %s = %s bits/s ",
                    $IFName, commify( sprintf "%.2f", $Speed );
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
                warn "DEBUG: "
                    . strftime( "%Y-%m-%d %H:%M:%S", localtime )
                    . " $Report"
                    if ($opt_d);
            } ## end if ( $RXPrevBytes_Hourly...)
            $RXPrevBytes_Hourly{"$IFName"} = $RXbytes;

            my $TX_percent
                = ( $TXpkts > 0 )
                ? ( $TXerr + $TXdrop + $TXfifo + $TXcomp ) * 100 / $TXpkts
                : 0;
            $Report = sprintf "HOURLY: Transmit errors for %s = %0.2f%% ",
                $IFName, $TX_percent;
            if ( $TX_percent < 0.3 )
            {
                $Report .= '(low)';
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
            } elsif ( $TX_percent < 1 )
            {
                $Report .= '(medium)';
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
            } else
            {
                $Report .= '(high)';
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
            } ## end else [ if ( $TX_percent < 0.3...)]
            warn "DEBUG: "
                . strftime( "%Y-%m-%d %H:%M:%S", localtime )
                . " $Report"
                if ($opt_d);

            # Calculate the transmit speed
            if ( $TXPrevBytes_Hourly{"$IFName"} )
            {
                my $Speed = 0;
                if ( $TXPrevBytes_Hourly{"$IFName"} > $TXbytes )
                {

                    # Deal with the 4GB counter limitation of the Linux kernel
                    $Speed = (
                        (   ( 4294967296 - $TXPrevBytes_Hourly{"$IFName"} )
                            + $TXbytes
                        ) / $opt_I
                    ) * 8;
                } else
                {
                    $Speed
                        = (
                        ( $TXbytes - $TXPrevBytes_Hourly{"$IFName"} ) / 3600 )
                        * 8;
                } ## end else [ if ( $TXPrevBytes_Hourly...)]
                $Report
                    = sprintf "HOURLY: Transmit speed for %s = %s bits/s ",
                    $IFName, commify( sprintf "%.2f", $Speed );
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
                warn "DEBUG: "
                    . strftime( "%Y-%m-%d %H:%M:%S", localtime )
                    . " $Report"
                    if ($opt_d);
            } ## end if ( $TXPrevBytes_Hourly...)
            $TXPrevBytes_Hourly{"$IFName"} = $TXbytes;
        } ## end while ( my $DEVLine = <DEVSTAT>...)
        close(DEVSTAT);
    } ## end if ( open( DEVSTAT, '<'...))

    #-------------------------
    # Also compute disk speeds
    # See: http://ubuntuforums.org/showthread.php?t=31213
    if ( open( DEVSTAT, '<', '/proc/diskstats' ) )
    {
        while ( my $DEVLine = <DEVSTAT> )
        {
            # See: http://www.mjmwired.net/kernel/Documentation/iostats.txt

            my $DiskPart   = '';
            my $DiskReads  = 0;
            my $DiskWrites = 0;
            if ( $DEVLine
                =~ /^\s*\d+\s+\d+\s+([a-z]d[a-z]\d+)\s+\d+\s+\d+\s+(\d+)\s+\d+\s+\d+\s+\d+\s+(\d+)/o
                )
            {
                # [a-z]d[a-z][0-9], eg. sda1
                $DiskPart   = "$1";
                $DiskReads  = $2 * 512;
                $DiskWrites = $3 * 512;

            } elsif ( $DEVLine
                =~ /^\s*\d+\s+\d+\s+(dm\-\d+)\s+\d+\s+\d+\s+(\d+)\s+\d+\s+\d+\s+\d+\s+(\d+)/o
                )
            {
                # dm-[0-9], eg. dm-0
                $DiskPart   = "$1";
                $DiskReads  = $2 * 512;
                $DiskWrites = $3 * 512;
            } ## end elsif ( $DEVLine =~ ...)

            # No need to continue if we don't have a disk partition
            next unless ( length($DiskPart) );

            warn "DEBUG: "
                . strftime( "%Y-%m-%d %H:%M:%S", localtime )
                . " $DiskPart $DiskReads $DiskWrites"
                if ($opt_d);

            # Calculate the read speed for the partition
            if ( $ReadBytes_Hourly{"$DiskPart"} )
            {
                my $Speed = 0;
                if ( $ReadBytes_Hourly{"$DiskPart"} > $DiskReads )
                {

                    # Deal with the 4GB counter limitation of the Linux kernel
                    $Speed = ( ( 4294967296 - $ReadBytes_Hourly{"$DiskPart"} )
                        + $DiskReads ) / $opt_I;
                } else
                {
                    $Speed = ( $DiskReads - $ReadBytes_Hourly{"$DiskPart"} )
                        / 3600;
                } ## end else [ if ( $ReadBytes_Hourly...)]
                $Report
                    = sprintf "HOURLY: Disk read speed for %s = %s bytes/s ",
                    $DiskPart, commify( sprintf "%.2f", $Speed );
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
                warn "DEBUG: "
                    . strftime( "%Y-%m-%d %H:%M:%S", localtime )
                    . " $Report"
                    if ($opt_d);
            } ## end if ( $ReadBytes_Hourly...)
            $ReadBytes_Hourly{"$DiskPart"} = $DiskReads;

            # Calculate the write speed for the partition
            if ( $WriteBytes_Hourly{"$DiskPart"} )
            {
                my $Speed = 0;
                if ( $WriteBytes_Hourly{"$DiskPart"} > $DiskWrites )
                {

                    # Deal with the 4GB counter limitation of the Linux kernel
                    $Speed
                        = ( ( 4294967296 - $WriteBytes_Hourly{"$DiskPart"} )
                        + $DiskWrites ) / $opt_I;
                } else
                {
                    $Speed = ( $DiskWrites - $WriteBytes_Hourly{"$DiskPart"} )
                        / 3600;
                } ## end else [ if ( $WriteBytes_Hourly...)]
                $Report
                    = sprintf "HOURLY: Disk write speed for %s = %s bytes/s ",
                    $DiskPart, commify( sprintf "%.2f", $Speed );
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
                warn "DEBUG: "
                    . strftime( "%Y-%m-%d %H:%M:%S", localtime )
                    . " $Report"
                    if ($opt_d);
            } ## end if ( $WriteBytes_Hourly...)
            $WriteBytes_Hourly{"$DiskPart"} = $DiskWrites;
        } ## end while ( my $DEVLine = <DEVSTAT>...)
        close(DEVSTAT);
    } ## end if ( open( DEVSTAT, '<'...))

    unless ( system('pgrep mysqld > /dev/null 2>&1') )
    {
        $Report = GetMysqldStats();
        if ( $opt_s eq 'syslog' )
        {
            syslog 6, "info HOURLY: %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": INFO: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
        warn "DEBUG: "
            . strftime( "%Y-%m-%d %H:%M:%S", localtime )
            . " $Report"
            if ($opt_d);
    } ## end unless ( system('pgrep mysqld > /dev/null 2>&1'...))
        # Start the next reporting cycle
    $VMLNo_Hourly    = 3;
    $RunQueue_Hourly = 0;
    $BlockedP_Hourly = 0;
    $PageIn_Hourly   = 0;
    $CPUWait_Hourly  = 0;
} ## end sub ReportHourly

#--------------------------------------------------------------------
# Create a daily report
#--------------------------------------------------------------------
sub ReportDaily()
{
    # Write a syslog entry with the correct severity
    my $Avg = $RunQueue_Daily / ( $VMLNo_Daily - 3 );
    my $Report
        = sprintf "DAILY: Running process average (CPU usage) = %0.2f %s",
        $Avg,
        $ReportTail;
    if ( $Avg > ( ( $CPUNo + 1 ) * 2 ) )
    {
        $Report =~ s/HHMMLL/high/;
        if ( $opt_s eq 'syslog' )
        {
            syslog 3, "error %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": ERROR: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
    } elsif ( $Avg > $CPUNo )
    {
        $Report =~ s/HHMMLL/medium/;
        if ( $opt_s eq 'syslog' )
        {
            syslog 4, "warning %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": WARNING: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
    } else
    {
        $Report =~ s/HHMMLL/low/;
        if ( $opt_s eq 'syslog' )
        {
            syslog 6, "info %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": INFO: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
    } ## end else [ if ( $Avg > ( ( $CPUNo...)))]
    warn "DEBUG: " . strftime( "%Y-%m-%d %H:%M:%S", localtime ) . " $Report"
        if ($opt_d);

    $Avg = $BlockedP_Daily / ( $VMLNo_Daily - 3 );
    $Report = sprintf "DAILY: Blocked process average (I/O usage) = %0.2f %s",
        $Avg, $ReportTail;
    if ( $Avg > ( ( $CPUNo + 1 ) * 2 ) )
    {
        $Report =~ s/HHMMLL/high/;
        if ( $opt_s eq 'syslog' )
        {
            syslog 3, "error %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": ERROR: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
    } elsif ( $Avg > $CPUNo )
    {
        $Report =~ s/HHMMLL/medium/;
        if ( $opt_s eq 'syslog' )
        {
            syslog 4, "warning %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": WARNING: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
    } else
    {
        $Report =~ s/HHMMLL/low/;
        if ( $opt_s eq 'syslog' )
        {
            syslog 6, "info %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": INFO: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
    } ## end else [ if ( $Avg > ( ( $CPUNo...)))]
    warn "DEBUG: " . strftime( "%Y-%m-%d %H:%M:%S", localtime ) . " $Report"
        if ($opt_d);

    $Avg = $PageIn_Daily / ( $VMLNo_Daily - 3 );
    $Report = sprintf "DAILY: Paged-in memory average (Mem usage) = %0.2f %s",
        $Avg, $ReportTail;
    if ( $Avg > 50 )
    {
        $Report =~ s/HHMMLL/high/;
        if ( $opt_s eq 'syslog' )
        {
            syslog 3, "error %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": ERROR: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
    } elsif ( $Avg > 20 )
    {
        $Report =~ s/HHMMLL/medium/;
        if ( $opt_s eq 'syslog' )
        {
            syslog 4, "warning %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": WARNING: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
    } else
    {
        $Report =~ s/HHMMLL/low/;
        if ( $opt_s eq 'syslog' )
        {
            syslog 6, "info %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": INFO: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
    } ## end else [ if ( $Avg > 50 ) ]
    warn "DEBUG: " . strftime( "%Y-%m-%d %H:%M:%S", localtime ) . " $Report"
        if ($opt_d);

    #-------------------------------------------------
    # Also compute network interface errors and speeds
    if ( open( DEVSTAT, '<', '/proc/net/dev' ) )
    {
        while ( my $DEVLine = <DEVSTAT> )
        {
            next unless ( $DEVLine =~ /^\s*(\S+):\s*(.*)/o );
            my $IFName = "$1";
            my $IFData = "$2";
            next if ( $IFName eq 'lo' );
            chomp($IFData);

            warn "DEBUG: "
                . strftime( "%Y-%m-%d %H:%M:%S", localtime )
                . " $IFData"
                if ($opt_d);
            my ($RXbytes, $RXpkts,  $RXerr,   $RXdrop, $RXfifo, $RXframe,
                $RXcomp,  $RXmulti, $TXbytes, $TXpkts, $TXerr,  $TXdrop,
                $TXfifo,  $TXframe, $TXcomp,  $TXmulti
            ) = split( /\s+/, $IFData );
            warn "DEBUG: "
                . strftime( "%Y-%m-%d %H:%M:%S", localtime )
                . " $RXbytes, $RXpkts,  $RXerr,  $RXdrop, $RXfifo,  $RXframe, $RXcomp, $RXmulti,"
                . " $TXbytes, $TXpkts,  $TXerr,  $TXdrop, $TXfifo,  $TXframe, $TXcomp, $TXmulti"
                if ($opt_d);

            my $RX_percent
                = ( $RXpkts > 0 )
                ? ( $RXerr + $RXdrop + $RXfifo + $RXcomp ) * 100 / $RXpkts
                : 0;
            $Report = sprintf "DAILY: Receive errors for %s = %0.2f%% ",
                $IFName, $RX_percent;
            if ( $RX_percent < 0.3 )
            {
                $Report .= '(low)';
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
            } elsif ( $RX_percent < 1 )
            {
                $Report .= '(medium)';
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
            } else
            {
                $Report .= '(high)';
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
            } ## end else [ if ( $RX_percent < 0.3...)]
            warn "DEBUG: "
                . strftime( "%Y-%m-%d %H:%M:%S", localtime )
                . " $Report"
                if ($opt_d);

            # Calculate the receive speed
            if ( $RXPrevBytes_Daily{"$IFName"} )
            {
                my $Speed = 0;
                if ( $RXPrevBytes_Daily{"$IFName"} > $RXbytes )
                {

                    # Deal with the 4GB counter limitation of the Linux kernel
                    $Speed = (
                        (   ( 4294967296 - $RXPrevBytes_Daily{"$IFName"} )
                            + $RXbytes
                        ) / $opt_I
                    ) * 8;
                } else
                {
                    $Speed
                        = (
                        ( $RXbytes - $RXPrevBytes_Daily{"$IFName"} ) / 86400 )
                        * 8;
                } ## end else [ if ( $RXPrevBytes_Daily...)]
                $Report = sprintf "DAILY: Receive speed for %s = %s bits/s ",
                    $IFName, commify( sprintf "%.2f", $Speed );
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
                warn "DEBUG: "
                    . strftime( "%Y-%m-%d %H:%M:%S", localtime )
                    . " $Report"
                    if ($opt_d);
            } ## end if ( $RXPrevBytes_Daily...)
            $RXPrevBytes_Daily{"$IFName"} = $RXbytes;

            my $TX_percent
                = ( $TXpkts > 0 )
                ? ( $TXerr + $TXdrop + $TXfifo + $TXcomp ) * 100 / $TXpkts
                : 0;
            $Report = sprintf "DAILY: Transmit errors for %s = %0.2f%% ",
                $IFName, $TX_percent;
            if ( $TX_percent < 0.3 )
            {
                $Report .= '(low)';
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
            } elsif ( $TX_percent < 1 )
            {
                $Report .= '(medium)';
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
            } else
            {
                $Report .= '(high)';
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
            } ## end else [ if ( $TX_percent < 0.3...)]
            warn "DEBUG: "
                . strftime( "%Y-%m-%d %H:%M:%S", localtime )
                . " $Report"
                if ($opt_d);

            # Calculate the transmit speed
            if ( $TXPrevBytes_Daily{"$IFName"} )
            {
                my $Speed = 0;
                if ( $TXPrevBytes_Daily{"$IFName"} > $TXbytes )
                {

                    # Deal with the 4GB counter limitation of the Linux kernel
                    $Speed = (
                        (   ( 4294967296 - $TXPrevBytes_Daily{"$IFName"} )
                            + $TXbytes
                        ) / $opt_I
                    ) * 8;
                } else
                {
                    $Speed
                        = (
                        ( $TXbytes - $TXPrevBytes_Daily{"$IFName"} ) / 86400 )
                        * 8;
                } ## end else [ if ( $TXPrevBytes_Daily...)]
                $Report = sprintf "DAILY: Transmit speed for %s = %s bits/s ",
                    $IFName, commify( sprintf "%.2f", $Speed );
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
                warn "DEBUG: "
                    . strftime( "%Y-%m-%d %H:%M:%S", localtime )
                    . " $Report"
                    if ($opt_d);
            } ## end if ( $TXPrevBytes_Daily...)
            $TXPrevBytes_Daily{"$IFName"} = $TXbytes;
        } ## end while ( my $DEVLine = <DEVSTAT>...)
        close(DEVSTAT);
    } ## end if ( open( DEVSTAT, '<'...))

    #-------------------------
    # Also compute disk speeds
    # See: http://ubuntuforums.org/showthread.php?t=31213
    if ( open( DEVSTAT, '<', '/proc/diskstats' ) )
    {
        while ( my $DEVLine = <DEVSTAT> )
        {
            # See: http://www.mjmwired.net/kernel/Documentation/iostats.txt

            my $DiskPart   = '';
            my $DiskReads  = 0;
            my $DiskWrites = 0;
            if ( $DEVLine
                =~ /^\s*\d+\s+\d+\s+([a-z]d[a-z]\d+)\s+\d+\s+\d+\s+(\d+)\s+\d+\s+\d+\s+\d+\s+(\d+)/o
                )
            {
                # [a-z]d[a-z][0-9], eg. sda1
                $DiskPart   = "$1";
                $DiskReads  = $2 * 512;
                $DiskWrites = $3 * 512;

            } elsif ( $DEVLine
                =~ /^\s*\d+\s+\d+\s+(dm\-\d+)\s+\d+\s+\d+\s+(\d+)\s+\d+\s+\d+\s+\d+\s+(\d+)/o
                )
            {
                # dm-[0-9], eg. dm-0
                $DiskPart   = "$1";
                $DiskReads  = $2 * 512;
                $DiskWrites = $3 * 512;
            } ## end elsif ( $DEVLine =~ ...)

            # No need to continue if we don't have a disk partition
            next unless ( length($DiskPart) );

            warn "DEBUG: "
                . strftime( "%Y-%m-%d %H:%M:%S", localtime )
                . " $DiskPart $DiskReads $DiskWrites"
                if ($opt_d);

            # Calculate the read speed for the partition
            if ( $ReadBytes_Daily{"$DiskPart"} )
            {
                my $Speed = 0;
                if ( $ReadBytes_Daily{"$DiskPart"} > $DiskReads )
                {

                    # Deal with the 4GB counter limitation of the Linux kernel
                    $Speed = ( ( 4294967296 - $ReadBytes_Daily{"$DiskPart"} )
                        + $DiskReads ) / $opt_I;
                } else
                {
                    $Speed = ( $DiskReads - $ReadBytes_Daily{"$DiskPart"} )
                        / 86400;
                } ## end else [ if ( $ReadBytes_Daily{...})]
                $Report
                    = sprintf "DAILY: Disk read speed for %s = %s bytes/s ",
                    $DiskPart, commify( sprintf "%.2f", $Speed );
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
                warn "DEBUG: "
                    . strftime( "%Y-%m-%d %H:%M:%S", localtime )
                    . " $Report"
                    if ($opt_d);
            } ## end if ( $ReadBytes_Daily{...})
            $ReadBytes_Daily{"$DiskPart"} = $DiskReads;

            # Calculate the write speed for the partition
            if ( $WriteBytes_Daily{"$DiskPart"} )
            {
                my $Speed = 0;
                if ( $WriteBytes_Daily{"$DiskPart"} > $DiskWrites )
                {

                    # Deal with the 4GB counter limitation of the Linux kernel
                    $Speed = ( ( 4294967296 - $WriteBytes_Daily{"$DiskPart"} )
                        + $DiskWrites ) / $opt_I;
                } else
                {
                    $Speed = ( $DiskWrites - $WriteBytes_Daily{"$DiskPart"} )
                        / 86400;
                } ## end else [ if ( $WriteBytes_Daily...)]
                $Report
                    = sprintf "DAILY: Disk write speed for %s = %s bytes/s ",
                    $DiskPart, commify( sprintf "%.2f", $Speed );
                if ( $opt_s eq 'syslog' )
                {
                    syslog 6, "info %s", $Report;
                } else
                {
                    print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                        ": INFO: $Report\n";
                } ## end else [ if ( $opt_s eq 'syslog'...)]
                warn "DEBUG: "
                    . strftime( "%Y-%m-%d %H:%M:%S", localtime )
                    . " $Report"
                    if ($opt_d);
            } ## end if ( $WriteBytes_Daily...)
            $WriteBytes_Daily{"$DiskPart"} = $DiskWrites;
        } ## end while ( my $DEVLine = <DEVSTAT>...)
        close(DEVSTAT);
    } ## end if ( open( DEVSTAT, '<'...))

    unless ( system('pgrep mysqld > /dev/null 2>&1') )
    {
        $Report = GetMysqldStats();
        if ( $opt_s eq 'syslog' )
        {
            syslog 6, "info DAILY: %s", $Report;
        } else
        {
            print LF strftime( "%Y-%m-%d %H:%M:%S", localtime ),
                ": INFO: $Report\n";
        } ## end else [ if ( $opt_s eq 'syslog'...)]
        warn "DEBUG: "
            . strftime( "%Y-%m-%d %H:%M:%S", localtime )
            . " $Report"
            if ($opt_d);
    } ## end unless ( system('pgrep mysqld > /dev/null 2>&1'...))
        # Start the next reporting cycle
    $VMLNo_Daily    = 3;
    $RunQueue_Daily = 0;
    $BlockedP_Daily = 0;
    $PageIn_Daily   = 0;
    $CPUWait_Daily  = 0;
} ## end sub ReportDaily

#--------------------------------------------------------------------
# Main function
#--------------------------------------------------------------------
$|++;
print "$ProgName\n$CopyRight\n\n";

# Get possible options
getopts('a:dhi:Ds:o:I:Q:') or ShowUsage();
ShowUsage() if ( ($opt_h) or ( $opt_i <= 0 ) );

if ($opt_Q)
{
    # Check validity of 'quiet' hours
    if ( $opt_Q =~ /^[\d,]+/o )
    {
        @QuietHours = split( /,/, $opt_Q );
    } else
    {
        warn
            "'$opt_Q' does not contain valid hours - 'quiet' hours disabled!\n";
    } ## end else [ if ( $opt_Q =~ /^[\d,]+/o...)]
} ## end if ($opt_Q)

if ($opt_a)
{
# Check validity of alert email address
# see: http://www.rcamilleri.com/blog/perl-validate-email-addresses-using-regex/
    if (   ( $opt_a !~ /^(\w|\-|\_|\.)+\@((\w|\-|\_)+\.)+[a-zA-Z]{2,}$/ )
        || ( $opt_a =~ /\.@|\.\./ ) )
    {
        warn "'$opt_a' is not a valid email address - disabling alerts!\n";
        $opt_a = '';
    } ## end if ( ( $opt_a !~ ...))
} ## end if ($opt_a)

if ($opt_o)
{
    # Check whether output path for '.csv' files exists
    if ( !-d $opt_o )
    {
        warn
            "Output path '$opt_o' does not exist - disabling creation of '.csv' files\n";
        $opt_o = '';
    } ## end if ( !-d $opt_o )
} ## end if ($opt_o)

# Determine the number of processors in the system
open( CPUS, '<', '/proc/cpuinfo' )
    or die "ERROR: Can not determine number of processors\n";
while ( my $CPULine = <CPUS> )
{
    $CPUNo++ if ( $CPULine =~ /^processor/o );
} ## end while ( my $CPULine = <CPUS>...)
close(CPUS);
warn "DEBUG: "
    . strftime( "%Y-%m-%d %H:%M:%S", localtime )
    . " Number of processors = $CPUNo"
    if ($opt_d);
die "ERROR: No processors found\n" unless ($CPUNo);
$ReportTail = sprintf "(HHMMLL for %d processor%s)", $CPUNo,
    ( ( $CPUNo > 1 ) ? 's' : '' );

# Become a daemon process (if specified)
Daemonize if ($opt_D);

# Write the PID
if ( open( PF, '>', '/var/run/SysMon.pid' ) )
{
    print PF "$$\n";
    close(PF);
} ## end if ( open( PF, '>', '/var/run/SysMon.pid'...))

open( VMS, "-|", "$VMSTAT -n $opt_i" )
    or die "ERROR: Can not find or start 'vmstat': $!";

# Create the correct output for logging
if ( $opt_s eq 'syslog' )
{
    warn "DEBUG: "
        . strftime( "%Y-%m-%d %H:%M:%S", localtime )
        . " Logging to syslog via 'daemon' facility"
        if ($opt_d);
    openlog "$ProgName", LOG_PID, LOG_DAEMON;
} else
{
    my $LogFile = '';
    if ( $opt_s =~ /^(\/(?:tmp|var\/log)\/\S+)/ )
    {
        $LogFile = "$1";
    } ## end if ( $opt_s =~ /^(\/(?:tmp|var\/log)\/\S+)/...)
    die "ERROR: Logfile must be in /tmp or in /var/log\n"
        unless ( length($LogFile) );
    warn "DEBUG: "
        . strftime( "%Y-%m-%d %H:%M:%S", localtime )
        . " Logging to $LogFile"
        if ($opt_d);
    open LF, '>', "$LogFile" or die "$@";
} ## end else [ if ( $opt_s eq 'syslog'...)]

# Constantly get the input from "vmstat"
while ( my $VMLine = <VMS> )
{
    $VMLNo_Interval++;
    $VMLNo_Hourly++;
    $VMLNo_Daily++;
    warn "DEBUG: "
        . strftime( "%Y-%m-%d %H:%M:%S", localtime )
        . " vmstat line number = $VMLNo_Interval"
        if ($opt_d);

    # Skip 1st three lines of output
    next unless ( $VMLNo_Interval > 3 );

    $VMLine =~ s/^\s+//;
    warn "DEBUG: "
        . strftime( "%Y-%m-%d %H:%M:%S", localtime )
        . " VMLine = $VMLine"
        if ($opt_d);
    my ($RQ,   $BP,   undef, undef, undef, undef, $PI,   undef,
        undef, undef, undef, undef, undef, undef, undef, $WA
    ) = ( split( /\s+/, $VMLine ) );
    # Update the counters for interval logging
    $RunQueue_Interval += $RQ;
    $BlockedP_Interval += $BP;
    $PageIn_Interval   += $PI;
    $CPUWait_Interval  += $WA;
    # Update the counters for hourly report
    $RunQueue_Hourly += $RQ;
    $BlockedP_Hourly += $BP;
    $PageIn_Hourly   += $PI;
    $CPUWait_Hourly  += $WA;
    # Update the counters for daily report
    $RunQueue_Daily += $RQ;
    $BlockedP_Daily += $BP;
    $PageIn_Daily   += $PI;
    $CPUWait_Daily  += $WA;
    warn "DEBUG: "
        . strftime( "%Y-%m-%d %H:%M:%S", localtime )
        . " RunQueue = $RQ, Blocked processes = $BP, Paged in memory = $PI, CPUWait = $CPUWait_Interval"
        if ($opt_d);

    if ( $VMLNo_Interval == ( ( $opt_I / $opt_i ) + 3 ) )
    {
        # Create the standard report per interval
        ReportInterval();

        my ( undef, $CurMin, $CurHour ) = localtime();
        if ( $CurMin < ( $opt_I / 60 ) )
        {
            # Create an hourly report
            ReportHourly();

            if ( $CurHour == 0 )
            {
                # Create a daily report
                ReportDaily();
            } ## end if ( $CurHour == 0 )
        } ## end if ( $CurMin < ( $opt_I...))

    } ## end if ( $VMLNo_Interval ==...)

    # Only continue loop if we are running in daemon mode
    last unless ($opt_D);
} ## end while ( my $VMLine = <VMS>...)
if ( $opt_s eq 'syslog' )
{
    closelog;
} else
{
    close(LF);
} ## end else [ if ( $opt_s eq 'syslog'...)]

close(VMS);

# We are done
exit 0;
__END__

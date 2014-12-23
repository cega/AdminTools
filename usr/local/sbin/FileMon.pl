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
use Digest::MD5;
use Time::localtime;
use Unix::Syslog qw(:macros :subs);
use Sys::Hostname;
use POSIX qw(setsid);
use Getopt::Std;

#--------------------------------------------------------------------
# Globals
#--------------------------------------------------------------------
$ENV{PATH} = '/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin';

# Where the checksums live
my $CSPATH = '/usr/local/etc/...';
my $CSFILE = "$CSPATH/checks";
my $GDB    = '/usr/bin/gdb';
my $UNAME  = '/bin/uname';

# Program names (adapt if necessary)
my $SendMailProg = '/usr/lib/sendmail';
my $WhoAmI       = ( getpwuid($>) )[0];
die "ERROR: You must be 'root' to run this script\n"
    unless ( $WhoAmI =~ /^root$/ );

# Name of the config file
my $CFFile = '.FileMon.rc';

# Search path for the config file
my @SPC = ( $ENV{'HOME'}, '/usr/local/etc', '/' );

# Host to monitor
my $MHOST = hostname;

# Default files to monitor and their classification
my %MFILE = (
    '/etc/passwd'                   => 'error',
    '/etc/group'                    => 'error',
    '/etc/syslog.conf'              => 'warning',
    '/etc/fstab'                    => 'error',
    '/etc/exports'                  => 'error',
    '/var/spool/cron/crontabs/root' => 'warning',
);

# Default sleep time

my $SleepTime = 12 * 60 * 60;

# Script to run at the end
my $Script = '';

# The recipient for the mail messages
our $opt_r = 'root';

# No daemon or help etc. :-)
our $opt_c = '';
our $opt_d = 0;
our $opt_D = 0;
our $opt_h = 0;
our $opt_s = 0;
our $opt_S = 0;

# The names of the change statuses
my @ChangeStatus = ( 'unchanged', 'new', 'empty', ' CHANGED ' );

# By default no permission warning
my $PermWarn = '';

# Recorded values
my (%CSChCount, %CSCkSum,   %CSChMode, %CSTime,
    %CNCkSum,   %CNChCount, %CNChMode
);

# Other globals
my $STime = 0;
my $Now   = time();

#--------------------------------------------------------------------
# Get the list of setuid and setgid files
#--------------------------------------------------------------------
sub GetSGID()
{
    my $RefreshSGID = 0;
    if ( -s "$CSPATH/.FileMon.sgid" )
    {

        # We need to refresh if the file is older than a day
        my $SGIDTime = ( stat("$CSPATH/.FileMon.sgid") )[9];
        my $SGIDAge  = time() - $SGIDTime;
        $RefreshSGID = 1 if ( $SGIDAge > 86400 );
        print 'DEBUG: SGID file is present and '
            . ( $RefreshSGID ? 'stale' : 'current' )
            . " ($SGIDAge seconds old ["
            . ctime($SGIDTime) . "])\n"
            if ($opt_d);
    } else
    {

        # We need to refresh since the file is absent
        $RefreshSGID = 1;
        print "DEBUG: SGID file is empty (or not present)\n" if ($opt_d);
    } ## end else [ if ( -s "$CSPATH/.FileMon.sgid"...)]

    if ($RefreshSGID)
    {

        # Refresh the list of setuid and setgid files
        my $pid = fork;

        if ($pid)
        {

            # The parent waits
            warn "DEBUG: Waiting for child $pid to build the SGID list\n"
                if ($opt_d);
            wait;
            print "DEBUG: Refreshed SGID file\n" if ($opt_d);
        } else
        {

            # The child builds the new list in lower priority
            setpriority( 0, 0, getpriority( 0, 0 ) + 10 );
            open( SGID, '>', "$CSPATH/.FileMon.sgid" )
                or die "Can not create $CSPATH/.FileMon.sgid: $!";
            print SGID '# Last updated: ' . ctime() . "\n";

            open( FIND, '-|',
                'find / \( -fstype ext3 -o -fstype ext4 \) -type f -perm /u=s,g=s -print 2>/dev/null'
            ) or die "Can not execute find command: $!";
            while (<FIND>)
            {
                # $_ will have each file name found with full path name
                print SGID "FILE $_";
                chomp();
                warn "DEBUG: setuid/setgid file '$_'\n" if ($opt_d);
                $MFILE{"$_"} = 'warning';
            } ## end while (<FIND>)
            close(FIND);
            close(SGID);

            exit 0;
        } ## end else [ if ($pid) ]
    } ## end if ($RefreshSGID)

    # Get the list of SIGD files
    if ( open( SGID, '<', "$CSPATH/.FileMon.sgid" ) )
    {

        while ( my $SGLine = <SGID> )
        {
            chomp($SGLine);

            # Ignore comments and empty lines
            next if ( $SGLine =~ /^\s*#|^\s*$/o );

            if ( $SGLine =~ /^FILE\s+(\S+)\s*(\S*)/o )
            {

                # File spec
                $MFILE{$1} = ( length($2) ? $2 : 'warning' );
                print "DEBUG: File $1 $MFILE{$1}\n"
                    if ($opt_d);
            } ## end if ( $SGLine =~ /^FILE\s+(\S+)\s*(\S*)/o...)
        } ## end while ( my $SGLine = <SGID>...)
        close(SGID);
    } ## end if ( open( SGID, '<', ...))
} ## end sub GetSGID

#--------------------------------------------------------------------
# Get the configuration infos
#--------------------------------------------------------------------
sub GetConfig()
{

    my (@CFConts) = ();
    my ( $CFPath, $MFIndex, $CFLine, $FMode );

    # Search for the config file
    if ($opt_c)
    {

        print "DEBUG: Using $opt_c:\n" if ($opt_d);
        if ( -r $opt_c )
        {
            $FMode = ( stat($opt_c) )[2] & 0777;
            $PermWarn
                = sprintf
                "WARNING: File \"%s\" is writable by this user (%04o).",
                $opt_c, $FMode
                if ( -w $opt_c );
            if ( open( CF, '<', "$opt_c" ) )
            {
                @CFConts = <CF>;
                close(CF);
            } ## end if ( open( CF, '<', "$opt_c"...))
        } else
        {
            print "DEBUG: Specified file \"$opt_c\" not found.\n"
                if ($opt_d);
        } ## end else [ if ( -r $opt_c ) ]
    } else
    {

        foreach $CFPath (@SPC)
        {
            if ( -r "$CFPath/$CFFile" )
            {

                # Found it ...
                print "DEBUG: Found $CFFile in $CFPath:\n" if ($opt_d);
                $FMode = ( stat("$CFPath/$CFFile") )[2] & 0777;
                $PermWarn
                    = sprintf 'WARNING: File "%s/%s" '
                    . "is writable by this user (%04o).", $CFPath, $CFFile,
                    $FMode
                    if ( -w "$CFPath/$CFFile" );
                if ( open( CF, '<', "$CFPath/$CFFile" ) )
                {
                    @CFConts = <CF>;
                    close(CF);
                } ## end if ( open( CF, '<', "$CFPath/$CFFile"...))
                last;
            } ## end if ( -r "$CFPath/$CFFile"...)
        } ## end foreach $CFPath (@SPC)
    } ## end else [ if ($opt_c) ]

    # Did we find anything?
    if ( scalar @CFConts )
    {

        # Interpret the contents of the config file
        foreach $CFLine (@CFConts)
        {

            chomp($CFLine);

            # Ignore comments and empty lines
            next if ( $CFLine =~ /^\s*#|^\s*$/o );

        SWITCH_CFLINE:
            {
                if ( $CFLine =~ /^FILE\s+(\S+)\s*(\S*)/o )
                {

                    # File spec
                    $MFILE{$1} = ( length($2) ? $2 : 'warning' );
                    print "DEBUG: File $1 $MFILE{$1}\n"
                        if ($opt_d);
                    last SWITCH_CFLINE;
                } ## end if ( $CFLine =~ /^FILE\s+(\S+)\s*(\S*)/o...)

                if ( $CFLine =~ /^SLEEP\s+(\d+)/o )
                {

                    # Max. wait time
                    $SleepTime = $1;
                    print "DEBUG: SleepTime: $SleepTime\n" if ($opt_d);
                    last SWITCH_CFLINE;
                } ## end if ( $CFLine =~ /^SLEEP\s+(\d+)/o...)

                if ( $CFLine =~ /^CSPATH\s+(\S+)/o )
                {

                    # The path for the 'checks' file
                    $CSPATH = $1;
                    $CSFILE = "$CSPATH/checks";
                    print "DEBUG: CSFILE: $CSFILE\n" if ($opt_d);
                    last SWITCH_CFLINE;
                } ## end if ( $CFLine =~ /^CSPATH\s+(\S+)/o...)

                if ( $CFLine =~ /^SCRIPT\s+(\S+)/o )
                {

                    # And external script to run at the end
                    $Script = $1;
                    print "DEBUG: Script: $Script\n" if ($opt_d);
                    last SWITCH_CFLINE;
                } ## end if ( $CFLine =~ /^SCRIPT\s+(\S+)/o...)

                print "DEBUG: Syntax error: $CFLine\n" if ($opt_d);
            } ## end SWITCH_CFLINE:
        } ## end foreach $CFLine (@CFConts)
    } else
    {
        print "DEBUG: Using default file list.\n" if ($opt_d);
    } ## end else [ if ( scalar @CFConts )]
} ## end sub GetConfig

#--------------------------------------------------------------------
# Inspect each file
#--------------------------------------------------------------------
sub InspectFiles()
{
    # Get the entries from the checksum file
    if ( open( CS, '<', "$CSFILE" ) )
    {
        # Interpret each file entry
        foreach my $CSLine (<CS>)
        {
            unless ( $CSLine =~ /^\s*#/o )
            {
                chomp($CSLine);
                my ( $CSFile, @CSvals ) = split( / \| /o, $CSLine );

                # Save the info
                $CSChCount{$CSFile} = $CSvals[0];
                $CSCkSum{$CSFile}   = $CSvals[1];
                if ( scalar @CSvals >= 2 )
                {
                    $CSChMode{$CSFile} = $CSvals[2];
                    $CSTime{$CSFile}   = $CSvals[3];
                } else
                {
                    $CSChMode{$CSFile} = -1;
                    $CSTime{$CSFile}   = $CSvals[2];
                } ## end else [ if ( scalar @CSvals >=...)]
            } ## end unless ( $CSLine =~ /^\s*#/o...)
        } ## end foreach my $CSLine (<CS>)
        close(CS);
    } ## end if ( open( CS, '<', "$CSFILE"...))

    # Inspect all files
    my $CSChange = 0;
    my %CNChange = ();
    $Now = ctime();
    foreach my $IFile ( keys %MFILE )
    {

        # Build the info
        my $ChCount = 0;
        my $CkSum   = 0;
        my $ChMode  = 0;
        if ( open( CF, '<', "$IFile" ) )
        {

            # File actually exist
            print "DEBUG: Getting info for $IFile\n" if ($opt_d);
            binmode(CF);
            $CkSum = Digest::MD5->new->addfile(*CF)->hexdigest;
            close(CF);

            ( undef, undef, $ChMode, undef, undef, undef, undef, $ChCount )
                = lstat($IFile);

            print "DEBUG: $IFile \| $ChCount \| $CkSum \| $ChMode \| $Now\n"
                if ($opt_d);

            # Compare the findings to the old info
            if ( $CSChCount{$IFile} )
            {

                # Detect a change
                if (   ( $CSCkSum{$IFile} ne $CkSum )
                    || ( $CSChCount{$IFile} != $ChCount )
                    || (   ( $ChMode >= 0 )
                        && ( $CSChMode{$IFile} != $ChMode ) )
                    )
                {
                    $CNChange{$IFile} = 3;    # CHANGED
                    $CSChange++;
                } else
                {
                    $CNChange{$IFile} = 0;    # unchanged
                } ## end else [ if ( ( $CSCkSum{$IFile...}))]
            } else
            {
                $CNChange{$IFile} = 1;        # new
            } ## end else [ if ( $CSChCount{$IFile...})]

            # Save the infos
            $CNCkSum{$IFile}   = $CkSum;
            $CNChCount{$IFile} = $ChCount;
            $CNChMode{$IFile}  = $ChMode;

        } ## end if ( open( CF, '<', "$IFile"...))
    } ## end foreach my $IFile ( keys %MFILE...)

    # Write out the new infos
    if ( open( CS, '>', "$CSFILE" ) )
    {
        print CS "# $PermWarn\n# Checksums, created by $WhoAmI\n";

        map {
                  print CS "$_ \| $CNChCount{$_} \| "
                . "$CNCkSum{$_} \| $CNChMode{$_} \| "
                . "$Now\n"
        } ( keys %CNCkSum );
        #        foreach my $IFile ( keys %CNCkSum )
        #        {
        #            print CS "$IFile \| $CNChCount{$IFile} \| "
        #              . "$CNCkSum{$IFile} \| $CNChMode{$IFile} \| "
        #              . "$Now\n";
        #        } ## end foreach my $IFile ( keys %CNCkSum...
        print CS "# It is now: $Now\n",
              '# Sleeping until '
            . ctime( $Now + $STime )
            . "  ($STime seconds)...\n"
            if ($opt_D);
        close(CS);
    } ## end if ( open( CS, '>', "$CSFILE"...))

    # Run an external script if specified
    my $SResult = 0;
    my @SOut    = ();
    if ( ($Script) && ( -x $Script ) )
    {

        print "DEBUG: Running \"$Script\"\n" if ($opt_d);
        $SIG{PIPE} = 'IGNORE';
        if ( open( SC, '-|', "$Script" ) )
        {
            @SOut = <SC>;
            close(SC);
            $SResult = $?;
        } ## end if ( open( SC, '-|', "$Script"...))

        unless ($SResult)
        {
            foreach my $Line (@SOut)
            {

                # Trim the line
                $Line =~ s/^\s+//;
                chomp($Line);
                chomp($Line);
                $Line =~ s/\s+$//;

                if ( length($Line) )
                {
                    $SResult = -1;
                    last;
                } ## end if ( length($Line) )
            } ## end foreach my $Line (@SOut)
        } ## end unless ($SResult)

        print "DEBUG: \"$Script\" resulted in $SResult (@SOut, "
            . scalar @SOut . ")\n"
            if ($opt_d);
    } ## end if ( ($Script) && ( -x...))

    # Write an email if we have a changed file or a script problem
    if ( ( $CSChange > 0 ) || ( $SResult != 0 ) )
    {

        print "DEBUG: Sending notification via email ($CSChange, $SResult)\n"
            if ($opt_d);

        open( SM, '|-' ) or exec "$SendMailProg", '-t';
        print SM "From: root\n"
            . "To: $opt_r\n"
            . "Subject: $ProgName notification\n"
            . "Mime-Version: 1.0\nContent-Type: text/plain; charset=US-ASCII\n"
            . "X-Mailer: $ProgName\n\n"
            . "$ProgName found:\n";

        my $EmailBody = '';
        if ( $CSChange > 0 )
        {

            $EmailBody .= "$CSChange changed file(s) on \"$MHOST\".\n";
            openlog( "$ProgName", LOG_PID, LOG_LOCAL7 );

            foreach my $IFile (
                sort { $CNChange{$a} cmp $CNChange{$b} }
                keys %CNChange
                )
            {

                # Skip any unchanged files
                next unless ( $CNChange{$IFile} );

                $EmailBody
                    .= "\nFile name:               "
                    . "$IFile ($ChangeStatus[$CNChange{$IFile}])\n"
                    . 'Checksum   (old \| new): ';
                $EmailBody .= sprintf '%s',
                    ( ( $CSCkSum{$IFile} ) ? "$CSCkSum{$IFile}" : '0' );
                $EmailBody
                    .= " \| $CNCkSum{$IFile}\n" . 'Char count (old \| new): ';
                $EmailBody .= sprintf '%s',
                    ( ( $CSChCount{$IFile} ) ? "$CSChCount{$IFile}" : '0' );
                $EmailBody
                    .= " \| $CNChCount{$IFile}\n"
                    . "File mode  (old \| new): $CSChMode{$IFile} \| $CNChMode{$IFile}\n"
                    . "Last check was:          $CSTime{$IFile}\n";

                # Write a syslog entry with the specified severity
                syslog 4, '%s %s %s File %s changed', $MFILE{$IFile},
                    ctime(), $MHOST, $IFile
                    if ( $CNChange{$IFile} == 2 );
            } ## end foreach my $IFile ( sort { ...})
            closelog;
        } ## end if ( $CSChange > 0 )
        if ( ( $SResult != 0 ) && ( $SResult != 15 ) && ( $SResult != 9 ) )
        {

            $EmailBody
                .= "\"$Script\" on \"$MHOST\" had a possible problem:\n\n"
                . "> Script result: $SResult\n";
            if ( scalar @SOut )
            {
                $EmailBody .= "> Script output:\n\n" . join( "", @SOut );
            } ## end if ( scalar @SOut )
            $EmailBody .= "\n";

        } ## end if ( ( $SResult != 0 )...)
        print SM "$EmailBody\n";
        close(SM);

        print "DEBUG: EmailBody = $EmailBody\n" if ($opt_d);
    } ## end if ( ( $CSChange > 0 )...)

} ## end sub InspectFiles

#--------------------------------------------------------------------
# Get the contents of the system call table
#--------------------------------------------------------------------
sub GetSysCallTable ($$$)
{
    my ( $SysCallAddr, $NoEntries, $FileName ) = @_;
    my @SysCalls = ();

    # Write the gdb commands into a temp file
    my $TempFile = "/var/tmp/gdb.$$";
    open( TF, '>', "$TempFile" ) or return (@SysCalls);
    print TF "set height 999\n" . "x/"
        . "$NoEntries"
        . "x 0x$SysCallAddr\n"
        . "quit\n";
    close(TF);
    chmod 0600, $TempFile;

    # Get the original kernel table

    print "DEBUG: Getting system call table from $FileName\n" if ($opt_d);
    $FileName =~ m/(.*)/;
    if ( open( TF, '-|', "gdb -x $TempFile $1" ) )
    {
        while ( my $Line = <TF> )
        {

            next unless ( $Line =~ /^0x.+sys_call_table/o );
            chomp($Line);
            print "DEBUG: $Line\n" if ($opt_d);
            push( @SysCalls, $Line );
        } ## end while ( my $Line = <TF> )
        close(TF);

    } ## end if ( open( TF, '-|', "gdb -x $TempFile $1"...))
    unlink($TempFile);
    return (@SysCalls);
} ## end sub GetSysCallTable ($$$)

#--------------------------------------------------------------------
# Compare the kernel amd memory system call tables
#--------------------------------------------------------------------
sub CompareSysCallTables ()
{

    # Bail if 'gdb' and 'kcore' are not present
    unless ( ( -x $GDB ) && ( -f '/proc/kcore' ) )
    {
        print "DEBUG: No 'gdb' or '/proc/kcore'\n" if ($opt_d);
        return;
    } ## end unless ( ( -x $GDB ) && ( ...))

    my $KernelRev = '';
    open( FOO, '-|', "$UNAME -r" ) or return '';
    chomp( $KernelRev = <FOO> );
    close(FOO);

    # Bail if the System.map can not be found
    unless ( -f '/usr/src/linux-' . $KernelRev . '/System.map' )
    {
        print "DEBUG: No '/usr/src/linux-" . $KernelRev . "/System.map'\n"
            if ($opt_d);
        return;
    } ## end unless ( -f '/usr/src/linux-'...)

    # Get the base address of the system call table
    my $SysCallAddr = '';
    if ( open( ST, '<', '/usr/src/linux-' . $KernelRev . '/System.map' ) )
    {
        while ( my $Line = <ST> )
        {

            if ( $Line =~ /^(.+) [A-Z] sys_call_table/o )
            {
                $SysCallAddr = uc("$1");
                last;
            } ## end if ( $Line =~ /^(.+) [A-Z] sys_call_table/o...)
        } ## end while ( my $Line = <ST> )
        close(ST);
    } ## end if ( open( ST, '<', '/usr/src/linux-'...))
    unless ( length($SysCallAddr) )
    {
        print "DEBUG: No address for SysCallTable found\n" if ($opt_d);
        return;
    } ## end unless ( length($SysCallAddr...))

    # Get the tables
    my @KernelTable = GetSysCallTable( $SysCallAddr, 256,
        '/usr/src/linux-' . $KernelRev . '/vmlinux' );
    my @MemoryTable = GetSysCallTable( $SysCallAddr, 256,
        '/usr/src/linux-' . $KernelRev . '/vmlinux /proc/kcore' );

    # Compare the tables
    my $EntryNo = 0;
    foreach my $MemEntry (@MemoryTable)
    {
        print "Changed system call:\n"
            . "\tMemory: $MemEntry\n"
            . "\tKernel: $KernelTable[$EntryNo]\n"
            if ( $MemEntry ne $KernelTable[$EntryNo] );
        $EntryNo++;
    } ## end foreach my $MemEntry (@MemoryTable...)
} ## end sub CompareSysCallTables

#--------------------------------------------------------------------
# Become a daemon process
#--------------------------------------------------------------------
sub Daemonize()
{

    # pretty command line in ps
    $0 = join( ' ', $0, @ARGV ) unless ($opt_d);

    chdir '/' or die "Can't chdir to '/': $!";

    # Redirect STDIN and STDOUT
    open STDIN,  '/dev/null'  or die "Can't read '/dev/null': $!";
    open STDOUT, '>/dev/null' or die "Can't write '/dev/null': $!";
    defined( my $pid = fork ) or die "Can't fork: $!";

    if ($pid)
    {

        # The parent can die now
        print "DEBUG: Parent dies\n" if ($opt_d);
        exit;
    } ## end if ($pid)

    setsid or die "Can't start new session: $!";
    open STDERR, '>&STDOUT' or die "Can't duplicate stdout: $!";
} ## end sub Daemonize

#--------------------------------------------------------------------
# Display the usage
#--------------------------------------------------------------------
sub ShowUsage()
{

    print "Usage: $ProgName [options]\n"
        . "       -c path Specify the configuration file [no default]\n"
        . "       -D      Run as daemon [default=no]\n"
        . "       -r name Specify recipient for mail [default: $opt_r]\n"
        . "       -s      Do not check setuid/setgid files [default=yes]\n"
        . "       -S      Check Linux System Call Table [default=no]\n"
        . "       -h      Show this help [default=no]\n"
        . "       -d      Show some debug info on STDERR [default=no]\n\n"
        . " - $ProgName uses a configuration file called \"$CFFile\" to obtain\n"
        . "   information what to monitor.  The structure of this file is:\n"
        . "   # Comment line\n"
        . "   FILE filename [critical|error|warning|info]\n"
        . "    (one entry per line, default is warning)\n"
        . "   SLEEP <num> (max. time between checks in seconds)\n"
        . "         [default=$SleepTime]\n"
        . "   CSPATH <directory> (the path for the persistent info file\n"
        . "          [default=$CSPATH])\n"
        . " - The search path for the configuration file is:\n";
    map { print "   - $_\n" } @SPC;
    print
        " - Without any option and configuration $ProgName will monitor the\n"
        . "   following files on \"$MHOST\":\n";
    map { print "   - $_\n" } ( keys %MFILE );

    exit 0;
} ## end sub ShowUsage

#--------------------------------------------------------------------
# Main function
#--------------------------------------------------------------------
print "$ProgName\n$CopyRight\n\n";
$| = 1;

# Get possible options
getopts('c:dhr:DsS') or ShowUsage();
ShowUsage() if ($opt_h);

# Make sure the checksum directory exists
GetConfig();
if ( !-d $CSPATH )
{
    print "DEBUG: Creating \"$CSPATH\"\n" if ($opt_d);
    system("mkdir $CSPATH; chmod 400 $CSPATH");
} ## end if ( !-d $CSPATH )

srand();

# Become a daemon process (if specified)
Daemonize if ($opt_D);

# Write the PID
if ( open( PF, '>', '/var/run/FileMon.pid' ) )
{
    print PF "$$\n";
    close(PF);
} ## end if ( open( PF, '>', '/var/run/FileMon.pid'...))

do
{
    # By default we don't have any files to check
    %MFILE = ();

    # Get the config infos (in case they got updated)
    GetConfig();

    # Create the list of setuid and setgid files
    GetSGID() unless ($opt_s);

    # Calculate the sleep time
    $STime = int( rand($SleepTime) );

    # Inspect each file
    InspectFiles();

    # Check the syscall tables between kernel and memory
    CompareSysCallTables() if ($opt_S);

    # Sleep if we run as a daemon
    if ($opt_D)
    {
        print 'DEBUG: Sleeping until '
            . ctime( $Now + $STime )
            . "($STime seconds)...\n"
            if ($opt_d);
        sleep($STime);
        print "DEBUG: I'm baaaack!\n" if ($opt_d);
    } ## end if ($opt_D)
} while ($opt_D);

# Remove pid file
unlink '/var/run/FileMon.pid';

# We are done
exit 0;
__END__

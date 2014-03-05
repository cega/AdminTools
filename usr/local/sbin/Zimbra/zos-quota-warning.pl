#!/usr/bin/perl
################################################################
#
# $Id: xwa-quota-warning.pl,v 1.2 2011/10/24 02:54:54 xdefenders Exp $
#
# (c) Copyright 2006 xDefenders, inc. and Thomas Bullinger
################################################################
# quota_zimbra.pl :     this perl script allows the user to know if his current mail quota is a warning state...
#                       the state is determinated by the thresholds (in percent) you set
#
# link : http://wiki.zimbra.com/index.php?title=Quota_Warnings
#
# History :
# v0.2  2007-08-08              : update of the code by Rick van der Zwet : rick.van.der.zwet<at>joost.com
# v0.1          2007-04-24              : first version by Erwan Ben Souiden : erwan<at>aleikoum.net

use strict;
use Getopt::Long;

if ( -f '/proc/drbd' )
{
    my $Primary = `df -P /opt/zimbra | grep drbd`;
    chomp($Primary);
    exit 0 unless length($Primary);
} ## end if ( -f '/proc/drbd' )

my $ProgName = '';
( $ProgName = $0 ) =~ s%.*/%%;

#############################
# DON T FORGET TO MODIFY LIKE YOU WANT

my $megabytes = 1024 * 1024;
#use this quota if there is no quota set in zimbra
my $softquota = 512 * $megabytes;
#commands you need
my $command  = '/opt/zimbra/bin/zmprov gqu';
my $sendmail = '/opt/zimbra/postfix/sbin/sendmail';

my $mailfrom = 'admin';
my $verbose  = 0;
my @servers  = ('localhost');

my $message_realquota = sprintf <<EOF;
To: <###NAME###> ###NAME###
Subject: Zimbra Quota ###STATE### for ###NAME### - used ###USED###% - trigger ###STATEMAX###%
X-Mailbox-State: ###STATE###

Hi ###NAME###,

Your mailbox is in a ###STATE### state, because more than ###STATEMAX### percent
of the usual quota is being used.
Please delete some emails or you might run the risk of not being able to receive
any more emails in the future.

You are using ###SPACE### and the quota is set to ###QUOTA###.

Some tips of reducing your mailbox size:
* Delete and expunge old emails
* Empty your trash folder
* Make a local backup of some messages

Best regards,
Your quota reminder
EOF

my $message_softquota = sprintf <<EOF;
To: <###NAME###> ###NAME###
Subject: Zimbra Quota warning for ###NAME###

Hi ###NAME###,

Your mailbox is in a warning state, because more than ###STATEMAX### percent
of the default quota is being used.
Please delete some emails or you might run the risk of not being able to receive
any more emails in the future.

You are using ###SPACE### and the default quota is ###QUOTA###.

Some tips of reducing your mailbox size:
* Delete and expunge old emails
* Empty your trash folder
* Make a local backup of some messages

Best regards,
Your quota reminder
EOF
#############################

my ( $warning, $critical, $mailinform );
my ( $mail_warn, $mail_crit );
my ( $nom, $quota, $used );
my $c_all  = 0;
my $c_warn = 0;
my $c_crit = 0;
my @result;

sub print_usage()
{
    print
      "Usage: $ProgName -mail [1 | 0] -warning 85 -critical 90\n",
      "Options:\n",
      "\t-mail [1 | 0]\n",
      "\t\The mail value must be '1'  or '0' to disable mail notification. The default value is '0'\n",
      "\t-warning INTEGER\n",
      "\t\tallow you to set up the warning threshold. The default value is 85\n",
      "\t-critical INTEGER\n",
      "\t\tallow you to set up the critical threshold. The default value is 90\n";
    exit(0);
} ## end sub print_usage

if ( $ARGV[0] =~ /^-h|^--help|^-H/ )
{
    print " *** $ProgName *** \n";
    print_usage();
} ## end if ( $ARGV[0] =~ /^-h|^--help|^-H/...)
GetOptions(
    'mail=s'     => \$mailinform,
    'warning=s'  => \$warning,
    'critical=s' => \$critical
);

if ( $mailinform !~ /^(0|1)$/ )
{
    print
      "ERROR : the mail value must be '1'  or '0' to disable mail notification\n";
    print_usage();
} ## end if ( $mailinform !~ /^(0|1)$/...)

# default values
$warning    = "85" unless $warning;
$critical   = "90" unless $critical;
$mailinform = "0"  unless $mailinform;

print "-- Quota Warning v2 --\n";
print
  "Options :\n\tmailinform : $mailinform\n\twarning : $warning%\n\tcritical : $critical%\n\n";

foreach my $server (@servers)
{
    print "INFO : Reporting server $server\n" if ($verbose);
    @result = `$command $server`;
    foreach (@result)
    {
        ( $nom, $quota, $used ) = split( / /, $_ );
        # Skip any account with no usage
        next if ($used <= 0);

        my $UseSoftQuota = 0;
        unless ($quota > 0)
        {
            #use softquota if no quota set in zimbra
            $quota = $softquota;
            $UseSoftQuota++;
        } ## end unless ($quota)
        $c_all++;
        my $usedMB  = sprintf "%.2f", $used /  ($megabytes);
        my $quotaMB = sprintf "%.2f", $quota / ($megabytes);
        #print "$quota $quotaMB";
        my $message =
          ($UseSoftQuota) ? $message_softquota : $message_realquota;
        $used = sprintf "%.2f", ( $used / $quota ) * 100;

        $message =~ s/###QUOTA###/${quotaMB}MB/g;
        $message =~ s/###SPACE###/${usedMB}MB/g;
        $message =~ s/###NAME###/$nom/g;
        $message =~ s/###USED###/$used/g;

        if (   ($UseSoftQuota)
            or ( ( $used >= $warning ) and ( $used < $critical ) ) )
        {
            $c_warn++;
            print "WARNING : $nom used $used\% - trigger $warning\% \n";
            $message =~ s/###STATE###/warning/g;
            $message =~ s/###STATEMAX###/$warning/g;
            if ($mailinform)
            {
                open( MAIL, '|-', "$sendmail -F$mailfrom $nom $mailfrom" );
                print MAIL $message;
                close(MAIL);
            } ## end if ($mailinform)
        } elsif ( $used >= $critical )
        {
            $c_crit++;
            print "CRITICAL : $nom used $used\% - trigger $critical\% \n";
            $message =~ s/###STATE###/critical/g;
            $message =~ s/###STATEMAX###/$critical/g;
            if ($mailinform)
            {
                open( MAIL, '|-', "$sendmail -F$mailfrom $nom $mailfrom" );
                print MAIL $message;
                close(MAIL);
            } ## end if ($mailinform)
        } elsif ($verbose)
        {
            print "INFO : $nom is ok - used $used\% of $quotaMB MB\n";
        } ## end elsif ($verbose)
    } ## end foreach (@result)
} ## end foreach my $server (@servers...)

if ($verbose)
{
    print "\n*******\n",
      "INFO : Softquota in use $softquota bytes (individual users might have hard quota)\n",
      "INFO : Stats from $ProgName\n",
      "INFO : $c_crit users in a critical state\n",
      "INFO : $c_warn users in a warning state\n",
      "INFO : There are $c_all zimbra users\n";
} ## end if ($verbose)

#make sure to exit with non-zero when some mailbox is in warning of critical state
exit( $c_crit + $c_warn );

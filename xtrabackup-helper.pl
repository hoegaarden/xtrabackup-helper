#!/usr/bin/env perl

use strict;
use warnings;
use 5.10.00;

use Data::Dumper;
use Getopt::Long;
use File::Basename;
use Cwd 'abs_path';
use File::Temp;

my $dir = '/var/backups/mysql/data';
my $mode = 'list';
my $restore;
my $out = $dir . '/../restore';
my $chown;
my $force = 0;
my $full_day = 1;

my $update_url = 'https://raw.github.com/hoegaarden/xtrabackup-helper/master/xtrabackup-helper.pl';

my %modes = (
    'list'    => \&doList ,
    'restore' => \&doRestore ,
    'backup'  => \&doBackup ,
    'wedge'   => \&doWedge ,
    'update'  => \&doUpdate
);


# handle commandline arguments
handleCmdline();

# call the function
$modes{ $mode }->();

exit;

sub handleCmdline {
    GetOptions(
	'mode=s'    => \$mode ,
	'dir=s'     => \$dir ,
	'restore=s' => \$restore ,
	'out=s'     => \$out ,
	'chown=s'   => \$chown ,
	'force!'    => \$force ,
	'full-day=i'=> \$full_day
    ) or die();

    if (scalar @ARGV) {
	die('unknown commandline parameters');
    }
    
    unless ( defined($modes{$mode}) ) {
	die('unknown mode. valid modes are: ' . join(', ', keys(%modes)) );
    }

    unless (-d $dir) {
	die("backup dir $dir must be a directory");
    }
}

sub doWedge {
    die 'not implemented';
}

sub doUpdate {
    # perhaps not the safest way ...

    my $bin_path = abs_path($0);
    my $tmp = tmpnam();
    
    execCmd('wget', '-O', $tmp, $update_url);
    execCmd('mv', $bin_path, $bin_path.'.bak');
    execCmd('mv', $tmp, $bin_path);
    execCmd('chmod', '+x', $bin_path);

    say(' ** Update complete ** ');
    exit;
}

sub doBackup {
    my $make_full = 0;
    $full_day = $full_day  % 7;

    my $dow = `date '+%u'`;
    chomp($dow);

    if ($dow eq $full_day) {
	$make_full = 1;
    } else {
	my @full = grep {
	    $_->[1] eq 'full-backuped'
	} @{ getBackupList() };
	
	if (scalar @full < 1) {
	    $make_full = 1;
	}
    }
	
    my @cmd = ( 'innobackupex', '--rsync', '--defaults-extra-file=/etc/mysql/debian.cnf' );
    if (!$make_full) {
	push(@cmd, '--incremental');
    }
    push(@cmd, $dir);

    execCmd(@cmd);
}

sub execCmd {
    system(@_);
    
    if ($? == -1) {
	die("failed to execute: $!");
    } elsif ($? & 127) {
	my $msg = sprintf(
	    "child died with signal %d, %s coredump" ,
	    ($? & 127) ,
	    ($? & 128) ? 'with' : 'without'
        );
	die($msg);
    } else {
	my $code = $? >> 8;
	if (0 != $code) {
	    die("child exited with code $code");
	}
    }
}

sub readFile {
    my $file = shift;
    my $str = '';

    open(IN, '<', $file)
	or die('cannot read from file '.$file);

    read(IN, $str, 1024)
	or die('cannot read from file '.$file);

    close(IN)
	or die('cannot close file '.$file);

    return $str;
}

sub getBackupList {
    my @backups;

    my $pattern = $dir . '/*/xtrabackup_checkpoints';
    my @list = glob($pattern);

    foreach (@list) {
	my $cont = readFile($_);
	my $id = basename(dirname($_));

	if ( $cont =~ m/^backup_type\s*=\s*([^\s]+)$/mg ) {
	    push(@backups, [$id, $1]);
	}
    }

    @backups = sort {
    	$a->[0] cmp $b->[0]
    } @backups;

    return \@backups;
}

sub doList {
    my $list = getBackupList();
    my @others;
    my $indent = ' 'x4;

    foreach (@$list) {
	my $id = $_->[0];
	my $type = $_->[1];

	if ($type eq 'incremental') {
	    say $indent . $id;
	    next;
	}

	if ($type eq 'full-backuped') {
	    say "\n" . $id;
	    next;
	}

	push( @others, [ $id, $type ] );
    }

    if (scalar @others) {
	say "\nOthers:";
	foreach (@others) {
	    my $id = $_->[0];
	    my $type = $_->[1];

	    say "${indent}${id} : ${type}";
	}
    }
}

sub doRestore() {
    my $full_list = getBackupList();
    my $target;

    unless (defined($restore)) {
	$target = @$full_list[-1]->[0];
    } else {
	$target = $restore;
    }

    my $cur;
    my @restore_list = ();
    
    foreach (@$full_list) {
	my $id = $_->[0];
	my $type = $_->[1];
	
	last if ($id gt $target);
	
	if ($type eq 'full-backuped') {
	    @restore_list = ();
	}
	
	$cur = $id;
	push(@restore_list, $cur);
    }
    
    my $full = shift(@restore_list);
    restoreFull( $full );

    foreach (@restore_list) {
	restoreInc( $_ );
    }

    restoreFinishUp();
}

sub restoreFinishUp {
    execCmd("innobackupex", "--apply-log", $out);

    if (defined($chown)) {
	execCmd("chown", "-R", $chown, $out);
    }
}

sub id2Path {
    return $dir . '/' . shift;
}

sub restoreFull {
    my $id = shift;

    if (scalar <$out/*>) {
	if ($force) {
	    execCmd("rm", "-r", $out);
	} else {
	    die("restore dir $out must be empty");
	}
    }

    my $src = id2Path($id);
    execCmd("cp", "-a", $src, $out);

    execCmd("innobackupex", "--apply-log", "--redo-only", $out);
}

sub restoreInc {
    my $id = shift;
    my $path = id2Path($id);

    execCmd("innobackupex", "--apply-log", "--redo-only", $out, "--incremental-dir", $path);
}


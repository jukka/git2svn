#!/usr/bin/perl

use strict;
use warnings;

my $GIT = shift;
my $SVN = shift;

sub run {
    my ($cmd, @args) = @_;
    print join(' ', @_), "\n";
    chdir($cmd) or die "chdir: $!";
    system($cmd, @args) == 0 or die "$cmd: $?";
    chdir('..') or die "chdir: $!";
}

sub git { run('git', @_); }
sub svn { run('svn', @_); }

system('git', 'clone', $GIT, 'git') == 0 or die "git: $?";

my %commits = ();
my $head;
open LOG, '(GIT_DIR=git/.git git log --format=format:%H,%P,%ci)|'
    or die "open: $!";
for my $log (<LOG>) {
    chomp $log;
    my ($hash, $parents, $date) = split /,/, $log;
    $head = $hash unless $head;

    $commits{$hash} = {
        hash => $hash,
        date => $date,
        parents => [ split / /, $parents ],
        children => []
    };
}
for my $commit (values %commits) {
    $commit->{parents} = [ map { $commits{$_} } @{$commit->{parents}} ];
}
for my $commit (values %commits) {
    for my $parent (@{$commit->{parents}}) {
        push @{$parent->{children}}, $commit;
    }
}
close LOG;

my $pwd = `pwd`;
chomp($pwd);
system('svnadmin', 'create', 'repo') == 0 or die "svnadmin: $?";
system('svn', 'checkout', "file://$pwd/repo", 'svn') == 0 or die "svn: $?";

svn('mkdir', 'trunk');
svn('mkdir', 'branches');
svn('mkdir', 'tags');
svn('commit', '-m', 'mkdir {trunk,branches,tags}');

my %branches = ( trunk => 'trunk' );

sub listdir {
    my $dir = shift;
    my %map = ();
    opendir my $dh, $dir or die "opendir: $!";
    for my $file (grep { !/^\.{1,2}$/ } readdir $dh) {
        my ($dev, $ino, $mode, $nlink, $uid, $gid, $rdev, $size,
            $atime, $mtime, $ctime, $blksize, $blocks) = stat("$dir/$file")
            or die "stat: $!";
        $map{$file} = { size => $size, mtime => $mtime, file => -f _ };
    }
    closedir $dh;
    return %map;
}

sub copy {
    system('cp', '-p', '-r', @_) == 0 or die "cp: $?";
}

sub sync {
    my ($branch, $dir) = @_;
    my %source = listdir("git$dir");
    delete $source{'.git'} unless $dir;
    my %target = listdir("svn/$branch$dir");
    delete $target{'.svn'};

    for my $file (keys %target) {
        svn('delete', "$branch$dir/$file") unless exists $source{$file};
    }

    for my $file (keys %source) {
        my $sfile = $source{$file};
        my $tfile = $target{$file};
        if (not $tfile) {
            copy("git$dir/$file", "svn/$branch$dir/$file");
            svn('add', "$branch$dir/$file");
        } elsif (!$tfile->{file}) {
            sync($branch, "$dir/$file");
        } elsif (!$sfile->{file}) {
            die "Unable to replace a file with a directory";
        } elsif ($sfile->{size} != $tfile->{size}
              or $sfile->{mtime} != $tfile->{mtime}) {
            copy("git$dir/$file", "svn/$branch$dir/$file");
        }
    }
}

sub commit {
    my $commit = shift;
    my $branch = shift;
    return if $commit->{revision};

    my ($first, @rest) = @{$commit->{parents}};
    if ($first) {
        commit($first, $branch);
        for my $c (@rest) {
            commit($c, $c->{hash});
        }
    }

    my $dir = $branches{$branch};
    unless ($dir) {
        $dir = "branches/$branch";
        my $r = $first->{revision};
        my $b = $first->{branch};
        svn('copy', '-r', $r, "$branches{$b}\@$r", $dir);
        $branches{$branch} = $dir;
    }

    git('checkout', $commit->{hash});
    sync($dir, "");
    svn('commit', '-m', $commit->{hash});

    `cd svn; svn update` =~ /revision (\d+)/ or die "Unknown svn revision";
    my $revision = $1;

    $commit->{revision} = $revision;
    $commit->{branch} = $branch;

    print "commit $commit->{revision} to branch $commit->{branch} at $commit->{date}: $commit->{hash}\n";
}

commit($commits{$head}, 'trunk');

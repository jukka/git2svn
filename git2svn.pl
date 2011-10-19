#!/usr/bin/perl

use strict;
use warnings;

my $GIT = shift;
my $SVN = shift;

sub run {
    my ($cmd, @args) = @_;
    print join(' ', @_), "\n";
    chdir($cmd) or die "chdir: $!";
    if ($cmd eq 'svn' and $args[0] eq 'commit') {
        system($cmd, @args) == 0
            or do {
                system('rm', '-rf', 'trunk',  'branches', 'tags');
                system('svn', 'update');
            };
    } else {
        system($cmd, @args) == 0 or die "$cmd: $?";
    }
    chdir('..') or die "chdir: $!";
}

sub git { run('git', @_); }
sub svn { run('svn', @_); }

system('git', 'clone', $GIT, 'git') == 0 or die "git clone: $?";

my %commits = ();
my $trunk;
my %banches = ();
do {
    # Collect basic information about all reachable commits in the repository
    open GIT, 'GIT_DIR=git/.git git log --all --format=format:%H,%P,%ci |'
        or die "git log: $!";
    for my $line (<GIT>) {
        chomp $line;
        my ($hash, $parents, $date) = split /,/, $line;
        $head = $hash unless $head;

        $commits{$hash} = {
            hash     => $hash,
            date     => $date,
            parents  => [ split / /, $parents ],
            branch   => '',
            tags     => [],
            revision => 0
        };
    }
    close GIT;

    # Replace parent hashes with references to the commit objects
    for my $commit (values %commits) {
        $commit->{parents} = [ map { $commits{$_} } @{$commit->{parents}} ];
    }

    # Collect information about branches and tags
    open GIT, 'GIT_DIR=git/.git git show-ref |' or die "git show-ref: $!";
    for my $line (<GIT>) {
        chomp $line;
        my ($hash, $ref) = split / /, $line;
        if ($ref =~ m[^refs/tags/(.*)]) {
            # Record tag information
            push @{$commits{$hash}->{tags}}, $1;
        } elsif ($ref =~ m[^refs/remotes/origin/(.*)]) {
            my $branch = $1;
            if ($branch eq 'master') {
                $trunk = $commits{$hash};
            } elsif ($branch ne 'HEAD') {
                $branches{$branch} = $commits{$hash};
            }
        }
    }
    close GIT;

    # Map commits to the main branch lines
    set_linear_branch($trunk, 'trunk') if $trunk;
    for my $branch (keys %branches) {
        set_linear_branch($branches{$branch}, "branches/$branch");
    }

    # Map remaining commits to temporary branches
    for my $commit (sort { $b->{date} cmp $a->{date} } values %commits) {
        set_linear_branch($commit, "branches/$commit->{hash}")
             unless $commit->{branch};
    }
};

# Sets the branch mapping of all linear ancestors (following first parent)
sub set_linear_branch {
    my ($commit, $branch) = @_;
    while ($commit and not $commit->{branch}) {
        $commit->{branch} = $branch;
        ($commit) = @{$commit->{parents}};
    }
}

my $pwd = `pwd`;
chomp($pwd);
system('svnadmin', 'create', 'repo') == 0
    or die "svnadmin create: $?";
system('svn', 'checkout', "file://$pwd/repo", 'svn') == 0
    or die "svn checkout: $?";

svn('mkdir', 'trunk');
svn('mkdir', 'branches');
svn('mkdir', 'tags');
svn('commit', '-m', 'mkdir {trunk,branches,tags}');

my %branches = ( trunk => 'trunk' );

sub listdir {
    my $dir = shift;
    my %map = ();
    opendir my $dh, $dir or die "opendir($dir): $!";
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
        if ($first) {
            my $r = $first->{revision};
            my $b = $first->{branch};
            svn('copy', '-r', $r, "$branches{$b}\@$r", $dir);
        } else {
            svn('mkdir', $dir);
        }
        $branches{$branch} = $dir;
    }

    git('checkout', $commit->{hash});
    sync($dir, "");

    for my $c (@rest) {
        my $removebranch = $c->{branch} ne 'trunk' and $c->{branch} ne $branch;
        for my $child (@{$c->{children}}) {
            $removebranch = 0
                if $child->{hash} ne $commit->{hash} and not $child->{revision};
        }
        if ($removebranch) {
            svn('delete', $branches{$c->{branch}});
            delete $branches{$c->{branch}};
        }
    }
    
    svn('commit', '-m', $commit->{hash});

    `cd svn; svn update` =~ /revision (\d+)/ or die "Unknown svn revision";
    my $revision = $1;

    $commit->{revision} = $revision;
    $commit->{branch} = $branch;

    print "commit $commit->{revision} to branch $commit->{branch} at $commit->{date}: $commit->{hash}\n";
}

commit($commits{$head}, 'trunk');

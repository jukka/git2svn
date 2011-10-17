#!/usr/bin/perl

use strict;
use warnings;

my $GIT = shift;
my $SVN = shift;

sub git {
    system("git", @_) == 0 or die "git: $?";
}

sub svn {
    system("svn", @_) == 0 or die "svn: $?";
}

git('clone', $GIT, 'git');
chdir('git') or die "chdir: $!";
my $git = `pwd`;
my %commits = ();
my $first;
open LOG, 'git log --format=format:%H,%P,%ci|'
    or die "open: $!";
for my $log (<LOG>) {
    chomp $log;
    my ($hash, $parents, $date) = split /,/, $log;
    $first = $hash unless $first;

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
chdir('..') or die "chdir: $!";

svn('checkout', $SVN, 'svn');
chdir('svn') or die "chdir: $!";
svn('mkdir', 'trunk');
svn('mkdir', 'branches');
svn('mkdir', 'tags');
svn('commit', '-m', 'mkdir {trunk,branches,tags}');
my %branches = ( trunk => 'trunk' );

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
    unless $dir {
        $dir = "branches/$branch";
        svn('mkdir', $dir);
        $branches{$branch} = $dir;
    };
    chdir($dir) or die "chdir: $!";

    sync(
    $commit->{revision} = $i++;
    $commit->{branch} = $branch;

    print "commit $commit->{revision} to branch $commit->{branch} at $commit->{date}: $commit->{hash}\n";
}

commit($commits{$first}, 'trunk');

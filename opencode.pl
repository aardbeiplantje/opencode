#!/usr/bin/perl

use strict; use warnings;

# scope this, the $bd and $ln will be garbage collected, but $0 set. Doesn't
# matter alot, as we'll exec another process over it at the end
{
    my $bd = $ENV{BDIR}    // "session";
    $bd =~ s/^.*\///g;
    $bd =~ s/[^a-zA-Z0-9_-]/_/g;
    my $ln = $ENV{LOGNAME} // "node";
    $ln =~ s/[^a-zA-Z0-9_-]/_/g;
    $0 = "opencode:$ln:$bd";
}

use File::Path qw(make_path);
use File::Find qw(find);
use File::stat;

my $UID = 1000;
my $GID = 1000;
my $workspace = "/workspace";

sub copy_file {
    my ($src, $dst) = @_;
    if (open(my $in, "<", $src) and open(my $out, ">", $dst)) {
        local $/; my $data = <$in>; print $out $data; close($in); close($out);
        return 1;
    }
    0;
}

sub set_mtime {
    my ($file, $mtime) = @_;
    utime($mtime, $mtime, $file);
}

sub copy_tree {
    my ($src, $dst_dir) = @_;
    find({
        no_chdir => 1,
        follow_skip => 2,
        wanted => sub {
            my $rel; { local $File::Find::name = $_; ($rel = $_) =~ s{^\Q${src}/?\E}{}o; }
            my $dest = "$dst_dir/$rel";

            if (-l $_) {
                unlink($dest) if -e $dest;
                symlink(readlink($_), $dest);
            } elsif (-d $_) {
                make_path($dest) unless -d $dest;
                my $st = lstat($_);
                chmod($st->mode, $dest) if defined($st);
                set_mtime($dest, $st->mtime) if defined($st);
                chown($UID, $GID, $dest) if -e $dest;
            } elsif (-f $_) {
                copy_file($_, $dest);
                my $st = stat($_);
                chmod($st->mode & 07777, $dest) if defined($st);
                set_mtime($dest, $st->mtime) if defined($st);
                chown($UID, $GID, $dest) if -e $dest;
            }
        },
    }, $src);
}

# Clear error flag before privilege operations
$! = 0;

# Drop group privileges: set real GID to 1000 (node group)
$( = $GID;
die "[ERROR] setting RGID to $UID: $!\n"
    if $!;
$! = 0;

# Set effective GID to 1000 and preserve docker group (983) in supplementary groups
# Format: "primary_gid supplementary_gid1 supplementary_gid2 ..."
$) = "$GID 983";
die "[ERROR] setting EGID to $GID with docker group 983: $!\n"
    if $!;

# Set umask to 0022 (owner=rwx, group=rx, other=rx for new dirs; rw-r--r-- for files)
umask 0022;
die "[ERROR] setting umask 0022: $!\n"
    if $!;

# if containerd sock, group change it
my $ctr_s = $ENV{CONTAINERD_ADDRESS} // "";
if(length($ctr_s) and -S $ctr_s){
    chown($UID, $GID, $ctr_s)
        or die "[ERROR] changing ownership of $ctr_s to $UID:$GID: $!\n";
}

# make /workspace/.bash_history
my $history_path = "$workspace/.bash_history";
if(!-f $history_path){
    open(my $fh, ">", $history_path)
        or die "[ERROR] failed to create $history_path: $!\n";
    close($fh);
    chown($UID, $GID, $history_path)
        or die "[ERROR] changing ownership of $history_path to $UID:$GID: $!\n";
}

# setup /workspace/.opencode
foreach my $d ('.opencode', '.local', '.config', '.cache'){
    my $sd = "$workspace/$d";
    if(!-d $sd){
        mkdir($sd)
            or die "[ERROR] failed to create directory $sd: $!\n";
    }
    chown($UID, $GID, $sd)
        or die "[ERROR] changing ownership of $sd to $UID:$GID: $!\n";
}

# copy skills (overwrite existing files)
my $skills_src = "/skills";
my $skills_dir = "$workspace/.opencode/skills";
if (-d $skills_src) {
    make_path($skills_dir) unless -d $skills_dir;
    copy_tree($skills_src, $skills_dir);
}

# If running as root and UID environment variable is set, use that UID
if($< == 0 and length($ENV{UID}//"")){
    local $! = 0;
    my $target_uid = $ENV{UID};
    # Drop to GID
    $) = "$GID 986 992 109";
    $( = $);
    # Drop to UID
    $> = $target_uid;
    $< = $>;
    die "[ERROR] setting UID to $target_uid: $!\n"
        if $!;
}

# If still running as root (no UID env var), default to UID 1000
if($< == 0){
    local $! = 0;
    # Drop to GID
    $) = "$GID 986 992 109";
    $( = $);
    # Drop to UID
    $> = $UID;
    $< = $>;
    die "[ERROR] setting UID to $UID: $!\n"
        if $!;
}

# Final safety check: ensure we're not running as root
die "[ERROR] running as root is not allowed\n"
    if $< == 0;

$ENV{XDG_CACHE_HOME} = "$workspace/.cache";
$ENV{PROMPT_COMMAND} = 'history -a';
$ENV{HISTFILE} = $history_path;

# Set HOME environment variable for node user
$ENV{HOME} = $workspace;
$ENV{LOGNAME} = "node";
$ENV{PATH} = "$ENV{PATH}:$ENV{ROCM_PATH}/bin" if length($ENV{ROCM_PATH}//"");

# $ENV{BDIR} was mounted on /workdir/$BDIR
if($ENV{BDIR}){
    chdir("/workdir/$ENV{BDIR}")
        or die "[ERROR] chdir to /workdir/$ENV{BDIR}: $!\n";
} else {
    chdir("/workdir")
        or die "[ERROR] chdir to /workdir/: $!\n";
}

# Execute the actual opencode CLI with all provided arguments
exec("/home/node/.npm-global/bin/opencode", @ARGV)
    or die "[ERROR] failed to exec: $!\n";

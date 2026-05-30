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

# make /workspace/.bash_history, own by UID/GID
my $history_path = "$workspace/.bash_history";
if(!-f $history_path){
    open(my $fh, ">", $history_path)
        or die "[ERROR] failed to create $history_path: $!\n";
    close($fh);
    chown($UID, $GID, $history_path)
        or die "[ERROR] changing ownership of $history_path to $UID:$GID: $!\n";
}

# make /workspace/.bashrc own by root
if(length($ENV{ROCM_PATH}//"")){
    $ENV{PATH} = "$ENV{PATH}:$ENV{ROCM_PATH}/bin";
    my $b_fn = "$workspace/.bashrc";
    open(my $bfh, ">>$b_fn")
        or die "[ERROR] failed opening $b_fn: $!\n";
    print $bfh "PATH=$ENV{PATH}\nexport PATH\n";
    close($bfh)
        or die "[ERROR] failed close $b_fn: $!\n";
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
my $target_uid = $ENV{UID} // $UID;
if($< == 0){
    local $! = 0;
    # Drop to GID
    $) = "$GID 983 986 992 109";
    die "[ERROR] setting EGID to $GID: $!\n"
        if $!;
    $( = $);
    die "[ERROR] setting RGID to $): $!\n"
        if $!;
    # Drop to UID
    $> = $target_uid;
    die "[ERROR] setting EUID to $target_uid: $!\n"
        if $!;
    $< = $>;
    die "[ERROR] setting RUID to $>: $!\n"
        if $!;
}

# Final safety check: ensure we're not running as root
die "[ERROR] running as root EUID/RUID is not allowed\n"
    if $< == 0 or $> == 0;
die "[ERROR] running as root EGID/RGID is not allowed\n"
    if $( == 0 or $) == 0;

$ENV{XDG_CACHE_HOME} = "$workspace/.cache";
$ENV{PROMPT_COMMAND} = 'history -a';
$ENV{HISTFILE} = $history_path;

# Set HOME environment variable for node user
$ENV{HOME} = $workspace;
$ENV{LOGNAME} = "node";

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

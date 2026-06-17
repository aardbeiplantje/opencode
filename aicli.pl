#!/usr/bin/perl
#
#  ↓ root user

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
use POSIX ();

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
foreach my $d ('.opencode', '.local', '.config', '.cache', '.pi'){
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

# check DOCKER_HOST
if(($ENV{DIND}//0) == 1 and !length($ENV{DOCKER_HOST}//"")){
    # run dockerd ourselves, like dind
    mkdir("$workspace/docker")
        or (!$!{EEXIST} and die "[ERROR] problem making $workspace/docker: $!\n");
    local $SIG{HUP}  = 'IGNORE';
    local $SIG{INT}  = 'DEFAULT';
    local $SIG{TERM} = 'DEFAULT';
    local $SIG{QUIT} = 'DEFAULT';
    local $SIG{CHLD} = 'IGNORE';
    local $SIG{ALRM} = 'IGNORE';
    my $c_pid = fork();
    if($c_pid){
        # original process here
        $ENV{DOCKER_HOST} = "unix:///var/run/docker.sock";
    } elsif(!defined $c_pid){
        die "[ERROR] couldn't fork for daemonizing dockerd: $!\n";
    } else {
        eval {
            POSIX::setsid() != -1 or (!$!{EPERM} and die "problem making new session/process group dockerd: $!\n");
            chdir('/')                 or die "Cannot chdir to '/': $!\n";
            umask(0022);
            # redirect STDOUT
            my $l_file = POSIX::strftime("$workspace/docker/docker-%Y%m%d-%H:%M:%S.log", gmtime());
            open(my $l_fh, ">", $l_file)
                or die "Can't open $l_file for dockerd logging: $!\n";
            open(STDOUT, '>&', $l_fh)
                or die "Can't dup STDOUT to $l_file: $!\n";
            *STDOUT->autoflush();
            *STDERR->autoflush();
            open(STDERR, '>&STDOUT')   or die "Can't dup STDERR to STDOUT: $!\n";
            open(STDIN,  '</dev/null') or die "Can't read /dev/null: $!\n";

            # dup() sets $! as ioctl() is done in perl, so reset ERRNO
            $! = 0;

            my $c_pid = fork();
            if($c_pid){
                POSIX::_exit(0);
            } elsif(!defined $c_pid){
                die "[ERROR] couldn't second fork for daemonizing dockerd: $!\n";
            } else {
                # forked worker second
                no warnings;
                exec {"dockerd"} "dockerd", 
                    "--raw-logs",
                    "--log-level", "error",
                    "--log-format", "text",
                    "--host=unix:///var/run/docker.sock",
                    "-G", "1000",
                    "-D",
                    "--data-root", "$workspace/docker";
                # likely not reached, but if dockerd isn't found, it is, so exit!
                print "[ERROR] failed running dockerd: $!\n";
                POSIX::_exit(2);
            }
        };
        # there are cases that we get here, mostly signals and/or die/eval
        # caches (not the case here), also, "exit" handles END blocks, which
        # can do nasty stuff. As we really don't want this worker process to
        # continue, we use POSIX _exit
        chomp(my $err = $@);
        print "[ERROR] problem setting up fork/daemon for dockerd: $err\n";
        POSIX::_exit(1);
    }

    # re-own the docker data dir
    sleep(1);
    chown($UID, $GID, "$workspace/docker")
        or die "[ERROR] problem chwon $UID:$GID /workspace/docker: $!\n";
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

#  ↑ root user
#--------------------------------------------------------
#  ↓ user 1000 (node)
#

$ENV{XDG_CACHE_HOME} = "$workspace/.cache";
$ENV{PROMPT_COMMAND} = 'history -a';
$ENV{HISTFILE} = $history_path;


# $ENV{BDIR} was mounted on /workdir/$BDIR
if($ENV{BDIR}){
    chdir("/workdir/$ENV{BDIR}")
        or die "[ERROR] chdir to /workdir/$ENV{BDIR}: $!\n";
} else {
    chdir("/workdir")
        or die "[ERROR] chdir to /workdir/: $!\n";
}

# If first argument is 'pi', run pi-coding-agent instead
if (@ARGV && $ARGV[0] eq "-pi") {
    # Remove the 'pi' command from arguments and pass rest to pi binary
    # Set HOME environment variable for node user
    $ENV{HOME} = $workspace;
    $ENV{LOGNAME} = "node";
    shift @ARGV;
    exec("/home/node/.npm-global/bin/pi", @ARGV)
        or die "[ERROR] failed to exec pi: $!\n";
}
# Otherwise, run opencode CLI with all provided arguments
# Set HOME environment variable for node user
$ENV{OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT} = "true";
$ENV{HOME} = $workspace;
$ENV{LOGNAME} = "node";
@ARGV && $ARGV[0] eq "-opencode" && shift @ARGV;
exec("/home/node/.npm-global/bin/opencode", @ARGV)
    or die "[ERROR] failed to exec: $!\n";

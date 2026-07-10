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

use File::Path qw(make_path rmtree);
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

# setup /workspace/ subdirs
foreach my $d ('.opencode', '.local', '.config', '.cache', '.pi', '.opencode-mem', '.cocoindex'){
    my $sd = "$workspace/$d";
    if(!-d $sd){
        mkdir($sd)
            or die "[ERROR] failed to create directory $sd: $!\n";
    }
    chown($UID, $GID, $sd)
        or die "[ERROR] changing ownership of $sd to $UID:$GID: $!\n";
}

my $skills_src = "/skills";
my $skills_dir = "$workspace/.opencode/skills";
unlink $skills_dir if -l $skills_dir;
rmtree $skills_dir if -d $skills_dir;
symlink($skills_src, $skills_dir)
    or die "Error symlink $skills_dir to -> $skills_src: $!\n";

my $commands_src = "/commands";
my $commands_dir = "$workspace/.opencode/commands";
unlink $commands_dir if -l $commands_dir;
rmtree $commands_dir if -d $commands_dir;
symlink($commands_src, $commands_dir)
    or die "Error symlink $commands_dir to -> $commands_src: $!\n";

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

# Generate dynamic cocoindex global_settings.yml from ENV vars
{
    my $coco_dir    = "$ENV{HDIR}/.cocoindex";
    my $coco_file   = "$coco_dir/global_settings.yml";
    my $base_url    = $ENV{LLAMA_BASE_URL}       // "http://[::1]:4000/v1";
    my $api_key     = $ENV{LLAMA_SERVER_API_KEY} // "nokeyneeded";
    my $index_model = $ENV{INDEX_MODEL}          // "embeddinggemma-300M-Q8_0";

    # YAML single-quote strings: escape ' by doubling them
    (my $qurl = $base_url) =~ s/'/''/g;
    (my $qkey = $api_key) =~ s/'/''/g;

    if (open(my $out, ">", $coco_file)) {
        print $out "embedding:\n";
        print $out "  model: llamacpp/$index_model\n";
        print $out "  min_interval_ms: 300\n";
        print $out "  indexing_params:\n";
        print $out "    input_type: search_document\n";
        print $out "  query_params:\n";
        print $out "    input_type: search_query\n";
        print $out "envs:\n";
        print $out "  OPENAI_BASE_URL: '$qurl'\n";
        print $out "  OPENAI_API_KEY: '$qkey'\n";
        close($out);
    } else {
        warn "[WARN] could not write $coco_file: $!\n";
    }
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
$ENV{HOME} = "/home/node";
$ENV{LOGNAME} = "node";
$ENV{PATH} = "/home/node/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$ENV{PATH}";

# $ENV{BDIR} was mounted on /workdir/$BDIR
if($ENV{BDIR}){
    chdir("/workdir/$ENV{BDIR}")
        or die "[ERROR] chdir to /workdir/$ENV{BDIR}: $!\n";

    # init ccc
    system("ccc init >/dev/null 2>&1");
} else {
    chdir("/workdir")
        or die "[ERROR] chdir to /workdir/: $!\n";
}

# If first argument is 'pi', run pi-coding-agent instead
if (@ARGV && $ARGV[0] eq "-pi") {
    # Remove the 'pi' command from arguments and pass rest to pi binary
    # Set HOME environment variable for node user
    $ENV{PI_SKIP_VERSION_CHECK} //= 1;
    $ENV{PI_TELEMETRY}          //= 0;
    $ENV{EDITOR}                //= 'nano';
    $ENV{PI_OFFLINE}            //= 1;
    $ENV{PI_CODING_AGENT_DIR}   //= "/home/node/.pi/agent";
    $ENV{PI_CODING_AGENT_SESSION_DIR} = "$workspace/.pi/sessions";
    $ENV{LLAMA_BASE_URL}        //= "http://[::1]:13305";
    $ENV{LLAMA_SERVER_API_KEY}  //= "nokeyneeded";
    $ENV{SLOT_ID}               //= "0";
    shift @ARGV;
    exec("/home/node/.npm-global/bin/pi", @ARGV)
        or die "[ERROR] failed to exec pi: $!\n";
}
# Register custom LiteLLM providers (llamacpp embedding support)
system("python3 /cocoindex_plugins/register_providers.py");
# Otherwise, run opencode CLI with all provided arguments
# Set HOME environment variable for node user
$ENV{OPENCODE_EXPERIMENTAL_DISABLE_COPY_ON_SELECT} = "true";
@ARGV && $ARGV[0] eq "-opencode" && shift @ARGV;
exec("/home/node/.npm-global/bin/opencode", @ARGV)
    or die "[ERROR] failed to exec: $!\n";

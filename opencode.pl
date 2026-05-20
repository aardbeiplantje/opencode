#!/usr/bin/perl

use File::Path qw(make_path);

# Set process name to 'opencode' for cleaner process listings
$0 = 'opencode';

print "Using: LLAMA_MODEL=$ENV{LLAMA_MODEL}, LLAMA_SERVER_URL=$ENV{LLAMA_SERVER_URL}\n";

# Clear error flag before privilege operations
$! = 0;

# Drop group privileges: set real GID to 1000 (node group)
$( = 1000;
die "Error setting RGID to 1000: $!"
    if $!;
$! = 0;

# Set effective GID to 1000 and preserve docker group (983) in supplementary groups
# Format: "primary_gid supplementary_gid1 supplementary_gid2 ..."
$) = "1000 983";
die "Error setting EGID to 1000 with docker group 983: $!"
    if $!;

# Set umask to 0022 (owner=rwx, group=rx, other=rx for new dirs; rw-r--r-- for files)
umask 0022;
die "Error setting umask 0022: $!"
    if $!;

if (-d $ENV{BDIR}) {
    chdir($ENV{BDIR})
        or die "Failed to change directory to $ENV{BDIR}: $!";
}

# setup /workspace/tmp, the symlink from /tmp to /workspace/tmp is already there
my $tmp_path = "/workspace/tmp";
if(!-d $tmp_path){
    mkdir($tmp_path, 0777)
        or die "Failed to create directory $tmp_path: $!";
    chown(1000, 1000, $tmp_path)
        or die "Error changing ownership of $tmp_path to 1000: $!";
    chmod(01777, $tmp_path)
        or die "Error setting permissions of $tmp_path to 1777: $!";
}
# list contents of /tmp for debugging
rmdir("/tmp")
    or die "Failed to remove existing /tmp directory: $!";
symlink($tmp_path, "/tmp")
    or die "Failed to create symlink from $tmp_path to /tmp: $!";

# mkdir $ENV{XDG_CACHE_HOME} if it doesn't exist, and set ownership to 1000
my $cache_path = $ENV{XDG_CACHE_HOME} //= "/workspace/.cache";
if(!-d $cache_path){
    mkdir($cache_path)
        or die "Failed to create directory $cache_path: $!";
    chown(1000, 1000, $cache_path)
        or die "Error changing ownership of $cache_path to 1000: $!";
}

# If running as root and UID environment variable is set, use that UID
if($< == 0 and length($ENV{UID}//"")){
    my $target_uid = $ENV{UID};

    # add UID to /etc/passwd if it doesn't exist
    my $uid_exists = system("getent", "passwd", $target_uid) == 0;
    if(!$uid_exists){
        open(my $fh, ">>", "/etc/passwd")
            or die "Failed to open /etc/passwd for writing: $!";
        print {$fh} "node:x:$target_uid:1000::/home/node:/usr/sbin/nologin\n";
        close($fh);
    }

    # Drop to GID 986 109 992
    $) = "1000 986 992 109";
    $( = $);
    # Drop to the specified UID
    $> = $target_uid;
    $< = $>;
    die "Error setting UID to $target_uid: $!"
        if $!;
}

# If still running as root (no UID env var), default to UID 1000
if($< == 0){
    # Drop to GID 986 109 992
    $) = "1000 986 992 109";
    $( = $);
    # Drop to UID 1000
    $> = 1000;
    $< = $>;
    die "Error setting UID to 1000: $!"
        if $!;
}

# Final safety check: ensure we're not running as root
die "Error: Running as root is not allowed"
    if $< == 0;

# make /workspace/.bash_history
my $history_path = "/workspace/.bash_history";
if(!-f $history_path){
    open(my $fh, ">", $history_path)
        or die "Failed to create $history_path: $!";
    close($fh);
    chown(1000, 1000, $history_path)
        or die "Error changing ownership of $history_path to 1000: $!";
}
$ENV{PROMPT_COMMAND} = 'history -a';
$ENV{HISTFILE} = $history_path;

# Set HOME environment variable for node user
$ENV{HOME} = "/workspace";
$ENV{LOGNAME} = "node";
$ENV{OPENCODE_AUTO_SHARE} = "/workspace/.opencode";

# Execute the actual opencode CLI with all provided arguments
exec("/home/node/.npm-global/bin/opencode", @ARGV)
    or die "Failed to exec: $!";

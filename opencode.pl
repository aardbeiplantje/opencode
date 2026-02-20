#!/usr/bin/perl

$0 = 'opencode';

$! = 0;

$( = 1000;
die "Error setting RGID to 1000: $!"
    if $!;
$! = 0;

$) = 1000;
die "Error setting EGID to 1000: $!"
    if $!;

system("chown", "-R", "1000:1000", "/home/node") == 0
    or die "Error changing ownership of /home/node to 1000: $!";
system("chmod", "-R", "u+rwX,g+rwX,o+rX", "/home/node") == 0
    or die "Error setting permissions on /home/node: $!";

chown(1000, 1000, "/workspace")
    or die "Error changing ownership of /workspace to 1000: $!";

$! = 0;
umask 0022;
die "Error setting umask 0022: $!"
    if $!;

if (-d "/workspace/workdir"){
    chdir("/workspace/workdir")
        or die "Failed to change directory to /workspace: $!";
}

if($< == 0 and length($ENV{UID}//"")){
    # add UID to /etc/passwd if it doesn't exist
    my $uid_exists = system("getent", "passwd", $ENV{UID}) == 0;
    if(!$uid_exists){
        open(my $fh, ">>", "/etc/passwd")
            or die "Failed to open /etc/passwd for writing: $!";
        print $fh "node:x:$ENV{UID}:1000::/home/node:/usr/sbin/nologin\n";
        close($fh);
    }

    # Drop to the specified UID
    $> = $ENV{UID};
    $! = 0;
    $< = $ENV{UID};
    die "Error setting UID to $ENV{UID}: $!"
        if $!;
}

# If still running as root (no UID env var), default to UID 1000
if($< == 0){
    # Drop to UID 1000
    $> = 1000;
    $! = 0;
    $< = 1000;
    die "Error setting UID to 1000: $!"
        if $!;
}

# Final safety check: ensure we're not running as root
die "Error: Running as root is not allowed"
    if $< == 0;

# Set HOME environment variable for node user
$ENV{HOME} = "/home/node";
$ENV{LOGNAME} = "node";

exec("/home/node/.opencode/bin/opencode", @ARGV)
    or die "Failed to exec: $!";

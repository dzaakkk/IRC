#!/usr/bin/perl
#
# SeenServ v2 - a TS6 IRC service that tracks when nicknames were last seen,
# in the spirit of the old UniBG SeenServ (ivanatora@gmail.com, 2005).
#
# Links directly to ircd-ratbox (TS6 protocol) as a services server and
# stores its data in MySQL, keeping a full session history per nick so
# "SEEN nick d5" can show the last 5 sightings, not just the latest.
#
# Usage: ./seenserv.pl /path/to/seenserv.conf
#
use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use DBI;
use POSIX qw(strftime);
use Time::HiRes qw(time);

# ---------------------------------------------------------------------------
# Configuration loading
# ---------------------------------------------------------------------------

my $conf_file = shift @ARGV or die "Usage: $0 <config file>\n";
my %cfg = load_config($conf_file);

for my $required (qw(uplink_host uplink_port link_password
                      server_name server_sid server_desc
                      service_nick service_user service_host service_gecos
                      db_host db_name db_user db_pass)) {
    die "Missing required config option: $required\n" unless defined $cfg{$required};
}

my @seed_channels = split /,/, ($cfg{channels} // '');
s/^\s+|\s+$//g for @seed_channels;
@seed_channels = grep { length } @seed_channels;

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------

my $sock;
my $inbuf = '';
my $our_sid   = $cfg{server_sid};
my $service_uid = $our_sid . 'AAAAAA';
my %users;        # uid => { nick, user, host, ip, umodes, session_id }
my %nick2uid;      # lowercase nick => uid
my %joined_chans;  # lowercase channel => 1  (channels we currently sit in)

my $dbh = db_connect();
cleanup_stale_sessions();
ensure_seed_channels();

$SIG{INT}  = sub { log_msg("Caught SIGINT, exiting."); exit 0; };
$SIG{TERM} = sub { log_msg("Caught SIGTERM, exiting."); exit 0; };

while (1) {
    eval {
        connect_uplink();
        run_event_loop();
    };
    log_msg("Link error: $@") if $@;
    %users = ();
    %nick2uid = ();
    %joined_chans = ();
    log_msg("Disconnected from uplink, retrying in " . ($cfg{reconnect_delay} // 15) . "s...");
    sleep($cfg{reconnect_delay} // 15);
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

sub load_config {
    my ($file) = @_;
    open(my $fh, '<', $file) or die "Cannot open config $file: $!\n";
    my %c;
    while (my $line = <$fh>) {
        $line =~ s/#.*$//;
        $line =~ s/^\s+|\s+$//g;
        next unless length $line;
        next unless $line =~ /^(\S+)\s*=\s*(.*)$/;
        $c{$1} = $2;
    }
    close $fh;
    return %c;
}

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

sub db_connect {
    my $dsn = "DBI:mysql:database=$cfg{db_name};host=$cfg{db_host}" .
              ($cfg{db_port} ? ";port=$cfg{db_port}" : "");
    my $dbh = DBI->connect($dsn, $cfg{db_user}, $cfg{db_pass}, {
        RaiseError => 1,
        PrintError => 0,
        AutoCommit => 1,
        mysql_auto_reconnect => 1,
    });
    die "Cannot connect to MySQL: " . DBI->errstr . "\n" unless $dbh;
    return $dbh;
}

# Close any sessions left open by a previous run (crash/SIGKILL/SQUIT), same
# trick the original SeenServ used: mark them closed with a "restart" note
# so they don't linger as bogus "still online" entries.
sub cleanup_stale_sessions {
    eval {
        $dbh->do(
            "UPDATE seen SET when_off = NOW(), quit_msg = 'SeenServ restart'
             WHERE when_off IS NULL"
        );
    };
    log_msg("DB error in cleanup_stale_sessions: $@") if $@;
}

# Make sure any statically configured channels exist in the chans table,
# without clobbering ones that were already added/parted dynamically.
sub ensure_seed_channels {
    return unless @seed_channels;
    eval {
        my $sth = $dbh->prepare(
            "INSERT IGNORE INTO chans (chan, joined, privacy, ts) VALUES (?, 1, 'public', ?)"
        );
        $sth->execute($_, time()) for @seed_channels;
    };
    log_msg("DB error in ensure_seed_channels: $@") if $@;
}

sub load_joined_channels {
    my @chans;
    eval {
        my $sth = $dbh->prepare("SELECT chan FROM chans WHERE joined = 1");
        $sth->execute();
        while (my ($chan) = $sth->fetchrow_array) {
            push @chans, $chan;
        }
    };
    log_msg("DB error in load_joined_channels: $@") if $@;
    return @chans;
}

sub chan_privacy {
    my ($chan) = @_;
    my $privacy = 'public';
    eval {
        my $sth = $dbh->prepare("SELECT privacy FROM chans WHERE chan = ?");
        $sth->execute($chan);
        my ($p) = $sth->fetchrow_array;
        $privacy = $p if defined $p;
    };
    return $privacy;
}

# Open a new "session" row for a nick that just appeared on the network
# (fresh connect, or the tail end of a nick change). Returns the new row id.
sub open_session {
    my (%row) = @_;
    my $id;
    eval {
        $dbh->do(
            "INSERT INTO seen (nick, ident, host, when_on) VALUES (?, ?, ?, NOW())",
            undef, $row{nick}, $row{ident} // '', $row{host} // ''
        );
        $id = $dbh->last_insert_id(undef, undef, "seen", undef);
    };
    if ($@) {
        log_msg("DB error in open_session: $@");
        eval { $dbh = db_connect(); };
    }
    return $id;
}

# Close a session (quit, kill, or nick change) with a reason.
sub close_session {
    my ($session_id, %fields) = @_;
    return unless $session_id;
    eval {
        if (exists $fields{newnick}) {
            $dbh->do(
                "UPDATE seen SET when_off = NOW(), newnick = ? WHERE id = ?",
                undef, $fields{newnick}, $session_id
            );
        } else {
            $dbh->do(
                "UPDATE seen SET when_off = NOW(), quit_msg = ? WHERE id = ?",
                undef, $fields{quit_msg} // '', $session_id
            );
        }
    };
    if ($@) {
        log_msg("DB error in close_session: $@");
        eval { $dbh = db_connect(); };
    }
}

# Record "what the user is up to right now" against their open session, so
# a SEEN lookup can say more than just "connected at time X" - e.g. "was
# last seen talking on #perl" even while nick/quit info is unrelated.
sub update_activity {
    my ($session_id, $channel, $action, $message) = @_;
    return unless $session_id;
    eval {
        $dbh->do(
            "UPDATE seen SET last_channel = ?, last_action = ?, last_message = ?
             WHERE id = ?",
            undef, $channel, $action, $message, $session_id
        );
    };
    log_msg("DB error in update_activity: $@") if $@;
}

# Wildcard SEEN lookup. mask_field is 'nick' or 'user_host'.
sub lookup_seen {
    my ($mask, $limit) = @_;
    $limit = 1 unless $limit && $limit =~ /^\d+$/;
    $limit = 5 if $limit > 5;

    my @rows;
    eval {
        my $sth;
        if ($mask =~ /^(.*)\@(.*)$/) {
            my ($user_pat, $host_pat) = (like_pattern($1), like_pattern($2));
            $sth = $dbh->prepare(
                "SELECT nick, ident, host, when_on, when_off, newnick, quit_msg,
                        last_channel, last_action, last_message
                 FROM seen WHERE ident LIKE ? AND host LIKE ?
                 ORDER BY id DESC LIMIT $limit"
            );
            $sth->execute($user_pat, $host_pat);
        } else {
            my $nick_pat = like_pattern($mask);
            $sth = $dbh->prepare(
                "SELECT nick, ident, host, when_on, when_off, newnick, quit_msg,
                        last_channel, last_action, last_message
                 FROM seen WHERE nick LIKE ?
                 ORDER BY id DESC LIMIT $limit"
            );
            $sth->execute($nick_pat);
        }
        while (my $row = $sth->fetchrow_hashref) {
            push @rows, $row;
        }
    };
    log_msg("DB error in lookup_seen: $@") if $@;
    return @rows;
}

# Turn a user-supplied mask into a safe SQL LIKE pattern: escape existing
# %/_ so they're literal, then let '*' behave as the user-facing wildcard.
sub like_pattern {
    my ($s) = @_;
    $s =~ s/([%_])/\\$1/g;
    $s =~ tr/*/%/;
    return $s;
}

# ---------------------------------------------------------------------------
# Networking / TS6 link
# ---------------------------------------------------------------------------

sub connect_uplink {
    log_msg("Connecting to $cfg{uplink_host}:$cfg{uplink_port} ...");
    $sock = IO::Socket::INET->new(
        PeerHost => $cfg{uplink_host},
        PeerPort => $cfg{uplink_port},
        Proto    => 'tcp',
        Timeout  => 10,
    ) or die "Cannot connect to uplink: $!\n";
    $sock->autoflush(1);

    send_line("PASS $cfg{link_password} TS 6 :$our_sid");
    send_line("CAPAB :QS EX CHW IE KLN GLN KNOCK TB UNKLN CLUSTER ENCAP SERVICES EUID EOB");
    send_line("SERVER $cfg{server_name} 1 :$cfg{server_desc}");
    send_line("SVINFO 6 6 0 :" . int(time()));

    log_msg("Handshake sent, waiting for uplink burst...");
}

sub send_line {
    my ($line) = @_;
    print $sock "$line\r\n";
    debug_log(">> $line");
}

sub run_event_loop {
    my $sel = IO::Select->new($sock);
    introduce_service();
    rejoin_channels();

    while (1) {
        my @ready = $sel->can_read(30);
        if (!@ready) {
            send_line("PING :$our_sid");
            next;
        }
        my $buf;
        my $n = sysread($sock, $buf, 8192);
        die "Uplink closed connection\n" if !defined $n || $n == 0;

        $inbuf .= $buf;
        while ($inbuf =~ s/^([^\r\n]*)\r?\n//) {
            my $line = $1;
            next unless length $line;
            debug_log("<< $line");
            eval { handle_line($line); };
            log_msg("Error handling line [$line]: $@") if $@;
        }
    }
}

sub introduce_service {
    my $ts = int(time());
    send_line(":$our_sid UID $cfg{service_nick} 1 $ts +oiS $cfg{service_user} " .
              "$cfg{service_host} 0 $service_uid :$cfg{service_gecos}");
    $users{$service_uid} = {
        nick => $cfg{service_nick}, user => $cfg{service_user},
        host => $cfg{service_host}, ip => '0', umodes => 'oiS',
    };
    $nick2uid{lc $cfg{service_nick}} = $service_uid;
    log_msg("Introduced $cfg{service_nick} as $service_uid");
}

sub rejoin_channels {
    my $ts = int(time());
    for my $chan (load_joined_channels()) {
        send_line(":$our_sid SJOIN $ts $chan + :\@$service_uid");
        $joined_chans{lc $chan} = 1;
        log_msg("Rejoined $chan");
    }
}

# ---------------------------------------------------------------------------
# Protocol line dispatch
# ---------------------------------------------------------------------------

sub handle_line {
    my ($line) = @_;
    my $prefix;
    if ($line =~ s/^:(\S+)\s+//) {
        $prefix = $1;
    }
    my ($cmd, $rest) = split(/ /, $line, 2);
    $cmd = uc($cmd // '');
    my @params = split_params($rest // '');

    if ($cmd eq 'PING') {
        my $origin = $params[0] // $prefix // $cfg{server_name};
        send_line(":$our_sid PONG $cfg{server_name} :$origin");
    }
    elsif ($cmd eq 'PASS' || $cmd eq 'CAPAB' || $cmd eq 'SERVER' || $cmd eq 'SVINFO' || $cmd eq 'SID') {
        # uplink handshake / remote server introductions - nothing to do
    }
    elsif ($cmd eq 'UID' || $cmd eq 'EUID') {
        handle_uid($cmd, $prefix, @params);
    }
    elsif ($cmd eq 'NICK') {
        handle_nick($prefix, @params);
    }
    elsif ($cmd eq 'QUIT') {
        handle_quit($prefix, @params);
    }
    elsif ($cmd eq 'KILL') {
        handle_kill($prefix, @params);
    }
    elsif ($cmd eq 'JOIN') {
        handle_join($prefix, @params);
    }
    elsif ($cmd eq 'SJOIN') {
        handle_sjoin($prefix, @params);
    }
    elsif ($cmd eq 'PART') {
        handle_part($prefix, @params);
    }
    elsif ($cmd eq 'MODE') {
        handle_mode($prefix, @params);
    }
    elsif ($cmd eq 'PRIVMSG' || $cmd eq 'NOTICE') {
        handle_privmsg($cmd, $prefix, @params);
    }
    elsif ($cmd eq 'ERROR') {
        die "ERROR from uplink: " . join(' ', @params) . "\n";
    }
}

sub split_params {
    my ($str) = @_;
    my @out;
    while (length $str) {
        if ($str =~ s/^://) { push @out, $str; last; }
        if ($str =~ s/^(\S+)\s*//) { push @out, $1; } else { last; }
    }
    return @out;
}

# ---------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------

sub handle_uid {
    my ($cmd, $sid, @p) = @_;
    my ($nick, $hop, $ts, $umodes, $user, $host, $ip, $uid) = @p[0..7];
    return unless $uid;

    my $session_id = open_session(nick => $nick, ident => $user, host => $host);
    $users{$uid} = {
        nick => $nick, user => $user, host => $host, ip => $ip,
        umodes => $umodes, session_id => $session_id,
    };
    $nick2uid{lc $nick} = $uid;
}

sub handle_nick {
    my ($uid, @p) = @_;
    my $newnick = $p[0] or return;
    my $u = $users{$uid} or return;

    close_session($u->{session_id}, newnick => $newnick);
    my $new_session_id = open_session(nick => $newnick, ident => $u->{user}, host => $u->{host});

    delete $nick2uid{lc $u->{nick}};
    $u->{nick} = $newnick;
    $u->{session_id} = $new_session_id;
    $nick2uid{lc $newnick} = $uid;
}

sub handle_quit {
    my ($uid, @p) = @_;
    my $reason = $p[0] // '';
    my $u = delete $users{$uid} or return;
    delete $nick2uid{lc $u->{nick}};
    close_session($u->{session_id}, quit_msg => $reason);
}

sub handle_kill {
    my ($uid, @p) = @_;
    my ($target, $reason) = @p;
    return unless $target && exists $users{$target};
    my $killer_nick = ($users{$uid} && $users{$uid}{nick}) || $uid;
    my $u = delete $users{$target};
    delete $nick2uid{lc $u->{nick}};
    close_session($u->{session_id}, quit_msg => "Killed by $killer_nick: " . ($reason // ''));
}

sub handle_join {
    my ($uid, @p) = @_;
    my ($ts, $chan) = @p;
    return if !$chan || $chan eq '0';
    my $u = $users{$uid} or return;
    update_activity($u->{session_id}, $chan, 'joining', undef);
}

sub handle_sjoin {
    my ($sid, @p) = @_;
    my $chan = $p[1];
    my $nickstr = $p[-1] // '';
    return unless $chan;
    for my $tok (split ' ', $nickstr) {
        (my $uid = $tok) =~ s/^[+\@%&~!]*//;
        my $u = $users{$uid} or next;
        update_activity($u->{session_id}, $chan, 'joining', undef);
    }
}

sub handle_part {
    my ($uid, @p) = @_;
    my ($chan, $reason) = @p;
    my $u = $users{$uid} or return;
    update_activity($u->{session_id}, $chan, 'leaving', $reason);
}

sub handle_mode {
    my ($source, @p) = @_;
    my ($target, @modes) = @p;
    return unless $target;
    return if $target =~ /^#/;          # channel modes - not our concern here
    my $u = $users{$target} or return;   # only track self user-mode changes

    my $modestr = join(' ', @modes);
    my $sign = '+';
    for my $ch (split //, $modestr) {
        if    ($ch eq '+') { $sign = '+'; }
        elsif ($ch eq '-') { $sign = '-'; }
        elsif ($ch eq ' ') { next; }
        else {
            $u->{umodes} //= '';
            if ($sign eq '+') {
                $u->{umodes} .= $ch unless $u->{umodes} =~ /\Q$ch\E/;
            } else {
                $u->{umodes} =~ s/\Q$ch\E//g;
            }
        }
    }
}

sub handle_privmsg {
    my ($cmd, $uid, @p) = @_;
    my ($target, $text) = @p;
    my $u = $users{$uid};

    if ($u && $target && $target =~ /^#/) {
        my $snippet = defined $text ? substr($text, 0, 200) : '';
        update_activity($u->{session_id}, $target, 'talking', $snippet);

        # Implicit "seen nick [dN]" trigger inside a monitored channel -
        # no need to address the bot by name, same as the original.
        if ($cmd eq 'PRIVMSG' && defined $text && $text =~ /^!?seen\s+(\S+)(?:\s+d(\d+))?/i) {
            handle_seen_query($uid, $u, $1, $2, $target);
        }
        return;
    }

    return unless $cmd eq 'PRIVMSG';
    return unless $target && $target eq $service_uid;
    return unless $u;

    dispatch_command($uid, $u, $text // '');
}

# ---------------------------------------------------------------------------
# SeenServ commands
# ---------------------------------------------------------------------------

sub dispatch_command {
    my ($uid, $u, $text) = @_;
    $text =~ s/^\s+|\s+$//g;
    my ($cmd, @args) = split ' ', $text;
    $cmd = uc($cmd // '');

    if ($cmd eq 'SEEN' || $cmd eq 'S') {
        handle_seen_query($uid, $u, $args[0], ($args[1] // '') =~ /^d(\d+)$/ ? $1 : undef, undef);
    }
    elsif ($cmd eq 'HELP' || $cmd eq '') {
        reply($uid, undef, "SeenServ - tracks when a nickname (or user\@host) was last seen.");
        reply($uid, undef, "Syntax: SEEN <nickname|user\@host> [dN]  -- N = how many past sightings (max 5)");
        reply($uid, undef, "Wildcards (*) are allowed, e.g. SEEN *\@*.example.com");
        if (is_admin($u)) {
            reply($uid, undef, "Admin: JOIN #chan | PART #chan | PRIVACY #chan public|private | CHANNELS");
        }
    }
    elsif ($cmd eq 'JOIN' && is_admin($u)) {
        cmd_join($uid, $args[0]);
    }
    elsif ($cmd eq 'PART' && is_admin($u)) {
        cmd_part($uid, $args[0]);
    }
    elsif ($cmd eq 'PRIVACY' && is_admin($u)) {
        cmd_privacy($uid, $args[0], $args[1]);
    }
    elsif ($cmd eq 'CHANNELS' && is_admin($u)) {
        reply($uid, undef, "Monitored channels: " . (join(', ', sort keys %joined_chans) || '(none)'));
    }
    else {
        reply($uid, undef, "Unknown command \"$cmd\". Try HELP.");
    }
}

sub is_admin {
    my ($u) = @_;
    return $u->{umodes} && $u->{umodes} =~ /o/;
}

sub handle_seen_query {
    my ($uid, $u, $mask, $limit, $channel) = @_;
    if (!defined $mask || !length $mask) {
        reply($uid, $channel, "Syntax: SEEN <nickname|user\@host> [dN]");
        return;
    }

    # Currently-online short circuit, only meaningful for plain nick lookups.
    if (exists $nick2uid{lc $mask} && $mask !~ /\@/) {
        my $target_uid = $nick2uid{lc $mask};
        if ($target_uid ne $service_uid) {
            reply($uid, $channel, "$mask is currently ONLINE!");
            return;
        }
    }

    my @rows = lookup_seen($mask, $limit);
    if (!@rows) {
        reply($uid, $channel, "Sorry, I haven't seen $mask.");
        return;
    }

    for my $row (@rows) {
        reply($uid, $channel, describe_row($row));
    }
}

sub describe_row {
    my ($row) = @_;
    my $who = "$row->{nick} ($row->{ident}\@$row->{host})";

    if (!defined $row->{when_off}) {
        my $activity = '';
        if ($row->{last_action} && $row->{last_action} eq 'talking' && $row->{last_channel}) {
            my $snippet = defined $row->{last_message} && length $row->{last_message}
                ? " saying: $row->{last_message}" : "";
            $activity = ", last seen talking on $row->{last_channel}$snippet";
        } elsif ($row->{last_action} && $row->{last_channel}) {
            $activity = ", last seen $row->{last_action} $row->{last_channel}";
        }
        return "$who is currently ONLINE$activity.";
    }

    my $ago = time_ago($row->{when_off});
    my $tail;
    if ($row->{newnick}) {
        $tail = "user changed nick to $row->{newnick}";
    } elsif ($row->{quit_msg}) {
        $tail = "quit: ($row->{quit_msg})";
    } else {
        $tail = "";
    }
    return "$who was last on IRC $ago ago" . ($tail ? ", $tail" : ".");
}

sub cmd_join {
    my ($uid, $chan) = @_;
    if (!$chan || $chan !~ /^#/) {
        reply($uid, undef, "Syntax: JOIN #channel");
        return;
    }
    eval {
        $dbh->do(
            "INSERT INTO chans (chan, joined, privacy, ts) VALUES (?, 1, 'public', ?)
             ON DUPLICATE KEY UPDATE joined = 1",
            undef, $chan, time()
        );
    };
    if ($@) { reply($uid, undef, "DB error, see log."); log_msg($@); return; }

    send_line(":$our_sid SJOIN " . int(time()) . " $chan + :\@$service_uid");
    $joined_chans{lc $chan} = 1;
    reply($uid, undef, "Joined $chan.");
}

sub cmd_part {
    my ($uid, $chan) = @_;
    if (!$chan || $chan !~ /^#/) {
        reply($uid, undef, "Syntax: PART #channel");
        return;
    }
    eval { $dbh->do("UPDATE chans SET joined = 0 WHERE chan = ?", undef, $chan); };
    if ($@) { reply($uid, undef, "DB error, see log."); log_msg($@); return; }

    send_line(":$service_uid PART $chan :leaving");
    delete $joined_chans{lc $chan};
    reply($uid, undef, "Parted $chan.");
}

sub cmd_privacy {
    my ($uid, $chan, $mode) = @_;
    if (!$chan || $chan !~ /^#/ || !$mode || $mode !~ /^(public|private)$/) {
        reply($uid, undef, "Syntax: PRIVACY #channel public|private");
        return;
    }
    eval { $dbh->do("UPDATE chans SET privacy = ? WHERE chan = ?", undef, $mode, $chan); };
    if ($@) { reply($uid, undef, "DB error, see log."); log_msg($@); return; }
    reply($uid, undef, "Privacy for $chan set to $mode.");
}

# Reply to a SEEN query (or any command). If $channel is set and that
# channel's privacy is 'public', answer in the channel; otherwise answer
# privately via NOTICE - mirrors the old bot's "answerprivate" behaviour.
sub reply {
    my ($uid, $channel, $text) = @_;
    my $u = $users{$uid};
    my $nick = $u ? $u->{nick} : $uid;

    if ($channel && chan_privacy($channel) ne 'private') {
        send_line(":$service_uid PRIVMSG $channel :$nick: $text");
    } else {
        send_line(":$service_uid NOTICE $uid :$text");
    }
}

# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------

sub time_ago {
    my ($mysql_datetime) = @_;
    my @t = $mysql_datetime =~ /^(\d+)-(\d+)-(\d+) (\d+):(\d+):(\d+)$/;
    return $mysql_datetime unless @t;
    my $then = POSIX::mktime($t[5], $t[4], $t[3], $t[2], $t[1] - 1, $t[0] - 1900);
    my $diff = time() - $then;
    return "a moment" if $diff < 1;

    my $sec = $diff % 60;  $diff = int($diff / 60);
    my $min = $diff % 60;  $diff = int($diff / 60);
    my $hr  = $diff % 24;  $diff = int($diff / 24);
    my $day = $diff;

    my @parts;
    push @parts, "${day}d" if $day;
    push @parts, "${hr}h"  if $hr;
    push @parts, "${min}m" if $min;
    push @parts, "${sec}s" if $sec || !@parts;
    return join(' ', @parts);
}

sub log_msg {
    my ($msg) = @_;
    my $ts = strftime("%Y-%m-%d %H:%M:%S", localtime);
    print STDERR "[$ts] $msg\n";
}

sub debug_log {
    return unless $cfg{debug} && $cfg{debug} =~ /^(1|yes|true)$/i;
    log_msg(shift);
}

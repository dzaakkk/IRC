
SeenServ v2

TS6 services daemon written in Perl + MySQL that handles SEEN <nick> — the second generation of the script, now with functions ported from the original UniBG SeenServ (ivanatora@gmail.com, 2005), but linked via the modern TS6 protocol to ircd-ratbox (tested with 3.1.x / synandro fork).

What's new compared to v1

Taken directly from ivanatora's original and ported to TS6:

Session history, not just the last record. Every network login opens a new row in seen (when_on/when_off), so:

/msg SeenServ SEEN ivo d5

displays up to the last 5 "appearances" of the nickname, rather than only the most recent one.

Wildcard search by user@host.

/msg SeenServ SEEN *@*.example.com

* is converted to SQL %; any other %/_ characters in the query are escaped so they do not unintentionally affect the search.

Public SEEN in a channel, with private fallback. If SeenServ is present in a channel and someone types seen nick (without even addressing the bot by name), they receive a response directly in the channel — unless the channel is marked as PRIVACY #chan private, in which case the response is sent as a NOTICE.

Dynamic join/part of channels, restricted to IRC opers.

/msg SeenServ JOIN #newchan
/msg SeenServ PART #newchan
/msg SeenServ PRIVACY #newchan private
/msg SeenServ CHANNELS

The original relied on a separate CS (ChanServ) component from hybserv to tell SeenServ when to join/part channels; here, instead, admin status is checked directly through the IRC oper flag (+o) of the sender, tracked through UID/MODE lines on the link — no additional services components are required.

Cleanup on restart. On startup, all "stuck" sessions (when_off IS NULL) are closed with the note SeenServ restart, exactly as in the original — preventing phantom "online" records after a SQUIT.
1. Dependencies
apt install libdbi-perl libdbd-mysql-perl mysql-server
2. Database
mysql -u root -p -e "CREATE DATABASE seenserv CHARACTER SET utf8mb4;"
mysql -u root -p -e "CREATE USER 'seenserv'@'localhost' IDENTIFIED BY 'ChangeThisDbPassword';"
mysql -u root -p -e "GRANT ALL PRIVILEGES ON seenserv.* TO 'seenserv'@'localhost';"
mysql -u seenserv -p seenserv < schema.sql
3. ircd-ratbox configuration (ircd.conf)
connect {
	name = "services.yournetwork.bg";
	host = "127.0.0.1";
	send_password = "ChangeThisLinkPassword";
	accept_password = "ChangeThisLinkPassword";
	port = 6900;
	class = "server";
	flags = autoconn;
};

service {
	name = "services.yournetwork.bg";
};

server_name / server_sid / uplink_port / link_password in seenserv.conf must match the above. server_sid must be unique across the network.

4. Configuration
cp seenserv.conf.example seenserv.conf
$EDITOR seenserv.conf
chmod 600 seenserv.conf
./seenserv.pl seenserv.conf
5. Usage
/msg SeenServ SEEN Ivan               -> last seen
/msg SeenServ SEEN Ivan d3            -> last 3 appearances
/msg SeenServ SEEN *@*.sofia.bg       -> wildcard host search
[#help] seen Ivan                     -> public query directly in the channel
/msg SeenServ JOIN #newchan           -> IRC opers only
/msg SeenServ PART #newchan           -> IRC opers only
/msg SeenServ PRIVACY #newchan private -> IRC opers only
/msg SeenServ HELP
6. Admin access

The JOIN, PART, PRIVACY, and CHANNELS commands require the sender to be an IRC oper (umode +o) at the time the command is sent. The script tracks umode changes for every user through MODE lines received from the uplink, ensuring that the status is updated correctly when /oper is used.

7. systemd
# /etc/systemd/system/seenserv.service
[Unit]
Description=SeenServ IRC service
After=network.target mysql.service

[Service]
Type=simple
User=irc
WorkingDirectory=/opt/seenserv
ExecStart=/opt/seenserv/seenserv.pl /opt/seenserv/seenserv.conf
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
8. Differences compared to the original from 2005 (for reference)
The protocol is TS6 (SID+UID) instead of the old PASS ... :TS / bare NICK introductions from the hyb7 era — required for a modern ircd-ratbox.
Admin commands go through oper status instead of a separate CS pseudo-user and !ssctl commands.
SQL queries use placeholders (?) instead of manually escaping strings directly in the SQL text — safer against SQL injection.
The fix/fixm/fixc/fixq regex filters from the original are no longer required for SQL protection itself (replaced by placeholders), but wildcard escaping (like_pattern) provides similar protection for LIKE queries.

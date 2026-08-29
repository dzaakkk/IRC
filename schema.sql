-- SeenServ v2 MySQL schema
--
-- Usage:
--   mysql -u root -p -e "CREATE DATABASE seenserv CHARACTER SET utf8mb4;"
--   mysql -u root -p -e "CREATE USER 'seenserv'@'localhost' IDENTIFIED BY 'ChangeThisDbPassword';"
--   mysql -u root -p -e "GRANT ALL PRIVILEGES ON seenserv.* TO 'seenserv'@'localhost';"
--   mysql -u seenserv -p seenserv < schema.sql

-- One row per "session" (connect .. disconnect/nick-change). This is the
-- part borrowed from the original 2005 UniBG/BgChat SeenServ: it keeps full
-- history, so "SEEN nick d5" can show the last 5 sightings, not just the
-- latest one.
CREATE TABLE IF NOT EXISTS seen (
    id            INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    nick          VARCHAR(31)  NOT NULL,
    ident         VARCHAR(31)  NOT NULL DEFAULT '',
    host          VARCHAR(128) NOT NULL DEFAULT '',
    when_on       DATETIME     NOT NULL,
    when_off      DATETIME     DEFAULT NULL,       -- NULL while still connected
    newnick       VARCHAR(31)  DEFAULT NULL,        -- set if session ended via nick change
    quit_msg      VARCHAR(400) DEFAULT NULL,        -- set if session ended via quit/kill
    last_channel  VARCHAR(64)  DEFAULT NULL,        -- most recent channel activity
    last_action   VARCHAR(16)  DEFAULT NULL,        -- joining / leaving / talking
    last_message  VARCHAR(400) DEFAULT NULL,        -- part reason / message snippet
    INDEX idx_nick (nick),
    INDEX idx_ident_host (ident, host),
    INDEX idx_when_off (when_off)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Channels SeenServ sits in, plus per-channel reply privacy - the
-- "answerprivate" concept from the original bot, renamed to `privacy`.
CREATE TABLE IF NOT EXISTS chans (
    id       INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    chan     VARCHAR(64)  NOT NULL UNIQUE,
    joined   TINYINT(1)   NOT NULL DEFAULT 1,
    privacy  ENUM('public','private') NOT NULL DEFAULT 'public',
    ts       INT UNSIGNED NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

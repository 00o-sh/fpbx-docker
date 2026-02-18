-- Create the CDR database and grant permissions.
-- The primary 'asterisk' database is created automatically
-- by the MYSQL_DATABASE env var in the MariaDB container.

CREATE DATABASE IF NOT EXISTS `asteriskcdrdb`;

GRANT ALL PRIVILEGES ON `asterisk`.* TO 'freepbx'@'%';
GRANT ALL PRIVILEGES ON `asteriskcdrdb`.* TO 'freepbx'@'%';
FLUSH PRIVILEGES;

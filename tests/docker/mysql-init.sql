-- A user on the legacy mysql_native_password plugin.
CREATE USER 'native_user'@'%' IDENTIFIED WITH mysql_native_password BY 'native_pw';
GRANT ALL PRIVILEGES ON dbdash_test.* TO 'native_user'@'%';

-- A user whose password is stored as MD5, to exercise md5 authentication.
SET password_encryption = 'md5';
CREATE USER md5_user PASSWORD 'md5_pw';
GRANT ALL PRIVILEGES ON DATABASE dbdash_test TO md5_user;

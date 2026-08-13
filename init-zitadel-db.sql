-- Prod: the default DB is the app's `grg`, so create ZITADEL's database on first init.
-- .sql (read by psql), not .sh, to avoid the noexec bind-mount issue on Docker Desktop.
CREATE DATABASE zitadel;

-- PiBench: one-time setup on the SHARED PostgreSQL instance.
-- Creates only the pibench role + database. Touches nothing else.
-- Run (password passed as a psql variable):
--   docker exec -i shared-postgres psql -U postgres -v pw='YOUR_DB_PASSWORD' < db/init.sql

SELECT 'CREATE ROLE pibench_db_user LOGIN PASSWORD ' || quote_literal(:'pw')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pibench_db_user') \gexec

SELECT 'CREATE DATABASE pibench_db OWNER pibench_db_user'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'pibench_db') \gexec

REVOKE ALL ON DATABASE pibench_db FROM PUBLIC;
GRANT CONNECT, TEMP ON DATABASE pibench_db TO pibench_db_user;

-- Note: private.get_secret function is now defined in migration 00024_add_vault_get_secret_function.sql
-- This file can be used for seed data only

-- ----------------------------------------------------------------------------
-- LOCAL grant repair (seed.sql runs ONLY on `supabase db reset`/start, never on
-- staging/prod). Newer Supabase CLI versions no longer hand out default grants
-- on public tables (anon/authenticated keep only
-- TRUNCATE/REFERENCES/TRIGGER/MAINTAIN) — the migration chain comes from the
-- legacy era and relies on the old defaults. Without this block every local
-- integration test fails with "permission denied for table profiles" (RLS is
-- the second layer; the table grant is the first). Staging/prod have the legacy
-- default ACL — nothing to do there; NEW tables get their grant explicitly in
-- the migration from 00069 on.
-- ----------------------------------------------------------------------------
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public
  TO anon, authenticated, service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public
  TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES
  TO anon, authenticated, service_role;

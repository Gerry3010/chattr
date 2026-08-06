-- Note: private.get_secret function is now defined in migration 00024_add_vault_get_secret_function.sql
-- This file can be used for seed data only

-- ----------------------------------------------------------------------------
-- LOKALER Grant-Repair (seed.sql läuft NUR bei `supabase db reset`/start,
-- nie auf Staging/Prod). Neuere Supabase-CLI-Versionen vergeben keine
-- Default-Grants mehr auf public-Tabellen (anon/authenticated behalten nur
-- TRUNCATE/REFERENCES/TRIGGER/MAINTAIN) — die Migrationskette stammt aus der
-- Legacy-Ära und verlässt sich auf die alten Defaults. Ohne diesen Block
-- scheitert jeder lokale Integrationstest an "permission denied for table
-- profiles" (RLS ist die zweite Schicht; der Tabellen-Grant ist die erste).
-- Staging/Prod haben die Legacy-Default-ACL — dort ist nichts zu tun; NEUE
-- Tabellen bekommen ihren Grant ab 00069 explizit in der Migration.
-- ----------------------------------------------------------------------------
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public
  TO anon, authenticated, service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public
  TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES
  TO anon, authenticated, service_role;

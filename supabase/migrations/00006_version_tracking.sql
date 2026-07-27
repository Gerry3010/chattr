-- =====================================================
-- Version Tracking System
-- =====================================================
-- This migration adds version tracking for the backend
-- to enable client-server compatibility checks

-- Create app_versions table
CREATE TABLE IF NOT EXISTS app_versions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    component TEXT NOT NULL CHECK (component IN ('backend', 'migrations', 'functions', 'database')),
    version TEXT NOT NULL,
    description TEXT,
    deployed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deployed_by TEXT,
    metadata JSONB DEFAULT '{}'::jsonb,
    
    -- Ensure only one active version per component
    UNIQUE (component, version)
);

-- Create index for faster lookups
CREATE INDEX IF NOT EXISTS idx_app_versions_component ON app_versions(component);
CREATE INDEX IF NOT EXISTS idx_app_versions_deployed_at ON app_versions(deployed_at DESC);

-- Enable RLS
ALTER TABLE app_versions ENABLE ROW LEVEL SECURITY;

-- Public read access to versions (no auth required)
CREATE POLICY "Anyone can read version information"
    ON app_versions
    FOR SELECT
    USING (true);

-- Only service role can insert/update versions
CREATE POLICY "Service role can manage versions"
    ON app_versions
    FOR ALL
    USING (auth.role() = 'service_role');

-- =====================================================
-- Functions
-- =====================================================

-- Get current backend version
CREATE OR REPLACE FUNCTION get_backend_version()
RETURNS TABLE (
    component TEXT,
    version TEXT,
    deployed_at TIMESTAMPTZ,
    description TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        av.component,
        av.version,
        av.deployed_at,
        av.description
    FROM app_versions av
    WHERE av.component = 'backend'
    ORDER BY av.deployed_at DESC
    LIMIT 1;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Get all component versions
CREATE OR REPLACE FUNCTION get_all_versions()
RETURNS TABLE (
    component TEXT,
    version TEXT,
    deployed_at TIMESTAMPTZ,
    description TEXT,
    metadata JSONB
) AS $$
BEGIN
    RETURN QUERY
    WITH ranked_versions AS (
        SELECT 
            av.component,
            av.version,
            av.deployed_at,
            av.description,
            av.metadata,
            ROW_NUMBER() OVER (PARTITION BY av.component ORDER BY av.deployed_at DESC) as rn
        FROM app_versions av
    )
    SELECT 
        rv.component,
        rv.version,
        rv.deployed_at,
        rv.description,
        rv.metadata
    FROM ranked_versions rv
    WHERE rv.rn = 1
    ORDER BY rv.component;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Register a new version
CREATE OR REPLACE FUNCTION register_version(
    p_component TEXT,
    p_version TEXT,
    p_description TEXT DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'::jsonb
)
RETURNS UUID AS $$
DECLARE
    v_id UUID;
BEGIN
    INSERT INTO app_versions (component, version, description, metadata)
    VALUES (p_component, p_version, p_description, p_metadata)
    ON CONFLICT (component, version) DO UPDATE
    SET 
        deployed_at = NOW(),
        description = COALESCE(EXCLUDED.description, app_versions.description),
        metadata = EXCLUDED.metadata
    RETURNING id INTO v_id;
    
    RETURN v_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =====================================================
-- Initial Version Data
-- =====================================================

-- Insert initial backend version
INSERT INTO app_versions (component, version, description, deployed_by) 
VALUES 
    ('backend', '1.0.0', 'Initial backend version with version tracking', 'migration'),
    ('migrations', '1.0.0', 'Initial migration version (00006)', 'migration'),
    ('database', '1.0.0', 'Database schema version 1.0.0', 'migration')
ON CONFLICT (component, version) DO NOTHING;

-- =====================================================
-- Comments
-- =====================================================

COMMENT ON TABLE app_versions IS 'Tracks versions of different system components for compatibility checking';
COMMENT ON FUNCTION get_backend_version() IS 'Returns the current backend version for client compatibility checks';
COMMENT ON FUNCTION get_all_versions() IS 'Returns the latest version for each component';
COMMENT ON FUNCTION register_version(TEXT, TEXT, TEXT, JSONB) IS 'Registers a new version deployment for a component';

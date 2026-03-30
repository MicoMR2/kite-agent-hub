defmodule KiteAgentHub.Repo.Migrations.AddRlsPolicies do
  use Ecto.Migration

  def up do
    # ── Helper function ──────────────────────────────────────────────────────
    # Returns the org IDs the current session user is a member of.
    # Reads app.current_user_id set by Repo.with_user/2 before each query.
    # Returns empty set when not set — unauthenticated connections see zero rows.
    execute """
    CREATE OR REPLACE FUNCTION current_user_org_ids()
    RETURNS SETOF uuid AS $$
      SELECT organization_id
      FROM org_memberships
      WHERE user_id::text = COALESCE(current_setting('app.current_user_id', true), '')
    $$ LANGUAGE sql STABLE SECURITY DEFINER;
    """

    # ── Enable RLS on all tables ──────────────────────────────────────────────
    execute "ALTER TABLE users ENABLE ROW LEVEL SECURITY;"
    execute "ALTER TABLE users FORCE ROW LEVEL SECURITY;"
    execute "ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;"
    execute "ALTER TABLE organizations FORCE ROW LEVEL SECURITY;"
    execute "ALTER TABLE org_memberships ENABLE ROW LEVEL SECURITY;"
    execute "ALTER TABLE org_memberships FORCE ROW LEVEL SECURITY;"
    execute "ALTER TABLE kite_agents ENABLE ROW LEVEL SECURITY;"
    execute "ALTER TABLE kite_agents FORCE ROW LEVEL SECURITY;"
    execute "ALTER TABLE trade_records ENABLE ROW LEVEL SECURITY;"
    execute "ALTER TABLE trade_records FORCE ROW LEVEL SECURITY;"

    # ── users ─────────────────────────────────────────────────────────────────
    execute """
    CREATE POLICY users_self_select ON users
      FOR SELECT
      USING (id::text = COALESCE(current_setting('app.current_user_id', true), ''));
    """

    execute """
    CREATE POLICY users_self_update ON users
      FOR UPDATE
      USING (id::text = COALESCE(current_setting('app.current_user_id', true), ''));
    """

    # INSERT open — no user context exists yet at registration time
    execute """
    CREATE POLICY users_insert ON users
      FOR INSERT
      WITH CHECK (true);
    """

    # ── organizations ─────────────────────────────────────────────────────────
    execute """
    CREATE POLICY orgs_member_select ON organizations
      FOR SELECT
      USING (id IN (SELECT current_user_org_ids()));
    """

    execute """
    CREATE POLICY orgs_owner_insert ON organizations
      FOR INSERT
      WITH CHECK (true);
    """

    execute """
    CREATE POLICY orgs_owner_update ON organizations
      FOR UPDATE
      USING (
        id IN (
          SELECT organization_id FROM org_memberships
          WHERE user_id::text = COALESCE(current_setting('app.current_user_id', true), '')
            AND role = 'owner'
        )
      );
    """

    # ── org_memberships ───────────────────────────────────────────────────────
    execute """
    CREATE POLICY memberships_member_select ON org_memberships
      FOR SELECT
      USING (organization_id IN (SELECT current_user_org_ids()));
    """

    execute """
    CREATE POLICY memberships_owner_insert ON org_memberships
      FOR INSERT
      WITH CHECK (
        organization_id IN (
          SELECT organization_id FROM org_memberships
          WHERE user_id::text = COALESCE(current_setting('app.current_user_id', true), '')
            AND role IN ('owner', 'admin')
        )
        OR user_id::text = COALESCE(current_setting('app.current_user_id', true), '')
      );
    """

    execute """
    CREATE POLICY memberships_owner_delete ON org_memberships
      FOR DELETE
      USING (
        organization_id IN (
          SELECT organization_id FROM org_memberships m2
          WHERE m2.user_id::text = COALESCE(current_setting('app.current_user_id', true), '')
            AND m2.role IN ('owner', 'admin')
        )
      );
    """

    # ── kite_agents ───────────────────────────────────────────────────────────
    execute """
    CREATE POLICY kite_agents_org_select ON kite_agents
      FOR SELECT
      USING (organization_id IN (SELECT current_user_org_ids()));
    """

    execute """
    CREATE POLICY kite_agents_org_insert ON kite_agents
      FOR INSERT
      WITH CHECK (organization_id IN (SELECT current_user_org_ids()));
    """

    execute """
    CREATE POLICY kite_agents_org_update ON kite_agents
      FOR UPDATE
      USING (organization_id IN (SELECT current_user_org_ids()));
    """

    execute """
    CREATE POLICY kite_agents_org_delete ON kite_agents
      FOR DELETE
      USING (organization_id IN (SELECT current_user_org_ids()));
    """

    # ── trade_records ─────────────────────────────────────────────────────────
    # Append-only at DB level — no UPDATE or DELETE policies created.
    execute """
    CREATE POLICY trade_records_org_select ON trade_records
      FOR SELECT
      USING (
        kite_agent_id IN (
          SELECT id FROM kite_agents
          WHERE organization_id IN (SELECT current_user_org_ids())
        )
      );
    """

    execute """
    CREATE POLICY trade_records_org_insert ON trade_records
      FOR INSERT
      WITH CHECK (
        kite_agent_id IN (
          SELECT id FROM kite_agents
          WHERE organization_id IN (SELECT current_user_org_ids())
        )
      );
    """
  end

  def down do
    execute "DROP POLICY IF EXISTS users_self_select ON users;"
    execute "DROP POLICY IF EXISTS users_self_update ON users;"
    execute "DROP POLICY IF EXISTS users_insert ON users;"
    execute "DROP POLICY IF EXISTS orgs_member_select ON organizations;"
    execute "DROP POLICY IF EXISTS orgs_owner_insert ON organizations;"
    execute "DROP POLICY IF EXISTS orgs_owner_update ON organizations;"
    execute "DROP POLICY IF EXISTS memberships_member_select ON org_memberships;"
    execute "DROP POLICY IF EXISTS memberships_owner_insert ON org_memberships;"
    execute "DROP POLICY IF EXISTS memberships_owner_delete ON org_memberships;"
    execute "DROP POLICY IF EXISTS kite_agents_org_select ON kite_agents;"
    execute "DROP POLICY IF EXISTS kite_agents_org_insert ON kite_agents;"
    execute "DROP POLICY IF EXISTS kite_agents_org_update ON kite_agents;"
    execute "DROP POLICY IF EXISTS kite_agents_org_delete ON kite_agents;"
    execute "DROP POLICY IF EXISTS trade_records_org_select ON trade_records;"
    execute "DROP POLICY IF EXISTS trade_records_org_insert ON trade_records;"

    execute "ALTER TABLE trade_records DISABLE ROW LEVEL SECURITY;"
    execute "ALTER TABLE kite_agents DISABLE ROW LEVEL SECURITY;"
    execute "ALTER TABLE org_memberships DISABLE ROW LEVEL SECURITY;"
    execute "ALTER TABLE organizations DISABLE ROW LEVEL SECURITY;"
    execute "ALTER TABLE users DISABLE ROW LEVEL SECURITY;"

    execute "DROP FUNCTION IF EXISTS current_user_org_ids();"
  end
end

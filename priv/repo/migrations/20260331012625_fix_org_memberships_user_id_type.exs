defmodule KiteAgentHub.Repo.Migrations.FixOrgMembershipsUserIdType do
  use Ecto.Migration

  def up do
    # Drop policies that DIRECTLY reference org_memberships.user_id column.
    # These are not covered by the CASCADE on the function below.
    execute "DROP POLICY IF EXISTS memberships_owner_insert ON org_memberships"
    execute "DROP POLICY IF EXISTS memberships_owner_delete ON org_memberships"
    execute "DROP POLICY IF EXISTS orgs_owner_update ON organizations"

    # DROP FUNCTION CASCADE drops all policies that call current_user_org_ids():
    # orgs_member_select, memberships_member_select, kite_agents_org_*, trade_records_*
    execute "DROP FUNCTION IF EXISTS current_user_org_ids() CASCADE"

    execute "ALTER TABLE org_memberships DROP CONSTRAINT IF EXISTS org_memberships_user_id_fkey"

    # Cast column to bigint. Safe: org_memberships is empty (no users/orgs registered yet).
    execute "ALTER TABLE org_memberships ALTER COLUMN user_id TYPE bigint USING user_id::text::bigint"

    # Restore FK
    execute """
    ALTER TABLE org_memberships
      ADD CONSTRAINT org_memberships_user_id_fkey
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    """

    # Recreate current_user_org_ids() helper
    execute """
    CREATE OR REPLACE FUNCTION current_user_org_ids()
    RETURNS SETOF uuid AS $$
      SELECT organization_id
      FROM org_memberships
      WHERE user_id::text = COALESCE(current_setting('app.current_user_id', true), '')
    $$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public;
    """

    # Recreate all RLS policies that were dropped by CASCADE

    # organizations
    execute """
    CREATE POLICY orgs_member_select ON organizations
      FOR SELECT
      USING (id IN (SELECT current_user_org_ids()))
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
      )
    """

    # org_memberships
    execute """
    CREATE POLICY memberships_member_select ON org_memberships
      FOR SELECT
      USING (organization_id IN (SELECT current_user_org_ids()))
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
      )
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
      )
    """

    # kite_agents
    execute """
    CREATE POLICY kite_agents_org_select ON kite_agents
      FOR SELECT
      USING (organization_id IN (SELECT current_user_org_ids()))
    """

    execute """
    CREATE POLICY kite_agents_org_insert ON kite_agents
      FOR INSERT
      WITH CHECK (organization_id IN (SELECT current_user_org_ids()))
    """

    execute """
    CREATE POLICY kite_agents_org_update ON kite_agents
      FOR UPDATE
      USING (organization_id IN (SELECT current_user_org_ids()))
    """

    execute """
    CREATE POLICY kite_agents_org_delete ON kite_agents
      FOR DELETE
      USING (organization_id IN (SELECT current_user_org_ids()))
    """

    # trade_records
    execute """
    CREATE POLICY trade_records_org_select ON trade_records
      FOR SELECT
      USING (
        kite_agent_id IN (
          SELECT id FROM kite_agents
          WHERE organization_id IN (SELECT current_user_org_ids())
        )
      )
    """

    execute """
    CREATE POLICY trade_records_org_insert ON trade_records
      FOR INSERT
      WITH CHECK (
        kite_agent_id IN (
          SELECT id FROM kite_agents
          WHERE organization_id IN (SELECT current_user_org_ids())
        )
      )
    """
  end

  def down do
    execute "DROP POLICY IF EXISTS memberships_owner_insert ON org_memberships"
    execute "DROP POLICY IF EXISTS memberships_owner_delete ON org_memberships"
    execute "DROP POLICY IF EXISTS orgs_owner_update ON organizations"
    execute "DROP FUNCTION IF EXISTS current_user_org_ids() CASCADE"
    execute "ALTER TABLE org_memberships DROP CONSTRAINT IF EXISTS org_memberships_user_id_fkey"
    execute "ALTER TABLE org_memberships ALTER COLUMN user_id TYPE uuid USING user_id::text::uuid"

    execute """
    ALTER TABLE org_memberships
      ADD CONSTRAINT org_memberships_user_id_fkey
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    """

    execute """
    CREATE OR REPLACE FUNCTION current_user_org_ids()
    RETURNS SETOF uuid AS $$
      SELECT organization_id
      FROM org_memberships
      WHERE user_id::text = COALESCE(current_setting('app.current_user_id', true), '')
    $$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public;
    """

    execute """
    CREATE POLICY orgs_member_select ON organizations
      FOR SELECT USING (id IN (SELECT current_user_org_ids()))
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
      )
    """

    execute """
    CREATE POLICY memberships_member_select ON org_memberships
      FOR SELECT USING (organization_id IN (SELECT current_user_org_ids()))
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
      )
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
      )
    """

    execute "CREATE POLICY kite_agents_org_select ON kite_agents FOR SELECT USING (organization_id IN (SELECT current_user_org_ids()))"
    execute "CREATE POLICY kite_agents_org_insert ON kite_agents FOR INSERT WITH CHECK (organization_id IN (SELECT current_user_org_ids()))"
    execute "CREATE POLICY kite_agents_org_update ON kite_agents FOR UPDATE USING (organization_id IN (SELECT current_user_org_ids()))"
    execute "CREATE POLICY kite_agents_org_delete ON kite_agents FOR DELETE USING (organization_id IN (SELECT current_user_org_ids()))"

    execute """
    CREATE POLICY trade_records_org_select ON trade_records
      FOR SELECT
      USING (kite_agent_id IN (SELECT id FROM kite_agents WHERE organization_id IN (SELECT current_user_org_ids())))
    """

    execute """
    CREATE POLICY trade_records_org_insert ON trade_records
      FOR INSERT
      WITH CHECK (kite_agent_id IN (SELECT id FROM kite_agents WHERE organization_id IN (SELECT current_user_org_ids())))
    """
  end
end

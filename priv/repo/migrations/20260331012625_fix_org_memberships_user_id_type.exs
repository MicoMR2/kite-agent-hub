defmodule KiteAgentHub.Repo.Migrations.FixOrgMembershipsUserIdType do
  use Ecto.Migration

  def up do
    # Drop all RLS policies and the helper function that reference org_memberships.user_id.
    # Postgres blocks ALTER COLUMN TYPE when policies depend on the column.
    execute "DROP POLICY IF EXISTS orgs_owner_update ON organizations"
    execute "DROP POLICY IF EXISTS memberships_member_select ON org_memberships"
    execute "DROP POLICY IF EXISTS memberships_owner_insert ON org_memberships"
    execute "DROP POLICY IF EXISTS memberships_owner_delete ON org_memberships"
    execute "DROP FUNCTION IF EXISTS current_user_org_ids()"

    # Drop and re-add the FK constraint
    execute "ALTER TABLE org_memberships DROP CONSTRAINT IF EXISTS org_memberships_user_id_fkey"

    # Cast column to bigint. Safe: table is empty in prod (no users/orgs yet).
    execute "ALTER TABLE org_memberships ALTER COLUMN user_id TYPE bigint USING user_id::text::bigint"

    # Restore FK
    execute """
    ALTER TABLE org_memberships
      ADD CONSTRAINT org_memberships_user_id_fkey
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    """

    # Recreate the current_user_org_ids() helper (body is identical — ::text cast works for bigint)
    execute """
    CREATE OR REPLACE FUNCTION current_user_org_ids()
    RETURNS SETOF uuid AS $$
      SELECT organization_id
      FROM org_memberships
      WHERE user_id::text = COALESCE(current_setting('app.current_user_id', true), '')
    $$ LANGUAGE sql STABLE SECURITY DEFINER;
    """

    # Recreate all dropped policies
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
  end

  def down do
    # Reverse: restore uuid type (safe only if table is empty)
    execute "DROP POLICY IF EXISTS orgs_owner_update ON organizations"
    execute "DROP POLICY IF EXISTS memberships_member_select ON org_memberships"
    execute "DROP POLICY IF EXISTS memberships_owner_insert ON org_memberships"
    execute "DROP POLICY IF EXISTS memberships_owner_delete ON org_memberships"
    execute "DROP FUNCTION IF EXISTS current_user_org_ids()"

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
    $$ LANGUAGE sql STABLE SECURITY DEFINER;
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
  end
end

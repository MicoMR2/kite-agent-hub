defmodule KiteAgentHub.Repo.Migrations.FixOrgMembershipsUserIdType do
  use Ecto.Migration

  def up do
    # Drop the existing FK constraint (references users, but column may be uuid)
    execute "ALTER TABLE org_memberships DROP CONSTRAINT IF EXISTS org_memberships_user_id_fkey"

    # Change user_id column to bigint (matching users.id which is a default bigint PK).
    # USING clause handles cast — safe when table is empty or values are valid bigints.
    execute "ALTER TABLE org_memberships ALTER COLUMN user_id TYPE bigint USING user_id::text::bigint"

    # Re-add the FK constraint with correct types
    execute """
    ALTER TABLE org_memberships
      ADD CONSTRAINT org_memberships_user_id_fkey
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    """
  end

  def down do
    execute "ALTER TABLE org_memberships DROP CONSTRAINT IF EXISTS org_memberships_user_id_fkey"
    execute "ALTER TABLE org_memberships ALTER COLUMN user_id TYPE uuid USING user_id::text::uuid"

    execute """
    ALTER TABLE org_memberships
      ADD CONSTRAINT org_memberships_user_id_fkey
      FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    """
  end
end

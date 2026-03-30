defmodule KiteAgentHub.Repo.Migrations.AddServerBootstrapFunctions do
  use Ecto.Migration

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION active_agents_with_owners()
    RETURNS TABLE(agent_id uuid, owner_user_id bigint) AS $$
      SELECT a.id, m.user_id
      FROM kite_agents a
      JOIN org_memberships m
        ON m.organization_id = a.organization_id
       AND m.role = 'owner'
      WHERE a.status = 'active'
    $$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION owner_user_id_for_agent(p_agent_id uuid)
    RETURNS bigint AS $$
      SELECT m.user_id
      FROM kite_agents a
      JOIN org_memberships m
        ON m.organization_id = a.organization_id
       AND m.role = 'owner'
      WHERE a.id = p_agent_id
      LIMIT 1
    $$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public;
    """)
  end

  def down do
    execute("DROP FUNCTION IF EXISTS active_agents_with_owners()")
    execute("DROP FUNCTION IF EXISTS owner_user_id_for_agent(uuid)")
  end
end

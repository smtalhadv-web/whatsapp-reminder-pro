type WriteResult = { data: { id: string } | null; error: { message: string } | null };
type WriteQuery = {
  eq(column: string, value: string): WriteQuery;
  select(columns: string): WriteQuery;
  single(): PromiseLike<WriteResult>;
};
type WorkspaceWriter = {
  from(table: string): {
    insert(payload: Record<string, unknown>): WriteQuery;
    update(payload: Record<string, unknown>): WriteQuery;
  };
};

/** Keep UI identities in sync with persisted rows; never treat a hidden row as saved. */
export async function writeWorkspaceRow(
  client: WorkspaceWriter,
  table: string,
  businessId: string,
  payload: Record<string, unknown>,
  id?: string,
): Promise<string> {
  const query = id
    ? client.from(table).update({ ...payload, updated_at: new Date().toISOString() })
      .eq('id', id).eq('business_id', businessId)
    : client.from(table).insert({ ...payload, business_id: businessId });
  const { data, error } = await query.select('id').single();
  if (error) throw new Error(error.message);
  if (!data?.id) throw new Error('The saved record was not returned. Reload the workspace before retrying.');
  return data.id;
}

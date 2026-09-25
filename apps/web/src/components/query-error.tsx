export default function QueryError({ error }: { error: unknown }) {
  const msg = error instanceof Error ? error.message : String(error);
  return <p className="text-destructive break-all">Chain read failed: {msg.split("\n")[0]}</p>;
}

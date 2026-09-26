export default function QueryError({ error }: { error: unknown }) {
  const msg = error instanceof Error ? error.message : String(error);
  return (
    <p className="rs-error" role="alert" style={{ margin: 0 }}>
      Chain read failed: {msg.split("\n")[0]}
    </p>
  );
}

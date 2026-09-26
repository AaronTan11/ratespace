import { Loader2 } from "lucide-react";

export default function Loader() {
  return (
    <div className="flex h-full items-center justify-center pt-8" style={{ color: "var(--text-2)" }}>
      <Loader2 className="animate-spin" size={16} />
    </div>
  );
}

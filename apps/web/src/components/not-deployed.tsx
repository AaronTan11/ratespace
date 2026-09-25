import { Card, CardContent, CardHeader, CardTitle } from "@ratespace/ui/components/card";

import { loaded } from "@/lib/chain/deployments";

/** Shown instead of live data while only deployments.example.json is available. */
export default function NotDeployed() {
  return (
    <Card>
      <CardHeader>
        <CardTitle>Not deployed</CardTitle>
      </CardHeader>
      <CardContent className="space-y-2">
        <p>
          No local demo deployment found (packages/contracts/deployments/31337.json). Run{" "}
          <code>script/demo.sh</code> in packages/contracts, then reload.
        </p>
        <p className="text-muted-foreground">Loaded: {loaded.source}</p>
        {loaded.error ? <p className="text-destructive">{loaded.error}</p> : null}
      </CardContent>
    </Card>
  );
}

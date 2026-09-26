import { Card, CardContent, CardHeader, CardTitle } from "@ratespace/ui/components/card";

import { CHAIN_ID, IS_LOCAL_DEMO } from "@/lib/chain/config";
import { loaded } from "@/lib/chain/deployments";

/** Shown instead of live data while only deployments.example.json is available. */
export default function NotDeployed() {
  return (
    <Card>
      <CardHeader>
        <CardTitle>Not deployed</CardTitle>
      </CardHeader>
      <CardContent className="space-y-2">
        {IS_LOCAL_DEMO ? (
          <p>
            No local demo deployment found (packages/contracts/deployments/{CHAIN_ID}.json). Run{" "}
            <code>script/demo.sh</code> in packages/contracts, then reload.
          </p>
        ) : (
          <p>
            No deployment found for chain {CHAIN_ID} (packages/contracts/deployments/{CHAIN_ID}.json with
            chainId {CHAIN_ID}).
          </p>
        )}
        <p className="text-muted-foreground">Loaded: {loaded.source}</p>
        {loaded.error ? <p className="text-destructive">{loaded.error}</p> : null}
      </CardContent>
    </Card>
  );
}

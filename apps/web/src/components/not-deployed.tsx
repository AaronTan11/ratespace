import { CHAIN_ID, IS_LOCAL_DEMO } from "@/lib/chain/config";
import { loaded } from "@/lib/chain/deployments";

/** Shown instead of live data while only deployments.example.json is available. */
export default function NotDeployed() {
  return (
    <div className={`rs-notice${loaded.error ? " bad" : ""}`} role="status">
      <span className="t">Not deployed</span>
      {IS_LOCAL_DEMO ? (
        <p style={{ margin: 0 }}>
          No local demo deployment found (<code>packages/contracts/deployments/{CHAIN_ID}.json</code>). Run{" "}
          <code>script/demo.sh</code> in packages/contracts, then reload.
        </p>
      ) : (
        <p style={{ margin: 0 }}>
          No deployment found for chain {CHAIN_ID} (<code>packages/contracts/deployments/{CHAIN_ID}.json</code> with
          chainId {CHAIN_ID}).
        </p>
      )}
      <p className="muted" style={{ margin: 0 }}>
        Loaded: <span className="rs-num">{loaded.source}</span>
      </p>
      {loaded.error ? <p className="rs-error" style={{ margin: 0 }}>{loaded.error}</p> : null}
    </div>
  );
}

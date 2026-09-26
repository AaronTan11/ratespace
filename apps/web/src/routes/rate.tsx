import { useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";
import { Check } from "lucide-react";
import { toast } from "sonner";
import { zeroAddress, type Hash } from "viem";

import { Details, Hex, Num, PageHead, Pair, Panel, Skel } from "@/components/display";
import NotDeployed from "@/components/not-deployed";
import QueryError from "@/components/query-error";
import { IS_LOCAL_DEMO, REFRESH_MS, publicClient } from "@/lib/chain/config";
import { loaded, marketsOf, toOrderTuple, type Market } from "@/lib/chain/deployments";
import { NotMakerError, readRate, simulateReport } from "@/lib/chain/feeds";
import { formatDeltaBps } from "@/lib/chain/math";
import { buildTakerData } from "@/lib/chain/orderBuilder";
import { quote, routerHash } from "@/lib/chain/router";
import { useWallet } from "@/lib/chain/wallet";
import { deltaSign } from "@/lib/format";

export const Route = createFileRoute("/rate")({
  component: RateComponent,
});

const d = loaded.deployments;
const markets = marketsOf(d);
const ONE = 10n ** 18n;
const STEP_BPS = 1n;

/** Rate, the 1e18 yield→WETH quote and router.hash(order), all at one block. */
async function readCard(m: Market, blockNumber?: bigint) {
  const bn = blockNumber ?? (await publicClient.getBlockNumber());
  const takerData = await buildTakerData(publicClient, d.addresses.orderBuilder, zeroAddress, true, true);
  const order = toOrderTuple(m.order);
  const [rate, qt, hash] = await Promise.all([
    readRate(publicClient, m.feed, bn),
    quote(publicClient, m.router, order, m.order.tokenYield, m.order.tokenWeth, ONE, takerData, undefined, bn),
    routerHash(publicClient, m.router, order, bn),
  ]);
  return { blockNumber: bn, rate, out: qt.amountOut, hash };
}

interface Step {
  tx: Hash;
  before: Awaited<ReturnType<typeof readCard>>;
  after: Awaited<ReturnType<typeof readCard>>;
}

function RateCard({ m }: { m: Market }) {
  const wallet = useWallet();
  const qc = useQueryClient();
  const [busy, setBusy] = useState(false);
  const [step, setStep] = useState<Step | null>(null);

  const q = useQuery({
    queryKey: ["rate-card", m.key],
    queryFn: () => readCard(m),
    refetchInterval: REFRESH_MS,
    retry: false,
  });

  async function onStep() {
    if (!wallet.address || !wallet.client) {
      toast.error("Connect the liquidity provider's wallet first.");
      return;
    }
    setBusy(true);
    try {
      if (wallet.address.toLowerCase() !== m.order.maker.toLowerCase()) {
        throw new NotMakerError(wallet.address, m.order.maker);
      }
      const before = await readCard(m);
      const r = await simulateReport(publicClient, wallet.client, wallet.address, m.order.maker, m.feed, STEP_BPS);
      const after = await readCard(m, r.blockNumber);
      setStep({ tx: r.tx, before, after });
      toast.success(`${m.key} feed stepped ${formatDeltaBps(before.rate, after.rate)} bps`, {
        description: `tx ${r.tx}`,
        duration: 20000,
      });
      console.info("[rate] step", {
        key: m.key,
        tx: r.tx,
        rateBefore: before.rate.toString(),
        rateAfter: after.rate.toString(),
        quoteBefore: before.out.toString(),
        quoteAfter: after.out.toString(),
        hashBefore: before.hash,
        hashAfter: after.hash,
      });
      await qc.invalidateQueries();
    } catch (e) {
      const msg = e instanceof Error ? e.message.split("\n")[0] : String(e);
      toast.error(e instanceof NotMakerError ? msg : `Rate step failed: ${msg}`);
      console.error("[rate] step failed", e);
    } finally {
      setBusy(false);
    }
  }

  const matches = q.data ? q.data.hash.toLowerCase() === m.order.strategyHash.toLowerCase() : undefined;

  return (
    <tbody>
      <tr>
        <td>
          <Pair yieldSym={m.key} />
        </td>
        <td>
          {q.data ? (
            <span
              className={`rs-chip sans ${matches ? "good" : "bad"}`}
              title={`Same order as shipped. router.hash(order) now: ${q.data.hash}`}
              aria-label={matches ? "Verified" : "Order changed"}
            >
              {matches ? <Check size={12} aria-hidden /> : <span className="rs-dot bad" aria-hidden />}
              {matches ? "matches" : "DOES NOT MATCH"}
            </span>
          ) : q.isError ? null : (
            <Skel w={64} />
          )}
        </td>
        <td className="num r">{q.isError ? "—" : q.data ? <Num value={q.data.rate} /> : <Skel w={72} />}</td>
        <td className="num r">{q.isError ? "—" : q.data ? <Num value={q.data.out} unit="WETH" /> : <Skel w={72} />}</td>
        <td className="r" style={IS_LOCAL_DEMO ? undefined : { whiteSpace: "normal", minWidth: 220 }}>
          {IS_LOCAL_DEMO ? (
            <button
              type="button"
              className="rs-btn"
              aria-label="Simulate report +1 bp"
              onClick={() => void onStep()}
              disabled={busy || !wallet.address}
              title={wallet.address ? undefined : "Connect the liquidity provider's wallet to use this"}
            >
              {busy ? "Sending…" : "Simulate an oracle update"}
            </button>
          ) : (
            <span className="muted">Rate comes from Lido's Sepolia oracle; it updates when Lido reports.</span>
          )}
        </td>
      </tr>
      {q.isError ? (
        <tr>
          <td colSpan={5} style={{ height: "auto", padding: "8px 12px" }}>
            <QueryError error={q.error} />
          </td>
        </tr>
      ) : null}
      {step ? <StepRow step={step} /> : null}
      <tr className="rs-caption">
        <td colSpan={5}>
          <Details summary="Technical details" style={{ fontSize: 12 }}>
            <dl className="rs-kv" style={{ maxWidth: 720 }}>
              <dt>Oracle feed</dt>
              <dd>
                <Hex value={m.feed} />
              </dd>
              <dt>Order id (strategy hash, as shipped)</dt>
              <dd>
                <Hex value={m.order.strategyHash} head={10} tail={8} />
              </dd>
              <dt>router.hash(order) now</dt>
              <dd>
                {q.data ? (
                  <>
                    <Hex value={q.data.hash} head={10} tail={8} />
                    <span className={matches ? "good" : "bad"}>{matches ? "(same)" : "(DIFFERENT)"}</span>
                  </>
                ) : (
                  "—"
                )}
              </dd>
              <dt>Block</dt>
              <dd>{q.data ? q.data.blockNumber.toString() : "—"}</dd>
              {step ? (
                <>
                  <dt>Quote change</dt>
                  <dd>
                    <Delta before={step.before.out} after={step.after.out} />
                  </dd>
                  <dt>router.hash before</dt>
                  <dd>
                    <Hex value={step.before.hash} />
                  </dd>
                  <dt>router.hash after</dt>
                  <dd>
                    <Hex value={step.after.hash} />
                  </dd>
                  <dt>Oracle update tx</dt>
                  <dd>
                    <Hex value={step.tx} head={10} tail={8} />
                  </dd>
                  <dt>Update blocks</dt>
                  <dd>
                    {step.before.blockNumber.toString()} → {step.after.blockNumber.toString()}
                  </dd>
                </>
              ) : null}
            </dl>
          </Details>
        </td>
      </tr>
    </tbody>
  );
}

/** Mono delta chip: good/bad by sign; `hero` makes it the page's one --highlight number. */
function Delta({ before, after, hero = false }: { before: bigint; after: bigint; hero?: boolean }) {
  if (before === 0n) return <span className="muted">n/a</span>;
  const d = formatDeltaBps(before, after);
  const sign = deltaSign(d);
  const tone = hero ? "hl" : sign > 0 ? "good" : sign < 0 ? "bad" : "";
  return <span className={`rs-chip${tone ? ` ${tone}` : ""}`}>{d} bps</span>;
}

function StepRow({ step }: { step: Step }) {
  const unchanged = step.before.hash === step.after.hash;
  return (
    <tr className="rs-step">
      <td colSpan={5}>
        <div
          style={{
            display: "flex",
            flexWrap: "wrap",
            alignItems: "center",
            gap: 8,
            padding: "12px 0 4px",
            borderTop: "1px solid var(--hairline)",
            fontSize: 13,
            color: "var(--text-2)",
          }}
        >
          <span>Rate</span>
          <span className="rs-num" style={{ color: "var(--text)" }}>
            <Num value={step.before.rate} /> <span className="muted">→</span> <Num value={step.after.rate} />
          </span>
          <Delta before={step.before.rate} after={step.after.rate} hero />
          <span className="muted">·</span>
          <span>Your quote</span>
          <span className="rs-num" style={{ color: "var(--text)" }}>
            <Num value={step.before.out} /> <span className="muted">→</span> <Num value={step.after.out} />
          </span>
          <span className="muted">·</span>
          <span>Order id</span>
          {unchanged ? <span className="muted">unchanged</span> : <span className="rs-chip sans bad">CHANGED</span>}
        </div>
      </td>
    </tr>
  );
}

function RateComponent() {
  return (
    <main className="rs-page">
      <PageHead
        eyebrow="Live rate"
        title="Rates update themselves."
        sub="When an oracle reports a new rate, every quote moves with it. Nothing is re-posted."
      />
      {!loaded.deployed ? (
        <NotDeployed />
      ) : (
        <>
          <Panel
            title="Live rates"
            meta={IS_LOCAL_DEMO ? "demo oracle · refreshes every " + REFRESH_MS / 1000 + "s" : "Lido oracle · read only"}
            bodyClass="rs-table-wrap"
          >
            <table className="rs-table">
              <thead>
                <tr>
                  <th scope="col">Token</th>
                  <th scope="col">Same order</th>
                  <th scope="col" className="r">
                    Oracle rate
                  </th>
                  <th scope="col" className="r">
                    You'd get for 1 token
                  </th>
                  <th scope="col" className="r">
                    {IS_LOCAL_DEMO ? "Try it" : "Source"}
                  </th>
                </tr>
              </thead>
              {markets.map((m) => (
                <RateCard key={m.key} m={m} />
              ))}
            </table>
          </Panel>
          {IS_LOCAL_DEMO ? (
            <p className="rs-meta" style={{ margin: 0, fontSize: 13, color: "var(--text-2)", maxWidth: 720 }}>
              This button plays the role of the oracle for the demo: it moves the rate by 0.01% so you can watch quotes
              follow it. The order id does not change.
            </p>
          ) : null}
        </>
      )}
    </main>
  );
}

import { useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";
import { toast } from "sonner";
import { zeroAddress, type Hash } from "viem";

import { Hex, Num, PageHead, Pair, Panel, Skel } from "@/components/display";
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
      toast.error("Connect the maker wallet first.");
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
          <Hex value={m.feed} />
        </td>
        <td className="num r">{q.isError ? "—" : q.data ? <Num value={q.data.rate} /> : <Skel w={72} />}</td>
        <td className="num r">{q.isError ? "—" : q.data ? <Num value={q.data.out} /> : <Skel w={72} />}</td>
        <td>
          {q.data ? (
            <span className={`rs-chip sans ${matches ? "good" : "bad"}`} title={`router.hash(order) now: ${q.data.hash}`}>
              <span className={`rs-dot ${matches ? "good" : "bad"}`} aria-hidden />
              {matches ? "matches" : "DOES NOT MATCH"}
            </span>
          ) : q.isError ? null : (
            <Skel w={64} />
          )}
        </td>
        <td className="r" style={IS_LOCAL_DEMO ? undefined : { whiteSpace: "normal", minWidth: 220 }}>
          {IS_LOCAL_DEMO ? (
            <button type="button" className="rs-btn" onClick={() => void onStep()} disabled={busy || !wallet.address}>
              {busy ? "Sending…" : "Simulate report +1 bp"}
            </button>
          ) : (
            <span className="muted">Rate comes from Lido's Sepolia oracle; it updates when Lido reports.</span>
          )}
        </td>
      </tr>
      {q.isError ? (
        <tr>
          <td colSpan={6} style={{ height: "auto", padding: "8px 12px" }}>
            <QueryError error={q.error} />
          </td>
        </tr>
      ) : null}
      {step ? <StepRow step={step} /> : null}
      <tr className="rs-caption">
        <td colSpan={6}>
          <span className="muted">Same order, no re-ship: the strategy hash is unchanged —</span>{" "}
          <Hex value={m.order.strategyHash} head={10} tail={8} />
          {q.data ? (
            <>
              <span className="muted"> · router.hash(order) now </span>
              <Hex value={q.data.hash} head={10} tail={8} />{" "}
              <span className={matches ? "good" : "bad"}>{matches ? "(matches)" : "(DOES NOT MATCH)"}</span>
              <span className="muted"> · block </span>
              <span className="rs-num soft">{q.data.blockNumber.toString()}</span>
            </>
          ) : null}
        </td>
      </tr>
    </tbody>
  );
}

function Delta({ before, after }: { before: bigint; after: bigint }) {
  if (before === 0n) return <span className="muted">n/a</span>;
  const d = formatDeltaBps(before, after);
  const sign = deltaSign(d);
  return <span className={`rs-num ${sign > 0 ? "good" : sign < 0 ? "bad" : "muted"}`}>{d} bps</span>;
}

function StepRow({ step }: { step: Step }) {
  const unchanged = step.before.hash === step.after.hash;
  return (
    <tr className="rs-step">
      <td colSpan={6}>
        <div className="rs-step-grid">
          <span className="rs-eyebrow">Rate</span>
          <span className="rs-num">
            <Num value={step.before.rate} /> <span className="muted">→</span> <Num value={step.after.rate} />
          </span>
          <Delta before={step.before.rate} after={step.after.rate} />

          <span className="rs-eyebrow">Quote</span>
          <span className="rs-num">
            <Num value={step.before.out} /> <span className="muted">→</span> <Num value={step.after.out} />
          </span>
          <Delta before={step.before.out} after={step.after.out} />

          <span className="rs-eyebrow">Hash</span>
          <span className="rs-num">
            <Hex value={step.before.hash} /> <span className="muted">→</span> <Hex value={step.after.hash} />
          </span>
          <span className={`rs-chip sans ${unchanged ? "good" : "bad"}`}>{unchanged ? "unchanged" : "CHANGED"}</span>

          <span className="rs-eyebrow">Tx</span>
          <span className="rs-num">
            <Hex value={step.tx} head={10} tail={8} />
          </span>
          <span className="rs-meta">
            blocks <span className="rs-num soft">{step.before.blockNumber.toString()}</span> →{" "}
            <span className="rs-num soft">{step.after.blockNumber.toString()}</span>
          </span>
        </div>
      </td>
    </tr>
  );
}

function RateComponent() {
  return (
    <main className="rs-page">
      <PageHead eyebrow="Rate" title="Watch the peg move" />
      {!loaded.deployed ? (
        <NotDeployed />
      ) : (
        <Panel
          title="Feeds"
          meta={IS_LOCAL_DEMO ? "anvil · DemoRateFeed, maker can step +1 bp" : "Lido oracle · read only"}
          bodyClass="rs-table-wrap"
        >
          <table className="rs-table">
            <thead>
              <tr>
                <th scope="col">Market</th>
                <th scope="col">Feed</th>
                <th scope="col" className="r">
                  Feed rate()
                </th>
                <th scope="col" className="r">
                  Quote 1 unit → WETH
                </th>
                <th scope="col">router.hash</th>
                <th scope="col" className="r">
                  {IS_LOCAL_DEMO ? "Simulate" : "Source"}
                </th>
              </tr>
            </thead>
            {markets.map((m) => (
              <RateCard key={m.key} m={m} />
            ))}
          </table>
        </Panel>
      )}
    </main>
  );
}

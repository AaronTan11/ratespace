import { Button } from "@ratespace/ui/components/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@ratespace/ui/components/card";
import { Skeleton } from "@ratespace/ui/components/skeleton";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";
import { toast } from "sonner";
import { formatUnits, zeroAddress, type Hash } from "viem";

import NotDeployed from "@/components/not-deployed";
import QueryError from "@/components/query-error";
import { REFRESH_MS, publicClient } from "@/lib/chain/config";
import { loaded, marketsOf, toOrderTuple, type Market } from "@/lib/chain/deployments";
import { NotMakerError, readRate, simulateReport } from "@/lib/chain/feeds";
import { formatDeltaBps, formatFixed } from "@/lib/chain/math";
import { buildTakerData } from "@/lib/chain/orderBuilder";
import { quote, routerHash } from "@/lib/chain/router";
import { useWallet } from "@/lib/chain/wallet";

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

  return (
    <Card>
      <CardHeader>
        <CardTitle>{m.key}</CardTitle>
        <CardDescription className="font-mono break-all">feed {m.feed}</CardDescription>
      </CardHeader>
      <CardContent className="space-y-3">
        {q.isError ? (
          <QueryError error={q.error} />
        ) : q.data ? (
          <div className="space-y-1">
            <div className="flex justify-between">
              <span className="text-muted-foreground">Feed rate()</span>
              <span className="font-mono">{formatFixed(q.data.rate, 18, 6)}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-muted-foreground">Quote: 1 {m.key} → WETH</span>
              <span className="font-mono">{formatUnits(q.data.out, 18)}</span>
            </div>
            <div className="text-xs text-muted-foreground">block {q.data.blockNumber.toString()}</div>
          </div>
        ) : (
          <Skeleton className="h-12 w-full" />
        )}
        <Button onClick={() => void onStep()} disabled={busy || !wallet.address}>
          {busy ? "Sending…" : "Simulate report +1 bp"}
        </Button>
        {step ? (
          <div className="space-y-1 border p-2">
            <div className="flex justify-between gap-2">
              <span className="text-muted-foreground">rate</span>
              <span className="font-mono">
                {formatFixed(step.before.rate, 18, 6)} → {formatFixed(step.after.rate, 18, 6)} (
                {formatDeltaBps(step.before.rate, step.after.rate)} bps)
              </span>
            </div>
            <div className="flex justify-between gap-2">
              <span className="text-muted-foreground">quote</span>
              <span className="font-mono">
                {formatUnits(step.before.out, 18)} → {formatUnits(step.after.out, 18)} (
                {step.before.out === 0n ? "n/a" : formatDeltaBps(step.before.out, step.after.out)} bps)
              </span>
            </div>
            <div className="text-xs text-muted-foreground break-all">
              tx {step.tx} · blocks {step.before.blockNumber.toString()} → {step.after.blockNumber.toString()}
            </div>
            <div className="text-xs break-all">
              router.hash(order): {step.before.hash} → {step.after.hash}{" "}
              {step.before.hash === step.after.hash ? "(unchanged)" : "(CHANGED)"}
            </div>
          </div>
        ) : null}
        <p className="text-xs text-muted-foreground break-all">
          Same order, no re-ship: the strategy hash is unchanged — {m.order.strategyHash}
          {q.data ? (
            <span className="block">
              router.hash(order) now: {q.data.hash}{" "}
              {q.data.hash.toLowerCase() === m.order.strategyHash.toLowerCase() ? "(matches)" : "(DOES NOT MATCH)"}
            </span>
          ) : null}
        </p>
      </CardContent>
    </Card>
  );
}

function RateComponent() {
  return (
    <div className="container mx-auto max-w-4xl space-y-4 px-4 py-6">
      <h1 className="text-lg font-semibold">Watch the peg move</h1>
      {!loaded.deployed ? (
        <NotDeployed />
      ) : (
        <div className="grid gap-4 md:grid-cols-3">
          {markets.map((m) => (
            <RateCard key={m.key} m={m} />
          ))}
        </div>
      )}
    </div>
  );
}

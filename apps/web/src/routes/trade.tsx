import { Button } from "@ratespace/ui/components/button";
import { Card, CardContent, CardHeader, CardTitle } from "@ratespace/ui/components/card";
import { Input } from "@ratespace/ui/components/input";
import { Label } from "@ratespace/ui/components/label";
import { Skeleton } from "@ratespace/ui/components/skeleton";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";
import { toast } from "sonner";
import { formatUnits, parseUnits, zeroAddress } from "viem";

import NotDeployed from "@/components/not-deployed";
import QueryError from "@/components/query-error";
import { txUrl } from "@/lib/chain/chains";
import { REFRESH_MS, chain, publicClient } from "@/lib/chain/config";
import { loaded, marketsOf, toOrderTuple, type YieldKey } from "@/lib/chain/deployments";
import { readRate } from "@/lib/chain/feeds";
import { formatFixed, ratio1e18 } from "@/lib/chain/math";
import { buildTakerData } from "@/lib/chain/orderBuilder";
import { quote, swap, type SwapResult } from "@/lib/chain/router";
import { decimals } from "@/lib/chain/tokens";
import { useWallet } from "@/lib/chain/wallet";

export const Route = createFileRoute("/trade")({
  component: TradeComponent,
});

const d = loaded.deployments;
const markets = marketsOf(d);

type Direction = "exit" | "enter";

function parseAmount(s: string, dec: number): bigint | null {
  if (!/^\d*\.?\d*$/.test(s) || s === "" || s === ".") return null;
  try {
    const v = parseUnits(s, dec);
    return v > 0n ? v : null;
  } catch {
    return null;
  }
}

function TxLine({ label, hash }: { label: string; hash: string }) {
  const url = txUrl(chain, hash);
  return (
    <div>
      {label} tx{" "}
      {url ? (
        <a className="font-mono underline" href={url} target="_blank" rel="noreferrer">
          {hash}
        </a>
      ) : (
        <span className="font-mono">{hash}</span>
      )}
    </div>
  );
}

function TradeComponent() {
  const wallet = useWallet();
  const qc = useQueryClient();
  const [key, setKey] = useState<YieldKey>(markets[0]?.key ?? "wstETH");
  const [dir, setDir] = useState<Direction>("exit");
  const [amountStr, setAmountStr] = useState("0.1");
  const [busy, setBusy] = useState(false);
  const [last, setLast] = useState<SwapResult | null>(null);

  const market = markets.find((m) => m.key === key);
  const tokenIn = market ? (dir === "exit" ? market.order.tokenYield : market.order.tokenWeth) : undefined;
  const tokenOut = market ? (dir === "exit" ? market.order.tokenWeth : market.order.tokenYield) : undefined;
  const symIn = dir === "exit" ? key : "WETH";
  const symOut = dir === "exit" ? "WETH" : key;

  const decs = useQuery({
    queryKey: ["decimals", tokenIn, tokenOut],
    queryFn: async () => {
      const [i, o] = await Promise.all([decimals(publicClient, tokenIn!), decimals(publicClient, tokenOut!)]);
      return { in: i, out: o };
    },
    enabled: loaded.deployed && !!tokenIn && !!tokenOut,
    staleTime: Number.POSITIVE_INFINITY,
  });
  const amount = decs.data ? parseAmount(amountStr, decs.data.in) : null;

  const q = useQuery({
    queryKey: ["quote", key, dir, amount?.toString(), wallet.address],
    queryFn: async () => {
      const blockNumber = await publicClient.getBlockNumber();
      const taker = wallet.address ?? zeroAddress;
      const takerData = await buildTakerData(publicClient, d.addresses.orderBuilder, taker, true, true);
      const [qt, rate] = await Promise.all([
        quote(
          publicClient,
          market!.router,
          toOrderTuple(market!.order),
          tokenIn!,
          tokenOut!,
          amount!,
          takerData,
          wallet.address,
          blockNumber,
        ),
        readRate(publicClient, market!.feed, blockNumber),
      ]);
      // WETH per yield token, 1e18-scaled, from the quote itself.
      const implied = dir === "exit" ? ratio1e18(qt.amountOut, qt.amountIn) : ratio1e18(qt.amountIn, qt.amountOut);
      return { ...qt, rate, implied, blockNumber };
    },
    enabled: loaded.deployed && !!market && amount !== null,
    refetchInterval: REFRESH_MS,
    retry: false,
  });

  async function onSwap() {
    if (!market || !tokenIn || !tokenOut || amount === null || !decs.data) return;
    if (!wallet.address || !wallet.client) {
      toast.error("Connect a wallet first.");
      return;
    }
    setBusy(true);
    try {
      const takerData = await buildTakerData(publicClient, d.addresses.orderBuilder, wallet.address, true, true);
      const r = await swap(
        publicClient,
        wallet.client,
        wallet.address,
        market.router,
        toOrderTuple(market.order),
        tokenIn,
        tokenOut,
        amount,
        takerData,
      );
      toast.success(`Swapped ${formatUnits(r.amountIn, decs.data.in)} ${symIn} → ${formatUnits(r.amountOut, decs.data.out)} ${symOut}`, {
        description: `tx ${r.swapTx}${r.approveTx ? ` (approve ${r.approveTx})` : ""} · amounts from ${r.source}${
          r.eventError ? ` (event decode failed: ${r.eventError})` : ""
        }`,
        duration: 20000,
      });
      setLast(r);
      console.info("[trade] swap", { ...r, amountIn: r.amountIn.toString(), amountOut: r.amountOut.toString() });
      await qc.invalidateQueries();
    } catch (e) {
      const msg = e instanceof Error ? e.message.split("\n")[0] : String(e);
      toast.error(`Swap failed: ${msg}`);
      console.error("[trade] swap failed", e);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="container mx-auto max-w-xl space-y-4 px-4 py-6">
      <h1 className="text-lg font-semibold">Trade</h1>
      {!loaded.deployed ? (
        <NotDeployed />
      ) : markets.length === 0 ? (
        <p className="text-muted-foreground">
          The deployments file ({loaded.source}) has no no-fee order for any yield token.
        </p>
      ) : (
        <Card>
          <CardHeader>
            <CardTitle>Swap (exact in)</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            <div className="flex gap-2">
              {markets.map((m) => (
                <Button key={m.key} variant={m.key === key ? "default" : "outline"} onClick={() => setKey(m.key)}>
                  {m.key}
                </Button>
              ))}
            </div>
            <div className="flex gap-2">
              <Button variant={dir === "exit" ? "default" : "outline"} onClick={() => setDir("exit")}>
                Exit: {key} → WETH
              </Button>
              <Button variant={dir === "enter" ? "default" : "outline"} onClick={() => setDir("enter")}>
                Enter: WETH → {key}
              </Button>
            </div>
            <div className="space-y-1">
              <Label htmlFor="amount">Amount in ({symIn})</Label>
              <Input
                id="amount"
                inputMode="decimal"
                value={amountStr}
                onChange={(e) => setAmountStr(e.target.value.trim())}
              />
              {decs.data && amount === null ? (
                <p className="text-destructive">Enter a positive amount with at most {decs.data.in} decimals.</p>
              ) : null}
            </div>
            <div className="space-y-1 border p-3">
              {q.isError ? (
                <QueryError error={q.error} />
              ) : q.data && decs.data ? (
                <>
                  <div className="flex justify-between">
                    <span className="text-muted-foreground">You receive</span>
                    <span className="font-mono">
                      {formatUnits(q.data.amountOut, decs.data.out)} {symOut}
                    </span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-muted-foreground">Implied WETH per {key}</span>
                    <span className="font-mono">{q.data.implied === null ? "n/a" : formatUnits(q.data.implied, 18)}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-muted-foreground">Feed rate()</span>
                    <span className="font-mono">{formatFixed(q.data.rate, 18, 18)}</span>
                  </div>
                  <div className="text-xs text-muted-foreground">block {q.data.blockNumber.toString()}</div>
                </>
              ) : amount === null ? (
                <span className="text-muted-foreground">Enter an amount to quote.</span>
              ) : (
                <Skeleton className="h-16 w-full" />
              )}
            </div>
            <Button className="w-full" onClick={() => void onSwap()} disabled={busy || !q.data || !wallet.address}>
              {busy ? "Swapping…" : wallet.address ? "Swap" : "Connect wallet to swap"}
            </Button>
            {last ? (
              <div className="space-y-1 text-xs break-all text-muted-foreground">
                {last.approveTx ? <TxLine label="approve" hash={last.approveTx} /> : null}
                <TxLine label="swap" hash={last.swapTx} />
              </div>
            ) : null}
          </CardContent>
        </Card>
      )}
    </div>
  );
}

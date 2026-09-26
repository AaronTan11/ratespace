import { useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";
import { toast } from "sonner";
import { formatUnits, parseUnits, zeroAddress } from "viem";

import { Hex, Num, PageHead, Pair, Panel, Skel } from "@/components/display";
import NotDeployed from "@/components/not-deployed";
import QueryError from "@/components/query-error";
import { txUrl } from "@/lib/chain/chains";
import { REFRESH_MS, chain, publicClient } from "@/lib/chain/config";
import { loaded, marketsOf, toOrderTuple, type YieldKey } from "@/lib/chain/deployments";
import { readRate } from "@/lib/chain/feeds";
import { rawBalances } from "@/lib/chain/aqua";
import { formatDeltaBps, ratio1e18 } from "@/lib/chain/math";
import { buildTakerData } from "@/lib/chain/orderBuilder";
import { quote, swap, type SwapResult } from "@/lib/chain/router";
import { allowance, balanceOf, decimals } from "@/lib/chain/tokens";
import { useWallet } from "@/lib/chain/wallet";
import { shortHex } from "@/lib/format";

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
    <>
      <dt>{label} tx</dt>
      <dd>
        {url ? (
          <a className="rs-link" href={url} target="_blank" rel="noreferrer" title={hash}>
            {shortHex(hash, 10, 8)}
          </a>
        ) : (
          <Hex value={hash} head={10} tail={8} />
        )}
      </dd>
    </>
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

  // Display-only reads: wallet balance (for Max), allowance (inline approve state), Aqua backing.
  const acct = useQuery({
    queryKey: ["ticket-account", tokenIn, market?.router, wallet.address],
    queryFn: async () => {
      const [bal, allow] = await Promise.all([
        balanceOf(publicClient, tokenIn!, wallet.address!),
        allowance(publicClient, tokenIn!, wallet.address!, market!.router),
      ]);
      return { bal, allow };
    },
    enabled: loaded.deployed && !!market && !!tokenIn && !!wallet.address,
    refetchInterval: REFRESH_MS,
    retry: false,
  });
  const backing = useQuery({
    queryKey: ["ticket-backing", key],
    queryFn: () =>
      rawBalances(
        publicClient,
        d.addresses.aqua,
        market!.order.maker,
        market!.router,
        market!.order.strategyHash,
        market!.order.tokenWeth,
      ),
    enabled: loaded.deployed && !!market,
    refetchInterval: REFRESH_MS,
    retry: false,
  });
  const needsApprove = acct.data !== undefined && amount !== null && acct.data.allow < amount;

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

  const swapLabel = busy
    ? needsApprove
      ? "Approving, then swapping…"
      : "Swapping…"
    : wallet.address
      ? needsApprove
        ? "Approve and swap"
        : "Swap"
      : "Connect wallet to swap";

  return (
    <main className="rs-page">
      <PageHead eyebrow="Trade" title="Swap exact in" />
      {!loaded.deployed ? (
        <NotDeployed />
      ) : markets.length === 0 ? (
        <div className="rs-notice">
          <span className="t">No markets</span>
          The deployments file ({loaded.source}) has no no-fee order for any yield token.
        </div>
      ) : (
        <div className="rs-cols">
          <section className="rs-panel" aria-label="Order ticket">
            <div className="rs-panel-head">
              <span className="rs-eyebrow">Order ticket</span>
              <span className="rs-meta">exact in · quote refresh {REFRESH_MS / 1000}s</span>
            </div>
            <div className="rs-panel-body">
              <div className="rs-seg" role="group" aria-label="Market">
                {markets.map((m) => (
                  <button key={m.key} type="button" aria-pressed={m.key === key} onClick={() => setKey(m.key)}>
                    <span className="rs-dot teal" aria-hidden />
                    {m.key}
                  </button>
                ))}
              </div>
              <div className="rs-seg" role="group" aria-label="Direction">
                <button type="button" aria-pressed={dir === "exit"} onClick={() => setDir("exit")}>
                  Exit: {key} → WETH
                </button>
                <button type="button" aria-pressed={dir === "enter"} onClick={() => setDir("enter")}>
                  Enter: WETH → {key}
                </button>
              </div>

              <div className="rs-field">
                <div className="rs-field-top">
                  <label htmlFor="amount" className="rs-eyebrow">
                    Amount in ({symIn})
                  </label>
                  <span className="rs-meta">
                    Balance{" "}
                    {acct.data && decs.data ? (
                      <Num value={acct.data.bal} decimals={decs.data.in} />
                    ) : (
                      <span className="rs-num">—</span>
                    )}
                  </span>
                </div>
                <div className="rs-input" data-invalid={!!decs.data && amount === null}>
                  <input
                    id="amount"
                    inputMode="decimal"
                    autoComplete="off"
                    value={amountStr}
                    onChange={(e) => setAmountStr(e.target.value.trim())}
                  />
                  <span className="sym">
                    <span className={`rs-dot ${dir === "exit" ? "teal" : "weth"}`} aria-hidden />
                    {symIn}
                  </span>
                  <button
                    type="button"
                    className="rs-btn sm"
                    disabled={!acct.data || !decs.data}
                    onClick={() => acct.data && decs.data && setAmountStr(formatUnits(acct.data.bal, decs.data.in))}
                  >
                    Max
                  </button>
                </div>
                {decs.data && amount === null ? (
                  <p className="rs-error" style={{ margin: 0 }}>
                    Enter a positive amount with at most {decs.data.in} decimals.
                  </p>
                ) : null}
              </div>

              <div className="rs-quote" aria-live="polite">
                {decs.isError || q.isError ? (
                  <div style={{ padding: "16px 0" }}>
                    <QueryError error={decs.isError ? decs.error : q.error} />
                  </div>
                ) : q.data && decs.data ? (
                  <>
                    <div className="receive">
                      <span className="rs-eyebrow">You receive</span>
                      <span className="v">
                        <Num value={q.data.amountOut} decimals={decs.data.out} unit={symOut} />
                      </span>
                    </div>
                    <dl className="rs-kv">
                      <dt>Implied WETH per {key}</dt>
                      <dd>{q.data.implied === null ? "n/a" : <Num value={q.data.implied} />}</dd>
                      <dt>Feed rate()</dt>
                      <dd>
                        <Num value={q.data.rate} />
                      </dd>
                      <dt>Quote vs feed</dt>
                      <dd>
                        {q.data.implied === null || q.data.rate === 0n ? (
                          "n/a"
                        ) : (
                          // the page's one --highlight number
                          <span className="hl">{`${formatDeltaBps(q.data.rate, q.data.implied)} bps`}</span>
                        )}
                      </dd>
                      <dt>Block</dt>
                      <dd>{q.data.blockNumber.toString()}</dd>
                    </dl>
                  </>
                ) : amount === null ? (
                  <div className="muted" style={{ padding: "16px 0" }}>
                    Enter an amount to quote.
                  </div>
                ) : (
                  <div style={{ padding: "16px 0", display: "grid", gap: 8 }}>
                    <Skel w={160} />
                    <Skel w={220} />
                  </div>
                )}
              </div>

              {wallet.address && acct.data && amount !== null ? (
                <div className="rs-inline-note">
                  <span className={`rs-dot${needsApprove ? "" : " good"}`} aria-hidden />
                  {needsApprove
                    ? `Needs approval: the swap first sends approve(router, amount) on ${symIn}.`
                    : `${symIn} allowance covers this amount; one transaction.`}
                </div>
              ) : null}

              <button
                type="button"
                className="rs-btn-primary"
                onClick={() => void onSwap()}
                disabled={busy || !q.data || !wallet.address}
              >
                {swapLabel}
              </button>
            </div>
          </section>

          <Panel title="Market" meta={market ? <Pair yieldSym={market.key} /> : null}>
            {market ? (
              <dl className="rs-kv">
                <dt>Feed rate()</dt>
                <dd>{q.data ? <Num value={q.data.rate} /> : amount === null || q.isError ? "—" : <Skel w={80} />}</dd>
                <dt>Virtual WETH backing (Aqua)</dt>
                <dd>
                  {backing.isError ? (
                    <span className="bad">read failed</span>
                  ) : backing.data ? (
                    <Num value={backing.data.balance} unit="WETH" />
                  ) : (
                    <Skel w={80} />
                  )}
                </dd>
                <dt>Order hash</dt>
                <dd>{q.data ? <Hex value={q.data.orderHash} /> : amount === null || q.isError ? "—" : <Skel w={120} />}</dd>
                <dt>Strategy hash</dt>
                <dd>
                  <Hex value={market.order.strategyHash} />
                </dd>
                <dt>Router</dt>
                <dd>
                  <Hex value={market.router} />
                </dd>
                <dt>Feed</dt>
                <dd>
                  <Hex value={market.feed} />
                </dd>
                <dt>Maker</dt>
                <dd>
                  <Hex value={market.order.maker} />
                </dd>
                {last ? (
                  <>
                    {last.approveTx ? <TxLine label="Last approve" hash={last.approveTx} /> : null}
                    <TxLine label="Last swap" hash={last.swapTx} />
                  </>
                ) : (
                  <>
                    <dt>Last tx</dt>
                    <dd className="muted">none this session</dd>
                  </>
                )}
              </dl>
            ) : null}
          </Panel>
        </div>
      )}
    </main>
  );
}

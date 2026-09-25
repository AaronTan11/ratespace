import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@ratespace/ui/components/card";
import { Skeleton } from "@ratespace/ui/components/skeleton";
import { useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { formatUnits } from "viem";

import NotDeployed from "@/components/not-deployed";
import QueryError from "@/components/query-error";
import { rawBalances } from "@/lib/chain/aqua";
import { REFRESH_MS, publicClient } from "@/lib/chain/config";
import { loaded, marketsOf } from "@/lib/chain/deployments";
import { readRate } from "@/lib/chain/feeds";
import { formatFixed } from "@/lib/chain/math";
import { balanceOf } from "@/lib/chain/tokens";

export const Route = createFileRoute("/")({
  component: HomeComponent,
});

const d = loaded.deployments;
const markets = marketsOf(d);

async function readHome() {
  // Pin every read to one block so the numbers on screen are mutually consistent.
  const blockNumber = await publicClient.getBlockNumber();
  const maker = markets[0]?.order.maker;
  if (!maker) throw new Error("deployments file has no no-fee orders for wstETH/rETH/weETH");
  const [walletWeth, rows] = await Promise.all([
    balanceOf(publicClient, d.addresses.weth, maker, blockNumber),
    Promise.all(
      markets.map(async (m) => {
        const [rate, weth] = await Promise.all([
          readRate(publicClient, m.feed, blockNumber),
          rawBalances(
            publicClient,
            d.addresses.aqua,
            m.order.maker,
            d.addresses.router,
            m.order.strategyHash,
            m.order.tokenWeth,
            blockNumber,
          ),
        ]);
        return { key: m.key, rate, virtualWeth: weth.balance, strategyHash: m.order.strategyHash };
      }),
    ),
  ]);
  const totalVirtualWeth = rows.reduce((s, r) => s + r.virtualWeth, 0n);
  return { blockNumber, maker, walletWeth, rows, totalVirtualWeth };
}

function HomeComponent() {
  const q = useQuery({
    queryKey: ["home", d.addresses.aqua],
    queryFn: readHome,
    refetchInterval: REFRESH_MS,
    enabled: loaded.deployed,
  });

  return (
    <div className="container mx-auto max-w-4xl space-y-4 px-4 py-6">
      <h1 className="text-lg font-semibold">One ETH balance, many staked-ETH markets</h1>
      {!loaded.deployed ? (
        <NotDeployed />
      ) : (
        <>
          <Card>
            <CardHeader>
              <CardTitle>Maker wallet</CardTitle>
              <CardDescription className="font-mono break-all">{markets[0]?.order.maker}</CardDescription>
            </CardHeader>
            <CardContent>
              {q.isError ? (
                <QueryError error={q.error} />
              ) : q.data ? (
                <p className="text-sm">
                  <span className="font-mono">{formatUnits(q.data.walletWeth, 18)}</span> WETH in the wallet
                  backs <span className="font-mono">{formatUnits(q.data.totalVirtualWeth, 18)}</span> WETH of
                  quotes
                  <span className="block text-xs text-muted-foreground">
                    block {q.data.blockNumber.toString()}
                  </span>
                </p>
              ) : (
                <Skeleton className="h-5 w-72" />
              )}
            </CardContent>
          </Card>
          <div className="grid gap-4 md:grid-cols-3">
            {markets.map((m) => {
              const row = q.data?.rows.find((r) => r.key === m.key);
              return (
                <Card key={m.key}>
                  <CardHeader>
                    <CardTitle>{m.key} / WETH</CardTitle>
                    <CardDescription className="font-mono break-all">{m.order.strategyHash}</CardDescription>
                  </CardHeader>
                  <CardContent className="space-y-2">
                    <div>
                      <div className="text-muted-foreground">Feed rate()</div>
                      {row ? (
                        <div className="font-mono text-sm">{formatFixed(row.rate, 18, 6)}</div>
                      ) : (
                        <Skeleton className="h-5 w-24" />
                      )}
                    </div>
                    <div>
                      <div className="text-muted-foreground">Virtual WETH backing (Aqua)</div>
                      {row ? (
                        <div className="font-mono text-sm">{formatUnits(row.virtualWeth, 18)}</div>
                      ) : (
                        <Skeleton className="h-5 w-24" />
                      )}
                    </div>
                  </CardContent>
                </Card>
              );
            })}
          </div>
        </>
      )}
    </div>
  );
}

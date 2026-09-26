import { useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { Details, Hex, routeName, Num, PageHead, Pair, Panel, Skel } from "@/components/display";
import { Fragment, type ReactNode } from "react";
import NotDeployed from "@/components/not-deployed";
import QueryError from "@/components/query-error";
import { rawBalances } from "@/lib/chain/aqua";
import { REFRESH_MS, publicClient } from "@/lib/chain/config";
import { loaded, marketsOf } from "@/lib/chain/deployments";
import { readRate } from "@/lib/chain/feeds";
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
  if (!maker) throw new Error("deployments file has no no-fee order for any yield token");
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
            m.router,
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

/** Skeleton while loading; a dash once the read has failed (the error is shown once, above the table). */
function Wait({ w, failed }: { w: number; failed: boolean }): ReactNode {
  return failed ? <span className="muted">—</span> : <Skel w={w} />;
}

function HomeComponent() {
  const q = useQuery({
    queryKey: ["home", d.addresses.aqua],
    queryFn: readHome,
    refetchInterval: REFRESH_MS,
    enabled: loaded.deployed,
  });
  const maker = markets[0]?.order.maker;

  const routeLabel = (router: string) => {
    const n = routeName(router);
    return n.startsWith("1inch") ? "via 1inch" : `via ${n}`;
  };

  return (
    <main className="rs-page">
      <PageHead
        eyebrow="Markets"
        title="Swap staked ETH to ETH at today's rate."
        sub="One ETH balance backs every market below — no separate pools, no stale prices."
      />
      {!loaded.deployed ? (
        <NotDeployed />
      ) : (
        <>
          <section className="rs-panel rs-stats" aria-label="Shared backing">
            {q.isError ? (
              <div className="rs-statement">
                <QueryError error={q.error} />
              </div>
            ) : q.data ? (
              <p className="rs-statement">
                <Num value={q.data.walletWeth} unit="WETH" /> in the wallet backs
                <span className="n hero">
                  <Num value={q.data.totalVirtualWeth} unit="WETH" />
                </span>
                of quotes across <span className="rs-num">{markets.length}</span> markets
              </p>
            ) : (
              <div className="rs-statement">
                <Skel w={320} />
              </div>
            )}
            <div style={{ padding: "10px 16px" }} className="rs-meta">
              Block{" "}
              <span className="rs-num">{q.data ? q.data.blockNumber.toString() : q.isError ? "—" : "…"}</span> · updates
              every {REFRESH_MS / 1000}s
            </div>
          </section>

          <Panel title="Markets" meta={`${markets.length} markets · one shared balance`} bodyClass="rs-table-wrap">
            <table className="rs-table">
              <thead>
                <tr>
                  <th scope="col">Token</th>
                  <th scope="col" className="r">
                    1 token = … ETH
                  </th>
                  <th scope="col" className="r">
                    Available
                  </th>
                  <th scope="col">Route</th>
                  <th scope="col">Status</th>
                </tr>
              </thead>
              <tbody>
                {markets.map((m) => {
                  const row = q.data?.rows.find((r) => r.key === m.key);
                  return (
                    <tr key={m.key}>
                      <td>
                        <Pair yieldSym={m.key} />
                      </td>
                      <td className="num r">{row ? <Num value={row.rate} /> : <Wait w={72} failed={q.isError} />}</td>
                      <td className="num r">
                        {row ? <Num value={row.virtualWeth} unit="WETH" /> : <Wait w={72} failed={q.isError} />}
                      </td>
                      <td>
                        <span className="rs-chip sans" title={`Router ${m.router}`}>
                          {routeLabel(m.router)}
                        </span>
                      </td>
                      <td>
                        {row ? (
                          <span className="rs-chip sans good">
                            <span className="rs-dot good" aria-hidden />
                            Live
                          </span>
                        ) : (
                          <Wait w={48} failed={q.isError} />
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </Panel>

          <Details summary="Technical details">
            <dl className="rs-kv" style={{ maxWidth: 720 }}>
              <dt>Liquidity provider</dt>
              <dd>{maker ? <Hex value={maker} /> : "none"}</dd>
              {markets.map((m) => (
                <Fragment key={m.key}>
                  <dt>{m.key} order id</dt>
                  <dd>
                    <Hex value={m.order.strategyHash} />
                  </dd>
                  <dt>{m.key} route</dt>
                  <dd>
                    <span className="muted">{routeLabel(m.router)}</span>
                    <Hex value={m.router} />
                  </dd>
                </Fragment>
              ))}
              <dt>How "Available" is read</dt>
              <dd className="muted" style={{ fontFamily: "var(--font-sans)" }}>
                Aqua rawBalances per order, all at one block
              </dd>
            </dl>
          </Details>
        </>
      )}
    </main>
  );
}

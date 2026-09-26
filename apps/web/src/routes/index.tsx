import { useQuery } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { Hex, Num, PageHead, Pair, Panel, Skel } from "@/components/display";
import type { ReactNode } from "react";
import NotDeployed from "@/components/not-deployed";
import QueryError from "@/components/query-error";
import { rawBalances } from "@/lib/chain/aqua";
import { REFRESH_MS, publicClient } from "@/lib/chain/config";
import { loaded, marketsOf } from "@/lib/chain/deployments";
import { readRate } from "@/lib/chain/feeds";
import { balanceOf } from "@/lib/chain/tokens";
import { shortHex } from "@/lib/format";

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

  return (
    <main className="rs-page">
      <PageHead eyebrow="Markets" title="One ETH balance, many staked-ETH markets" />
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
                of quotes
              </p>
            ) : null}
            <div className="rs-strip" aria-label="Summary">
              <div>
                <span className="rs-eyebrow">Maker wallet WETH</span>
                <span className="v">{q.data ? <Num value={q.data.walletWeth} unit="WETH" /> : <Wait w={120} failed={q.isError} />}</span>
                <span className="rs-meta">{maker ? <Hex value={maker} /> : "no maker"}</span>
              </div>
              <div>
                <span className="rs-eyebrow">Total virtual backing</span>
                <span className="v">
                  {q.data ? <Num value={q.data.totalVirtualWeth} unit="WETH" /> : <Wait w={120} failed={q.isError} />}
                </span>
                <span className="rs-meta">
                  Aqua rawBalances across <span className="rs-num">{markets.length}</span> orders
                </span>
              </div>
              <div>
                <span className="rs-eyebrow">Block</span>
                <span className="v">{q.data ? q.data.blockNumber.toString() : <Wait w={64} failed={q.isError} />}</span>
                <span className="rs-meta">every read pinned to this block</span>
              </div>
            </div>
          </section>

          <Panel
            title="Shared-backing orders"
            meta={`${markets.length} markets · one maker wallet · refresh ${REFRESH_MS / 1000}s`}
            bodyClass="rs-table-wrap"
          >
            <table className="rs-table">
              <thead>
                <tr>
                  <th scope="col">Market</th>
                  <th scope="col" className="r">
                    Live rate
                  </th>
                  <th scope="col" className="r">
                    Virtual WETH backing
                  </th>
                  <th scope="col">Strategy hash</th>
                  <th scope="col">Router</th>
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
                      <td className="num r">{row ? <Num value={row.virtualWeth} /> : <Wait w={72} failed={q.isError} />}</td>
                      <td>
                        <Hex value={m.order.strategyHash} />
                      </td>
                      <td>
                        <span className="rs-chip" title={m.router}>
                          {m.router.toLowerCase() === d.addresses.ourRouter?.toLowerCase()
                            ? "RateSpaceAquaRouter"
                            : m.router.toLowerCase() === d.addresses.router.toLowerCase()
                              ? "AquaSwapVMRouter"
                              : "router"}
                          <span className="muted">{shortHex(m.router)}</span>
                        </span>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </Panel>
        </>
      )}
    </main>
  );
}

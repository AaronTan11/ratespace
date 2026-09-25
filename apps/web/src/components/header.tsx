import { Button } from "@ratespace/ui/components/button";
import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";

import { CHAIN_ID, REFRESH_MS, anvil, publicClient } from "@/lib/chain/config";
import { shortAddress, useWallet } from "@/lib/chain/wallet";

export default function Header() {
  const links = [
    { to: "/", label: "Markets" },
    { to: "/trade", label: "Trade" },
    { to: "/rate", label: "Rate" },
  ] as const;
  const wallet = useWallet();
  const rpcChain = useQuery({
    queryKey: ["rpc-chain-id"],
    queryFn: () => publicClient.getChainId(),
    refetchInterval: REFRESH_MS,
    retry: false,
  });

  const rpcLabel = rpcChain.isError
    ? "RPC offline"
    : rpcChain.data === undefined
      ? "RPC …"
      : rpcChain.data === CHAIN_ID
        ? `${rpcChain.data} · ${anvil.name}`
        : `RPC chain ${rpcChain.data} ≠ ${CHAIN_ID}`;
  const walletOnWrongChain =
    wallet.address !== undefined && wallet.walletChainId !== undefined && wallet.walletChainId !== CHAIN_ID;

  return (
    <div>
      <div className="flex flex-row items-center justify-between gap-4 px-4 py-2">
        <div className="flex items-center gap-6">
          <span className="text-base font-semibold">RateSpace</span>
          <nav className="flex gap-4 text-sm">
            {links.map(({ to, label }) => (
              <Link
                key={to}
                to={to}
                activeOptions={{ exact: true }}
                className="text-muted-foreground [&.active]:text-foreground"
              >
                {label}
              </Link>
            ))}
          </nav>
        </div>
        <div className="flex items-center gap-2 text-xs">
          <span className="border px-2 py-1 font-mono">{rpcLabel}</span>
          {walletOnWrongChain ? (
            <span className="border border-destructive px-2 py-1 text-destructive">
              wallet on chain {wallet.walletChainId}
            </span>
          ) : null}
          {wallet.address ? (
            <span className="border px-2 py-1 font-mono">{shortAddress(wallet.address)}</span>
          ) : (
            <Button variant="outline" onClick={() => void wallet.connect()} disabled={wallet.connecting}>
              {wallet.connecting ? "Connecting…" : wallet.available ? "Connect wallet" : "No wallet"}
            </Button>
          )}
        </div>
      </div>
      {wallet.error ? <p className="px-4 pb-2 text-xs text-destructive">{wallet.error}</p> : null}
      <hr />
    </div>
  );
}

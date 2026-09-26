import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";

import { CHAIN_ID, REFRESH_MS, chain, publicClient } from "@/lib/chain/config";
import { shortAddress, useWallet } from "@/lib/chain/wallet";

function Mark() {
  // Neutral mark (v2: no chromatic brand colour): white ring, text-2 core. 18px.
  return (
    <svg width="18" height="18" viewBox="0 0 26 26" fill="none" aria-hidden="true">
      <circle cx="13" cy="13" r="11" stroke="var(--text)" strokeWidth="2.4" />
      <circle cx="15.5" cy="13" r="5.5" fill="var(--text-2)" />
    </svg>
  );
}

export default function Header() {
  const links = [
    { to: "/", label: "Markets" },
    { to: "/trade", label: "Trade" },
    { to: "/rate", label: "Live rate" },
  ] as const;
  const wallet = useWallet();
  const rpcChain = useQuery({
    queryKey: ["rpc-chain-id"],
    queryFn: () => publicClient.getChainId(),
    refetchInterval: REFRESH_MS,
    retry: false,
  });

  const rpcLabel = rpcChain.isError
    ? "Network offline"
    : rpcChain.data === undefined
      ? "Network …"
      : rpcChain.data === CHAIN_ID
        ? CHAIN_ID === 31337
          ? "Local test network"
          : chain.name
        : "Wrong network";
  const rpcTone = rpcChain.isError ? "bad" : rpcChain.data === undefined ? "" : rpcChain.data === CHAIN_ID ? "good" : "bad";
  const walletOnWrongChain =
    wallet.available && wallet.walletChainId !== undefined && wallet.walletChainId !== CHAIN_ID;

  return (
    <div>
      {walletOnWrongChain ? (
        <div className="rs-topbar" role="alert">
          <span>
            Wallet is on chain <span className="rs-num">{wallet.walletChainId}</span>; this app uses{" "}
            <span className="rs-num">{CHAIN_ID}</span> · {chain.name}.
          </span>
          <button
            type="button"
            className="rs-btn sm bad"
            onClick={() => void wallet.switchNetwork()}
            disabled={wallet.switching}
          >
            {wallet.switching ? "Switching…" : "Switch network"}
          </button>
        </div>
      ) : null}
      {wallet.error ? (
        <div className="rs-topbar" role="alert">
          <span>{wallet.error}</span>
        </div>
      ) : null}
      <header className="rs-header">
        <Link to="/" className="rs-wordmark" aria-label="RateSpace home">
          <Mark />
          RateSpace
        </Link>
        <nav className="rs-nav" aria-label="Main">
          {links.map(({ to, label }) => (
            <Link key={to} to={to} activeOptions={{ exact: true }}>
              {label}
            </Link>
          ))}
        </nav>
        <div className="right">
          <span className="rs-chip" title={`Chain ${rpcChain.data ?? "?"} (${chain.name}); this app expects chain ${CHAIN_ID}`}>
            <span className={`rs-dot${rpcTone ? ` ${rpcTone}` : ""}`} aria-hidden />
            {rpcLabel}
          </span>
          {wallet.address ? (
            <span className="rs-chip" title={wallet.address} style={{ color: "var(--text)" }}>
              <span
                className={`rs-dot ${walletOnWrongChain ? "bad" : "good"}`}
                aria-label={walletOnWrongChain ? "connected, wrong chain" : "connected"}
              />
              {shortAddress(wallet.address)}
            </span>
          ) : (
            <button
              type="button"
              className="rs-chip"
              onClick={() => void wallet.connect()}
              disabled={wallet.connecting}
            >
              <span className="rs-dot" aria-label="not connected" />
              {wallet.connecting ? "Connecting…" : "Connect wallet"}
            </button>
          )}
        </div>
      </header>
    </div>
  );
}

import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import {
  createWalletClient,
  custom,
  getAddress,
  numberToHex,
  type Address,
  type EIP1193Provider,
  type WalletClient,
} from "viem";

import { CHAIN_ID, RPC_URL, chain } from "./config";

declare global {
  interface Window {
    ethereum?: EIP1193Provider;
  }
}

interface WalletState {
  /** Injected provider present (false during SSR and when no extension is installed). */
  available: boolean;
  address?: Address;
  walletChainId?: number;
  client?: WalletClient;
  connecting: boolean;
  connect: () => Promise<void>;
  /** wallet_switchEthereumChain to VITE_CHAIN_ID; adds the chain first if the wallet does not know it. */
  switchNetwork: () => Promise<void>;
  switching: boolean;
  error?: string;
}

const WalletContext = createContext<WalletState | null>(null);

function rpcErrorCode(e: unknown): number | undefined {
  if (typeof e !== "object" || e === null) return undefined;
  const r = e as { code?: unknown; data?: { originalError?: { code?: unknown } } };
  const inner = r.data?.originalError?.code;
  if (typeof inner === "number") return inner;
  return typeof r.code === "number" ? r.code : undefined;
}

async function ensureChain(provider: EIP1193Provider) {
  const hexId = numberToHex(CHAIN_ID);
  try {
    await provider.request({ method: "wallet_switchEthereumChain", params: [{ chainId: hexId }] });
  } catch (e) {
    // 4001 = the user rejected the switch: do not follow up with an add-chain prompt.
    if (rpcErrorCode(e) === 4001) throw e;
    await provider.request({
      method: "wallet_addEthereumChain",
      params: [
        {
          chainId: hexId,
          chainName: chain.name,
          nativeCurrency: chain.nativeCurrency,
          rpcUrls: [RPC_URL],
          ...(chain.blockExplorers ? { blockExplorerUrls: [chain.blockExplorers.default.url] } : {}),
        },
      ],
    });
    // Some wallets add without switching; switch explicitly (no-op if already there).
    await provider.request({ method: "wallet_switchEthereumChain", params: [{ chainId: hexId }] });
  }
}

export function WalletProvider({ children }: { children: ReactNode }) {
  const [provider, setProvider] = useState<EIP1193Provider | undefined>(undefined);
  const [address, setAddress] = useState<Address | undefined>(undefined);
  const [walletChainId, setWalletChainId] = useState<number | undefined>(undefined);
  const [connecting, setConnecting] = useState(false);
  const [switching, setSwitching] = useState(false);
  const [error, setError] = useState<string | undefined>(undefined);

  // window.ethereum only exists in the browser; read it after mount (SSR-safe).
  useEffect(() => {
    const eth = window.ethereum;
    if (!eth) return;
    setProvider(eth);
    const onAccounts = (accs: unknown) => {
      const list = accs as string[];
      setAddress(list[0] ? getAddress(list[0]) : undefined);
    };
    const onChain = (id: unknown) => setWalletChainId(Number(id as string));
    eth.on("accountsChanged", onAccounts);
    eth.on("chainChanged", onChain);
    eth.request({ method: "eth_accounts" }).then(onAccounts).catch(() => {});
    eth.request({ method: "eth_chainId" }).then(onChain).catch(() => {});
    return () => {
      eth.removeListener("accountsChanged", onAccounts);
      eth.removeListener("chainChanged", onChain);
    };
  }, []);

  const client = useMemo(
    () =>
      provider && address
        ? createWalletClient({ account: address, chain, transport: custom(provider) })
        : undefined,
    [provider, address],
  );

  const connect = useCallback(async () => {
    if (!provider) {
      setError("No injected wallet (window.ethereum) found.");
      return;
    }
    setConnecting(true);
    setError(undefined);
    try {
      const accs = await provider.request({ method: "eth_requestAccounts" });
      setAddress(accs[0] ? getAddress(accs[0]) : undefined);
      await ensureChain(provider);
      setWalletChainId(Number(await provider.request({ method: "eth_chainId" })));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setConnecting(false);
    }
  }, [provider]);

  const switchNetwork = useCallback(async () => {
    if (!provider) {
      setError("No injected wallet (window.ethereum) found.");
      return;
    }
    setSwitching(true);
    setError(undefined);
    try {
      await ensureChain(provider);
      setWalletChainId(Number(await provider.request({ method: "eth_chainId" })));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSwitching(false);
    }
  }, [provider]);

  const value: WalletState = {
    available: !!provider,
    address,
    walletChainId,
    client,
    connecting,
    connect,
    switchNetwork,
    switching,
    error,
  };
  return <WalletContext.Provider value={value}>{children}</WalletContext.Provider>;
}

export function useWallet(): WalletState {
  const ctx = useContext(WalletContext);
  if (!ctx) throw new Error("useWallet must be used inside <WalletProvider>");
  return ctx;
}

export function shortAddress(a: Address): string {
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}

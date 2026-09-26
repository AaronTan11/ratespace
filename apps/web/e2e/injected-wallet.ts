import type { BrowserContext, Page } from "@playwright/test";

// anvil's public default accounts (printed by `anvil` at startup). anvil unlocks them, so the node
// signs eth_sendTransaction itself: the fake wallet only forwards JSON-RPC, it holds no keys.
export const MAKER = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" as const; // anvil account 0
export const TAKER = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" as const; // anvil account 1
export const E2E_RPC = "http://127.0.0.1:8547";

interface WalletArgs {
  account: string;
  rpc: string;
}

/** Runs in the page before any app script: a minimal EIP-1193 provider as window.ethereum. */
function installProvider({ account, rpc }: WalletArgs) {
  let id = 0;
  // Like a wallet on a site it has not authorised yet: eth_accounts is empty until eth_requestAccounts.
  let authorised = false;
  const w = window as unknown as { ethereum: unknown; __e2eWalletCalls: string[] };
  w.__e2eWalletCalls = [];
  w.ethereum = {
    isMetaMask: true,
    on() {},
    removeListener() {},
    async request({ method, params }: { method: string; params?: unknown[] }) {
      w.__e2eWalletCalls.push(method);
      switch (method) {
        case "eth_requestAccounts":
          authorised = true;
          return [account];
        case "eth_accounts":
          return authorised ? [account] : [];
        case "eth_chainId":
          return "0x7a69";
        case "wallet_switchEthereumChain":
        case "wallet_addEthereumChain":
          return null;
      }
      const res = await fetch(rpc, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params: params ?? [] }),
      });
      const json = (await res.json()) as { result?: unknown; error?: { code: number; message: string; data?: unknown } };
      if (json.error) {
        const err = new Error(json.error.message) as Error & { code?: number; data?: unknown };
        err.code = json.error.code;
        err.data = json.error.data;
        throw err;
      }
      return json.result;
    },
  };
}

/** Install the fake wallet for `account` on a page or context (must run before the first navigation). */
export async function installWallet(target: Page | BrowserContext, account: string, rpc = E2E_RPC) {
  await target.addInitScript(installProvider, { account, rpc });
}

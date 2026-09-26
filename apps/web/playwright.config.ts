import { defineConfig } from "@playwright/test";

// E2E against an isolated anvil on 8547 (e2e/anvil-8547.sh, started by e2e/run.sh) and a dev server on
// 3002 pointed at it. Never touches the owner's anvil (8545) or dev server (3001).
const shots = process.env.E2E_SHOTS_DIR ?? "e2e/.run/shots";

export default defineConfig({
  testDir: "e2e",
  // Specs share one chain: run serially, in file order (markets, rate, trade: markets and rate assert fresh-deploy values).
  workers: 1,
  fullyParallel: false,
  timeout: 120_000,
  expect: { timeout: 20_000 },
  reporter: [["list"]],
  outputDir: "e2e/.run/test-results",
  use: {
    baseURL: "http://127.0.0.1:3002",
    viewport: { width: 1360, height: 900 },
    video: { mode: "on", size: { width: 1360, height: 900 } },
    trace: "retain-on-failure",
  },
  metadata: { shots },
  webServer: {
    command: "bun run dev --port 3002 --strictPort --host 127.0.0.1",
    url: "http://127.0.0.1:3002",
    reuseExistingServer: false,
    timeout: 120_000,
    env: { VITE_RPC_URL: "http://127.0.0.1:8547", VITE_CHAIN_ID: "31337", VITE_HIDE_DEVTOOLS: "1" },
  },
});

# Reset the local demo between takes

See the "Reset between takes" section of the repo-root `DEMO.md`:

```bash
cd packages/contracts && script/demo-stop.sh && script/demo.sh
```

then reload the app and reset both MetaMask accounts' activity/nonce data (the fresh anvil starts at
nonce 0). The e2e suite needs no reset: `bun run test:e2e` starts and stops its own anvil on 8547.

# RateSpace pitch

**One-liner.** One ETH balance is the exit and entry liquidity for every staked-ETH token — on 1inch Aqua, priced at the live rate, running on 1inch's official router.

**Problem.** Pegged pools freeze their price while wstETH, rETH and weETH grow every day. Each token needs its own pool with its own ETH, and issuer exits are not instant.

**Demo (local anvil, mock tokens).** 1) `/`: one 10 WETH maker wallet backs three markets. 2) `/trade`: exit wstETH, rETH or weETH to WETH near the live rate. 3) `/rate`: step a rate +1 bp; the quote follows and the order hash stays the same.

**Numbers.** After a 1.20 → 1.25 rate step: ours 0.010206 bps off, a frozen PeggedSwap 157.015569 bps off (`analysis/s3a_arb_step.py`). Our pricing on 1inch's official AquaSwapVMRouter v1.0.2 matches our own router to the wei (`test/extruction/MovingPegExtructionEquivalence.t.sol`). 1228 Lido reports since V2, largest 3.223442 bps, under the 10.0509 bps the 0.05% fee protects (`analysis/s5_lido_reports.py --offline`).

**Ask.** TODO-OWNER

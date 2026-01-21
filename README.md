# StacksYield: Advanced sBTC Staking Protocol

**Professional-grade Bitcoin staking on the Stacks Layer 2.**
Secure, time-locked staking with dynamic rewards for Bitcoin holders.

---

## 🧩 Overview

**StacksYield** is a production-ready smart contract enabling Bitcoin holders to earn yield through sBTC staking on the Stacks blockchain. It supports configurable reward rates, minimum stake periods, and comprehensive reward management, designed to serve both institutional and retail investors seeking Bitcoin-native DeFi opportunities.

---

## 🚀 Features

* ✅ **Time-locked staking** with block-based minimum periods.
* ✅ **Dynamic rewards** calculated on stake duration and configurable APY.
* ✅ **Claim rewards** without unstaking principal.
* ✅ **Admin-controlled** contract parameters (rate, min-period, ownership).
* ✅ **sBTC reward pool** with tracked distributions.
* ✅ **Full on-chain accounting** of stakes and claims.

---

## 📐 Architecture

```
Stacks Blockchain
│
├── StacksYield Clarity Smart Contract
│   ├── Stake Registry (Map: `stakes`)
│   │    └─ Principal → { amount, staked-at }
│   ├── Claimed Rewards (Map: `rewards-claimed`)
│   │    └─ Principal → amount
│   ├── Global Config
│   │    ├─ reward-rate (basis points, e.g., 5 = 0.5%)
│   │    ├─ reward-pool (uint)
│   │    ├─ min-stake-period (blocks)
│   │    └─ total-staked (uint)
│   └── sBTC Token Integration (via SIP-010)
│
└── Users
    ├── Stake sBTC → Earn Rewards
    ├── Claim Rewards → Compound Earnings
    └── Unstake → Withdraw Principal + Rewards
```

---

## 🛠 Deployment Info

* **Chain**: Stacks mainnet/testnet
* **Contract Language**: Clarity
* **sBTC Token Contract**: `ST1F7QA2MDF17S807EPA36TSS8AMEFY4KA9TVGWXT.sbtc-token`

---

## 📜 Contract Interface

### Staking Functions

```clojure
(stake (amount uint))           ;; Stake sBTC tokens
(unstake (amount uint))         ;; Unstake tokens (after min period)
(claim-rewards)                 ;; Claim staking rewards only
```

### Admin Functions

```clojure
(set-reward-rate (new-rate uint))          ;; Set new reward rate (basis points)
(set-min-stake-period (new-period uint))   ;; Set min staking period (blocks)
(add-to-reward-pool (amount uint))         ;; Add sBTC to reward pool
(set-contract-owner (new-owner principal)) ;; Transfer ownership
```

### Read-Only Queries

```clojure
(get-stake-info (staker principal))        ;; View stake data
(get-rewards-claimed (staker principal))   ;; View claimed rewards
(get-reward-rate)                          ;; View current reward rate
(get-min-stake-period)                     ;; View min staking period
(get-reward-pool)                          ;; View current reward pool
(get-total-staked)                         ;; View all staked sBTC
(get-current-apy)                          ;; View computed APY from reward rate
(calculate-rewards (staker principal))     ;; Estimate rewards
(get-contract-owner)                       ;; View contract owner
```

---

## ⚠️ Error Codes

| Code   | Description                |
| ------ | -------------------------- |
| `u100` | Not authorized             |
| `u101` | Zero stake amount          |
| `u102` | No stake found             |
| `u103` | Too early to unstake       |
| `u104` | Invalid reward rate        |
| `u105` | Not enough rewards in pool |

---

## 📈 Reward Calculation Logic

```text
reward = stake-amount * (reward-rate / 1000) * (duration / blocks-per-year)
```

* `reward-rate`: Basis points (e.g., 5 = 0.5%)
* `blocks-per-year`: \~52,560
* Rewards accrue linearly over time and are claimed/reset per epoch.

---

## 🧪 Example Flow

1. **Stake sBTC:**

   ```clojure
   (stake u1000000)
   ```

2. **Wait ≥ min-stake-period (\~10 days default).**

3. **Claim rewards:**

   ```clojure
   (claim-rewards)
   ```

4. **Unstake funds:**

   ```clojure
   (unstake u1000000)
   ```

---

## 🔐 Security Considerations

* **Immutable reward logic**: Ensures fair, transparent reward flow.
* **No custodial risk**: Rewards and staking are contract-enforced.
* **Owner can only change config**, not tamper with user funds.

---

## 🤝 Integrations

* **Frontend DApp**: Display APY, staking forms, history dashboard.
* **Wallets**: Support STX/sBTC compatible wallets (e.g., Hiro, Xverse).
* **Data Indexers**: Optional support for stacking analytics or DeFi dashboards.

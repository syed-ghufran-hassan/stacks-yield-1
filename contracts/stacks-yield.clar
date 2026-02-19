;; StacksYield - Advanced sBTC Staking Protocol
;; Title: Professional-grade Bitcoin staking on Stacks Layer 2
;; Summary: Secure, time-locked staking with dynamic rewards for Bitcoin holders
;; Description: A production-ready smart contract enabling Bitcoin holders to earn yield
;;              through sBTC staking with configurable reward rates, minimum stake periods,
;;              and comprehensive reward management. Built for institutional and retail
;;              investors seeking Bitcoin-native DeFi opportunities on Stacks.

;; ERROR CODES

(define-constant ERR_NOT_AUTHORIZED (err u100))
(define-constant ERR_ZERO_STAKE (err u101))
(define-constant ERR_NO_STAKE_FOUND (err u102))
(define-constant ERR_TOO_EARLY_TO_UNSTAKE (err u103))
(define-constant ERR_INVALID_REWARD_RATE (err u104))
(define-constant ERR_NOT_ENOUGH_REWARDS (err u105))
(define-constant ERR_INVALID_TIER (err u106))
(define-constant ERR_MAX_COMPOUNDS_EXCEEDED (err u107))
(define-constant ERR_VAULT_LOCKED (err u108))
(define-constant ERR_INSUFFICIENT_STAKE_FOR_TIER (err u109))
(define-constant ERR_COMPOUND_COOLDOWN (err u110))

;; DATA STORAGE

;; Individual stake records with amount and timestamp
(define-map stakes
  { staker: principal }
  {
    amount: uint,
    staked-at: uint,
  }
)

;; Track total rewards claimed by each staker
(define-map rewards-claimed
  { staker: principal }
  { amount: uint }
)

;; Tier configuration for bonus rewards
(define-map stake-tiers
  { tier-id: uint }
  {
    name: (string-ascii 20),
    min-amount: uint,
    bonus-multiplier: uint, ;; Basis points (100 = 1% bonus)
    lock-period: uint, ;; Additional lock period in blocks
    active: bool
  }
)

;; Enhanced stake record with compounding info
(define-map compound-stakes
  { staker: principal }
  {
    base-amount: uint,           ;; Original principal
    compounded-amount: uint,     ;; Current total (principal + compounded rewards)
    compound-count: uint,        ;; Number of times compounded
    last-compound-block: uint,   ;; Last compound timestamp
    current-tier: uint,          ;; Current tier ID
    next-tier-threshold: uint,   ;; Amount needed for next tier
    auto-compound-enabled: bool  ;; Auto-compound setting
  }
)

;; Vault schedule for automatic compounding
(define-map vault-schedule
  { vault-id: uint }
  {
    staker: principal,
    compound-interval: uint,     ;; Blocks between compounds
    next-compound-block: uint,
    min-compound-amount: uint,
    active: bool
  }
)

;; Protocol configuration variables
(define-data-var reward-rate uint u5) ;; 0.5% in basis points (5/1000)
(define-data-var reward-pool uint u0) ;; Available rewards for distribution
(define-data-var min-stake-period uint u1440) ;; Minimum stake period in blocks (~10 days)
(define-data-var total-staked uint u0) ;; Total sBTC currently staked
(define-data-var contract-owner principal tx-sender)
(define-data-var total-compound-stakes uint u0)
(define-data-var next-vault-id uint u1)
(define-data-var global-apy uint u5) ;; Base APY before tier bonuses
(define-data-var max-compounds-per-year uint u12) ;; Monthly compounding max
(define-data-var compound-cooldown uint u100) ;; Min blocks between compounds

;; ADMINISTRATIVE FUNCTIONS

(define-read-only (get-contract-owner)
  (var-get contract-owner)
)

(define-public (set-contract-owner (new-owner principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_NOT_AUTHORIZED)
    (asserts! (not (is-eq new-owner (var-get contract-owner))) (ok true))
    (ok (var-set contract-owner new-owner))
  )
)

(define-public (set-reward-rate (new-rate uint))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_NOT_AUTHORIZED)
    (asserts! (< new-rate u1000) ERR_INVALID_REWARD_RATE) ;; Cannot exceed 100%
    (var-set global-apy new-rate)
    (ok (var-set reward-rate new-rate))
  )
)

(define-public (set-min-stake-period (new-period uint))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_NOT_AUTHORIZED)
    (asserts! (> new-period u0) ERR_INVALID_REWARD_RATE)
    (ok (var-set min-stake-period new-period))
  )
)

;; Fund the reward pool with sBTC tokens
(define-public (add-to-reward-pool (amount uint))
  (begin
    (asserts! (> amount u0) ERR_ZERO_STAKE)
    ;; Transfer sBTC tokens to contract
    (try! (contract-call? 'ST1F7QA2MDF17S807EPA36TSS8AMEFY4KA9TVGWXT.sbtc-token
      transfer amount tx-sender (as-contract tx-sender) none
    ))
    ;; Update reward pool balance
    (var-set reward-pool (+ (var-get reward-pool) amount))
    (ok true)
  )
)

;; Tier Management Functions

(define-public (add-stake-tier
  (tier-id uint)
  (name (string-ascii 20))
  (min-amount uint)
  (bonus-multiplier uint)
  (lock-period uint)
)
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_NOT_AUTHORIZED)
    (asserts! (> min-amount u0) ERR_INVALID_TIER)
    (asserts! (<= bonus-multiplier u1000) ERR_INVALID_TIER) ;; Max 10% bonus
    
    (map-set stake-tiers
      { tier-id: tier-id }
      {
        name: name,
        min-amount: min-amount,
        bonus-multiplier: bonus-multiplier,
        lock-period: lock-period,
        active: true
      }
    )
    (ok true)
  )
)

;; Determine stake tier based on amount
(define-read-only (calculate-stake-tier (amount uint))
  (let
    (
      (tier1 (unwrap! (map-get? stake-tiers { tier-id: u1 }) 
              { name: "Bronze", min-amount: u1000000, bonus-multiplier: u0, lock-period: u0, active: false }))
      (tier2 (unwrap! (map-get? stake-tiers { tier-id: u2 }) 
              { name: "Silver", min-amount: u5000000, bonus-multiplier: u50, lock-period: u100, active: false }))
      (tier3 (unwrap! (map-get? stake-tiers { tier-id: u3 }) 
              { name: "Gold", min-amount: u10000000, bonus-multiplier: u100, lock-period: u300, active: false }))
      (tier4 (unwrap! (map-get? stake-tiers { tier-id: u4 }) 
              { name: "Platinum", min-amount: u50000000, bonus-multiplier: u200, lock-period: u500, active: false }))
    )
    (cond
      ((>= amount (get min-amount tier4)) u4)
      ((>= amount (get min-amount tier3)) u3)
      ((>= amount (get min-amount tier2)) u2)
      ((>= amount (get min-amount tier1)) u1)
      (true u0)
    )
  )
)

;; CORE STAKING FUNCTIONS

;; Stake sBTC tokens to earn rewards (enhanced with tier support)
(define-public (stake (amount uint))
  (begin
    (asserts! (> amount u0) ERR_ZERO_STAKE)
    ;; Transfer sBTC from user to contract
    (try! (contract-call? 'ST1F7QA2MDF17S807EPA36TSS8AMEFY4KA9TVGWXT.sbtc-token
      transfer amount tx-sender (as-contract tx-sender) none
    ))
    
    ;; Update or create stake record
    (match (map-get? stakes { staker: tx-sender })
      prev-stake (map-set stakes { staker: tx-sender } {
        amount: (+ amount (get amount prev-stake)),
        staked-at: stacks-block-height,
      })
      (map-set stakes { staker: tx-sender } {
        amount: amount,
        staked-at: stacks-block-height,
      })
    )
    
    ;; Update compound stake record
    (let
      (
        (total-staked-amount (+ amount 
          (default-to u0 (get amount (map-get? stakes { staker: tx-sender })))))
        (tier-id (calculate-stake-tier total-staked-amount))
      )
      (match (map-get? compound-stakes { staker: tx-sender })
        prev-compound (map-set compound-stakes
          { staker: tx-sender }
          {
            base-amount: (+ (get base-amount prev-compound) amount),
            compounded-amount: (+ (get compounded-amount prev-compound) amount),
            compound-count: (get compound-count prev-compound),
            last-compound-block: (get last-compound-block prev-compound),
            current-tier: tier-id,
            next-tier-threshold: (get min-amount (unwrap! (map-get? stake-tiers { tier-id: (+ tier-id u1) })
                                  { name: "", min-amount: u0, bonus-multiplier: u0, lock-period: u0, active: false })),
            auto-compound-enabled: (get auto-compound-enabled prev-compound)
          }
        )
        (map-set compound-stakes
          { staker: tx-sender }
          {
            base-amount: amount,
            compounded-amount: amount,
            compound-count: u0,
            last-compound-block: stacks-block-height,
            current-tier: tier-id,
            next-tier-threshold: (get min-amount (unwrap! (map-get? stake-tiers { tier-id: (+ tier-id u1) })
                                  { name: "", min-amount: u0, bonus-multiplier: u0, lock-period: u0, active: false })),
            auto-compound-enabled: false
          }
        )
      )
    )
    
    ;; Update total staked amount
    (var-set total-staked (+ (var-get total-staked) amount))
    (var-set total-compound-stakes (+ (var-get total-compound-stakes) amount))
    
    (ok true)
  )
)

;; Calculate accumulated rewards for a staker (enhanced with tier bonus)
(define-read-only (calculate-rewards (staker principal))
  (match (map-get? compound-stakes { staker: staker })
    compound-info (let
      (
        (current-amount (get compounded-amount compound-info))
        (tier-id (get current-tier compound-info))
        (tier-info (unwrap! (map-get? stake-tiers { tier-id: tier-id })
                    { name: "", min-amount: u0, bonus-multiplier: u0, lock-period: u0, active: false }))
        (last-compound (get last-compound-block compound-info))
        (blocks-elapsed (- stacks-block-height last-compound))
        (base-reward-rate (var-get global-apy))
        (bonus-multiplier (get bonus-multiplier tier-info))
        (effective-rate (+ base-reward-rate (/ (* base-reward-rate bonus-multiplier) u1000)))
        (reward-basis (/ (* current-amount effective-rate) u1000))
        (blocks-per-year u52560)
        (reward (* reward-basis (/ blocks-elapsed blocks-per-year)))
      )
      reward
    )
    ;; Fallback to basic calculation if no compound record
    (match (map-get? stakes { staker: staker })
      stake-info (let (
          (stake-amount (get amount stake-info))
          (stake-duration (- stacks-block-height (get staked-at stake-info)))
          (reward-basis (/ (* stake-amount (var-get reward-rate)) u1000))
          (blocks-per-year u52560)
          (time-factor (/ (* stake-duration u10000) blocks-per-year))
          (reward (* reward-basis (/ time-factor u10000)))
        )
        reward
      )
      u0
    )
  )
)

;; Claim accumulated rewards without unstaking principal
(define-public (claim-rewards)
  (let (
      (stake-info (unwrap! (map-get? stakes { staker: tx-sender }) ERR_NO_STAKE_FOUND))
      (reward-amount (calculate-rewards tx-sender))
    )
    (asserts! (> reward-amount u0) ERR_NO_STAKE_FOUND)
    (asserts! (<= reward-amount (var-get reward-pool)) ERR_NOT_ENOUGH_REWARDS)
    
    ;; Deduct rewards from pool
    (var-set reward-pool (- (var-get reward-pool) reward-amount))
    
    ;; Update claimed rewards tracking
    (match (map-get? rewards-claimed { staker: tx-sender })
      prev-claimed (map-set rewards-claimed { staker: tx-sender } { amount: (+ reward-amount (get amount prev-claimed)) })
      (map-set rewards-claimed { staker: tx-sender } { amount: reward-amount })
    )
    
    ;; Reset stake timestamp to restart reward calculation
    (map-set stakes { staker: tx-sender } {
      amount: (get amount stake-info),
      staked-at: stacks-block-height,
    })
    
    ;; Update compound stake timestamp
    (match (map-get? compound-stakes { staker: tx-sender })
      compound-info (map-set compound-stakes
        { staker: tx-sender }
        (merge compound-info {
          last-compound-block: stacks-block-height
        })
      )
      (ok true)
    )
    
    ;; Transfer rewards to staker
    (as-contract (try! (contract-call? 'ST1F7QA2MDF17S807EPA36TSS8AMEFY4KA9TVGWXT.sbtc-token
      transfer reward-amount (as-contract tx-sender) tx-sender none
    )))
    
    (ok true)
  )
)

;; Auto-Compound Execution
(define-public (execute-compound (staker principal))
  (let
    (
      (compound-info (unwrap! (map-get? compound-stakes { staker: staker }) 
                      ERR_NO_STAKE_FOUND))
      (pending-rewards (calculate-rewards staker))
      (current-tier (get current-tier compound-info))
      (tier-info (unwrap! (map-get? stake-tiers { tier-id: current-tier })
                  { name: "", min-amount: u0, bonus-multiplier: u0, lock-period: u0, active: false }))
      (current-amount (get compounded-amount compound-info))
    )
    
    (asserts! (> pending-rewards u0) ERR_NOT_ENOUGH_REWARDS)
    (asserts! (<= (get compound-count compound-info) (var-get max-compounds-per-year))
              ERR_MAX_COMPOUNDS_EXCEEDED)
    (asserts! (>= (- stacks-block-height (get last-compound-block compound-info))
                  (var-get compound-cooldown))
              ERR_COMPOUND_COOLDOWN)
    (asserts! (<= pending-rewards (var-get reward-pool)) ERR_NOT_ENOUGH_REWARDS)
    
    ;; Calculate new compounded amount
    (let
      (
        (new-amount (+ current-amount pending-rewards))
        (new-tier-id (calculate-stake-tier new-amount))
      )
      
      ;; Update compound stake record
      (map-set compound-stakes
        { staker: staker }
        {
          base-amount: (get base-amount compound-info),
          compounded-amount: new-amount,
          compound-count: (+ (get compound-count compound-info) u1),
          last-compound-block: stacks-block-height,
          current-tier: new-tier-id,
          next-tier-threshold: (get min-amount (unwrap! (map-get? stake-tiers { tier-id: (+ new-tier-id u1) })
                                { name: "", min-amount: u0, bonus-multiplier: u0, lock-period: u0, active: false })),
          auto-compound-enabled: (get auto-compound-enabled compound-info)
        }
      )
      
      ;; Update reward pool
      (var-set reward-pool (- (var-get reward-pool) pending-rewards))
      
      ;; Update legacy stake record
      (match (map-get? stakes { staker: staker })
        prev-stake (map-set stakes { staker: staker } {
          amount: (+ (get amount prev-stake) pending-rewards),
          staked-at: stacks-block-height,
        })
        (map-set stakes { staker: staker } {
          amount: pending-rewards,
          staked-at: stacks-block-height,
        })
      )
      
      ;; Update total staked
      (var-set total-staked (+ (var-get total-staked) pending-rewards))
      (var-set total-compound-stakes (+ (var-get total-compound-stakes) pending-rewards))
      
      (print {
        event: "compounded",
        staker: staker,
        amount: pending-rewards,
        new-tier: new-tier-id,
        block: stacks-block-height
      })
      
      (ok true)
    )
  )
)

;; Unstake tokens and claim any pending rewards
(define-public (unstake (amount uint))
  (let (
      (stake-info (unwrap! (map-get? stakes { staker: tx-sender }) ERR_NO_STAKE_FOUND))
      (compound-info (map-get? compound-stakes { staker: tx-sender }))
      (staked-amount (get amount stake-info))
      (staked-at (get staked-at stake-info))
      (stake-duration (- stacks-block-height staked-at))
    )
    
    ;; Validate unstake conditions
    (asserts! (> amount u0) ERR_ZERO_STAKE)
    (asserts! (>= staked-amount amount) ERR_NO_STAKE_FOUND)
    
    ;; Check tier lock period if exists
    (match compound-info
      info (let
        (
          (tier-id (get current-tier info))
          (tier-info (unwrap! (map-get? stake-tiers { tier-id: tier-id })
                      { name: "", min-amount: u0, bonus-multiplier: u0, lock-period: u0, active: false }))
          (additional-lock (get lock-period tier-info))
        )
        (asserts! (>= stake-duration (+ (var-get min-stake-period) additional-lock))
                  ERR_TOO_EARLY_TO_UNSTAKE)
      )
      (asserts! (>= stake-duration (var-get min-stake-period)) ERR_TOO_EARLY_TO_UNSTAKE)
    )
    
    ;; Claim any pending rewards first
    (try! (claim-rewards))
    
    ;; Update compound info if exists
    (match compound-info
      info (if (>= (get compounded-amount info) amount)
        (let
          (
            (new-amount (- (get compounded-amount info) amount))
            (new-tier-id (calculate-stake-tier new-amount))
          )
          (map-set compound-stakes
            { staker: tx-sender }
            (merge info {
              compounded-amount: new-amount,
              base-amount: (if (>= (get base-amount info) amount)
                            (- (get base-amount info) amount)
                            u0),
              current-tier: new-tier-id,
              next-tier-threshold: (get min-amount (unwrap! (map-get? stake-tiers { tier-id: (+ new-tier-id u1) })
                                    { name: "", min-amount: u0, bonus-multiplier: u0, lock-period: u0, active: false }))
            })
          )
        )
        (ok true)
      )
      (ok true)
    )
    
    ;; Update or remove stake record
    (if (> staked-amount amount)
      (map-set stakes { staker: tx-sender } {
        amount: (- staked-amount amount),
        staked-at: stacks-block-height,
      })
      (map-delete stakes { staker: tx-sender })
    )
    
    ;; Update total staked amount
    (var-set total-staked (- (var-get total-staked) amount))
    (match compound-info
      info (var-set total-compound-stakes (- (var-get total-compound-stakes) amount))
      (ok true)
    )
    
    ;; Return tokens to staker
    (as-contract (try! (contract-call? 'ST1F7QA2MDF17S807EPA36TSS8AMEFY4KA9TVGWXT.sbtc-token
      transfer amount (as-contract tx-sender) tx-sender none
    )))
    
    (ok true)
  )
)

;; Batch Process Multiple Compounds (Keeper Function)
(define-public (batch-compound (stakers (list 10 principal)))
  (let
    (
      (processed (fold process-compound stakers (ok u0)))
    )
    (match processed
      (count (ok count))
      (err (err err))
    )
  )
)

(define-private (process-compound
  (staker principal)
  (prior (response uint uint))
)
  (match prior
    count (begin
      (match (execute-compound staker)
        (success (ok (+ count u1)))
        (error (err error))
      )
    )
    error (err error)
  )
)

;; Vault Management
(define-public (enable-auto-compound
  (compound-interval uint)
  (min-compound-amount uint)
)
  (let
    (
      (compound-info (unwrap! (map-get? compound-stakes { staker: tx-sender })
                      ERR_NO_STAKE_FOUND))
      (vault-id (var-get next-vault-id))
    )
    
    (map-set vault-schedule
      { vault-id: vault-id }
      {
        staker: tx-sender,
        compound-interval: compound-interval,
        next-compound-block: (+ stacks-block-height compound-interval),
        min-compound-amount: min-compound-amount,
        active: true
      }
    )
    
    (map-set compound-stakes
      { staker: tx-sender }
      (merge compound-info {
        auto-compound-enabled: true
      })
    )
    
    (var-set next-vault-id (+ vault-id u1))
    
    (ok vault-id)
  )
)

(define-public (update-vault-schedule
  (vault-id uint)
  (new-interval uint)
  (active bool)
)
  (let
    (
      (vault (unwrap! (map-get? vault-schedule { vault-id: vault-id })
              ERR_NO_STAKE_FOUND))
    )
    (asserts! (is-eq tx-sender (get staker vault)) ERR_NOT_AUTHORIZED)
    
    (map-set vault-schedule
      { vault-id: vault-id }
      (merge vault {
        compound-interval: new-interval,
        next-compound-block: (+ stacks-block-height new-interval),
        active: active
      })
    )
    
    (ok true)
  )
)

;; READ-ONLY INTERFACE FUNCTIONS

(define-read-only (get-stake-info (staker principal))
  (map-get? stakes { staker: staker })
)

(define-read-only (get-compound-info (staker principal))
  (map-get? compound-stakes { staker: staker })
)

(define-read-only (get-rewards-claimed (staker principal))
  (map-get? rewards-claimed { staker: staker })
)

(define-read-only (get-reward-rate)
  (var-get reward-rate)
)

(define-read-only (get-min-stake-period)
  (var-get min-stake-period)
)

(define-read-only (get-reward-pool)
  (var-get reward-pool)
)

(define-read-only (get-total-staked)
  (var-get total-staked)
)

(define-read-only (get-total-compound-stakes)
  (var-get total-compound-stakes)
)

(define-read-only (get-tier-info (tier-id uint))
  (map-get? stake-tiers { tier-id: tier-id })
)

;; Calculate current APY based on reward rate and tier
(define-read-only (get-current-apy (tier-id uint))
  (match (map-get? stake-tiers { tier-id: tier-id })
    tier-info (let
      (
        (base-rate (var-get global-apy))
        (bonus (get bonus-multiplier tier-info))
        (effective-rate (+ base-rate (/ (* base-rate bonus) u1000)))
      )
      (* effective-rate u100)
    )
    (* (var-get global-apy) u100)
  )
)

;; Get tier statistics
(define-read-only (get-tier-stats)
  {
    bronze-min: u1000000,
    silver-min: u5000000,
    gold-min: u10000000,
    platinum-min: u50000000,
    current-stakers: (var-get total-compound-stakes)
  }
)

;; Initialize default tiers
(define-public (initialize-tiers)
  (begin
    (try! (add-stake-tier u1 "Bronze" u1000000 u0 u0))
    (try! (add-stake-tier u2 "Silver" u5000000 u50 u100))
    (try! (add-stake-tier u3 "Gold" u10000000 u100 u300))
    (try! (add-stake-tier u4 "Platinum" u50000000 u200 u500))
    (ok true)
  )
)

;; Contract initialization
(try! (initialize-tiers))

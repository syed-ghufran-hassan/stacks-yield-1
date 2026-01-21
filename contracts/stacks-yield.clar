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

;; Protocol configuration variables
(define-data-var reward-rate uint u5) ;; 0.5% in basis points (5/1000)
(define-data-var reward-pool uint u0) ;; Available rewards for distribution
(define-data-var min-stake-period uint u1440) ;; Minimum stake period in blocks (~10 days)
(define-data-var total-staked uint u0) ;; Total sBTC currently staked
(define-data-var contract-owner principal tx-sender)

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

;; CORE STAKING FUNCTIONS

;; Stake sBTC tokens to earn rewards
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
    ;; Update total staked amount
    (var-set total-staked (+ (var-get total-staked) amount))
    (ok true)
  )
)

;; Calculate accumulated rewards for a staker
(define-read-only (calculate-rewards (staker principal))
  (match (map-get? stakes { staker: staker })
    stake-info (let (
        (stake-amount (get amount stake-info))
        (stake-duration (- stacks-block-height (get staked-at stake-info)))
        (reward-basis (/ (* stake-amount (var-get reward-rate)) u1000))
        (blocks-per-year u52560) ;; Approximately 365 days on Stacks
        (time-factor (/ (* stake-duration u10000) blocks-per-year))
        (reward (* reward-basis (/ time-factor u10000)))
      )
      reward
    )
    u0
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
    ;; Transfer rewards to staker
    (as-contract (try! (contract-call? 'ST1F7QA2MDF17S807EPA36TSS8AMEFY4KA9TVGWXT.sbtc-token
      transfer reward-amount (as-contract tx-sender) tx-sender none
    )))
    (ok true)
  )
)

;; Unstake tokens and claim any pending rewards
(define-public (unstake (amount uint))
  (let (
      (stake-info (unwrap! (map-get? stakes { staker: tx-sender }) ERR_NO_STAKE_FOUND))
      (staked-amount (get amount stake-info))
      (staked-at (get staked-at stake-info))
      (stake-duration (- stacks-block-height staked-at))
    )
    ;; Validate unstake conditions
    (asserts! (> amount u0) ERR_ZERO_STAKE)
    (asserts! (>= staked-amount amount) ERR_NO_STAKE_FOUND)
    (asserts! (>= stake-duration (var-get min-stake-period))
      ERR_TOO_EARLY_TO_UNSTAKE
    )
    ;; Claim any pending rewards first
    (try! (claim-rewards))
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
    ;; Return tokens to staker
    (as-contract (try! (contract-call? 'ST1F7QA2MDF17S807EPA36TSS8AMEFY4KA9TVGWXT.sbtc-token
      transfer amount (as-contract tx-sender) tx-sender none
    )))
    (ok true)
  )
)

;; READ-ONLY INTERFACE FUNCTIONS

(define-read-only (get-stake-info (staker principal))
  (map-get? stakes { staker: staker })
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

;; Calculate current APY based on reward rate
(define-read-only (get-current-apy)
  (let ((rate-basis (var-get reward-rate)))
    (* rate-basis u100)
    ;; Convert basis points to percentage
  )
)

;; coinvine-core
;; 
;; This smart contract implements the core functionality for the CoinVine platform,
;; which connects content creators with their supporters through direct token payments.
;; It manages creator profiles, supporter relationships, reward distribution mechanisms
;; including tips, subscriptions, and milestone-based funding.
;;
;; The contract provides transparency for all transactions between creators and supporters,
;; giving creators tools to monetize their work without intermediaries while allowing
;; supporters to verify how their contributions are used.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-CREATOR-ALREADY-EXISTS (err u101))
(define-constant ERR-CREATOR-NOT-FOUND (err u102))
(define-constant ERR-INVALID-AMOUNT (err u103))
(define-constant ERR-SUBSCRIPTION-NOT-FOUND (err u104))
(define-constant ERR-SUBSCRIPTION-ALREADY-EXISTS (err u105))
(define-constant ERR-MILESTONE-NOT-FOUND (err u106))
(define-constant ERR-MILESTONE-ALREADY-EXISTS (err u107))
(define-constant ERR-MILESTONE-ALREADY-COMPLETED (err u108))
(define-constant ERR-MILESTONE-FUNDING-NOT-REACHED (err u109))
(define-constant ERR-TRANSFER-FAILED (err u110))

;; Data space definitions

;; Creator profiles
(define-map creators
  { creator: principal }
  {
    name: (string-ascii 64),
    description: (string-utf8 500),
    category: (string-ascii 64),
    total-earned: uint,
    supporter-count: uint,
    verified: bool,
    creation-time: uint
  }
)

;; Support records - track all contributions from supporters to creators
(define-map support-records
  { supporter: principal, creator: principal }
  {
    total-contributed: uint,
    last-contribution-time: uint,
    is-subscribing: bool
  }
)

;; One-time tips
(define-map tips
  { tip-id: uint }
  {
    supporter: principal,
    creator: principal,
    amount: uint,
    message: (optional (string-utf8 280)),
    public-recognition: bool,
    timestamp: uint
  }
)

;; Subscriptions
(define-map subscriptions
  { subscription-id: uint }
  {
    supporter: principal,
    creator: principal,
    amount: uint,
    frequency-days: uint,
    next-payment-block: uint,
    active: bool,
    creation-time: uint
  }
)

;; Milestones for funding goals
(define-map milestones
  { milestone-id: uint }
  {
    creator: principal,
    title: (string-ascii 64),
    description: (string-utf8 500),
    target-amount: uint,
    current-amount: uint,
    deadline-block: uint,
    completed: bool,
    creation-time: uint
  }
)

;; Milestone contributions
(define-map milestone-contributions
  { milestone-id: uint, supporter: principal }
  {
    amount: uint,
    timestamp: uint
  }
)

;; Counter variables
(define-data-var tip-counter uint u0)
(define-data-var subscription-counter uint u0)
(define-data-var milestone-counter uint u0)

;; Admin principal for platform maintenance
(define-data-var contract-admin principal tx-sender)

;; Platform fee percentage (in basis points, 100 = 1%)
(define-data-var platform-fee-bps uint u500) ;; 5% default fee

;; Private functions

;; Checks if caller is contract admin
(define-private (is-admin)
  (is-eq tx-sender (var-get contract-admin))
)

;; Checks if a creator exists
(define-private (creator-exists (creator-address principal))
  (default-to false (map-get? creators {creator: creator-address}))
)

;; Updates the support record when a supporter contributes to a creator
(define-private (update-support-record (supporter principal) (creator principal) (amount uint))
  (let (
    (existing-record (map-get? support-records {supporter: supporter, creator: creator}))
    (current-block-height block-height)
  )
    (if (is-some existing-record)
      (let (
        (record (unwrap-panic existing-record))
        (new-total (+ (get total-contributed record) amount))
      )
        (map-set support-records 
          {supporter: supporter, creator: creator}
          {
            total-contributed: new-total,
            last-contribution-time: current-block-height,
            is-subscribing: (get is-subscribing record)
          }
        )
      )
      ;; First time support
      (map-set support-records
        {supporter: supporter, creator: creator}
        {
          total-contributed: amount,
          last-contribution-time: current-block-height,
          is-subscribing: false
        }
      )
    )
  )
)

;; Updates creator stats when they receive a contribution
(define-private (update-creator-stats (creator-address principal) (amount uint))
  (let (
    (creator-data (unwrap-panic (map-get? creators {creator: creator-address})))
    (new-total-earned (+ (get total-earned creator-data) amount))
  )
    (map-set creators
      {creator: creator-address}
      (merge creator-data {total-earned: new-total-earned})
    )
  )
)

;; Calculate platform fee amount
(define-private (calculate-fee (amount uint))
  (/ (* amount (var-get platform-fee-bps)) u10000)
)

;; Process a payment from supporter to creator with platform fee
(define-private (process-payment (supporter principal) (creator principal) (amount uint))
  (let (
    (fee (calculate-fee amount))
    (creator-amount (- amount fee))
  )
    ;; Transfer from supporter to creator
    (match (stx-transfer? creator-amount supporter creator)
      success (begin
        ;; Transfer fee to contract admin
        (match (stx-transfer? fee supporter (var-get contract-admin))
          fee-success (begin
            ;; Update records
            (update-support-record supporter creator amount)
            (update-creator-stats creator creator-amount)
            (ok creator-amount)
          )
          fee-error (begin
            ;; If fee transfer fails, still consider the payment successful
            ;; but log the fee transfer failure
            (print {event: "fee-transfer-failed", error: fee-error})
            (update-support-record supporter creator amount)
            (update-creator-stats creator creator-amount)
            (ok creator-amount)
          )
        )
      )
      error ERR-TRANSFER-FAILED
    )
  )
)

;; Read-only functions

;; Get creator profile information
(define-read-only (get-creator-profile (creator-address principal))
  (map-get? creators {creator: creator-address})
)

;; Get supporter's relationship with a creator
(define-read-only (get-support-record (supporter principal) (creator principal))
  (map-get? support-records {supporter: supporter, creator: creator})
)

;; Get tip details
(define-read-only (get-tip (tip-id uint))
  (map-get? tips {tip-id: tip-id})
)

;; Get subscription details
(define-read-only (get-subscription (subscription-id uint))
  (map-get? subscriptions {subscription-id: subscription-id})
)

;; Get milestone details
(define-read-only (get-milestone (milestone-id uint))
  (map-get? milestones {milestone-id: milestone-id})
)

;; Get the contribution amount for a specific supporter to a milestone
(define-read-only (get-milestone-contribution (milestone-id uint) (supporter principal))
  (map-get? milestone-contributions {milestone-id: milestone-id, supporter: supporter})
)

;; Get platform fee percentage
(define-read-only (get-platform-fee)
  (var-get platform-fee-bps)
)

;; Public functions

;; Administrative functions

;; Change contract admin
(define-public (set-contract-admin (new-admin principal))
  (begin
    (asserts! (is-admin) ERR-NOT-AUTHORIZED)
    (ok (var-set contract-admin new-admin))
  )
)

;; Update platform fee
(define-public (set-platform-fee (new-fee-bps uint))
  (begin
    (asserts! (is-admin) ERR-NOT-AUTHORIZED)
    (asserts! (<= new-fee-bps u1000) (err u111)) ;; Max 10%
    (ok (var-set platform-fee-bps new-fee-bps))
  )
)

;; Creator functions

;; Register as a creator
(define-public (register-creator (name (string-ascii 64)) (description (string-utf8 500)) (category (string-ascii 64)))
  (let (
    (creator tx-sender)
  )
    (asserts! (not (creator-exists creator)) ERR-CREATOR-ALREADY-EXISTS)
    
    (map-set creators
      {creator: creator}
      {
        name: name,
        description: description,
        category: category,
        total-earned: u0,
        supporter-count: u0,
        verified: false,
        creation-time: block-height
      }
    )
    (ok true)
  )
)

;; Update creator profile
(define-public (update-creator-profile (name (string-ascii 64)) (description (string-utf8 500)) (category (string-ascii 64)))
  (let (
    (creator tx-sender)
    (existing-profile (map-get? creators {creator: creator}))
  )
    (asserts! (is-some existing-profile) ERR-CREATOR-NOT-FOUND)
    
    (map-set creators
      {creator: creator}
      (merge (unwrap-panic existing-profile)
        {
          name: name,
          description: description,
          category: category
        }
      )
    )
    (ok true)
  )
)

;; Create a new milestone
(define-public (create-milestone (title (string-ascii 64)) (description (string-utf8 500)) (target-amount uint) (deadline-blocks uint))
  (let (
    (creator tx-sender)
    (milestone-id (var-get milestone-counter))
    (deadline (+ block-height deadline-blocks))
  )
    (asserts! (creator-exists creator) ERR-CREATOR-NOT-FOUND)
    (asserts! (> target-amount u0) ERR-INVALID-AMOUNT)
    
    (map-set milestones
      {milestone-id: milestone-id}
      {
        creator: creator,
        title: title,
        description: description,
        target-amount: target-amount,
        current-amount: u0,
        deadline-block: deadline,
        completed: false,
        creation-time: block-height
      }
    )
    
    (var-set milestone-counter (+ milestone-id u1))
    (ok milestone-id)
  )
)

;; Claim milestone funds after target is reached
(define-public (claim-milestone-funds (milestone-id uint))
  (let (
    (milestone-data (map-get? milestones {milestone-id: milestone-id}))
  )
    (asserts! (is-some milestone-data) ERR-MILESTONE-NOT-FOUND)
    
    (let (
      (milestone (unwrap-panic milestone-data))
      (creator (get creator milestone))
    )
      (asserts! (is-eq tx-sender creator) ERR-NOT-AUTHORIZED)
      (asserts! (not (get completed milestone)) ERR-MILESTONE-ALREADY-COMPLETED)
      (asserts! (>= (get current-amount milestone) (get target-amount milestone)) ERR-MILESTONE-FUNDING-NOT-REACHED)
      
      ;; Mark milestone as completed
      (map-set milestones
        {milestone-id: milestone-id}
        (merge milestone {completed: true})
      )
      
      (ok true)
    )
  )
)

;; Supporter functions

;; Send a one-time tip to a creator
(define-public (send-tip (creator principal) (amount uint) (message (optional (string-utf8 280))) (public-recognition bool))
  (let (
    (supporter tx-sender)
    (tip-id (var-get tip-counter))
  )
    (asserts! (creator-exists creator) ERR-CREATOR-NOT-FOUND)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    
    ;; Process payment first
    (match (process-payment supporter creator amount)
      payment-success (begin
        ;; Record the tip
        (map-set tips
          {tip-id: tip-id}
          {
            supporter: supporter,
            creator: creator,
            amount: amount,
            message: message,
            public-recognition: public-recognition,
            timestamp: block-height
          }
        )
        
        (var-set tip-counter (+ tip-id u1))
        (ok tip-id)
      )
      payment-error payment-error
    )
  )
)

;; Subscribe to a creator with recurring payments
(define-public (subscribe-to-creator (creator principal) (amount uint) (frequency-days uint))
  (let (
    (supporter tx-sender)
    (subscription-id (var-get subscription-counter))
    (next-payment-block (+ block-height (* frequency-days u144))) ;; ~144 blocks per day
  )
    (asserts! (creator-exists creator) ERR-CREATOR-NOT-FOUND)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (> frequency-days u0) (err u112))
    
    ;; Process initial payment
    (match (process-payment supporter creator amount)
      payment-success (begin
        ;; Create subscription
        (map-set subscriptions
          {subscription-id: subscription-id}
          {
            supporter: supporter,
            creator: creator,
            amount: amount,
            frequency-days: frequency-days,
            next-payment-block: next-payment-block,
            active: true,
            creation-time: block-height
          }
        )
        
        ;; Update support record to mark as subscribing
        (let (
          (record (default-to 
            {total-contributed: amount, last-contribution-time: block-height, is-subscribing: false}
            (map-get? support-records {supporter: supporter, creator: creator})
          ))
        )
          (map-set support-records
            {supporter: supporter, creator: creator}
            (merge record {is-subscribing: true})
          )
        )
        
        (var-set subscription-counter (+ subscription-id u1))
        (ok subscription-id)
      )
      payment-error payment-error
    )
  )
)

;; Cancel a subscription
(define-public (cancel-subscription (subscription-id uint))
  (let (
    (subscription-data (map-get? subscriptions {subscription-id: subscription-id}))
  )
    (asserts! (is-some subscription-data) ERR-SUBSCRIPTION-NOT-FOUND)
    
    (let (
      (subscription (unwrap-panic subscription-data))
      (supporter (get supporter subscription))
      (creator (get creator subscription))
    )
      (asserts! (is-eq tx-sender supporter) ERR-NOT-AUTHORIZED)
      
      ;; Update subscription status
      (map-set subscriptions
        {subscription-id: subscription-id}
        (merge subscription {active: false})
      )
      
      ;; Update support record
      (let (
        (record (unwrap-panic (map-get? support-records {supporter: supporter, creator: creator})))
      )
        (map-set support-records
          {supporter: supporter, creator: creator}
          (merge record {is-subscribing: false})
        )
      )
      
      (ok true)
    )
  )
)

;; Process a subscription payment (can be called by anyone, but checks authorization internally)
(define-public (process-subscription-payment (subscription-id uint))
  (let (
    (subscription-data (map-get? subscriptions {subscription-id: subscription-id}))
  )
    (asserts! (is-some subscription-data) ERR-SUBSCRIPTION-NOT-FOUND)
    
    (let (
      (subscription (unwrap-panic subscription-data))
      (supporter (get supporter subscription))
      (creator (get creator subscription))
      (amount (get amount subscription))
      (active (get active subscription))
      (next-payment-block (get next-payment-block subscription))
      (frequency-days (get frequency-days subscription))
    )
      (asserts! active (err u113))
      (asserts! (>= block-height next-payment-block) (err u114))
      
      ;; Process payment
      (match (process-payment supporter creator amount)
        payment-success (begin
          ;; Update next payment block
          (map-set subscriptions
            {subscription-id: subscription-id}
            (merge subscription 
              {next-payment-block: (+ block-height (* frequency-days u144))}
            )
          )
          (ok true)
        )
        payment-error payment-error
      )
    )
  )
)

;; Contribute to a milestone
(define-public (contribute-to-milestone (milestone-id uint) (amount uint))
  (let (
    (supporter tx-sender)
    (milestone-data (map-get? milestones {milestone-id: milestone-id}))
  )
    (asserts! (is-some milestone-data) ERR-MILESTONE-NOT-FOUND)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    
    (let (
      (milestone (unwrap-panic milestone-data))
      (creator (get creator milestone))
      (completed (get completed milestone))
      (current-amount (get current-amount milestone))
      (deadline-block (get deadline-block milestone))
    )
      (asserts! (not completed) ERR-MILESTONE-ALREADY-COMPLETED)
      (asserts! (< block-height deadline-block) (err u115))
      
      ;; Process payment
      (match (process-payment supporter creator amount)
        payment-success (begin
          ;; Update milestone current amount
          (map-set milestones
            {milestone-id: milestone-id}
            (merge milestone {current-amount: (+ current-amount amount)})
          )
          
          ;; Record contribution
          (let (
            (existing-contribution (map-get? milestone-contributions {milestone-id: milestone-id, supporter: supporter}))
          )
            (if (is-some existing-contribution)
              (let (
                (contribution (unwrap-panic existing-contribution))
                (new-amount (+ (get amount contribution) amount))
              )
                (map-set milestone-contributions
                  {milestone-id: milestone-id, supporter: supporter}
                  {amount: new-amount, timestamp: block-height}
                )
              )
              (map-set milestone-contributions
                {milestone-id: milestone-id, supporter: supporter}
                {amount: amount, timestamp: block-height}
              )
            )
          )
          
          (ok true)
        )
        payment-error payment-error
      )
    )
  )
)
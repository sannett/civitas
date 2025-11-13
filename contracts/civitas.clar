;; Civitas DAO - A decentralized autonomous organization for treasury management
;; Contributors can propose spending and vote on proposals with weighted voting

;; =============================================================================
;; CONSTANTS & ERRORS
;; =============================================================================

(define-constant MIN_VOTE_THRESHOLD u51) ;; 51% of total contribution weight needed
(define-constant PROPOSAL_LIFETIME u100) ;; blocks
(define-constant MIN_CONTRIBUTION u1000000) ;; 1 STX minimum contribution
(define-constant MAX_PROPOSAL_AMOUNT u1000000000000) ;; 1M STX max proposal
(define-constant MAX_PROPOSAL_ID u4294967295) ;; Max uint32

;; Error codes
(define-constant ERR_NOT_CONTRIBUTOR u300)
(define-constant ERR_ALREADY_VOTED u101)
(define-constant ERR_PROPOSAL_NOT_FOUND u102)
(define-constant ERR_PROPOSAL_EXECUTED u100)
(define-constant ERR_PROPOSAL_EXPIRED u104)
(define-constant ERR_INSUFFICIENT_VOTES u201)
(define-constant ERR_INSUFFICIENT_BALANCE u202)
(define-constant ERR_PROPOSAL_ALREADY_EXECUTED u200)
(define-constant ERR_PROPOSAL_EXPIRED_EXEC u204)
(define-constant ERR_PROPOSAL_NOT_FOUND_EXEC u203)
(define-constant ERR_INVALID_AMOUNT u400)
(define-constant ERR_INVALID_PROPOSAL_ID u401)
(define-constant ERR_INVALID_RECIPIENT u402)
(define-constant ERR_WEIGHT_AFTER_SNAPSHOT u403)

;; =============================================================================
;; DATA VARIABLES
;; =============================================================================

(define-data-var next-proposal-id uint u0)
(define-data-var total-contributions uint u0) ;; Track total contributions for weighted voting

;; =============================================================================
;; DATA MAPS
;; =============================================================================

;; Track contributors and their contribution amounts
(define-map contributors
  principal
  {
    contributed: bool,
    amount: uint,
    last-contribution-proposal-id: uint
  }
)

;; Store proposal details with weighted vote tracking
(define-map proposals
  uint
  {
    amount: uint,
    recipient: principal,
    description: (string-ascii 100),
    yes-vote-weight: uint,
    no-vote-weight: uint,
    executed: bool,
    start-block: uint,
    proposer: principal,
    total-weight-at-creation: uint ;; Snapshot of total contributions when proposal was created
  }
)

;; Track votes to prevent double voting
(define-map votes
  {proposal-id: uint, voter: principal}
  {voted: bool, support: bool, weight: uint}
)

;; =============================================================================
;; PRIVATE FUNCTIONS
;; =============================================================================

;; Calculate vote weight percentage (returns percentage * 100 for precision)
(define-private (calculate-vote-percentage (vote-weight uint) (total-weight uint))
  (if (is-eq total-weight u0)
    u0
    (/ (* vote-weight u10000) total-weight) ;; Multiply by 10000 for 2 decimal precision
  )
)

;; Check if proposal has sufficient weighted votes (51% threshold)
(define-private (has-sufficient-weighted-votes (yes-weight uint) (total-weight uint))
  (let ((yes-percentage (calculate-vote-percentage yes-weight total-weight)))
    (>= yes-percentage u5100) ;; 51% * 100 for precision
  )
)

;; Validate proposal ID input
(define-private (validate-proposal-id (proposal-id uint))
  (and 
    (<= proposal-id MAX_PROPOSAL_ID)
    (< proposal-id (var-get next-proposal-id))
  )
)

;; Validate amount input
(define-private (validate-amount (amount uint))
  (and 
    (> amount u0)
    (<= amount MAX_PROPOSAL_AMOUNT)
  )
)

;; Validate recipient address (ensure it's not the contract itself)
(define-private (validate-recipient (recipient principal))
  (not (is-eq recipient (as-contract tx-sender)))
)

;; Check if a user is a contributor and return their stored data
(define-private (get-contributor-data (user principal))
  (match (map-get? contributors user)
    contributor-data 
    (if (get contributed contributor-data)
      (ok contributor-data)
      (err ERR_NOT_CONTRIBUTOR)
    )
    (err ERR_NOT_CONTRIBUTOR)
  )
)

;; Check if proposal is still active (not expired and not executed)
(define-private (is-proposal-active (proposal-data {amount: uint, recipient: principal, description: (string-ascii 100), yes-vote-weight: uint, no-vote-weight: uint, executed: bool, start-block: uint, proposer: principal, total-weight-at-creation: uint}))
  (let (
    (executed (get executed proposal-data))
    (start (get start-block proposal-data))
    (expired (> (- stacks-block-height start) PROPOSAL_LIFETIME))
  )
    (and (not executed) (not expired))
  )
)

;; =============================================================================
;; PUBLIC FUNCTIONS
;; =============================================================================

;; Contribute STX to the treasury with a specified amount
(define-public (contribute (amount uint))
  (begin
    ;; Validate input amount
    (asserts! (>= amount MIN_CONTRIBUTION) (err ERR_INVALID_AMOUNT))
    (asserts! (<= amount MAX_PROPOSAL_AMOUNT) (err ERR_INVALID_AMOUNT))
    
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (let ((current-proposal-id (var-get next-proposal-id)))
      (match (map-get? contributors tx-sender)
        existing-contributor
        ;; Update existing contributor
        (let (
          (existing-amount (get amount existing-contributor))
          (new-amount (+ existing-amount amount))
        )
          (map-set contributors tx-sender {
            contributed: true,
            amount: new-amount,
            last-contribution-proposal-id: current-proposal-id
          })
          (var-set total-contributions (+ (var-get total-contributions) amount))
        )
        ;; New contributor
        (begin
          (map-set contributors tx-sender {
            contributed: true,
            amount: amount,
            last-contribution-proposal-id: current-proposal-id
          })
          (var-set total-contributions (+ (var-get total-contributions) amount))
        )
      )
    )
    (ok amount)
  )
)

;; Propose a spend from the treasury
(define-public (propose-spend (amount uint) (recipient principal) (description (string-ascii 100)))
  (begin
    ;; Validate all inputs
    (asserts! (validate-amount amount) (err ERR_INVALID_AMOUNT))
    (asserts! (validate-recipient recipient) (err ERR_INVALID_RECIPIENT))
    (try! (get-contributor-data tx-sender))
    
    (let ((proposal-id (var-get next-proposal-id))
          (current-total-weight (var-get total-contributions)))
      ;; Ensure we don't overflow proposal IDs
      (asserts! (< proposal-id MAX_PROPOSAL_ID) (err ERR_INVALID_PROPOSAL_ID))
      
      (map-set proposals proposal-id {
        amount: amount,
        recipient: recipient,
        description: description,
        yes-vote-weight: u0,
        no-vote-weight: u0,
        executed: false,
        start-block: stacks-block-height,
        proposer: tx-sender,
        total-weight-at-creation: current-total-weight
      })
      (var-set next-proposal-id (+ proposal-id u1))
      (ok proposal-id)
    )
  )
)

;; Vote on a proposal with weighted voting
(define-public (vote (proposal-id uint) (support bool))
  (begin
    ;; Validate inputs
    (asserts! (validate-proposal-id proposal-id) (err ERR_INVALID_PROPOSAL_ID))
    (let ((contributor (try! (get-contributor-data tx-sender))))
      (match (map-get? proposals proposal-id)
        proposal-data
        (let (
          (vote-key {proposal-id: proposal-id, voter: tx-sender})
          (last-id (get last-contribution-proposal-id contributor))
          (voter-weight (get amount contributor))
        )
          (asserts! (<= last-id proposal-id) (err ERR_WEIGHT_AFTER_SNAPSHOT))
          (asserts! (is-proposal-active proposal-data) (err ERR_PROPOSAL_EXPIRED))
          (asserts! (is-none (map-get? votes vote-key)) (err ERR_ALREADY_VOTED))
          
          ;; Record the vote with weight
          (map-set votes vote-key {voted: true, support: support, weight: voter-weight})
          
          ;; Update proposal vote weights
          (if support
            (map-set proposals proposal-id (merge proposal-data {
              yes-vote-weight: (+ (get yes-vote-weight proposal-data) voter-weight)
            }))
            (map-set proposals proposal-id (merge proposal-data {
              no-vote-weight: (+ (get no-vote-weight proposal-data) voter-weight)
            }))
          )
          (ok true)
        )
        (err ERR_PROPOSAL_NOT_FOUND)
      )
    )
  )
)

;; Execute proposal if it meets weighted threshold and requirements
(define-public (execute-proposal (proposal-id uint))
  (begin
    ;; Validate input
    (asserts! (validate-proposal-id proposal-id) (err ERR_INVALID_PROPOSAL_ID))
    
    (match (map-get? proposals proposal-id)
      proposal-data
      (let (
        (executed (get executed proposal-data))
        (start (get start-block proposal-data))
        (expired (> (- stacks-block-height start) PROPOSAL_LIFETIME))
        (yes-vote-weight (get yes-vote-weight proposal-data))
        (total-weight (get total-weight-at-creation proposal-data))
        (proposal-amount (get amount proposal-data))
        (proposal-recipient (get recipient proposal-data))
        (balance (stx-get-balance (as-contract tx-sender)))
      )
        ;; Validate proposal state and requirements
        (asserts! (not executed) (err ERR_PROPOSAL_ALREADY_EXECUTED))
        (asserts! (not expired) (err ERR_PROPOSAL_EXPIRED_EXEC))
        (asserts! (has-sufficient-weighted-votes yes-vote-weight total-weight) (err ERR_INSUFFICIENT_VOTES))
        (asserts! (>= balance proposal-amount) (err ERR_INSUFFICIENT_BALANCE))
        
        ;; Re-validate the stored data before execution
        (asserts! (validate-amount proposal-amount) (err ERR_INVALID_AMOUNT))
        (asserts! (validate-recipient proposal-recipient) (err ERR_INVALID_RECIPIENT))
        
        ;; Execute the transfer
        (try! (as-contract (stx-transfer? proposal-amount tx-sender proposal-recipient)))
        
        ;; Reduce recorded voting weight for recipients drawing from the treasury
        (match (map-get? contributors proposal-recipient)
          recipient-data
          (let (
            (current-amount (get amount recipient-data))
            (deduction (if (> proposal-amount current-amount) current-amount proposal-amount))
          )
            (if (> deduction u0)
              (let (
                (current-total (var-get total-contributions))
                (new-total (if (> current-total deduction) (- current-total deduction) u0))
                (new-amount (- current-amount deduction))
                (last-id (get last-contribution-proposal-id recipient-data))
                (still-contributor (if (> new-amount u0) true false))
              )
                (map-set contributors proposal-recipient {
                  contributed: still-contributor,
                  amount: new-amount,
                  last-contribution-proposal-id: last-id
                })
                (var-set total-contributions new-total)
                u0
              )
              u0
            )
          )
          u0
        )
        
        ;; Mark proposal as executed
        (map-set proposals proposal-id (merge proposal-data {executed: true}))
        (ok true)
      )
      (err ERR_PROPOSAL_NOT_FOUND_EXEC)
    )
  )
)

;; =============================================================================
;; READ-ONLY FUNCTIONS
;; =============================================================================

;; Get proposal details
(define-read-only (get-proposal (proposal-id uint))
  (begin
    ;; Validate input
    (asserts! (validate-proposal-id proposal-id) (err ERR_INVALID_PROPOSAL_ID))
    (match (map-get? proposals proposal-id)
      proposal-data (ok proposal-data)
      (err ERR_PROPOSAL_NOT_FOUND)
    )
  )
)

;; Get treasury balance
(define-read-only (get-balance)
  (stx-get-balance (as-contract tx-sender))
)

;; Get total contributions (voting weight)
(define-read-only (get-total-contributions)
  (var-get total-contributions)
)

;; Check if user is a contributor
(define-read-only (is-user-contributor (user principal))
  (match (map-get? contributors user)
    contributor-data (ok (get contributed contributor-data))
    (ok false)
  )
)

;; Get contributor details
(define-read-only (get-contributor (user principal))
  (map-get? contributors user)
)

;; Get vote details for a specific proposal and voter
(define-read-only (get-vote (proposal-id uint) (voter principal))
  (begin
    ;; Validate input
    (asserts! (validate-proposal-id proposal-id) (err ERR_INVALID_PROPOSAL_ID))
    (ok (map-get? votes {proposal-id: proposal-id, voter: voter}))
  )
)

;; Get voting power percentage for a contributor
(define-read-only (get-voting-power (user principal))
  (match (map-get? contributors user)
    contributor-data
    (let ((user-weight (get amount contributor-data))
          (total-weight (var-get total-contributions)))
      (ok (calculate-vote-percentage user-weight total-weight))
    )
    (ok u0)
  )
)

;; Get next proposal ID
(define-read-only (get-next-proposal-id)
  (var-get next-proposal-id)
)

;; Check if proposal is active
(define-read-only (is-proposal-active-check (proposal-id uint))
  (begin
    ;; Validate input
    (asserts! (validate-proposal-id proposal-id) (err ERR_INVALID_PROPOSAL_ID))
    (match (map-get? proposals proposal-id)
      proposal-data (ok (is-proposal-active proposal-data))
      (err ERR_PROPOSAL_NOT_FOUND)
    )
  )
)

;; Get proposal voting status with percentages
(define-read-only (get-proposal-voting-status (proposal-id uint))
  (begin
    (asserts! (validate-proposal-id proposal-id) (err ERR_INVALID_PROPOSAL_ID))
    (match (map-get? proposals proposal-id)
      proposal-data
      (let (
        (yes-weight (get yes-vote-weight proposal-data))
        (no-weight (get no-vote-weight proposal-data))
        (total-weight (get total-weight-at-creation proposal-data))
        (yes-percentage (calculate-vote-percentage yes-weight total-weight))
        (no-percentage (calculate-vote-percentage no-weight total-weight))
      )
        (ok {
          yes-weight: yes-weight,
          no-weight: no-weight,
          total-weight: total-weight,
          yes-percentage: yes-percentage,
          no-percentage: no-percentage,
          passes-threshold: (has-sufficient-weighted-votes yes-weight total-weight)
        })
      )
      (err ERR_PROPOSAL_NOT_FOUND)
    )
  )
)

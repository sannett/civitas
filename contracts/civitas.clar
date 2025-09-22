;; Civitas DAO - A decentralized autonomous organization for treasury management
;; Contributors can propose spending and vote on proposals

;; =============================================================================
;; CONSTANTS & ERRORS
;; =============================================================================

(define-constant MIN_VOTE_THRESHOLD u2)
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

;; =============================================================================
;; DATA VARIABLES
;; =============================================================================

(define-data-var next-proposal-id uint u0)

;; =============================================================================
;; DATA MAPS
;; =============================================================================

;; Track contributors and their contribution amounts
(define-map contributors
  principal
  {
    contributed: bool,
    amount: uint
  }
)

;; Store proposal details
(define-map proposals
  uint
  {
    amount: uint,
    recipient: principal,
    description: (string-ascii 100),
    yes-votes: uint,
    no-votes: uint,
    executed: bool,
    start-block: uint,
    proposer: principal
  }
)

;; Track votes to prevent double voting
(define-map votes
  {proposal-id: uint, voter: principal}
  {voted: bool, support: bool}
)

;; =============================================================================
;; PRIVATE FUNCTIONS
;; =============================================================================

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

;; Check if a user is a contributor
(define-private (is-contributor (user principal))
  (match (map-get? contributors user)
    contributor-data (ok (get contributed contributor-data))
    (err ERR_NOT_CONTRIBUTOR)
  )
)

;; Check if proposal is still active (not expired and not executed)
(define-private (is-proposal-active (proposal-data {amount: uint, recipient: principal, description: (string-ascii 100), yes-votes: uint, no-votes: uint, executed: bool, start-block: uint, proposer: principal}))
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
    (match (map-get? contributors tx-sender)
      existing-contributor
      ;; Update existing contributor
      (map-set contributors tx-sender {
        contributed: true,
        amount: (+ (get amount existing-contributor) amount)
      })
      ;; New contributor
      (map-set contributors tx-sender {
        contributed: true,
        amount: amount
      })
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
    (try! (is-contributor tx-sender))
    
    (let ((proposal-id (var-get next-proposal-id)))
      ;; Ensure we don't overflow proposal IDs
      (asserts! (< proposal-id MAX_PROPOSAL_ID) (err ERR_INVALID_PROPOSAL_ID))
      
      (map-set proposals proposal-id {
        amount: amount,
        recipient: recipient,
        description: description,
        yes-votes: u0,
        no-votes: u0,
        executed: false,
        start-block: stacks-block-height,
        proposer: tx-sender
      })
      (var-set next-proposal-id (+ proposal-id u1))
      (ok proposal-id)
    )
  )
)

;; Vote on a proposal
(define-public (vote (proposal-id uint) (support bool))
  (begin
    ;; Validate inputs
    (asserts! (validate-proposal-id proposal-id) (err ERR_INVALID_PROPOSAL_ID))
    (try! (is-contributor tx-sender))
    
    (match (map-get? proposals proposal-id)
      proposal-data
      (let (
        (vote-key {proposal-id: proposal-id, voter: tx-sender})
      )
        (asserts! (is-proposal-active proposal-data) (err ERR_PROPOSAL_EXPIRED))
        (asserts! (is-none (map-get? votes vote-key)) (err ERR_ALREADY_VOTED))
        
        ;; Record the vote
        (map-set votes vote-key {voted: true, support: support})
        
        ;; Update proposal vote counts
        (if support
          (map-set proposals proposal-id (merge proposal-data {
            yes-votes: (+ (get yes-votes proposal-data) u1)
          }))
          (map-set proposals proposal-id (merge proposal-data {
            no-votes: (+ (get no-votes proposal-data) u1)
          }))
        )
        (ok true)
      )
      (err ERR_PROPOSAL_NOT_FOUND)
    )
  )
)

;; Execute proposal if it meets threshold and requirements
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
        (yes-votes (get yes-votes proposal-data))
        (proposal-amount (get amount proposal-data))
        (proposal-recipient (get recipient proposal-data))
        (balance (stx-get-balance (as-contract tx-sender)))
      )
        ;; Validate proposal state and requirements
        (asserts! (not executed) (err ERR_PROPOSAL_ALREADY_EXECUTED))
        (asserts! (not expired) (err ERR_PROPOSAL_EXPIRED_EXEC))
        (asserts! (>= yes-votes MIN_VOTE_THRESHOLD) (err ERR_INSUFFICIENT_VOTES))
        (asserts! (>= balance proposal-amount) (err ERR_INSUFFICIENT_BALANCE))
        
        ;; Re-validate the stored data before execution
        (asserts! (validate-amount proposal-amount) (err ERR_INVALID_AMOUNT))
        (asserts! (validate-recipient proposal-recipient) (err ERR_INVALID_RECIPIENT))
        
        ;; Execute the transfer
        (try! (as-contract (stx-transfer? proposal-amount tx-sender proposal-recipient)))
        
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
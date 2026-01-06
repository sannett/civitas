# Civitas DAO (contracts/civitas.clar)

A minimal DAO treasury in Clarity. Contributors deposit STX into the contract, propose spending, vote, and execute approved proposals.

## Constants
- MIN_VOTE_THRESHOLD: u2
- PROPOSAL_LIFETIME: u100 blocks
- MIN_CONTRIBUTION: u1000000 (1 STX)
- MAX_PROPOSAL_AMOUNT: u1000000000000 (1,000,000 STX)
- MAX_PROPOSAL_ID: u4294967295

## Errors (defined)
- ERR_NOT_CONTRIBUTOR u300
- ERR_ALREADY_VOTED u101
- ERR_PROPOSAL_NOT_FOUND u102
- ERR_PROPOSAL_EXECUTED u100
- ERR_PROPOSAL_EXPIRED u104
- ERR_INSUFFICIENT_VOTES u201
- ERR_INSUFFICIENT_BALANCE u202
- ERR_PROPOSAL_ALREADY_EXECUTED u200
- ERR_PROPOSAL_EXPIRED_EXEC u204
- ERR_PROPOSAL_NOT_FOUND_EXEC u203
- ERR_INVALID_AMOUNT u400
- ERR_INVALID_PROPOSAL_ID u401
- ERR_INVALID_RECIPIENT u402

## State
- Data var:
  - next-proposal-id: uint (starts at u0)
- Maps:
  - contributors: principal -> { contributed: bool, amount: uint }
  - proposals: uint -> {
      amount: uint,
      recipient: principal,
      description: (string-ascii 100),
      yes-votes: uint,
      no-votes: uint,
      executed: bool,
      start-block: uint,
      proposer: principal
    }
  - votes: { proposal-id: uint, voter: principal } -> { voted: bool, support: bool }

## Core rules
- Becoming a contributor requires calling contribute with amount >= MIN_CONTRIBUTION.
- Proposal IDs are sequential starting at u0.
- A proposal is active if not executed and not expired. Expiry condition: (stacks-block-height - start-block) > PROPOSAL_LIFETIME.
- One principal = one vote per proposal; votes are not weighted by contribution.
- Execution requires yes-votes >= MIN_VOTE_THRESHOLD; no-votes are tracked but do not affect the threshold check.

## Public functions

- contribute(amount uint) -> (response uint uint)
  - Transfers amount from tx-sender to the contract and upserts contributors[tx-sender].
  - Requires: amount >= MIN_CONTRIBUTION and amount <= MAX_PROPOSAL_AMOUNT.
  - Ok: amount
  - Err: ERR_INVALID_AMOUNT; or propagates stx-transfer? error.

- propose-spend(amount uint, recipient principal, description (string-ascii 100)) -> (response uint uint)
  - Requires caller is a contributor.
  - Stores a new proposal with the current next-proposal-id and increments it.
  - Requires: amount > u0 and <= MAX_PROPOSAL_AMOUNT; recipient != contract principal; next-proposal-id < MAX_PROPOSAL_ID.
  - Ok: proposal-id
  - Err: ERR_INVALID_AMOUNT, ERR_INVALID_RECIPIENT, ERR_NOT_CONTRIBUTOR, ERR_INVALID_PROPOSAL_ID

- vote(proposal-id uint, support bool) -> (response bool uint)
  - Records a vote and increments yes-votes or no-votes.
  - Requires: valid proposal-id; caller is a contributor; proposal is active; caller has not voted on this proposal.
  - Ok: true
  - Err: ERR_INVALID_PROPOSAL_ID, ERR_NOT_CONTRIBUTOR, ERR_PROPOSAL_EXPIRED, ERR_ALREADY_VOTED, ERR_PROPOSAL_NOT_FOUND

- execute-proposal(proposal-id uint) -> (response bool uint)
  - Executes an STX transfer from the contract to the proposal recipient.
  - Requires: valid proposal-id; proposal exists; not executed; not expired; yes-votes >= MIN_VOTE_THRESHOLD; contract balance >= amount; stored amount/recipient still valid.
  - Ok: true
  - Err: ERR_INVALID_PROPOSAL_ID, ERR_PROPOSAL_ALREADY_EXECUTED, ERR_PROPOSAL_EXPIRED_EXEC, ERR_INSUFFICIENT_VOTES, ERR_INSUFFICIENT_BALANCE, ERR_INVALID_AMOUNT, ERR_INVALID_RECIPIENT, ERR_PROPOSAL_NOT_FOUND_EXEC; or propagates stx-transfer? error.

## Read-only functions

- get-proposal(proposal-id uint) -> (response {…proposal…} uint)
  - Requires valid proposal-id.
  - Err: ERR_INVALID_PROPOSAL_ID, ERR_PROPOSAL_NOT_FOUND

- get-balance() -> uint
  - Returns the contract’s STX balance.

- is-user-contributor(user principal) -> (response bool none)
  - Ok true if user exists in contributors with contributed = true; otherwise Ok false.

- get-contributor(user principal) -> (optional { contributed: bool, amount: uint })

- get-vote(proposal-id uint, voter principal) -> (response (optional { voted: bool, support: bool }) uint)
  - Requires valid proposal-id.
  - Err: ERR_INVALID_PROPOSAL_ID

- get-next-proposal-id() -> uint

- is-proposal-active-check(proposal-id uint) -> (response bool uint)
  - Requires valid proposal-id.
  - Ok true if active by the same logic used for voting.
  - Err: ERR_INVALID_PROPOSAL_ID, ERR_PROPOSAL_NOT_FOUND

## Validation helpers (private)
- validate-proposal-id(proposal-id) -> bool: proposal-id <= MAX_PROPOSAL_ID and proposal-id < next-proposal-id.
- validate-amount(amount) -> bool: amount > u0 and amount <= MAX_PROPOSAL_AMOUNT.
- validate-recipient(recipient) -> bool: recipient != contract principal.
- is-contributor(user) -> (response bool uint): Ok(contributed) if present; Err(ERR_NOT_CONTRIBUTOR) if absent.
- is-proposal-active(proposal-data) -> bool: not executed and not expired by the lifetime rule.

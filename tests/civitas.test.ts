
import { describe, expect, it } from "vitest";
import { Cl } from "@stacks/transactions";

const contractName = "civitas";
const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const wallet1 = accounts.get("wallet_1")!;
const wallet2 = accounts.get("wallet_2")!;
const wallet3 = accounts.get("wallet_3")!;

const MIN_CONTRIBUTION = 1_000_000n;
const PROPOSAL_LIFETIME = 100n;
const ERR_INVALID_AMOUNT = 400n;
const ERR_NOT_CONTRIBUTOR = 300n;
const ERR_ALREADY_VOTED = 101n;
const ERR_WEIGHT_AFTER_SNAPSHOT = 403n;
const ERR_INSUFFICIENT_VOTES = 201n;
const ERR_PROPOSAL_EXPIRED = 104n;
const ERR_PROPOSAL_EXPIRED_EXEC = 204n;

const contribute = (sender: string, amount: bigint) =>
  simnet.callPublicFn(contractName, "contribute", [Cl.uint(amount)], sender);

const propose = (sender: string, amount: bigint, recipient: string, description: string) =>
  simnet.callPublicFn(contractName, "propose-spend", [
    Cl.uint(amount),
    Cl.standardPrincipal(recipient),
    Cl.stringAscii(description),
  ], sender);

const vote = (sender: string, proposalId: bigint, support: boolean) =>
  simnet.callPublicFn(contractName, "vote", [Cl.uint(proposalId), Cl.bool(support)], sender);

describe("contribute", () => {
  it("accepts valid contributions and rejects amounts below the minimum", () => {
    const ok = contribute(wallet1, MIN_CONTRIBUTION);
    expect(ok.result).toBeOk(Cl.uint(MIN_CONTRIBUTION));

    const total = simnet.callReadOnlyFn(contractName, "get-total-contributions", [], wallet1);
    expect(total.result).toBeUint(MIN_CONTRIBUTION);

    const contributor = simnet.callReadOnlyFn(
      contractName,
      "get-contributor",
      [Cl.standardPrincipal(wallet1)],
      deployer,
    );
    expect(contributor.result).toBeSome(
      Cl.tuple({
        contributed: Cl.bool(true),
        amount: Cl.uint(MIN_CONTRIBUTION),
        "last-contribution-proposal-id": Cl.uint(0),
      }),
    );

    const tooSmall = contribute(wallet2, MIN_CONTRIBUTION - 1n);
    expect(tooSmall.result).toBeErr(Cl.uint(ERR_INVALID_AMOUNT));
  });
});

describe("propose-spend", () => {
  it("requires contributors and snapshots the total weight at creation", () => {
    contribute(wallet1, 2_000_000n);
    contribute(wallet2, 1_000_000n);

    const nonContributor = propose(wallet3, 500_000n, wallet2, "should fail");
    expect(nonContributor.result).toBeErr(Cl.uint(ERR_NOT_CONTRIBUTOR));

    const proposal = propose(wallet1, 500_000n, wallet2, "fund wallet2");
    expect(proposal.result).toBeOk(Cl.uint(0));

    const status = simnet.callReadOnlyFn(
      contractName,
      "get-proposal-voting-status",
      [Cl.uint(0)],
      deployer,
    );
    expect(status.result).toBeOk(
      Cl.tuple({
        "yes-weight": Cl.uint(0),
        "no-weight": Cl.uint(0),
        "total-weight": Cl.uint(3_000_000n),
        "yes-percentage": Cl.uint(0),
        "no-percentage": Cl.uint(0),
        "passes-threshold": Cl.bool(false),
      }),
    );

    const nextId = simnet.callReadOnlyFn(contractName, "get-next-proposal-id", [], deployer);
    expect(nextId.result).toBeUint(1);
  });
});

describe("vote", () => {
  it("tracks weighted votes, blocks double-voting, and rejects post-snapshot weight", () => {
    contribute(wallet1, 2_000_000n);
    contribute(wallet2, 1_000_000n);
    propose(wallet1, 1_000_000n, wallet2, "operating budget");

    const yesVote = vote(wallet1, 0n, true);
    expect(yesVote.result).toBeOk(Cl.bool(true));

    const doubleVote = vote(wallet1, 0n, false);
    expect(doubleVote.result).toBeErr(Cl.uint(ERR_ALREADY_VOTED));

    contribute(wallet3, MIN_CONTRIBUTION);
    const lateWeight = vote(wallet3, 0n, true);
    expect(lateWeight.result).toBeErr(Cl.uint(ERR_WEIGHT_AFTER_SNAPSHOT));

    const noVote = vote(wallet2, 0n, false);
    expect(noVote.result).toBeOk(Cl.bool(true));

    const status = simnet.callReadOnlyFn(
      contractName,
      "get-proposal-voting-status",
      [Cl.uint(0)],
      deployer,
    );
    expect(status.result).toBeOk(
      Cl.tuple({
        "yes-weight": Cl.uint(2_000_000n),
        "no-weight": Cl.uint(1_000_000n),
        "total-weight": Cl.uint(3_000_000n),
        "yes-percentage": Cl.uint(6666),
        "no-percentage": Cl.uint(3333),
        "passes-threshold": Cl.bool(true),
      }),
    );
  });
});

describe("execute-proposal", () => {
  it("executes when threshold met and updates treasury and contributor weight", () => {
    contribute(wallet1, 2_000_000n);
    contribute(wallet2, 1_000_000n);
    propose(wallet1, 1_000_000n, wallet2, "payout");
    vote(wallet1, 0n, true);
    vote(wallet2, 0n, true);

    const exec = simnet.callPublicFn(contractName, "execute-proposal", [Cl.uint(0)], wallet1);
    expect(exec.result).toBeOk(Cl.bool(true));

    const balance = simnet.callReadOnlyFn(contractName, "get-balance", [], deployer);
    expect(balance.result).toBeUint(2_000_000n);

    const totalWeight = simnet.callReadOnlyFn(
      contractName,
      "get-total-contributions",
      [],
      deployer,
    );
    expect(totalWeight.result).toBeUint(2_000_000n);

    const recipient = simnet.callReadOnlyFn(
      contractName,
      "get-contributor",
      [Cl.standardPrincipal(wallet2)],
      deployer,
    );
    expect(recipient.result).toBeSome(
      Cl.tuple({
        contributed: Cl.bool(false),
        amount: Cl.uint(0),
        "last-contribution-proposal-id": Cl.uint(0),
      }),
    );

    const active = simnet.callReadOnlyFn(
      contractName,
      "is-proposal-active-check",
      [Cl.uint(0)],
      deployer,
    );
    expect(active.result).toBeOk(Cl.bool(false));
  });

  it("fails to execute when votes are below the 51% threshold", () => {
    contribute(wallet1, 1_000_000n);
    contribute(wallet2, 1_000_000n);
    propose(wallet1, 500_000n, wallet2, "needs more votes");
    vote(wallet1, 0n, true);

    const exec = simnet.callPublicFn(contractName, "execute-proposal", [Cl.uint(0)], wallet1);
    expect(exec.result).toBeErr(Cl.uint(ERR_INSUFFICIENT_VOTES));
  });

  it("prevents voting and execution after expiry", () => {
    contribute(wallet1, 1_000_000n);
    propose(wallet1, 500_000n, wallet2, "expires");

    simnet.mineEmptyStacksBlocks(Number(PROPOSAL_LIFETIME + 1n));

    const expiredVote = vote(wallet1, 0n, true);
    expect(expiredVote.result).toBeErr(Cl.uint(ERR_PROPOSAL_EXPIRED));

    const exec = simnet.callPublicFn(contractName, "execute-proposal", [Cl.uint(0)], wallet1);
    expect(exec.result).toBeErr(Cl.uint(ERR_PROPOSAL_EXPIRED_EXEC));

    const active = simnet.callReadOnlyFn(
      contractName,
      "is-proposal-active-check",
      [Cl.uint(0)],
      deployer,
    );
    expect(active.result).toBeOk(Cl.bool(false));
  });
});

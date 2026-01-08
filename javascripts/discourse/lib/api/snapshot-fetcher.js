import { makeArray } from "discourse/lib/helpers";
import {
  SNAPSHOT_BASE_URL,
  SNAPSHOT_GRAPHQL_ENDPOINT,
  SNAPSHOT_TESTNET_BASE_URL,
  SNAPSHOT_TESTNET_GRAPHQL_ENDPOINT,
} from "../constants";
import { fetchJson } from "../fetch";
import { formatProposalUrl } from "../url-parser.js";

const POSITIVE = [
  "for",
  "yes",
  "yea",
  "yae",
  "approve",
  "approved",
  "accept",
  "support",
  "in favor",
  "favour",
];

const NEGATIVE = [
  "against",
  "no",
  "nay",
  "reject",
  "rejected",
  "deny",
  "oppose",
  "opposed",
];

const NEUTRAL = ["abstain", "abstention", "neutral"];

export class SnapshotFetcher {
  constructor(baseApi) {
    this.baseApi = baseApi;
  }

  async autoFetchProposals({ topicURL, topicId, ignoreCache = false }) {
    // TODO: handles cache

    return this.fetchProposals({
      spaces: (settings.enable_testnet_snapshots
        ? settings.testnet_snapshot_spaces
        : settings.snapshot_spaces
      ).split("|"),
      first: 20,
      cutoff: moment().subtract(60, "days").unix(),
      orderBy: "created",
      orderDirection: "desc",
      testnet: settings.enable_testnet_snapshots,
      topicURL,
      topicId,
      ignoreCache,
    }).then((proposals) => {
      if (!proposals || !proposals.length) {
        return [];
      }

      return proposals.map((proposal) => {
        return {
          ...proposal,
          ...formatProposalUrl({
            type: "snapshot",
            url: `${settings.enable_testnet_snapshots ? SNAPSHOT_TESTNET_BASE_URL : SNAPSHOT_BASE_URL}/#/${proposal.space}/proposal/${proposal.id}`,
            space: proposal.space,
            id: proposal.id,
          }),
          loaded: true,
        };
      });
    });
  }

  async fetchProposals({
    spaces = ["comp-vote.eth"],
    first = 20,
    cutoff = 60,
    orderBy = "created",
    orderDirection = "desc",
    testnet = false,
    topicURL = "",
    topicId,
    ignoreCache,
  }) {
    const cacheKey = `snapshot:proposals:${spaces.join("|")}:${topicId}`;

    return this.baseApi.fetchWithCache(
      cacheKey,
      async () => {
        const query = `
        query Proposals(
          $spaces: [String!]!,
          $first: Int!,
          $cutoff: Int!,
          $orderBy: String!,
          $orderDirection: OrderDirection!
        ) {
          proposals(
            where: { space_in: $spaces, created_gte: $cutoff }
            orderBy: $orderBy
            orderDirection: $orderDirection
            first: $first
          ) {
            id
            title
            body
            choices
            start
            end
            snapshot
            state
            author
            created
            discussion
            scores
            scores_total
            scores_updated
            space {
              id
              name
            }
            quorum
            quorumType
            type
            flagged
          }
        }
      `;

        const endpoint = testnet
          ? SNAPSHOT_TESTNET_GRAPHQL_ENDPOINT
          : SNAPSHOT_GRAPHQL_ENDPOINT;

        const response = await fetchJson(endpoint, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            query,
            variables: {
              spaces: makeArray(spaces),
              first,
              cutoff,
              orderBy,
              orderDirection,
            },
          }),
        });

        if (!response?.data?.proposals) {
          return [];
        }

        let foundProposals = response.data.proposals;
        if (settings.enable_url_checking) {
          foundProposals = foundProposals.filter(
            (proposal) => proposal.discussion === topicURL
          );
        }

        if (foundProposals.length === 0) {
          return [];
        }

        return foundProposals.map((proposal) => {
          return this.processProposalData(proposal);
        });
      },
      { ttl: settings.auto_proposals_cache_ttl, ignoreCache }
    );
  }

  async fetchProposal(space, id, topicId, testnet = false) {
    const persistentCache = this.baseApi.getPersistentCache({
      type: "snapshot",
      id,
      topicId,
    });
    if (persistentCache) {
      return persistentCache;
    }

    const shortCacheKey = `snapshot:${space}:${id}:${topicId}`;

    return this.baseApi.fetchWithCache(shortCacheKey, async () => {
      const query = `
        query Proposal($id: String!) {
          proposal(id: $id) {
            id
            title
            body
            choices
            start
            end
            state
            author
            created
            discussion
            scores
            scores_total
            scores_updated
            space {
              id
              name
            }
            quorum
            quorumType
            type
            flagged
          }
        }
      `;

      const endpoint = testnet
        ? SNAPSHOT_TESTNET_GRAPHQL_ENDPOINT
        : SNAPSHOT_GRAPHQL_ENDPOINT;

      const response = await fetchJson(endpoint, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ query, variables: { id } }),
      });

      if (!response?.data?.proposal) {
        return [];
      }

      return this.processProposalData(response.data.proposal);
    });
  }

  bucketVotesByMeaning(proposal) {
    const choices = proposal.choices ?? [];
    const scores = proposal.scores ?? [];

    const buckets = {
      for: 0,
      against: 0,
      abstain: 0,
      other: 0,
      byChoice: [],
    };

    for (let i = 0; i < choices.length; i++) {
      const meaning = this.classifyChoice(choices[i]);
      const score = Number(scores[i] ?? 0);

      buckets[meaning] = (buckets[meaning] ?? 0) + score;
      buckets.byChoice.push({ index: i, label: choices[i], meaning, score });
    }

    const totalVotes =
      Number(proposal.scores_total) ||
      buckets.byChoice.reduce((sum, x) => sum + x.score, 0);

    return { buckets, totalVotes };
  }

  classifyChoice(label) {
    const l = String(label || "")
      .toLowerCase()
      .trim();

    const isMatch = (arr) => arr.some((w) => l === w || l.includes(w));

    if (isMatch(NEUTRAL)) {
      return "abstain";
    }

    if (isMatch(POSITIVE)) {
      return "for";
    }

    if (isMatch(NEGATIVE)) {
      return "against";
    }

    return "other";
  }

  getStatus(proposal) {
    if (
      proposal.state === "pending" ||
      proposal.state === "active" ||
      proposal.state !== "closed"
    ) {
      return proposal.state;
    }

    const choices = proposal.choices ?? [];
    const scores = proposal.scores ?? [];
    const totalVotes =
      Number(proposal.scores_total) ||
      scores.reduce((a, b) => a + Number(b || 0), 0);

    let winner = -1;
    let winnerScore = -Infinity;
    for (let i = 0; i < scores.length; i++) {
      const s = Number(scores[i] ?? 0);
      if (s > winnerScore) {
        winnerScore = s;
        winner = i;
      }
    }

    if (totalVotes > 0) {
      const quorum = Number(proposal.quorum ?? 0);
      const quorumType = proposal.quorumType;

      let meetsQuorum = true;
      if (quorum > 0) {
        if (!quorumType || quorumType === "default") {
          meetsQuorum = totalVotes >= quorum;
        } else if (quorumType === "approval") {
          meetsQuorum = winnerScore >= quorum;
        } else {
          meetsQuorum = totalVotes >= quorum;
        }
      }

      if (!meetsQuorum) {
        return "rejected";
      }

      const meanings = choices.map((c) => this.classifyChoice(c));
      const forIdx = meanings.findIndex((m) => m === "for");
      const againstIdx = meanings.findIndex((m) => m === "against");
      const hasBinarySemantics = forIdx !== -1 && againstIdx !== -1;

      if (hasBinarySemantics) {
        return winner === forIdx ? "passed" : "rejected";
      }
    }

    return totalVotes > 0 ? "closed" : "rejected";
  }

  getStage(proposal) {
    if (
      /temp\s*check/i.test(proposal.title) ||
      /temp\s*check/i.test(proposal.body)
    ) {
      return "temp-check";
    } else if (/arfc/i.test(proposal.title) || /arfc/i.test(proposal.body)) {
      return "arfc";
    }
    return "snapshot";
  }

  processProposalData(proposal) {
    const status = this.getStatus(proposal);
    const stage = this.getStage(proposal);
    const { buckets, totalVotes } = this.bucketVotesByMeaning(proposal);

    const forPercent = totalVotes > 0 ? (buckets.for / totalVotes) * 100 : 0;
    const againstPercent =
      totalVotes > 0 ? (buckets.against / totalVotes) * 100 : 0;
    const abstainPercent =
      totalVotes > 0 ? (buckets.abstain / totalVotes) * 100 : 0;

    return {
      id: proposal.id,
      title: proposal.title,
      body: proposal.body,
      discussion: proposal.discussion,
      state: proposal.state,
      space: proposal.space.id,
      status,
      stage,

      created: proposal.created * 1000,
      start: proposal.start * 1000,
      end: proposal.end * 1000,

      totalVotes,
      votes: {
        for: { count: buckets.for, percent: forPercent },
        against: { count: buckets.against, percent: againstPercent },
        abstain: { count: buckets.abstain, percent: abstainPercent },
      },
    };
  }
}

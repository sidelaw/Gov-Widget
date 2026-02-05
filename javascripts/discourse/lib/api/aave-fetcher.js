import {
  AAVE_SUBGRAPH_VOTES,
  AAVE_V3_SUBGRAPH,
  PROPOSAL_STATES,
} from "../constants";
import { fetchJson } from "../fetch";
import { formatProposalUrl } from "../url-parser.js";

export class AaveFetcher {
  constructor(baseApi) {
    this.baseApi = baseApi;
  }

  async autoFetchProposals({ topicURL, topicId, ignoreCache }) {
    // Should be removed later.
    // Currently kept to fix issues with previous cached data.
    const cachedProposal = this.baseApi.findPersistentCache({
      type: "aip",
      topicId,
    });

    if (cachedProposal) {
      if (cachedProposal.end <= 0) {
        this.baseApi.clearPersistentCache({
          type: "aip",
          id: cachedProposal.id,
          topicId,
        });
      } else {
        //return Promise.resolve(cachedProposal);
      }
    }

    return this.fetchProposals({
      first: 20,
      orderBy: "id",
      orderDirection: "desc",
      topicURL,
      topicId,
      ignoreCache,
    }).then(async (proposals) => {
      if (!proposals || !proposals.length) {
        return [];
      }

      return proposals.map((proposal) => {
        return {
          ...proposal,
          ...formatProposalUrl({
            type: "aip",
            id: proposal.id,
            url: `https://vote.onaave.com/proposal/?proposalId=${proposal.id}`,
          }),
          loaded: true,
          topicId,
        };
      });
    });
  }

  async fetchProposals({
    first = 20,
    orderBy = "proposalId",
    orderDirection = "desc",
    topicURL,
    topicId,
    ignoreCache,
  }) {
    if (!topicURL) {
      return Promise.reject("Topic URL is required");
    }

    const cacheKey = `aave:proposals:${topicId}`;

    return this.baseApi.fetchWithCache(
      cacheKey,
      async () => {
        const query = `
        query getProposals(
          $first: Int!
          $topicURL: String!
        ) {
          proposals(
            where: { proposalMetadata_: { rawContent_contains: $topicURL } }
            first: 20
            orderBy: proposalId
            orderDirection: desc
          ) {
            proposalId
            state
            creator
            ipfsHash
            votingDuration
            proposalMetadata {
              title
              rawContent
            }
            votes {
              forVotes
              againstVotes
            }
            transactions {
              id
              created {
                timestamp
              }
              active {
                timestamp
              }
              executed {
                timestamp
              }
              queued {
                timestamp
              }
              failed {
                timestamp
              }
              canceled {
                timestamp
              }
            }
            votingConfig {
              id
              cooldownBeforeVotingStart
              votingDuration
              minPropositionPower
              yesNoDifferential
              yesThreshold
            }
          }
        }
      `;

        const response = await fetchJson(AAVE_V3_SUBGRAPH, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            query,
            variables: {
              first,
              orderBy,
              orderDirection,
              topicURL: settings.enable_url_checking ? topicURL : "",
            },
          }),
        });

        let proposals = response.data?.proposals;
        if (!proposals || proposals.length === 0) {
          return [];
        }

        return await Promise.all(
          proposals.map(async (proposal) => {
            return this.processProposalData(proposal);
          })
        );
      },
      { ttl: settings.auto_proposals_cache_ttl * 1000, ignoreCache }
    );
  }

  async fetchProposal(id, topicId) {
    const persistentCache = this.baseApi.getPersistentCache({
      type: "aip",
      id,
      topicId,
    });
    if (persistentCache) {
      return persistentCache;
    }

    const shortCacheKey = `aip:${id}:${topicId}`;

    return this.baseApi.fetchWithCache(shortCacheKey, async () => {
      const query = `
        {
          proposals(where: { proposalId: "${id}" }) {
            proposalId
            state
            creator
            ipfsHash
            votingDuration
            proposalMetadata {
              title
              rawContent
            }
            votes {
              forVotes
              againstVotes
            }
            transactions {
              id
              created {
                timestamp
              }
              active {
                timestamp
              }
              executed {
                timestamp
              }
              queued {
                timestamp
              }
              failed {
                timestamp
              }
              canceled {
                timestamp
              }
            }
            votingConfig {
              id
              cooldownBeforeVotingStart
              votingDuration
              minPropositionPower
              yesNoDifferential
              yesThreshold
            }
          }
        }
      `;

      const response = await fetchJson(AAVE_V3_SUBGRAPH, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ query }),
      });

      const proposals = response.data?.proposals;
      if (!proposals || proposals.length === 0) {
        throw new Error("Proposal not found");
      }

      return this.processProposalData(proposals[0]);
    });
  }

  async fetchProposalVotes(id) {
    const cacheKey = `aave:proposal:votes:${id}`;

    return this.baseApi.fetchWithCache(cacheKey, async () => {
      const query = `
        {
          voteEmitteds(where: { proposalId: "${id}"}) {
            id
            votingPower
            support
          }
        }
      `;

      const response = await fetchJson(AAVE_SUBGRAPH_VOTES, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ query }),
      });

      const voteEmitteds = response.data?.voteEmitteds;
      if (!voteEmitteds || voteEmitteds.length === 0) {
        return [];
      }

      let data = {
        for: 0,
        against: 0,
      };

      voteEmitteds.forEach((vote) => {
        const power = Number(this.formatBigInt(vote.votingPower, 18));
        if (vote.support) {
          data.for += power;
        } else {
          data.against += power;
        }
      });

      return data;
    });
  }

  async updateProposalWithVotes(proposal) {
    if (!proposal.needsDetailedVotes) {
      return proposal;
    }

    try {
      const votesData = await this.fetchProposalVotes(proposal.id);
      const forVotes = votesData.for;
      const againstVotes = votesData.against;
      const totalVotes = forVotes + againstVotes;

      const forPercent = totalVotes > 0 ? (forVotes / totalVotes) * 100 : 0;
      const againstPercent =
        totalVotes > 0 ? (againstVotes / totalVotes) * 100 : 0;

      return {
        ...proposal,
        totalVotes,
        votes: {
          for: { count: forVotes, percent: forPercent },
          against: { count: againstVotes, percent: againstPercent },
          abstain: { count: 0, percent: 0 },
        },
        needsDetailedVotes: false,
      };
    } catch (error) {
      console.warn(
        "Failed to fetch detailed votes for proposal ID:",
        proposal.id,
        error
      );
      return proposal;
    }
  }

  parseFrontMatter(text) {
    if (!text || !text.startsWith("---")) {
      return { metadata: {}, markdown: text, raw: text };
    }

    const endIndex = text.indexOf("\n---", 4);
    if (endIndex === -1) {
      return { metadata: {}, markdown: text, raw: text };
    }

    const frontMatterText = text.substring(4, endIndex).trim();
    const markdown = text.substring(endIndex + 5).trim();

    const metadata = {};
    const lines = frontMatterText.split("\n");
    for (const line of lines) {
      const colonIndex = line.indexOf(":");
      if (colonIndex > 0) {
        const key = line.substring(0, colonIndex).trim();
        let value = line.substring(colonIndex + 1).trim();
        if (
          (value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'"))
        ) {
          value = value.slice(1, -1);
        }
        metadata[key] = value;
      }
    }

    return { metadata, markdown, raw: text };
  }

  formatBigInt(value, decimals) {
    const str = value.toString();
    const pad = decimals - str.length + 1;
    const padded = pad > 0 ? "0".repeat(pad) + str : str;

    const integer = padded.slice(0, -decimals);
    const fraction = padded.slice(-decimals);

    return `${integer}.${fraction}`.replace(/\.?0+$/, "");
  }

  async processProposalData(proposal, { fetchVotes = false } = {}) {
    let hasVotes = proposal.votes !== null;
    let hasDetailsVotes = false;
    let needsDetailedVotes =
      !hasVotes && PROPOSAL_STATES[proposal.state] !== "created";

    let forVotes = 0;
    let againstVotes = 0;
    let abstainVotes = 0;
    let totalVotes = 0;
    let forPercent = 0;
    let againstPercent = 0;

    let start = 0;
    let end = 0;

    if (needsDetailedVotes && fetchVotes) {
      try {
        const votesData = await this.fetchProposalVotes(proposal.proposalId);
        hasDetailsVotes = true;
        forVotes = votesData.for;
        againstVotes = votesData.against;
        needsDetailedVotes = false;
      } catch {
        console.warn(
          "Failed to fetch detailed votes for proposal ID:",
          proposal.proposalId
        );
      }
    }

    if (hasVotes || hasDetailsVotes) {
      if (!hasDetailsVotes) {
        forVotes = Number(this.formatBigInt(proposal?.votes.forVotes, 18));
        againstVotes = Number(
          this.formatBigInt(proposal?.votes?.againstVotes, 18)
        );
      }

      abstainVotes = 0; // Aave V3 does not have abstain votes
      totalVotes = forVotes + againstVotes;

      forPercent = totalVotes > 0 ? (forVotes / totalVotes) * 100 : 0;
      againstPercent = totalVotes > 0 ? (againstVotes / totalVotes) * 100 : 0;
    }

    if (proposal.transactions.active) {
      start = Number(proposal.transactions.active.timestamp);
    } else if (proposal.transactions.created) {
      start =
        Number(proposal.transactions.created?.timestamp) +
        proposal.votingConfig.cooldownBeforeVotingStart;
    }

    if (proposal.transactions.canceled) {
      end = Number(proposal.transactions.canceled.timestamp);
    } else if (proposal.transactions.queued) {
      end = Number(proposal.transactions.queued.timestamp);
    } else if (proposal.transactions.executed) {
      end = Number(proposal.transactions.executed.timestamp);
    } else if (proposal.transactions.failed) {
      end = Number(proposal.transactions.failed.timestamp);
    } else if (proposal.votingConfig.votingDuration) {
      end = start + proposal.votingConfig.votingDuration;
    }

    const discourseUrl = this.parseFrontMatter(
      proposal.proposalMetadata?.rawContent
    ).metadata?.discussions;

    return {
      id: proposal.proposalId,
      title: proposal.proposalMetadata?.title || "Untitled Proposal",
      body: proposal.proposalMetadata?.rawContent,
      discussion: discourseUrl,
      space: "aave-v3",
      ipfsHash: proposal.ipfsHash,
      state: proposal.state,
      status: PROPOSAL_STATES[proposal.state],
      stage: "aip",

      start: start * 1000,
      end: end * 1000,

      totalVotes,
      votes: {
        for: { count: forVotes, percent: forPercent },
        against: { count: againstVotes, percent: againstPercent },
        abstain: { count: abstainVotes, percent: 0 },
      },

      needsDetailedVotes,
    };
  }
}

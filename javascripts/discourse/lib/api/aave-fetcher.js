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
    const cachedProposal = this.baseApi.findPersistentCache({
      type: "aip",
      topicId,
    });

    if (cachedProposal) {
      return Promise.resolve(cachedProposal);
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

      let proposal = proposals[0];
      if (proposal instanceof Promise) {
        proposal = await proposal;
      }

      return [
        {
          ...proposal,
          ...formatProposalUrl({
            type: "aip",
            id: proposal.id,
            url: `https://app.aave.com/governance/v3/proposal/?proposalId=${proposal.id}`,
          }),
          loaded: true,
        },
      ];
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

        return [this.processProposalData(proposals[0])];
      },
      { ttl: settings.auto_proposals_cache_ttl, ignoreCache }
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
      throw new Error("Votes not found");
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

  async processProposalData(proposal) {
    let hasVotes =
      proposal.votes && proposal.votes.forVotes && proposal.votes.againstVotes;
    let hasDetailsVotes = false;

    let forVotes = 0;
    let againstVotes = 0;
    let abstainVotes = 0;
    let totalVotes = 0;
    let forPercent = 0;
    let againstPercent = 0;

    let start = 0;
    let end = 0;

    if (!hasVotes && PROPOSAL_STATES[proposal.state] !== "created") {
      try {
        const votesData = await this.fetchProposalVotes(proposal.proposalId);
        hasDetailsVotes = true;
        forVotes = votesData.for;
        againstVotes = votesData.against;
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

    if (proposal.transactions.active || proposal.transactions.created) {
      start =
        Number(
          proposal.transactions.active?.timestamp ||
            proposal.transactions.created?.timestamp
        ) * 1000;
    }

    if (proposal.votingDuration) {
      end = start + Number(proposal.votingDuration) * 1000;
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

      start,
      end,

      totalVotes,
      votes: {
        for: { count: forVotes, percent: forPercent },
        against: { count: againstVotes, percent: againstPercent },
        abstain: { count: abstainVotes, percent: 0 },
      },
    };
  }
}

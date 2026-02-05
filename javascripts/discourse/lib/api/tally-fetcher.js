import { TALLY_V3_SUBGRAPH } from "../constants";
import { fetchJson } from "../fetch";
import { formatProposalUrl, validateDiscussionUrl } from "../url-parser.js";

export class TallyFetcher {
  constructor(baseApi) {
    this.baseApi = baseApi;
  }

  async fetchOrganisationId(slug) {
    const shortCacheKey = `tally:orgId:${slug}`;

    return this.baseApi.fetchWithCache(shortCacheKey, async () => {
      const query = `
        query Organization($slug: String!) {
          organization(input: { slug: $slug }) {
            id
          }
        }`;

      const response = await fetchJson(TALLY_V3_SUBGRAPH, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Api-Key": settings.tally_subgraph_api_key,
        },
        body: JSON.stringify({ query, variables: { slug } }),
      });

      return response.data?.organization?.id;
    });
  }

  async organisationId() {
    if (!settings.tally_organization_slug) {
      return null;
    }

    try {
      const orgId = await this.fetchOrganisationId(
        settings.tally_organization_slug
      );

      if (orgId && /^[0-9]+$/.test(String(orgId))) {
        return orgId;
      }
    } catch (e) {
      console.warn("Failed to fetch Tally organization ID", e);
    }

    return null;
  }

  async autoFetchProposals({ topicURL, topicId, ignoreCache = false }) {
    const orgId = await this.organisationId();
    if (!orgId) {
      return Promise.resolve([]);
    }

    /*const cachedProposal = this.baseApi.findPersistentCache(
      { type: "tally", id: "orgId", topicId },
      orgId
    );

    if (cachedProposal) {
      return Promise.resolve(cachedProposal);
    }*/

    return this.fetchProposals({
      orgId,
      limit: 20,
      sortBy: "id",
      isDescending: true,
      topicURL,
      topicId,
      ignoreCache,
    }).then((proposals) => {
      if (!proposals || !proposals.length) {
        return [];
      }
      const proposal = proposals[0];

      return [
        {
          ...proposal,
          ...formatProposalUrl({
            type: "tally",
            id: proposal.id,
            url: `https://www.tally.xyz/gov/${settings.tally_organization_slug}/proposal/${proposal.chainId}/?govId=${proposal.govId}`,
          }),
          loaded: true,
          topicId,
        },
      ];
    });
  }

  async fetchProposals({
    orgId,
    limit = 20,
    sortBy = "id",
    isDescending = true,
    topicURL,
    topicId,
    ignoreCache,
  }) {
    if (!topicURL) {
      return Promise.reject("Topic URL is required");
    }

    const cacheKey = `tally:${orgId}:${topicId}`;

    return this.baseApi.fetchWithCache(
      cacheKey,
      async () => {
        const query = `
query Proposals($orgId: IntID!, $limit: Int!, $sortBy: ProposalsSortBy!, $isDescending: Boolean!) {
  proposals(
    input: {filters: {organizationId: $orgId},
    sort: {sortBy: $sortBy, isDescending: $isDescending},
    page: {limit: $limit}}
  ) {
    nodes {
      ... on Proposal {
        id
        onchainId
        governor {
          id
        }
        status
        metadata {
          title
          description
          eta
          discourseURL
          snapshotURL
        }
        start {
          ... on Block {
            number
            timestamp
          }
          ... on BlocklessTimestamp {
            timestamp
          }
        }
        end {
          ... on Block {
            timestamp
          }
          ... on BlocklessTimestamp {
            timestamp
          }
        }
        quorum
        voteStats {
          type
          votesCount
          votersCount
          percent
        }
        vetoVoteStats {
          type
          votesCount
          votersCount
          percent
        }
        vetoVoteParameters {
          votingPeriod
          extendedVotingPeriod
          quorum
        }
        events {
          type
          createdAt
        }
      }
    }
    pageInfo {
      firstCursor
      lastCursor
    }
  }
}`;
        const response = await fetchJson(TALLY_V3_SUBGRAPH, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "Api-Key": settings.tally_subgraph_api_key,
          },
          body: JSON.stringify({
            query,
            variables: { orgId, limit, sortBy, isDescending },
          }),
        });

        let proposals = response.data?.proposals?.nodes;
        if (!proposals || proposals.length === 0) {
          return [];
        }

        proposals = proposals.filter((proposal) =>
          validateDiscussionUrl(proposal.metadata?.discourseURL, topicURL)
        );
        if (proposals.length === 0) {
          return [];
        }

        return [this.processProposalData(proposals[0])];
      },
      { ttl: settings.auto_proposals_cache_ttl * 1000, ignoreCache }
    );
  }

  async fetchProposal(id, govId, topicId) {
    const persistentCache = this.baseApi.getPersistentCache({
      type: "tally",
      id,
      topicId,
    });
    if (persistentCache) {
      return persistentCache;
    }

    const shortCacheKey = `tally:proposal:${id}:${govId}`;

    return this.baseApi.fetchWithCache(shortCacheKey, async () => {
      const query = `
        query Proposal($id: String, $govId: AccountID) {
          proposal(
            input: {onchainId : $id, governorId: $govId},
          )
          {
            ... on Proposal {
              id
              onchainId
              governor {
                id
              }
              status
              metadata {
                title
                description
                eta
                discourseURL
                snapshotURL
              }
              start {
                ... on Block {
                  number
                  timestamp
                }
                ... on BlocklessTimestamp {
                  timestamp
                }
              }
              end {
                ... on Block {
                  timestamp
                }
                ... on BlocklessTimestamp {
                  timestamp
                }
              }
              quorum
              voteStats {
                type
                votesCount
                votersCount
                percent
              }
              vetoVoteStats {
                type
                votesCount
                votersCount
                percent
              }
              vetoVoteParameters {
                votingPeriod
                extendedVotingPeriod
                quorum
              }
              events {
                type
                createdAt
              }
            }
          }
        }`;

      const response = await fetchJson(TALLY_V3_SUBGRAPH, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Api-Key": settings.tally_subgraph_api_key,
        },
        body: JSON.stringify({
          query,
          variables: { id, govId },
        }),
      });

      const proposal = response.data?.proposal;
      if (!proposal) {
        return null;
      }

      return this.processProposalData(proposal);
    });
  }

  formatBigInt(value, decimals) {
    const str = value.toString();
    const pad = decimals - str.length + 1;
    const padded = pad > 0 ? "0".repeat(pad) + str : str;

    const integer = padded.slice(0, -decimals);
    const fraction = padded.slice(-decimals);

    return `${integer}.${fraction}`.replace(/\.?0+$/, "");
  }

  processProposalData(proposal) {
    let votes = {};
    let totalVotes = 0;

    proposal.voteStats.forEach((stat) => {
      votes[stat.type] = {
        count: Number(this.formatBigInt(stat.votesCount, 18)),
        percent: stat.percent,
      };

      totalVotes += votes[stat.type].count;
    });

    const quorum = Number(this.formatBigInt(proposal.quorum, 18));

    return {
      id: proposal.id,
      chainId: proposal.onchainId,
      govId: proposal.governor?.id,
      title: proposal.metadata?.title || "Untitled Proposal",
      body: proposal.metadata?.description || "",
      discussion: proposal.metadata?.discourseURL,
      snapshotURL: proposal.metadata?.snapshotURL,
      quorum,

      state: proposal.status,
      status: proposal.status,
      stage: "tally",

      start: moment(proposal.start.timestamp).unix() * 1000,
      end: moment(proposal.end.timestamp).unix() * 1000,

      totalVotes,
      votes,
    };
  }
}

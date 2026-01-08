import { ajax } from "discourse/lib/ajax";
import {
  AIP_URL_REGEX,
  SNAPSHOT_URL_REGEX,
  TALLY_URL_REGEX,
} from "./constants.js";

export function formatProposalUrl({
  type,
  url,
  id,
  space,
  chainId = null,
  govId = null,
}) {
  return {
    type,
    url,
    id,
    chainId, // for tally proposals
    govId, // for tally proposals
    space, // for snapshot proposals
    testnet: url.includes("testnet."),
  };
}

export function extractProposalUrls(list = []) {
  if (!list.length) {
    return [];
  }

  const proposals = [];

  list.forEach((content) => {
    let match = [...content.matchAll(new RegExp(SNAPSHOT_URL_REGEX))];
    if (match.length > 0) {
      match.forEach((m) => {
        const [url, space, id] = m;
        if (id) {
          proposals.push(
            formatProposalUrl({
              fetch: "manual",
              type: "snapshot",
              url,
              space,
              id,
            })
          );
        }
      });
    }

    match = [...content.matchAll(new RegExp(AIP_URL_REGEX))];
    if (match.length > 0) {
      match.forEach((m) => {
        const [url] = m;
        const id = extractAIPProposalId(url);
        if (id) {
          proposals.push(
            formatProposalUrl({
              fetch: "manual",
              type: "aip",
              url,
              id,
            })
          );
        }
      });
    }

    match = [...content.matchAll(new RegExp(TALLY_URL_REGEX))];
    if (match.length > 0) {
      match.forEach((m) => {
        const [url, orgSlug, chainId, govId] = m;
        if (chainId && govId) {
          proposals.push(
            formatProposalUrl({
              fetch: "manual",
              type: "tally",
              url,
              space: orgSlug,
              id: chainId,
              chainId,
              govId: decodeURIComponent(govId),
            })
          );
        }
      });
    }
  });

  return proposals;
}

/**
 * Extract proposal ID from AIP URLs
 * - app.aave.com/governance/v3/proposal/?proposalId=123
 * - app.aave.com/governance/123
 * - vote.onaave.com/proposal/?proposalId=123
 */
function extractAIPProposalId(url) {
  try {
    const urlObj = new URL(url);
    const queryParam = urlObj.searchParams.get("proposalId");
    if (queryParam) {
      const id = parseInt(queryParam, 10);
      if (!isNaN(id) && id > 0) {
        return id.toString();
      }
    }

    const pathMatch = url.match(/\/governance\/(?:v3\/proposal\/)?(\d+)/);
    if (pathMatch) {
      const id = parseInt(pathMatch[1], 10);
      if (!isNaN(id) && id > 0) {
        return id.toString();
      }
    }
  } catch {}

  return null;
}

export async function extractProposalsFromTopic(topic) {
  const needsDataExplorer =
    topic.postStream.stream.length > topic.postStream.posts.length;

  if (
    needsDataExplorer &&
    settings.data_explorer_query_id > 0 &&
    settings.data_explorer_api_key.length > 0
  ) {
    try {
      const response = await ajax(
        `/admin/plugins/explorer/queries/${settings.data_explorer_query_id}/run`,
        {
          type: "POST",
          headers: {
            "Api-Username": "system",
            "Api-Key": settings.data_explorer_api_key,
          },
          data: {
            params: JSON.stringify({
              topic_id: topic.id,
              domains: settings.proposal_domains.split("|").join(","),
            }),
          },
        }
      );

      if (response.success && response.result_count > 0) {
        /*
          // Associate columns with their values
          const result = response.rows.map((row) => {
          const obj = {};
          response.columns.forEach((col, index) => {
            obj[col] = row[index];
          });
          return obj;
        });*/

        const links = response.rows.flatMap((row) => row);
        return extractProposalUrls([...new Set(links)]);
      }
    } catch (e) {
      console.error("Error fetching proposals from Data Explorer:", e);
    }
  }

  return extractProposalUrls([
    ...new Set(
      topic?.postStream?.posts?.reduce((acc, post) => {
        const links =
          post.link_counts
            ?.filter((link) => !link.internal)
            .map((link) => link.url) || [];
        return links.length > 0 ? [...acc, ...links] : acc;
      }, [])
    ),
  ]);
}

export function extractProposalsFromPost(post) {
  return extractProposalUrls([
    ...new Set(
      post.link_counts
        ?.filter((link) => !link.internal)
        .map((link) => link.url) || []
    ),
  ]);
}

export function extractProposalsFromText(text) {
  return extractProposalUrls([text]);
}

export function extractProposalsFromElement(element) {
  return extractProposalUrls([
    ...new Set(
      Array.from(element.querySelectorAll("a"))
        .map((a) => a.href)
        .filter((href) =>
          settings.proposal_domains
            .split("|")
            .some((domain) => href.includes(domain))
        )
    ),
  ]);
}

export const SNAPSHOT_BASE_URL = "https://snapshot.org";
export const SNAPSHOT_GRAPHQL_ENDPOINT = "https://hub.snapshot.org/graphql";

export const SNAPSHOT_TESTNET_BASE_URL = "https://testnet.snapshot.org";
export const SNAPSHOT_TESTNET_GRAPHQL_ENDPOINT =
  "https://testnet.hub.snapshot.org/graphql";
export const SNAPSHOT_URL_REGEX =
  /https?:\/\/(?:www\.)?(?:snapshot\.org|snapshot\.box|testnet\.snapshot\.box)\/#\/([^\/\s<>"']+)\/(?:proposal\/)?([a-zA-Z0-9]+)/gi;
export const AIP_URL_REGEX =
  /https?:\/\/(?:www\.)?(?:app\.aave\.com\/governance[^\s<>"']*|vote\.onaave\.com[^\s<>"']*|governance\.aave\.com\/(?!t\/)[^\s<>"']+)/gi;
export const TALLY_URL_REGEX =
  /https?:\/\/(?:www\.)?tally\.xyz\/gov\/([^\/\s<>"']+)\/proposal\/([a-zA-Z0-9]+)(?:\?govId=([^\/\s<>"'&]+))?/gi;

export const AAVE_V3_SUBGRAPH = `https://gateway.thegraph.com/api/${settings.aave_subgraph_api_key}/subgraphs/id/A7QMszgomC9cnnfpAcqZVLr2DffvkGNfimD8iUSMiurK`;
// Aave Governance Votes Avax
export const AAVE_SUBGRAPH_VOTES = `https://gateway.thegraph.com/api/${settings.aave_subgraph_api_key}/subgraphs/id/FngMWWGJV45McvV7GUBkrta9eoEi3sHZoH7MYnFQfZkr`;

export const TALLY_V3_SUBGRAPH = `https://api.tally.xyz/query`;

// Proposal States (from Aave V3 contract)
export const PROPOSAL_STATES = {
  0: "null",
  1: "created",
  2: "active",
  3: "queued",
  4: "executed",
  5: "failed",
  6: "cancelled",
  7: "expired",
};

const STATUS_CLASS_PER_TYPE_MAP = {
  // Special case:
  //    "closed" with successful execution -> Passed
  //    "closed" with failed execution -> Rejected
  snapshot: {
    pending: "upcoming",
    active: "active",
    passed: "passed",
    rejected: "rejected",
    closed: "closed",
    flagged: "closed",
  },
  aip: {
    created: "upcoming",
    active: "active",
    queued: "pending",
    executed: "executed",

    cancelled: "failed",
    failed: "failed",

    expired: "expired",
  },
  tally: {
    draft: "upcoming",
    submitted: "upcoming",

    active: "active",
    extended: "active",
    vetovoteopen: "active",

    callexecuted: "executed",
    crosschainexecuted: "executed",
    executed: "executed",

    pending: "pending",
    pendingexecution: "pending",
    queued: "pending",
    succeeded: "pending",
    vetoquorummet: "pending",

    canceled: "failed",
    cancelled: "failed",
    defeated: "failed",
    expired: "failed",
    vetoed: "failed",

    archived: "closed",
  },
};

export function getStatusClass(status, type) {
  if (!status || !type || !["snapshot", "aip", "tally"].includes(type)) {
    return "inactive";
  }

  const key = status.trim().toLowerCase();
  return STATUS_CLASS_PER_TYPE_MAP[type]?.[key] ?? "inactive";
}

export const STATUS_CLASS_PRIORITY = {
  active: 1,
  upcoming: 2,
  pending: 3,
  executed: 4,
  closed: 5,
  failed: 6,
  inactive: 7,
  expired: 7,

  passed: 4, // snapshot
  rejected: 6, // snapshot
};

export const VOTE_ENDED_STATUSES = [
  "pending",
  "executed",
  "closed",
  "failed",
  "expired",
  "passed",
  "rejected",
];

export const PROPOSAL_ENDED_STATUSES = [
  "executed",
  "closed",
  "failed",
  "expired",
  "passed",
  "rejected",
];

export function getStatusPriority(status, type) {
  return STATUS_CLASS_PRIORITY[getStatusClass(status, type)];
}

export const DEFAULT_STATUS_PRIORITY = 99;

// Widget display constants
export const MAX_WIDGETS = 3;
export const WIDGET_GAP_PX = 20;
export const DEBOUNCE_DELAY_MS = 30;

export const SHORT_CACHE_TTL_MS = 5 * 60 * 1000; // 5 minutes

// Time constants
export const ONE_DAY_MS = 86400000; // 24 hours

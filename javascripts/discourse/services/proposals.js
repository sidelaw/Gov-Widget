import { tracked } from "@glimmer/tracking";
import Service, { service } from "@ember/service";

export default class Proposals extends Service {
  @service baseApi;

  @tracked cache = [];

  get items() {
    return this.cache;
  }

  addItems(proposals) {
    if (proposals.length === 0) {
      return;
    }
    proposals.forEach((proposal) => this.addItem(proposal));
  }

  addItem(proposal) {
    if (
      this.cache.find(
        (p) =>
          (p.type === "tally" &&
            p.chainId === proposal.chainId &&
            p.govId === proposal.govId) ||
          p.id === proposal.id
      )
    ) {
      return;
    }

    this.cache = [...this.cache, proposal];
  }

  async loadProposalData(proposal) {
    try {
      if (proposal.type === "snapshot") {
        return this.baseApi.snapshot.fetchProposal(
          proposal.space,
          proposal.id,
          proposal.topicId,
          proposal.testnet
        );
      } else if (proposal.type === "aip") {
        return this.baseApi.aave.fetchProposal(proposal.id, proposal.topicId);
      } else if (proposal.type === "tally") {
        return this.baseApi.tally.fetchProposal(
          proposal.id,
          proposal.govId,
          proposal.topicId
        );
      } else if (proposal.type === "placeholder") {
        return Promise.resolve({ loaded: true });
      }
      return Promise.reject({ error: "Unknown proposal type" });
    } catch (e) {
      return Promise.reject({
        ...proposal,
        loaded: false,
        error: e.message || "Failed to load proposal",
      });
    }
  }

  async loadAllProposalData(topicId) {
    const proposalsToLoad = this.cache.filter((p) => !p.loaded);
    if (proposalsToLoad.length === 0) {
      return this.cache;
    }

    const loadPromises = proposalsToLoad.map((proposal) =>
      this.loadProposalData({ topicId, ...proposal })
    );

    let loadedProposals = await Promise.all(loadPromises);
    loadedProposals = proposalsToLoad.map((proposal, index) => {
      return {
        ...proposal,
        ...loadedProposals[index],
        topicId,
        loaded: true,
      };
    });

    this.cache = this.cache.map((existing) => {
      const loaded = loadedProposals.find(
        (p) =>
          (p.type === "tally" &&
            p.chainId === existing.id &&
            p.govId === existing.govId) ||
          p.id === existing.id
      );
      return loaded || existing;
    });

    return this.cache;
  }

  addOrRemoveItems(proposals) {
    proposals.forEach((proposal) => {
      if (
        this.cache.find(
          (p) =>
            (p.type === "tally" &&
              p.chainId === proposal.id &&
              p.govId === proposal.govId) ||
            p.id === proposal.id
        )
      ) {
        this.removeItem(proposal);
      } else {
        this.addItem(proposal);
      }
    });
  }

  removeAutoFetchedItems() {
    this.cache = this.cache.filter((p) => p.fetch === "manual");
  }

  removeItem(proposal) {
    this.cache = this.cache.filter((p) => {
      if (proposal.type === "tally") {
        return !(p.chainId === proposal.id && p.govId === proposal.govId);
      } else {
        return p.id !== proposal.id;
      }
    });
  }

  removeItemFromUrl(url) {
    this.cache = this.cache.filter((p) => p.url !== url);
  }

  clear() {
    this.cache = [];
  }
}

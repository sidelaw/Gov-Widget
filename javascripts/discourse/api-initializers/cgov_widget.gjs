import { next } from "@ember/runloop";
import { apiInitializer } from "discourse/lib/api";
import PreviewProposal from "../components/proposal/preview";
import {
  extractProposalsFromElement,
  extractProposalsFromText,
} from "../lib/url-parser";

export default apiInitializer((api) => {
  const router = api.container.lookup("service:router");
  const proposalsCache = api.container.lookup("service:proposals");
  const appEvents = api.container.lookup("service:app-events");

  router.on("routeDidChange", () => {
    proposalsCache.clear();
    appEvents.trigger("proposals-cache:refresh");
  });

  if (!settings.manual_proposal_fetching) {
    return;
  }

  let currentComposerProposalUrls = new Set();
  let currentPostRaw = null;

  api.onAppEvent("composer:open", ({ model }) => {
    currentPostRaw = model.post?.raw;
  });

  api.onAppEvent("composer:opened", () => {
    document
      .querySelectorAll(".d-editor-preview .proposal-preview")
      .forEach((el) => currentComposerProposalUrls.add(el.dataset.proposalUrl));
  });

  api.onAppEvent("composer:cancelled", () => {
    if (currentPostRaw) {
      const proposals = extractProposalsFromText(currentPostRaw);
      const toRemove = Array.from(currentComposerProposalUrls.values()).filter(
        (url) => !proposals.find((p) => p.url === url)
      );
      toRemove.forEach((url) => {
        proposalsCache.removeItemFromUrl(url);
      });

      if (proposals.length) {
        proposalsCache.removeAutoFetchedItems();
      }

      proposalsCache.addItems(proposals);
      proposalsCache.loadAllProposalData(-1);
    }
  });

  api.onAppEvent("composer:closed", () => {
    currentComposerProposalUrls.clear();
    currentPostRaw = null;
  });

  api.decorateCookedElement(async (element, helper) => {
    const { model } = helper;
    const composerPreview = !model;

    let proposals = [];

    if (model) {
      proposals = extractProposalsFromText(model.cooked);
    } else {
      proposals = extractProposalsFromElement(element);

      next(async () => {
        if (proposals.length) {
          proposalsCache.removeAutoFetchedItems();
        }

        currentComposerProposalUrls.forEach((url) => {
          if (!proposals.length || !proposals.find((p) => p.url === url)) {
            proposalsCache.removeItemFromUrl(url);
          }
        });

        if (!proposalsCache.items.length) {
          // Add placeholder to avoid component tearing down
          proposalsCache.addItems([{ type: "placeholder", url: null }]);
        }

        proposals.forEach((proposal) => {
          proposal.fetch = "manual";
          currentComposerProposalUrls.add(proposal.url);
        });

        proposalsCache.addItems(proposals);
        await proposalsCache.loadAllProposalData(-1);

        if (
          !proposalsCache.items.filter((p) => p.type !== "placeholder").length
        ) {
          appEvents.trigger("proposals-cache:refresh");
        }
      });
    }

    if (proposals.length > 0) {
      const seenUrls = new Set();
      proposals = proposals.filter((proposal) => {
        if (seenUrls.has(proposal.url)) {
          return false;
        } else {
          seenUrls.add(proposal.url);
          return true;
        }
      });

      if (model) {
        next(async () => {
          proposalsCache.addItems(proposals);
          proposalsCache.loadAllProposalData(model.topic_id);
        });
      }

      proposals.reverse().forEach((proposal) => {
        const link = element.querySelector("a[href='" + proposal.url + "']");
        if (!link) {
          return;
        }
        const onebox = link.closest(
          ".onebox[data-onebox-src='" + proposal.url + "']"
        );

        const elementToReplace = onebox || link;

        const previewContainer = document.createElement("div");
        previewContainer.className = "proposal-preview";
        previewContainer.dataset.proposalUrl = proposal.url;

        helper.renderGlimmer(previewContainer, PreviewProposal, {
          proposal,
          composerPreview,
          topicId: model ? model.topic_id : -1,
        });

        elementToReplace.replaceWith(previewContainer);
      });
    }
  });
});

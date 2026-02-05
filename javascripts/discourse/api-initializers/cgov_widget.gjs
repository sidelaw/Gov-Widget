import { next } from "@ember/runloop";
import { apiInitializer } from "discourse/lib/api";
import PreviewProposal from "../components/proposal/preview";
import {
  dedupeUrls,
  extractProposalsFromElement,
  extractProposalsFromText,
} from "../lib/url-parser";

export default apiInitializer((api) => {
  const router = api.container.lookup("service:router");
  const proposalsCache = api.container.lookup("service:proposals");
  const appEvents = api.container.lookup("service:app-events");

  router.on("routeDidChange", () => {
    proposalsCache.clear();
    proposalsCache.addItems([{ type: "placeholder", url: null }]); // Add placeholder to avoid component tearing down

    appEvents.trigger("proposals-cache:refresh");
    appEvents.trigger("widget:check-position");
  });

  if (!settings.manual_proposal_fetching) {
    return;
  }

  let currentComposerProposalUrls = new Set();
  let currentPostRaw = null;

  api.onAppEvent("composer:open", ({ model }) => {
    if (proposalsCache.isTopicIgnored()) {
      return;
    }

    currentPostRaw = model.post?.raw;
  });

  api.onAppEvent("composer:opened", () => {
    if (proposalsCache.isTopicIgnored()) {
      return;
    }

    document
      .querySelectorAll(".d-editor-preview .proposal-preview")
      .forEach((el) => currentComposerProposalUrls.add(el.dataset.proposalUrl));
  });

  api.onAppEvent("composer:cancelled", () => {
    if (proposalsCache.isTopicIgnored()) {
      return;
    }

    if (currentPostRaw) {
      const proposals = extractProposalsFromText(currentPostRaw);
      const toRemove = Array.from(currentComposerProposalUrls.values()).filter(
        (url) => !proposals.find((p) => p.url === url)
      );
      toRemove.forEach((url) => {
        proposalsCache.removeItemFromUrl(url);
      });

      if (proposals.length) {
        proposalsCache.addItems(proposals);
        proposalsCache.loadAllProposalData(-1);
      }
    }
  });

  api.onAppEvent("composer:closed", () => {
    if (proposalsCache.isTopicIgnored()) {
      return;
    }

    currentComposerProposalUrls.clear();
    currentPostRaw = null;
  });

  api.decorateCookedElement(async (element, helper) => {
    const { model } = helper;
    const composerPreview = !model;

    let proposals = [];

    if (model) {
      if (proposalsCache.isTopicIgnored(model.topic_id)) {
        return;
      }

      proposals = extractProposalsFromText(model.cooked);
      proposals = dedupeUrls(proposals);
      proposals = proposals.map((proposal) => {
        proposal.fetch = "manual";
        return proposal;
      });

      next(async () => {
        if (proposals.length) {
          proposalsCache.addItems(proposals);
          await proposalsCache.loadAllProposalData(model.topic_id);
        }
      });
    } else {
      if (proposalsCache.isTopicIgnored()) {
        return;
      }

      proposals = extractProposalsFromElement(element);

      next(async () => {
        currentComposerProposalUrls.forEach((url) => {
          if (!proposals.length || !proposals.find((p) => p.url === url)) {
            proposalsCache.removeItemFromUrl(url);
          }
        });

        if (!proposalsCache.items.length) {
          // Add placeholder to avoid component tearing down
          proposalsCache.addItems([{ type: "placeholder", url: null }]);
        }

        if (proposals.length) {
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
        }
      });
    }

    if (proposals.length > 0) {
      proposals.reverse().forEach((proposal) => {
        const link = element.querySelector("a[href^='" + proposal.url + "']");
        if (!link) {
          return;
        }
        const onebox = link.closest(
          ".onebox[data-onebox-src='" + proposal.url + "']"
        );

        const elementToReplace = onebox || link;

        const parent = link.parentElement;
        if (
          !onebox &&
          (!parent ||
            parent.tagName !== "P" ||
            parent.textContent.trim() !== link.textContent.trim())
        ) {
          return;
        }

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

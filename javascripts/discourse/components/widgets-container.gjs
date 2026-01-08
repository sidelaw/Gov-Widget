import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import didUpdate from "@ember/render-modifiers/modifiers/did-update";
import willDestroy from "@ember/render-modifiers/modifiers/will-destroy";
import { cancel, schedule } from "@ember/runloop";
import { service } from "@ember/service";
import ConditionalLoadingSpinner from "discourse/components/conditional-loading-spinner";
import discourseDebounce from "discourse/lib/debounce";
import { bind } from "discourse/lib/decorators";
import { getAbsoluteURL } from "discourse/lib/get-url";
import { not } from "discourse/truth-helpers";
import {
  DEBOUNCE_DELAY_MS,
  getStatusClass,
  getStatusPriority,
  MAX_WIDGETS,
  PROPOSAL_ENDED_STATUSES,
  WIDGET_GAP_PX,
} from "../lib/constants";
import { extractProposalsFromTopic } from "../lib/url-parser";
import ConditionalOverflowNav from "./conditional-overflow-nav";
import Widget from "./proposal/widget";

export default class WidgetsContainer extends Component {
  @service proposals;
  @service baseApi;
  @service appEvents;

  @tracked showAsSidebar = false;
  @tracked loading = true;
  @tracked error = null;

  constructor() {
    super(...arguments);

    this.extractProposals();
    this.startBackgroundRefresh();
  }

  getDockedWidthPx(widget) {
    const width = getComputedStyle(widget)
      .getPropertyValue("--side-width")
      .trim();
    const widthFloat = parseFloat(width);
    return Number.isFinite(widthFloat) && widthFloat > 0 ? widthFloat : 0;
  }

  checkPosition() {
    const wrapper = document.querySelector("#main-outlet-wrapper");
    if (!wrapper || !this.widgetsContainer) {
      return;
    }

    const wrapperRect = wrapper.getBoundingClientRect();
    const viewportWidth = window.visualViewport
      ? window.visualViewport.width
      : window.innerWidth;

    const spaceRight = viewportWidth - wrapperRect.right;
    const widgetWidth = this.getDockedWidthPx(this.widgetsContainer);

    this.showAsSidebar = spaceRight >= widgetWidth + WIDGET_GAP_PX;
    this.widgetsContainer.classList.toggle(
      "widgets-on-side",
      this.showAsSidebar
    );
  }

  @bind
  checkPositionDebounced() {
    this.checkPositionTimer = discourseDebounce(
      this,
      this.checkPosition,
      DEBOUNCE_DELAY_MS
    );
  }

  @action
  setup(element) {
    this.widgetsContainer = element;
    this.resizeHandler = new ResizeObserver(this.checkPositionDebounced);
    this.resizeHandler.observe(document.documentElement);
    this.checkPosition();

    this.appEvents.on(
      "proposals-cache:refresh",
      this.autoExtractProposalsDeferred
    );
  }

  @action
  teardown() {
    this.resizeHandler?.disconnect();
    this.endBackgroundRefresh();
    cancel(this.checkPositionTimer);

    this.appEvents.off(
      "proposals-cache:refresh",
      this.autoExtractProposalsDeferred
    );
  }

  startBackgroundRefresh() {
    if (
      settings.auto_proposals_refresh_interval > 0 &&
      !this.extractProposalsTimer
    ) {
      this.extractProposalsTimer = setInterval(
        () => this.autoExtractProposalsDeferred({ ignoreCache: true }),
        settings.auto_proposals_refresh_interval * 1000
      );
    }
  }

  endBackgroundRefresh() {
    clearInterval(this.extractProposalsTimer);
    this.extractProposalsTimer = null;
  }

  canFetchProposalsBy({ mode, prefix }) {
    let enabledKey, tagsKey, categoriesKey;

    if (prefix === "aip") {
      prefix = "aave";
    }

    switch (mode) {
      case "method":
        enabledKey = `${prefix}_proposal_fetching`;
        tagsKey = `${prefix}_proposal_fetching_tags`;
        categoriesKey = `${prefix}_proposal_fetching_categories`;
        break;
      case "type":
        enabledKey = `enable_${prefix}_fetching`;
        tagsKey = `${prefix}_fetching_tags`;
        categoriesKey = `${prefix}_fetching_categories`;
        break;
    }

    const enabled = settings[enabledKey];
    const allowedTags = settings[tagsKey].split("|").filter(Boolean);
    const allowedCategories = settings[categoriesKey]
      .split("|")
      .map(Number)
      .filter(Boolean);

    return (
      enabled &&
      (!allowedTags.length ||
        (this.topicTags.length &&
          this.topicTags.some((tag) => allowedTags.includes(tag)) &&
          (!allowedCategories.length ||
            allowedCategories.includes(this.topicCategoryId))))
    );
  }

  get canManualFetchProposals() {
    return this.canFetchProposalsBy({
      mode: "method",
      prefix: "manual",
    });
  }

  get canAutoFetchProposals() {
    return this.canFetchProposalsBy({
      mode: "method",
      prefix: "auto",
    });
  }

  @bind
  async autoExtractProposalsDeferred(options = {}) {
    if (this.isDestroying || this.isDestroyed) {
      return;
    }

    if (!this.hasAutoProposals && this.hasManualLoadedProposals) {
      return;
    }

    const { ignoreCache } = options;
    const { topic } = this.args;

    if (!topic) {
      console.info("No topic available, skipping auto-extraction.");
      return;
    }

    if (
      this.canAutoFetchProposals &&
      (!this.canManualFetchProposals || !this.hasManualLoadedProposals)
    ) {
      let promises = [];

      if (this.canFetchProposalsBy({ mode: "type", prefix: "snapshot" })) {
        promises.push(
          this.baseApi.snapshot.autoFetchProposals({
            topicURL: this.topicUrl,
            topicId: this.topicId,
            ignoreCache,
          })
        );
      }

      if (this.canFetchProposalsBy({ mode: "type", prefix: "aave" })) {
        promises.push(
          this.baseApi.aave.autoFetchProposals({
            topicURL: this.topicUrl,
            topicId: this.topicId,
            ignoreCache,
          })
        );
      }

      if (this.canFetchProposalsBy({ mode: "type", prefix: "tally" })) {
        promises.push(
          this.baseApi.tally.autoFetchProposals({
            topicURL: this.topicUrl,
            topicId: this.topicId,
            ignoreCache,
          })
        );
      }

      if (promises.length) {
        const proposals = await Promise.all(promises);
        const foundProposals = proposals.flat();

        if (!this.hasAutoProposals && this.hasManualLoadedProposals) {
          return;
        }

        if (foundProposals.length) {
          this.proposals.addItems(foundProposals);
        }
      }
    }
  }

  async extractProposals() {
    const { topic } = this.args;

    if (!topic) {
      this.loading = false;
      return;
    }

    schedule("afterRender", this, async () => {
      try {
        if (this.canManualFetchProposals) {
          const foundProposals = await extractProposalsFromTopic(topic);
          const filteredProposals = foundProposals.filter((proposal) =>
            this.canFetchProposalsBy({ mode: "type", prefix: proposal.type })
          );

          if (filteredProposals.length) {
            this.proposals.addItems(
              filteredProposals.map((p) => ({
                ...p,
                fetch: "manual",
              }))
            );
            await this.proposals.loadAllProposalData(this.topicId);
          }
        }

        if (this.hasManualLoadedProposals) {
          console.info("Manual proposals found, skipping auto-fetching.");
          return;
        }

        console.info(
          "No manual proposals found, proceeding with auto-fetching."
        );

        this.autoExtractProposalsDeferred();
      } catch (error) {
        console.error("Failed to load proposals:", error);
        this.error = error.message || "Failed to load proposals";
      } finally {
        this.loading = false;
      }
    });
  }

  get topicUrl() {
    return getAbsoluteURL(this.args.topic.url);
  }

  get topicId() {
    return this.args.topic.id;
  }

  get topicTags() {
    return this.args.topic?.tags || [];
  }

  get topicCategoryId() {
    return this.args.topic?.category_id;
  }

  get hasProposals() {
    return this.proposals.items.length > 0;
  }

  get hasAutoProposals() {
    return (
      !this.hasProposals ||
      this.proposals.items.some((p) => p.fetch !== "manual")
    );
  }

  get hasManualLoadedProposals() {
    return this.loadedProposals.some((p) => p.fetch === "manual");
  }

  get loadedProposals() {
    return this.proposals.items.filter(
      (p) => p.loaded && this.validateDiscussionUrl(p.discussion)
    );
  }

  get snapshotProposals() {
    return this.loadedProposals.filter((p) => p.type === "snapshot");
  }

  get aipProposals() {
    return this.loadedProposals.filter((p) => p.type === "aip");
  }

  get tallyProposals() {
    return this.loadedProposals.filter((p) => p.type === "tally");
  }

  validateDiscussionUrl(url) {
    return url && (!settings.enable_url_checking || url === this.topicUrl);
  }

  get sortedProposals() {
    let proposals = [
      ...this.tallyProposals,
      ...this.aipProposals,
      ...this.snapshotProposals,
    ];

    if (!settings.enable_tagless_snapshots) {
      proposals = proposals.filter((p) => p.stage === "snapshot");
    }

    const toTime = (v) => {
      const t = new Date(v).getTime();
      return Number.isFinite(t) ? t : null;
    };

    const getSecondaryTime = (p) => {
      const cls = getStatusClass(p.status, p.type);
      const start = toTime(p.start);
      const end = toTime(p.end);

      switch (cls) {
        // urgency: ending sooner first
        case "active":
          return { value: end ?? Number.POSITIVE_INFINITY, dir: "asc" };
        // starts sooner first
        case "upcoming":
          return { value: start ?? Number.POSITIVE_INFINITY, dir: "asc" };
        // finished-ish: show most recent first
        default:
          return {
            value: end ?? start ?? Number.NEGATIVE_INFINITY,
            dir: "desc",
          };
      }
    };

    const sorted = proposals.sort((a, b) => {
      const statusA = getStatusPriority(a.status);
      const statusB = getStatusPriority(b.status);

      if (statusA !== statusB) {
        return statusA - statusB;
      }

      const secondaryA = getSecondaryTime(a);
      const secondaryB = getSecondaryTime(b);

      if (secondaryA.value !== secondaryB.value) {
        return secondaryA.dir === "asc"
          ? secondaryA.value - secondaryB.value
          : secondaryB.value - secondaryA.value;
      }
    });

    const allTypes = [...new Set(sorted.map((p) => p.stage))];

    let maxPerType;
    if (allTypes.length >= MAX_WIDGETS) {
      maxPerType = 1;
    } else if (allTypes.length === 2) {
      maxPerType = 2;
    } else {
      maxPerType = MAX_WIDGETS;
    }

    const selected = [];
    let typeCounts = { "temp-check": 0, arfc: 0, aip: 0, tally: 0 };

    if (settings.enable_tagless_snapshots) {
      typeCounts["snapshot"] = 0;
    }

    for (const proposal of sorted) {
      const type = proposal.stage;

      if (
        typeCounts[type] < maxPerType ||
        (selected.length < MAX_WIDGETS &&
          Object.values(typeCounts).every((count) => count === 0))
      ) {
        selected.push(proposal);
        typeCounts[type]++;
      }

      if (selected.length >= MAX_WIDGETS) {
        break;
      }
    }

    if (selected.length > 0) {
      selected.forEach((proposal) => {
        if (
          PROPOSAL_ENDED_STATUSES.includes(
            getStatusClass(proposal.status, proposal.type)
          )
        ) {
          let id = proposal.id;
          if (proposal.type === "tally") {
            id = `${proposal.chainId}-${proposal.govId}`;
          }
          this.baseApi.setPersistentCache(
            { type: proposal.type, id, topicId: this.topicId },
            proposal
          );
        }
      });
    }

    return selected;
  }

  <template>
    {{#if this.hasProposals}}
      <div
        class="aave-widgets-container"
        {{didInsert this.setup}}
        {{didUpdate this.extractProposals}}
        {{willDestroy this.teardown}}
      >
        {{#if this.error}}
          <div class="widgets-error">
            <p>{{this.error}}</p>
          </div>
        {{else}}
          <ConditionalLoadingSpinner @condition={{this.loading}}>
            <ConditionalOverflowNav @condition={{not this.showAsSidebar}}>
              {{#each this.sortedProposals as |proposal|}}
                <Widget
                  @type={{proposal.type}}
                  @space={{proposal.space}}
                  @proposalId={{proposal.id}}
                  @govId={{proposal.govId}}
                  @testnet={{proposal.testnet}}
                  @url={{proposal.url}}
                  @topicId={{this.topicId}}
                  @proposal={{proposal}}
                />
              {{/each}}
            </ConditionalOverflowNav>
          </ConditionalLoadingSpinner>
        {{/if}}
      </div>
    {{/if}}
  </template>
}

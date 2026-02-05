import Component from "@glimmer/component";
import { cached, tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import didUpdate from "@ember/render-modifiers/modifiers/did-update";
import willDestroy from "@ember/render-modifiers/modifiers/will-destroy";
import { cancel, later, next, schedule } from "@ember/runloop";
import { service } from "@ember/service";
import concatClass from "discourse/helpers/concat-class";
import discourseDebounce from "discourse/lib/debounce";
import { bind } from "discourse/lib/decorators";
import { getAbsoluteURL } from "discourse/lib/get-url";
import { not } from "discourse/truth-helpers";
import {
  cleanTitle,
  DEBOUNCE_DELAY_MS,
  getStatusClass,
  getStatusPriority,
  MAX_WIDGETS,
  PROPOSAL_ENDED_STATUSES,
  WIDGET_GAP_PX,
} from "../lib/constants";
import {
  dedupeUrls,
  extractProposalsFromTopic,
  validateDiscussionUrl,
} from "../lib/url-parser";
import ConditionalOverflowNav from "./conditional-overflow-nav";
import Widget from "./proposal/widget";

const SCROLL_STATE_CHANGE_COOLDOWN_MS = 500;

export default class WidgetsContainer extends Component {
  @service proposals;
  @service baseApi;
  @service appEvents;

  @tracked showAsSidebar = false;
  @tracked loading = true;
  @tracked error = null;
  @tracked isMinimized = false;

  lastScrollY = 0;
  lastStateChange = 0;
  scrollListenerActive = false;

  constructor() {
    super(...arguments);

    if (this.shouldIgnoreTopic) {
      this.loading = false;
      return;
    }

    this.extractProposals();
    document.body.classList.add("checking-proposals");

    later(() => this.startBackgroundRefresh(), 1000);
  }

  get shouldIgnoreTopic() {
    const { topic } = this.args;

    if (!topic) {
      return false;
    }

    this.proposals.setTopicId(topic.id);

    if (!settings.enable_tag_checking_in_topic_title) {
      return false;
    }

    const validTopicTag = !!topic.title
      .match(
        /\[(direct[\s+\-]to[\s+\-]aip|aip|arfc\s*addendum|arfc|temp(?:erature)? check)\]/i
      )?.[1]
      ?.toLowerCase();

    if (!validTopicTag) {
      this.proposals.addTopicToIgnore(topic.id);
      return true;
    }

    return false;
  }

  getDockedWidthPx(widget) {
    const width = getComputedStyle(widget)
      .getPropertyValue("--side-width")
      .trim();
    const widthFloat = parseFloat(width);
    return Number.isFinite(widthFloat) && widthFloat > 0 ? widthFloat : 0;
  }

  checkPosition({ hasProposals } = {}) {
    const wrapper = document.querySelector("#main-outlet-wrapper");
    if (!wrapper) {
      return;
    }

    const headerWrap = document.querySelector(".d-header .wrap");

    wrapper.style.transition = "";
    if (headerWrap) {
      headerWrap.style.transition = "";
    }

    wrapper.style.marginLeft = "";
    wrapper.style.marginRight = "";
    if (headerWrap) {
      headerWrap.style.marginLeft = "";
      headerWrap.style.marginRight = "";
    }

    if (!this.widgetsContainer) {
      return;
    }

    const wrapperRect = wrapper.getBoundingClientRect();
    const viewportWidth = window.visualViewport
      ? window.visualViewport.width
      : window.innerWidth;

    const spaceRight = viewportWidth - wrapperRect.right;
    const spaceLeft = wrapperRect.left;
    const widgetWidth = this.getDockedWidthPx(this.widgetsContainer);
    const widgetNeeds = widgetWidth + WIDGET_GAP_PX;

    let showAsSidebar = false;

    if (spaceRight >= widgetNeeds) {
      showAsSidebar = true;
    } else if (!this.loading && hasProposals) {
      const totalSpace = spaceLeft + spaceRight;
      if (totalSpace >= widgetNeeds) {
        showAsSidebar = true;

        const remainingSpace = totalSpace - widgetNeeds;
        const idealLeftSpace = remainingSpace / 2;

        wrapper.style.marginLeft = `${idealLeftSpace}px`;
        wrapper.style.marginRight = `${widgetNeeds}px`;
        if (headerWrap) {
          headerWrap.style.marginLeft = "0px";
          headerWrap.style.marginRight = `${widgetNeeds}px`;
        }
      }
    }

    this.showAsSidebar = showAsSidebar;
    this.updateScrollListener();
  }

  updateScrollListener() {
    const shouldListen = !this.showAsSidebar;

    if (shouldListen && !this.scrollListenerActive) {
      this.lastScrollY = window.scrollY;
      window.addEventListener("scroll", this.handleScroll, { passive: true });
      this.scrollListenerActive = true;
    } else if (!shouldListen && this.scrollListenerActive) {
      window.removeEventListener("scroll", this.handleScroll);
      this.scrollListenerActive = false;
      this.isMinimized = false;
    }
  }

  @bind
  checkPositionDebounced() {
    this.checkPositionTimer = discourseDebounce(
      this,
      this.checkPosition,
      { hasProposals: this.sortedProposals?.length > 0 },
      DEBOUNCE_DELAY_MS
    );
  }

  @bind
  handleScroll() {
    if (this.scrollRAF) {
      return;
    }

    this.scrollRAF = requestAnimationFrame(() => {
      this.scrollRAF = null;
      this.processScroll();
    });
  }

  processScroll() {
    const now = Date.now();
    const currentScrollY = window.scrollY;
    const scrollDelta = currentScrollY - this.lastScrollY;

    const isScrollingDown = scrollDelta > 0;
    const isScrollingUp = scrollDelta < 0;

    const isNearTop = currentScrollY < settings.scroll_expand_threshold_px;
    const threshold = isScrollingDown
      ? settings.scroll_minimize_threshold_px
      : isNearTop
        ? 0
        : settings.scroll_expand_threshold_px;

    if (Math.abs(scrollDelta) < threshold) {
      return;
    }

    if (now - this.lastStateChange < SCROLL_STATE_CHANGE_COOLDOWN_MS) {
      return;
    }

    let stateChanged = false;

    if (
      isScrollingDown &&
      currentScrollY > settings.scroll_minimize_threshold_px &&
      !this.isMinimized
    ) {
      this.isMinimized = true;
      stateChanged = true;
    } else if (isScrollingUp && this.isMinimized) {
      this.isMinimized = false;
      stateChanged = true;
    }

    if (stateChanged) {
      this.lastStateChange = now;
    }

    this.lastScrollY = currentScrollY;
  }

  @action
  setup(element) {
    this.widgetsContainer = element;
    this.resizeHandler = new ResizeObserver(this.checkPositionDebounced);
    this.resizeHandler.observe(document.documentElement);
    this.checkPosition({ hasProposals: this.sortedProposals?.length > 0 });

    this.appEvents.on("proposals-cache:refresh", this.onProposalsCacheRefresh);
    this.appEvents.on("widget:check-position", this.checkPosition);
  }

  @action
  teardown() {
    this.resizeHandler?.disconnect();
    this.endBackgroundRefresh();
    cancel(this.checkPositionTimer);

    if (this.scrollRAF) {
      cancelAnimationFrame(this.scrollRAF);
      this.scrollRAF = null;
    }

    if (this.scrollListenerActive) {
      window.removeEventListener("scroll", this.handleScroll);
      this.scrollListenerActive = false;
    }

    this.appEvents.off("proposals-cache:refresh", this.onProposalsCacheRefresh);
    this.appEvents.off("widget:check-position", this.checkPosition);
  }

  @bind
  async onProposalsCacheRefresh() {
    if (this.isDestroying || this.isDestroyed) {
      return;
    }

    if (this.proposals.isTopicIgnored(this.topicId)) {
      return;
    }

    await this.autoExtractProposalsDeferred();
    await this.checkTempcheckByTitle();
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

    const { ignoreCache } = options;
    const { topic } = this.args;

    if (!topic) {
      console.info("No topic available, skipping auto-extraction.");
      return;
    }

    if (this.autoLoading) {
      console.info("Auto-loading already in progress, skipping this run.");
      return;
    }

    if (this.canAutoFetchProposals) {
      let promises = [];

      this.autoLoading = true;

      if (this.canFetchProposalsBy({ mode: "type", prefix: "snapshot" })) {
        promises.push(
          this.baseApi.snapshot.autoFetchProposals({
            topicURL: this.topicUrl,
            topicId: this.topicId,
            topicCreatedAt: topic.created_at,
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

        if (foundProposals.length) {
          this.proposals.addOrUpdateItems(foundProposals);
        }
      }

      this.autoLoading = false;
    }
  }

  async checkTempcheckByTitle() {
    // Special case: if we have an ARFC but a temp-check exists in another topic.
    // Checking by title.
    const sortedProposals = this.sortedProposals;
    if (sortedProposals.length === 0) {
      return;
    }

    const arfc = sortedProposals.find((p) => p.stage === "arfc");
    const hasTempcheck = sortedProposals.some((p) => p.stage === "temp-check");

    if (arfc && !hasTempcheck) {
      const title = cleanTitle(arfc.title);
      if (!title.length) {
        return;
      }

      const possibleTempcheck =
        await this.baseApi.snapshot.fetchTempcheckByTitle({
          first: settings.auto_proposals_snapshot_limit,
          topicURL: this.topicUrl,
          topicId: this.topicId,
          ignoreCache: false,
          title,
        });

      if (possibleTempcheck.length) {
        const tempChecksProposals = possibleTempcheck
          .filter((p) => p.stage === "temp-check")
          .map((p) => ({
            ...p,
            type: "snapshot",
            fetch: "auto",
            linkedArfcId: arfc.id,
          }));

        if (tempChecksProposals.length === 0) {
          return;
        }

        this.proposals.addItems(tempChecksProposals);
        await this.proposals.loadAllProposalData(this.topicId);
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
          const filteredProposals = dedupeUrls(
            foundProposals.filter((proposal) =>
              this.canFetchProposalsBy({ mode: "type", prefix: proposal.type })
            )
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
        await this.autoExtractProposalsDeferred();
        await this.checkTempcheckByTitle();
      } catch (error) {
        console.warn("Failed to load proposals:", error);
        this.error = error.message || "Failed to load proposals";
      } finally {
        this.loading = false;
        document.body.classList.remove("checking-proposals");
        this.checkPosition({ hasProposals: this.sortedProposals?.length > 0 });
      }
    });
  }

  get topicUrl() {
    return getAbsoluteURL(this.args.topic.url);
  }

  get topicId() {
    return this.args.topic?.id;
  }

  get topicTags() {
    return this.args.topic?.tags || [];
  }

  get topicCategoryId() {
    return this.args.topic?.category_id;
  }

  get hasProposals() {
    return this.proposals.items.length > 0 && !this.shouldIgnoreTopic;
  }

  get hasPlaceholderProposals() {
    return this.proposals.items.some((p) => p.type === "placeholder");
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
      (p) =>
        p.loaded &&
        (p.linkedArfcId || validateDiscussionUrl(p.discussion, this.topicUrl))
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

  @cached
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

    const compareProposalsWithFetch = (a, b) => {
      const fetchA = a.fetch === "manual" ? 1 : 0;
      const fetchB = b.fetch === "manual" ? 1 : 0;

      if (fetchA !== fetchB) {
        return fetchB - fetchA;
      }

      return compareProposals(a, b);
    };

    const compareProposals = (a, b) => {
      const statusA = getStatusPriority(a.status, a.type);
      const statusB = getStatusPriority(b.status, b.type);

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

      return 0;
    };

    const byStage = proposals.reduce((acc, p) => {
      (acc[p.stage] ||= []).push(p);
      return acc;
    }, {});

    const top = (stage, n = 1) =>
      (byStage[stage] ?? []).toSorted(compareProposalsWithFetch).slice(0, n);

    let selected = [...top("tally"), ...top("aip"), ...top("arfc")];

    selected.push(...top("temp-check", MAX_WIDGETS - selected.length));

    if (selected.length < MAX_WIDGETS) {
      const pickedSet = new Set(selected);
      const leftovers = proposals
        .filter((p) => !pickedSet.has(p))
        .toSorted(compareProposalsWithFetch);

      selected.push(...leftovers.slice(0, MAX_WIDGETS - selected.length));
    }

    selected = selected.toSorted(compareProposals).slice(0, MAX_WIDGETS);
    if (selected.length > 0) {
      next(() => this.checkPosition({ hasProposals: true }));
    }

    if (settings.enable_url_checking && selected.length > 0) {
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
        class={{concatClass
          "aave-widgets-container"
          (if this.showAsSidebar "widgets-on-side")
          (if this.isMinimized "minimized")
        }}
        {{didInsert this.setup}}
        {{didUpdate this.extractProposals}}
        {{willDestroy this.teardown}}
      >
        {{#if this.error}}
          <div class="widgets-error">
            <p>{{this.error}}</p>
          </div>
        {{else if this.loading}}{{else}}
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
                @isMinimized={{this.isMinimized}}
              />
            {{/each}}
          </ConditionalOverflowNav>

        {{/if}}
      </div>
    {{/if}}
  </template>
}

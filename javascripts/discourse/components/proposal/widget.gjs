import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { htmlSafe } from "@ember/template";
import DButton from "discourse/components/d-button";
import concatClass from "discourse/helpers/concat-class";
import icon from "discourse/helpers/d-icon";
import { number } from "discourse/lib/formatter";
import { eq, or } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import {
  getStatusClass,
  ONE_DAY_MS,
  VOTE_ENDED_STATUSES,
} from "../../lib/constants";

export default class Widget extends Component {
  @service baseApi;

  @tracked proposal = null;
  @tracked loading = true;
  @tracked error = null;
  @tracked
  showResults = this.isVoteActive || this.isVotePending || this.isVoteUpcoming;
  @tracked hidden = false;

  constructor() {
    super(...arguments);

    if (this.args.proposal) {
      this.proposal = this.args.proposal;
      this.error = this.args.proposal.error || null;
      this.loading = false;
    } else {
      this.loadProposal();
    }
  }

  async loadProposal() {
    const { space, proposalId, govId, testnet, type, topicId } = this.args;

    try {
      this.error = null;

      if (type === "snapshot") {
        this.proposal = await this.baseApi.snapshot.fetchProposal(
          space,
          proposalId,
          topicId,
          testnet
        );
      } else if (type === "aip") {
        this.proposal = await this.baseApi.aave.fetchProposal(
          proposalId,
          topicId
        );
      } else if (type === "tally") {
        this.proposal = await this.baseApi.tally.fetchProposal(
          proposalId,
          govId,
          topicId
        );
      }
    } catch (e) {
      this.error = e.message || "Failed to load proposal";
    } finally {
      this.loading = false;
    }
  }

  @action
  closeWidget() {
    this.hidden = true;
  }

  get stageLabel() {
    const { type } = this.args;
    let key;

    if (type === "tally") {
      key = "widget.stage.tally";
    } else if (type === "aip") {
      key = "widget.stage.aip";
    } else if (type === "snapshot") {
      if (this.proposal?.stage === "temp-check") {
        key = "widget.stage.tempcheck";
      } else if (this.proposal?.stage === "arfc") {
        key = "widget.stage.arfc";
      } else {
        key = "widget.stage.snapshot";
      }
    }

    return key ? i18n(themePrefix(key)) : "unknown";
  }

  get actionLabel() {
    const { type } = this.args;
    const prefix = this.isVoteActive ? "vote_on" : "view_on";

    const typeMap = {
      snapshot: "snapshot",
      aip: "aave",
      tally: "tally",
    };

    const platform = typeMap[type];
    return i18n(themePrefix(`widget.proposal.${prefix}_${platform}`));
  }

  get status() {
    if (!this.proposal) {
      return "loading";
    }

    return getStatusClass(this.proposal.status, this.args.type);
  }

  get forBarStyle() {
    return htmlSafe(`width: ${this.proposal?.votes.for.percent}%`);
  }

  get againstBarStyle() {
    return htmlSafe(`width: ${this.proposal?.votes.against.percent}%`);
  }

  get abstainBarStyle() {
    return htmlSafe(`width: ${this.proposal?.votes.abstain.percent}%`);
  }

  get hasVotes() {
    return this.proposal?.totalVotes > 0;
  }

  get endDate() {
    return moment(this.proposal?.end).fromNow(this.isVoteActive);
  }

  get startDate() {
    return moment(this.proposal?.start).fromNow(true);
  }

  get statusClass() {
    return getStatusClass(this.proposal?.status, this.args.type);
  }

  get isVoteActive() {
    return ["active"].includes(this.statusClass);
  }

  get isVoteEnded() {
    return VOTE_ENDED_STATUSES.includes(this.statusClass);
  }

  get isVotePending() {
    return ["pending"].includes(this.statusClass);
  }

  get isVoteUpcoming() {
    return ["upcoming"].includes(this.statusClass);
  }

  get isVoteEndingSoon() {
    return this.proposal?.end - Date.now() <= ONE_DAY_MS;
  }

  get quorumMet() {
    return this.proposal?.totalVotes >= this.proposal?.quorum;
  }

  <template>
    {{#unless this.hidden}}
      <div class="aave-widget {{@type}} {{this.status}}">
        <div class="widget-header">
          <div class="widget-stage">{{this.stageLabel}}</div>
          <div class="widget-status {{this.status}}">
            {{this.status}}
          </div>
          <DButton
            @action={{this.closeWidget}}
            @icon="xmark"
            @ariaLabel="Close proposal widget"
            @title="Close proposal widget"
            class="btn-flat btn-small"
          />
        </div>

        {{#if this.loading}}
          <div class="widget-loading">
            {{i18n "loading"}}
          </div>
        {{else if this.error}}
          <div class="widget-error">
            <p>{{i18n (themePrefix "widget.proposal.error_loading")}}:
              {{this.error}}</p>
          </div>
        {{else if this.proposal}}
          <div class="widget-content">
            {{#if this.isVoteActive}}
              <div class="time-remaining">
                {{#if this.isVoteEndingSoon}}
                  <span class="ending-soon-icon">⚠️</span>
                {{/if}}
                {{this.endDate}}
                {{i18n (themePrefix "widget.proposal.time_left")}}
              </div>
            {{else if this.isVoteUpcoming}}
              <div class="time-starting">
                {{i18n (themePrefix "widget.proposal.starts_in")}}
                {{this.startDate}}
              </div>
            {{else if this.isVoteEnded}}
              <div class="time-ended">
                {{i18n (themePrefix "widget.proposal.ended")}}
                {{this.endDate}}
              </div>
            {{/if}}

            {{#if this.showResults}}
              {{#unless this.isVoteUpcoming}}
                {{#if this.proposal.quorum}}
                  <div class="quorum-info">
                    <div class="quorum-row">
                      <span class="quorum-label">
                        {{icon
                          (if
                            this.quorumMet "far-circle-check" "far-circle-xmark"
                          )
                          class=(concatClass
                            "quorum-icon" (if this.quorumMet "met" "not-met")
                          )
                        }}
                        {{i18n (themePrefix "widget.proposal.quorum")}}
                      </span>
                      <span class="quorum-value">{{number
                          this.proposal.totalVotes
                        }}
                        of
                        {{number this.proposal.quorum}}
                      </span>
                    </div>
                  </div>
                {{/if}}

                <div class="vote-results">
                  <div class="vote-summary">
                    <span class="vote-option for">
                      <span class="vote-label">For:</span>
                      <span class="vote-value">{{number
                          this.proposal.votes.for.count
                        }}</span>
                    </span>
                    |
                    <span class="vote-option against">
                      <span class="vote-label">Against:</span>
                      <span class="vote-value">{{number
                          this.proposal.votes.against.count
                        }}</span>
                    </span>
                    {{#if (or (eq @type "tally") (eq @type "snapshot"))}}
                      |
                      <span class="vote-option abstain">
                        <span class="vote-label">Abstain:</span>
                        <span class="vote-value">{{number
                            this.proposal.votes.abstain.count
                          }}</span>
                      </span>
                    {{/if}}
                  </div>

                  <div class="vote-bar">
                    <div class="vote-bar-for" style={{this.forBarStyle}}></div>
                    <div
                      class="vote-bar-against"
                      style={{this.againstBarStyle}}
                    ></div>
                    {{#if (eq @type "snapshot")}}
                      <div
                        class="vote-bar-abstain"
                        style={{this.abstainBarStyle}}
                      ></div>
                    {{/if}}
                  </div>
                </div>
              {{/unless}}

              <div class="widget-actions">
                <DButton
                  @translatedLabel={{this.actionLabel}}
                  @href={{@url}}
                  class="btn btn-primary btn-small"
                  target="_blank"
                />
              </div>
            {{else}}
              <DButton
                @translatedLabel="View Results"
                @icon="caret-right"
                @action={{fn (mut this.showResults) true}}
                class="btn btn-transparent btn-small view-results"
              />
            {{/if}}
          </div>
        {{/if}}
      </div>
    {{/unless}}
  </template>
}

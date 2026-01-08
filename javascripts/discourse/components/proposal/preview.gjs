import Component from "@glimmer/component";
import { service } from "@ember/service";
import AsyncContent from "discourse/components/async-content";
import { bind } from "discourse/lib/decorators";
import { cook } from "discourse/lib/text";
import { i18n } from "discourse-i18n";
import Widget from "./widget";

export default class PreviewProposal extends Component {
  @service baseApi;

  @bind
  async proposalData() {
    const { proposal, topicId } = this.args.data;
    const { space, id, govId, type, testnet } = proposal;

    let data = {};
    if (type === "snapshot") {
      data = await this.baseApi.snapshot.fetchProposal(
        space,
        id,
        topicId,
        testnet
      );
    } else if (type === "aip") {
      data = await this.baseApi.aave.fetchProposal(id, topicId);
    } else if (type === "tally") {
      data = await this.baseApi.tally.fetchProposal(id, govId, topicId);
    }

    return {
      ...data,
      body: await cook(data.body),
    };
  }

  <template>
    <AsyncContent @asyncData={{this.proposalData}}>
      <:loading>
        {{i18n "loading"}}
      </:loading>

      <:content as |proposal|>
        {{#if @data.composerPreview}}
          <Widget
            @type={{@data.proposal.type}}
            @space={{@data.proposal.space}}
            @proposalId={{@data.proposal.id}}
            @govId={{@data.proposal.govId}}
            @testnet={{@data.proposal.testnet}}
            @proposal={{proposal}}
          />
        {{/if}}
        <div class="proposal-preview-title">
          <h1><a
              href={{@data.proposal.url}}
              class="proposal-preview-title"
              target="_blank"
              rel="noopener noreferrer"
            >{{proposal.title}}</a>
          </h1>
        </div>

        <div class="proposal-preview-content">{{proposal.body}}</div>
      </:content>
    </AsyncContent>
  </template>
}

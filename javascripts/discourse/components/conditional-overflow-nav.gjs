import HorizontalOverflowNav from "discourse/components/horizontal-overflow-nav";

const ConditionalOverflowNav = <template>
  {{#if @condition}}
    <HorizontalOverflowNav>
      {{yield}}
    </HorizontalOverflowNav>
  {{else}}
    {{yield}}
  {{/if}}
</template>;

export default ConditionalOverflowNav;

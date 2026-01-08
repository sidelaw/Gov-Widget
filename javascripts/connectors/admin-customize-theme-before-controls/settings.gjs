import { tracked } from "@glimmer/tracking";
import Component from "@ember/component";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/components/d-button";

export default class Settings extends Component {
  @service router;

  @tracked showAdvanced = false;

  init() {
    super.init(...arguments);

    if (this.isComponentPage) {
      document.body.classList.add(
        "cgov-theme-settings-page",
        "adv-settings-hidden"
      );
    }
  }

  get isComponentPage() {
    const { currentRoute } = this.router;
    return (
      currentRoute.name === "adminCustomizeThemes.show.index" &&
      currentRoute.attributes.component &&
      currentRoute.attributes.theme_fields.length > 0 &&
      !!currentRoute.attributes.theme_fields.find(
        (field) => field.name === "discourse/api-initializers/cgov_widget.gjs"
      )
    );
  }

  get buttonLabel() {
    return this.showAdvanced
      ? "Hide advanced settings"
      : "Show advanced settings";
  }

  @action
  toggleAdvanced() {
    this.showAdvanced = !this.showAdvanced;
    document.body.classList.toggle("adv-settings-hidden", !this.showAdvanced);
  }

  <template>
    <DButton
      @translatedLabel={{this.buttonLabel}}
      class="btn btn-primary toggle-advanced-settings"
      @action={{this.toggleAdvanced}}
    />
  </template>
}

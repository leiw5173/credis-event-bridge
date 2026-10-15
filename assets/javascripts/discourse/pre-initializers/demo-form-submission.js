import { getOwner } from "@ember/owner";
import { withPluginApi } from "discourse/lib/plugin-api";
import Composer from "discourse/models/composer";
import FormTemplate from "discourse/models/form-template";
import { i18n } from "discourse-i18n";
import DemoFormSubmission, {
  positiveId,
  rememberTemplateIdentity,
} from "../lib/demo-form-submission";

const composerHooks = new WeakSet();
const managers = new WeakMap();

function managerFor(owner) {
  if (!managers.has(owner)) {
    managers.set(owner, new DemoFormSubmission());
  }
  return managers.get(owner);
}

export default {
  name: "credis-demo-form-submission",
  before: "inject-discourse-objects",

  initialize() {
    withPluginApi((api) => {
      api.modifyClass(
        "component:composer-editor",
        (Base) =>
          class extends Base {
            get selectedFormTemplateId() {
              const selected = super.selectedFormTemplateId;
              if (this.composer.site.credis_demo_form_capture !== true) {
                return selected;
              }
              const ids = this.composer.formTemplateIds ?? [];
              const allowed = ids.map(positiveId);
              if (allowed.includes(positiveId(selected))) {
                return selected;
              }
              const requested = this.composer.model?.formTemplateId;
              return allowed.includes(positiveId(requested))
                ? requested
                : ids[0];
            }

            set selectedFormTemplateId(value) {
              super.selectedFormTemplateId = value;
            }
          }
      );
      api.modifyClass(
        "component:form-template-field/wrapper",
        (Base) =>
          class extends Base {
            async _fetchTemplate(id) {
              const generation = (this._credisTemplateGeneration ?? 0) + 1;
              this._credisTemplateGeneration = generation;
              const response = await FormTemplate.findById(id);
              const previousDefinition = this.parsedTemplate;
              await super._loadTemplate(response.form_template.template);
              if (
                this._credisTemplateGeneration === generation &&
                positiveId(this.args.id) ===
                  positiveId(response.form_template.id) &&
                this.parsedTemplate !== previousDefinition &&
                this.composer.selectedFormTemplate === this.parsedTemplate
              ) {
                rememberTemplateIdentity(
                  this.parsedTemplate,
                  response.form_template.id
                );
              }
            }
          }
      );
      if (!composerHooks.has(Composer)) {
        api.composerBeforeSave(function (...args) {
          const savingModel = this;
          const owner = getOwner(savingModel);
          return this._super(...args).then(() =>
            managerFor(owner)
              .capture(
                owner.lookup("service:composer"),
                owner.lookup("service:site"),
                savingModel
              )
              .catch(() => {
                owner
                  .lookup("service:dialog")
                  .alert(
                    i18n("credis_event_bridge.demo_form_submission_failed")
                  );
                // The editor is still open. Core's save-error listener waits for
                // a later open event, so display our rejection here and stop save.
                return Promise.reject();
              })
          );
        });
        composerHooks.add(Composer);
      }
      api.addModelCallback("post", "beforeCreate", function (props) {
        const owner = getOwner(this);
        return managerFor(owner).attach(
          owner.lookup("service:composer"),
          owner.lookup("service:site"),
          this,
          props
        );
      });
      for (const event of ["composer:saved", "composer:cancelled"]) {
        api.onAppEvent(event, () => {
          const model = api.container.lookup("service:composer").model;
          if (model) {
            managerFor(getOwner(model)).clear(model);
          }
        });
      }
    });
  },
};

import Yaml from "js-yaml";
import prepareFormTemplateData from "discourse/lib/form-template-validation";
import Composer from "discourse/models/composer";
import FormTemplate from "discourse/models/form-template";
import { i18n } from "discourse-i18n";

function invalidSubmission() {
  return {
    responseJSON: {
      errors: [i18n("credis_event_bridge.demo_form_submission_failed")],
    },
  };
}

export function positiveId(value) {
  const text = String(value ?? "");
  return /^[1-9]\d*$/.test(text) && Number.isSafeInteger(Number(text))
    ? Number(text)
    : null;
}

const templateIdentities = new WeakMap();

export function rememberTemplateIdentity(definition, id) {
  if (Array.isArray(definition) && positiveId(id)) {
    templateIdentities.set(definition, positiveId(id));
  }
}

function canonical(value) {
  if (Array.isArray(value)) {
    return value.map(canonical);
  }
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, canonical(value[key])])
    );
  }
  return value;
}

function snapshot(composer, site, post, props, frozen) {
  const model = composer?.model;
  if (
    site?.credis_demo_form_capture !== true ||
    !composer?.hasFormTemplate ||
    model?.action !== Composer.CREATE_TOPIC ||
    props.topic_id ||
    props.reply_to_post_number
  ) {
    return null;
  }

  const ids = composer.formTemplateIds?.map(positiveId);
  const mapping = site.credis_demo_form_template_fields ?? {};
  if (!ids?.some((id) => Object.hasOwn(mapping, id))) {
    return null;
  }

  const form = document.querySelector("#form-template-form");
  const chooser = document.querySelector(
    "#reply-control .form-template-chooser .select-kit-header"
  );
  const definition = composer.selectedFormTemplate;
  // Bind the parsed object to the exact response that Core rendered. Identical
  // YAML definitions and a category's default ID do not identify its selection.
  const templateId = templateIdentities.get(definition);
  if (
    !templateId ||
    !ids.includes(templateId) ||
    (chooser && positiveId(chooser.getAttribute("data-value")) !== templateId)
  ) {
    throw invalidSubmission();
  }
  const fieldKey = mapping[templateId];
  if (!fieldKey) {
    return null;
  }

  if (
    (!form && !frozen) ||
    !Array.isArray(definition) ||
    !definition.some((field) => field.id === fieldKey) ||
    positiveId(props.category) !== positiveId(model.category?.id) ||
    positiveId(post.user_id) !== positiveId(model.user?.id) ||
    props.raw !== model.reply ||
    props.title !== model.title
  ) {
    throw invalidSubmission();
  }

  let fields = frozen?.binding.fields;
  let initialValues;
  if (form) {
    const keys = definition.map((field) => field.id);
    fields = Object.create(null);
    initialValues = Object.create(null);
    let lastIndex = -1;
    for (const [key, value] of new FormData(form)) {
      const index = keys.indexOf(key);
      // Native fields follow the template order. Files and interleaved duplicate
      // names cannot be represented by the source's bounded string field map.
      if (typeof value !== "string" || index < lastIndex || index < 0) {
        throw invalidSubmission();
      }
      lastIndex = index;
      fields[key] = Object.hasOwn(fields, key)
        ? `${fields[key]}\n${value}`
        : value;
      if (["multi-select", "tag-chooser"].includes(definition[index].type)) {
        initialValues[key] ??= [];
        initialValues[key].push(value);
      } else {
        initialValues[key] = fields[key];
      }
    }
    if (prepareFormTemplateData(form, definition, false) !== props.raw) {
      throw invalidSubmission();
    }
  }

  if (!Object.hasOwn(fields, fieldKey)) {
    throw invalidSubmission();
  }

  const binding = {
    author: post.user_id,
    category: positiveId(props.category),
    title: props.title,
    raw: props.raw,
    templateId,
    definition: canonical(definition),
    fieldKey,
    fields,
  };
  return { model, initialValues, binding, signature: JSON.stringify(binding) };
}

export default class DemoFormSubmission {
  #submissions = new WeakMap();
  #snapshots = new WeakMap();

  clear(model) {
    if (model) {
      this.#submissions.delete(model);
      this.#snapshots.delete(model);
    }
  }

  async capture(composer, site, expectedModel) {
    const model = composer.model;
    if (site?.credis_demo_form_capture !== true) {
      if (model) {
        this.#snapshots.delete(model);
      }
      return;
    }
    if (expectedModel && model !== expectedModel) {
      throw invalidSubmission();
    }
    if (!model) {
      return;
    }
    this.#snapshots.delete(model);
    const current = snapshot(
      composer,
      site,
      { user_id: model.user?.id },
      { category: model.category?.id, raw: model.reply, title: model.title }
    );
    if (current) {
      this.#snapshots.set(model, current);
      if (typeof model.set === "function") {
        model.set("formTemplateId", current.binding.templateId);
      } else {
        model.formTemplateId = current.binding.templateId;
      }
      // Core unmounts the form in SAVING. Restore actual multi-values when an
      // unsuccessful request returns to the native composer.
      composer.formTemplateInitialValues = current.initialValues;
    }
  }

  async attach(composer, site, post, props) {
    delete props.credis_form_submission;
    if (composer?.model?.composeState !== Composer.SAVING) {
      return;
    }

    try {
      const frozen = this.#snapshots.get(composer.model);
      const original = snapshot(composer, site, post, props, frozen);
      if (!original) {
        return;
      }
      if (!frozen || frozen.signature !== original.signature) {
        throw invalidSubmission();
      }
      const response = await FormTemplate.findById(original.binding.templateId);
      const template = response.form_template;
      if (
        positiveId(template?.id) !== original.binding.templateId ||
        JSON.stringify(canonical(Yaml.load(template.template))) !==
          JSON.stringify(original.binding.definition)
      ) {
        throw invalidSubmission();
      }

      const current = snapshot(composer, site, post, props, frozen);
      if (
        !current ||
        current.model !== original.model ||
        this.#snapshots.get(current.model) !== frozen ||
        current.signature !== original.signature
      ) {
        throw invalidSubmission();
      }

      let submission = this.#submissions.get(current.model);
      if (submission?.signature !== current.signature) {
        submission = {
          signature: current.signature,
          uid: crypto.randomUUID(),
        };
        this.#submissions.set(current.model, submission);
      }

      props.credis_form_submission = {
        evidence_uid: submission.uid,
        form_template_id: current.binding.templateId,
        field_key: current.binding.fieldKey,
        fields: current.binding.fields,
      };
    } catch {
      throw invalidSubmission();
    }
  }
}

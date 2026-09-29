const models = [
  {
    id: "deepseek-flash",
    name: "DeepSeek-V41-Flash",
    reasoning: {
      efforts: ["off", "low", "high", "max"].map((id) => ({ id })),
    },
  },
];
let optionResolutions = 0;

export function resolveAdapterOptions() {
  optionResolutions += 1;
  if (optionResolutions !== 1) throw new Error("adapter options must be resolved once");
  return { models };
}

export function catalogModelInfo(provider, row) {
  return {
    id: row.id,
    name: row.name,
    providerId: provider.id,
    provider: provider.name,
  };
}

export class DeepSeekAdapter {
  constructor({ options, resolveFiles, discoverModels }) {
    this.options = options;
    this.resolveFiles = resolveFiles;
    this.discoverModels = discoverModels;
  }

  providerInfo(id) {
    if (id !== "deepseek-official") throw new Error("unknown fixture provider");
    return { id, name: "DeepSeek" };
  }

  async listModels(providerId) {
    if (typeof this.discoverModels !== "function") return [];
    return this.discoverModels(this.providerInfo(providerId));
  }

  async resolveModel(providerId, modelId) {
    if (providerId !== "deepseek-official") throw new Error("unknown fixture provider");
    return this.options().models.find((model) => model.id === modelId);
  }
}

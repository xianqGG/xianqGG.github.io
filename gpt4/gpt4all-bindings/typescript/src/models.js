const { normalizePromptContext, warnOnSnakeCaseKeys } = require('./util');

class InferenceModel {
    llm;
    config;

    constructor(llmodel, config) {
        this.llm = llmodel;
        this.config = config;
    }

    async generate(prompt, promptContext) {
        warnOnSnakeCaseKeys(promptContext);
        const normalizedPromptContext = normalizePromptContext(promptContext);
        const result = this.llm.raw_prompt(prompt, normalizedPromptContext, () => {});
        return result;
    }
}

class EmbeddingModel {
    llm;
    config;

    constructor(llmodel, config) {
        this.llm = llmodel;
        this.config = config;
    }

    embed(text) {
        return this.llm.embed(text)
    }
}


module.exports = {
    InferenceModel,
    EmbeddingModel,
};

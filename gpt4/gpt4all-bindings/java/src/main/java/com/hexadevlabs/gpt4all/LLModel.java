package com.hexadevlabs.gpt4all;

import jnr.ffi.Pointer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public  class LLModel implements AutoCloseable {

    /**
     * Config used for how to decode LLM outputs.
     * High temperature closer to 1 gives more creative outputs
     * while low temperature closer to 0 produce more precise outputs.
     * <p>
     * Use builder to set settings you want.
     */
    public static class GenerationConfig extends LLModelLibrary.LLModelPromptContext {

        private GenerationConfig() {
            super(jnr.ffi.Runtime.getSystemRuntime());
            logits_size.set(0);
            tokens_size.set(0);
            n_past.set(0);
            n_ctx.set(1024);
            n_predict.set(128);
            top_k.set(40);
            top_p.set(0.95);
            temp.set(0.28);
            n_batch.set(8);
            repeat_penalty.set(1.1);
            repeat_last_n.set(10);
            context_erase.set(0.55);
        }

        public static class Builder {
            private final GenerationConfig configToBuild;

            public Builder() {
                configToBuild = new GenerationConfig();
            }

            public Builder withNPast(int n_past) {
                configToBuild.n_past.set(n_past);
                return this;
            }

            public Builder withNCtx(int n_ctx) {
                configToBuild.n_ctx.set(n_ctx);
                return this;
            }

            public Builder withNPredict(int n_predict) {
                configToBuild.n_predict.set(n_predict);
                return this;
            }

            public Builder withTopK(int top_k) {
                configToBuild.top_k.set(top_k);
                return this;
            }

            public Builder withTopP(float top_p) {
                configToBuild.top_p.set(top_p);
                return this;
            }

            public Builder withTemp(float temp) {
                configToBuild.temp.set(temp);
                return this;
            }

            public Builder withNBatch(int n_batch) {
                configToBuild.n_batch.set(n_batch);
                return this;
            }

            public Builder withRepeatPenalty(float repeat_penalty) {
                configToBuild.repeat_penalty.set(repeat_penalty);
                return this;
            }

            public Builder withRepeatLastN(int repeat_last_n) {
                configToBuild.repeat_last_n.set(repeat_last_n);
                return this;
            }

            public Builder withContextErase(float context_erase) {
                configToBuild.context_erase.set(context_erase);
                return this;
            }

            /**
             *
             * @return GenerationConfig build instance of the config
             */
            public GenerationConfig build() {
                return configToBuild;
            }
        }
    }

    /**
     * Shortcut for making GenerativeConfig builder.
     *
     * @return GenerationConfig.Builder - builder that can be used to make a GenerationConfig
     */
    public static GenerationConfig.Builder config(){
        return new GenerationConfig.Builder();
    }

    /**
     * This may be set before any Model instance classes are instantiated to
     * set where the native shared libraries are to be found.
     * <p>
     * This may be needed if setting library search path by standard means is not available
     * or the libraries loaded from the temp folder bundled with the binding jar is not desirable.
     */
    public static String LIBRARY_SEARCH_PATH;


    /**
     * Generally for debugging purposes only. Will print
     * the numerical tokens as they are generated instead of the string representations.
     * Will also print out the processed input tokens as numbers to standard out.
     */
    public static boolean OUTPUT_DEBUG = false;

    private static final Logger logger = LoggerFactory.getLogger(LLModel.class);

    /**
     * Which version of GPT4ALL that this binding is built for.
     * The binding is guaranteed to work with this version of
     * GPT4ALL native libraries. The binding may work for older
     * versions but that is not guaranteed.
     */
    public static final String GPT4ALL_VERSION = "2.4.11";

    protected static LLModelLibrary library;

    protected Pointer model;

    protected String modelName;

    /**
     * Package private default constructor, for testing purposes.
     */
    LLModel(){
    }

    public LLModel(Path modelPath) {

        logger.info("Java bindings for gpt4all version: " + GPT4ALL_VERSION);

        if(library==null) {

            if (LIBRARY_SEARCH_PATH != null){
                library = Util.loadSharedLibrary(LIBRARY_SEARCH_PATH);
                library.llmodel_set_implementation_search_path(LIBRARY_SEARCH_PATH);
            }  else {
                // Copy system libraries to Temp folder
                Path tempLibraryDirectory = Util.copySharedLibraries();
                library = Util.loadSharedLibrary(tempLibraryDirectory.toString());

                library.llmodel_set_implementation_search_path(tempLibraryDirectory.toString() );
            }

        }

        // modelType = type;
        modelName = modelPath.getFileName().toString();
        String modelPathAbs = modelPath.toAbsolutePath().toString();

        LLModelLibrary.LLModelError error = new LLModelLibrary.LLModelError(jnr.ffi.Runtime.getSystemRuntime());

        // Check if model file exists
        if(!Files.exists(modelPath)){
            throw new IllegalStateException("Model file does not exist: " + modelPathAbs);
        }

        // Check if file is Readable
        if(!Files.isReadable(modelPath)){
            throw new IllegalStateException("Model file cannot be read: " + modelPathAbs);
        }

        // Create Model Struct. Will load dynamically the correct backend based on model type
        model = library.llmodel_model_create2(modelPathAbs, "auto", error);

        if(model == null) {
            throw new IllegalStateException("Could not load, gpt4all backend returned error: " + error.message);
        }
        library.llmodel_loadModel(model, modelPathAbs);

        if(!library.llmodel_isModelLoaded(model)){
            throw new IllegalStateException("The model " + modelName + " could not be loaded");
        }

    }

    public void setThreadCount(int nThreads) {
        library.llmodel_setThreadCount(this.model, nThreads);
    }

    public int threadCount() {
        return library.llmodel_threadCount(this.model);
    }

    /**
     * Generate text after the prompt
     *
     * @param prompt The text prompt to complete
     * @param generationConfig What generation settings to use while generating text
     * @return String The complete generated text
     */
    public String generate(String prompt, GenerationConfig generationConfig) {
        return generate(prompt, generationConfig, false);
    }

    /**
     * Generate text after the prompt
     *
     * @param prompt The text prompt to complete
     * @param generationConfig What generation settings to use while generating text
     * @param streamToStdOut Should the generation be streamed to standard output. Useful for troubleshooting.
     * @return String The complete generated text
     */
    public String generate(String prompt, GenerationConfig generationConfig, boolean streamToStdOut) {

        ByteArrayOutputStream bufferingForStdOutStream = new ByteArrayOutputStream();
        ByteArrayOutputStream bufferingForWholeGeneration = new ByteArrayOutputStream();

        LLModelLibrary.ResponseCallback responseCallback = getResponseCallback(streamToStdOut, bufferingForStdOutStream, bufferingForWholeGeneration);

        library.llmodel_prompt(this.model,
                prompt,
                 (int tokenID) -> {
                    if(LLModel.OUTPUT_DEBUG)
                        System.out.println("token " + tokenID);
                    return true; // continue processing
                },
                responseCallback,
                (boolean isRecalculating) -> {
                    if(LLModel.OUTPUT_DEBUG)
                        System.out.println("recalculating");
                    return isRecalculating; // continue generating
                },
                generationConfig);

        return bufferingForWholeGeneration.toString(StandardCharsets.UTF_8);
    }

    /**
     * Callback method to be used by prompt method as text is generated.
     *
     * @param streamToStdOut Should send generated text to standard out.
     * @param bufferingForStdOutStream Output stream used for buffering bytes for standard output.
     * @param bufferingForWholeGeneration Output stream used for buffering a complete generation.
     * @return LLModelLibrary.ResponseCallback lambda function that is invoked by response callback.
     */
    static LLModelLibrary.ResponseCallback getResponseCallback(boolean streamToStdOut, ByteArrayOutputStream bufferingForStdOutStream, ByteArrayOutputStream bufferingForWholeGeneration) {
        return (int tokenID, Pointer response) -> {

            if(LLModel.OUTPUT_DEBUG)
                System.out.print("Response token " + tokenID + " " );

            // For all models if input sequence in tokens is longer then model context length
            // the error is generated.
            if(tokenID==-1){
                throw new PromptIsTooLongException(response.getString(0, 1000, StandardCharsets.UTF_8));
            }

            long len = 0;
            byte nextByte;
            do{
                try {
                    nextByte = response.getByte(len);
                } catch(IndexOutOfBoundsException e){
                    // Not sure if this can ever happen but just in case
                    // the generation does not terminate in a Null (0) value.
                    throw new RuntimeException("Empty array or not null terminated");
                }
                len++;
                if(nextByte!=0) {
                    bufferingForWholeGeneration.write(nextByte);
                    if(streamToStdOut){
                        bufferingForStdOutStream.write(nextByte);
                        // Test if Buffer is UTF8 valid string.
                        byte[] currentBytes = bufferingForStdOutStream.toByteArray();
                        String validString = Util.getValidUtf8(currentBytes);
                        if(validString!=null){ // is valid string
                            System.out.print(validString);
                            // reset the buffer for next utf8 sequence to buffer
                            bufferingForStdOutStream.reset();
                        }
                    }
                }
            } while(nextByte != 0);

            return true; // continue generating
        };
    }


    public static class ChatCompletionResponse {
        public String model;
        public Usage usage;
        public List<Map<String, String>> choices;

        // Getters and setters
    }

    public static class Usage {
        public int promptTokens;
        public int completionTokens;
        public int totalTokens;

        // Getters and setters
    }

    public ChatCompletionResponse chatCompletion(List<Map<String, String>> messages,
                                                              GenerationConfig generationConfig) {
        return chatCompletion(messages, generationConfig, false, false);
    }

    /**
     * chatCompletion formats the existing chat conversation into a template to be
     * easier to process for chat UIs. It is not absolutely necessary as generate method
     * may be directly used to make generations with gpt models.
     *
     * @param messages List of Maps "role"-&gt;"user", "content"-&gt;"...", "role"-&gt; "assistant"-&gt;"..."
     * @param generationConfig How to decode/process the generation.
     * @param streamToStdOut Send tokens as they are calculated Standard output.
     * @param outputFullPromptToStdOut Should full prompt built out of messages be sent to Standard output.
     * @return ChatCompletionResponse contains stats and generated Text.
     */
    public ChatCompletionResponse  chatCompletion(List<Map<String, String>> messages,
                                              GenerationConfig generationConfig, boolean streamToStdOut,
                                              boolean outputFullPromptToStdOut) {
        String fullPrompt = buildPrompt(messages);

        if(outputFullPromptToStdOut)
            System.out.print(fullPrompt);

        String generatedText = generate(fullPrompt, generationConfig, streamToStdOut);

        ChatCompletionResponse  response = new ChatCompletionResponse();
        response.model = this.modelName;

        Usage usage = new Usage();
        usage.promptTokens = fullPrompt.length();
        usage.completionTokens = generatedText.length();
        usage.totalTokens = fullPrompt.length() + generatedText.length();
        response.usage =  usage;

        Map<String, String> message = new HashMap<>();
        message.put("role", "assistant");
        message.put("content", generatedText);

        response.choices = List.of(message);

        return response;
    }

    protected static String buildPrompt(List<Map<String, String>> messages) {
        StringBuilder fullPrompt = new StringBuilder();

        for (Map<String, String> message : messages) {
            if ("system".equals(message.get("role"))) {
                String systemMessage = message.get("content") + "\n";
                fullPrompt.append(systemMessage);
            }
        }

        fullPrompt.append("### Instruction: \n" +
                "The prompt below is a question to answer, a task to complete, or a conversation to respond to; decide which and write an appropriate response.\n" +
                "### Prompt: ");

        for (Map<String, String> message : messages) {
            if ("user".equals(message.get("role"))) {
                String userMessage = "\n" + message.get("content");
                fullPrompt.append(userMessage);
            }
            if ("assistant".equals(message.get("role"))) {
                String assistantMessage = "\n### Response: " + message.get("content");
                fullPrompt.append(assistantMessage);
            }
        }

        fullPrompt.append("\n### Response:");

        return fullPrompt.toString();
    }

    @Override
    public void close() throws Exception {
        library.llmodel_model_destroy(model);
    }

}
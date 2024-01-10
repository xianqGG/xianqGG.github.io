#define LLAMAMODEL_H_I_KNOW_WHAT_I_AM_DOING_WHEN_INCLUDING_THIS_FILE
#include "llamamodel_impl.h"

#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <string>
#include <vector>
#include <iostream>
#if defined(_WIN32) && defined(_MSC_VER)
    #define WIN32_LEAN_AND_MEAN
    #ifndef NOMINMAX
        #define NOMINMAX
    #endif
    #include <windows.h>
    #include <io.h>
    #include <stdio.h>
#else
    #include <unistd.h>
#endif
#include <random>
#include <thread>
#include <unordered_set>

#include <llama.h>
#include <ggml.h>

#ifdef GGML_USE_KOMPUTE
#include "ggml-vulkan.h"
#endif

namespace {
const char *modelType_ = "LLaMA";
}

struct gpt_params {
    int32_t seed          = -1;   // RNG seed
    int32_t n_keep        = 0;    // number of tokens to keep from initial prompt
#if LLAMA_DATE <= 230511
    int32_t n_parts       = -1;   // amount of model parts (-1 = determine from model dimensions)
#endif

#if LLAMA_DATE >= 230519
    // sampling parameters
    float   tfs_z         = 1.0f; // 1.0 = disabled
    float   typical_p     = 1.0f; // 1.0 = disabled
#endif

    std::string prompt = "";

    bool memory_f16        = true;  // use f16 instead of f32 for memory kv

    bool use_mmap          = true;  // use mmap for faster loads
    bool use_mlock         = false; // use mlock to keep model in memory
};

#if LLAMA_DATE >= 230519
static int llama_sample_top_p_top_k(
        llama_context *ctx,
        const llama_token *last_n_tokens_data,
        int last_n_tokens_size,
        int top_k,
        float top_p,
        float temp,
        float repeat_penalty) {
    auto logits = llama_get_logits(ctx);
    auto n_vocab = llama_n_vocab(ctx);
    // Populate initial list of all candidates
    std::vector<llama_token_data> candidates;
    candidates.reserve(n_vocab);
    for (int token_id = 0; token_id < n_vocab; token_id++) {
        candidates.emplace_back(llama_token_data{token_id, logits[token_id], 0.0f});
    }
    llama_token_data_array candidates_p = {candidates.data(), candidates.size(), false};
    // Sample repeat penalty
    llama_sample_repetition_penalty(nullptr, &candidates_p, last_n_tokens_data, last_n_tokens_size, repeat_penalty);
    // Temperature sampling
    llama_sample_top_k(ctx, &candidates_p, top_k, 1);
    llama_sample_tail_free(ctx, &candidates_p, 1.0f, 1);
    llama_sample_typical(ctx, &candidates_p, 1.0f, 1);
    llama_sample_top_p(ctx, &candidates_p, top_p, 1);
    llama_sample_temperature(ctx, &candidates_p, temp);
    return llama_sample_token(ctx, &candidates_p);
}
#endif

struct LLamaPrivate {
    const std::string modelPath;
    bool modelLoaded;
    llama_context *ctx = nullptr;
    llama_context_params params;
    int64_t n_threads = 0;
};

LLamaModel::LLamaModel()
    : d_ptr(new LLamaPrivate) {
    d_ptr->modelLoaded = false;
}

// default hparams (LLaMA 7B)
struct llama_file_hparams {
    uint32_t n_vocab = 32000;
    uint32_t n_embd  = 4096;
    uint32_t n_mult  = 256;
    uint32_t n_head  = 32;
    uint32_t n_layer = 32;
    uint32_t n_rot   = 64;
    enum llama_ftype ftype = LLAMA_FTYPE_MOSTLY_F16;
};

size_t LLamaModel::requiredMem(const std::string &modelPath) {
    auto fin = std::ifstream(modelPath, std::ios::binary);
    fin.seekg(0, std::ios_base::end);
    size_t filesize = fin.tellg();
    fin.seekg(0, std::ios_base::beg);
    uint32_t magic = 0;
    fin.read(reinterpret_cast<char*>(&magic), sizeof(magic));
    if (magic != 0x67676a74) return 0;
    uint32_t version = 0;
    fin.read(reinterpret_cast<char*>(&version), sizeof(version));
    llama_file_hparams hparams;
    fin.read(reinterpret_cast<char*>(&hparams.n_vocab), sizeof(hparams.n_vocab));
    fin.read(reinterpret_cast<char*>(&hparams.n_embd), sizeof(hparams.n_embd));
    fin.read(reinterpret_cast<char*>(&hparams.n_head), sizeof(hparams.n_head));
    fin.read(reinterpret_cast<char*>(&hparams.n_layer), sizeof(hparams.n_layer));
    fin.read(reinterpret_cast<char*>(&hparams.n_rot), sizeof(hparams.n_rot));
    fin.read(reinterpret_cast<char*>(&hparams.ftype), sizeof(hparams.ftype));
    const size_t n_ctx = 2048;
    const size_t kvcache_element_size = 2; // fp16
    const size_t est_kvcache_size = hparams.n_embd * hparams.n_layer * 2u * n_ctx * kvcache_element_size;
    return filesize + est_kvcache_size;
}

bool LLamaModel::loadModel(const std::string &modelPath)
{
    // load the model
    d_ptr->params = llama_context_default_params();

    gpt_params params;
    d_ptr->params.n_ctx      = 2048;
    d_ptr->params.seed       = params.seed;
    d_ptr->params.f16_kv     = params.memory_f16;
    d_ptr->params.use_mmap   = params.use_mmap;
#if defined (__APPLE__)
    d_ptr->params.use_mlock  = true;
#else
    d_ptr->params.use_mlock  = params.use_mlock;
#endif
#if LLAMA_DATE <= 230511
    d_ptr->params.n_parts  = params.n_parts;
#endif
#ifdef GGML_USE_METAL
    std::cerr << "llama.cpp: using Metal" << std::endl;
    // metal always runs the whole model if n_gpu_layers is not 0, at least
    // currently
    d_ptr->params.n_gpu_layers = 1;
#endif
#ifdef GGML_USE_KOMPUTE
    if (ggml_vk_has_device()) {
        // vulkan always runs the whole model if n_gpu_layers is not 0, at least
        // currently
        d_ptr->params.n_gpu_layers = 1;
    }
#endif

    d_ptr->ctx = llama_init_from_file(modelPath.c_str(), d_ptr->params);
    if (!d_ptr->ctx) {
#ifdef GGML_USE_KOMPUTE
        // Explicitly free the device so next load it doesn't use it
        ggml_vk_free_device();
#endif
        std::cerr << "LLAMA ERROR: failed to load model from " <<  modelPath << std::endl;
        return false;
    }

#ifdef GGML_USE_KOMPUTE
    if (ggml_vk_has_device()) {
        std::cerr << "llama.cpp: using Vulkan on " << ggml_vk_current_device().name << std::endl;
    }
#endif

    d_ptr->n_threads = std::min(4, (int32_t) std::thread::hardware_concurrency());
    d_ptr->modelLoaded = true;
    fflush(stderr);
    return true;
}

void LLamaModel::setThreadCount(int32_t n_threads) {
    d_ptr->n_threads = n_threads;
}

int32_t LLamaModel::threadCount() const {
    return d_ptr->n_threads;
}

LLamaModel::~LLamaModel()
{
    if (d_ptr->ctx) {
        llama_free(d_ptr->ctx);
    }
}

bool LLamaModel::isModelLoaded() const
{
    return d_ptr->modelLoaded;
}

size_t LLamaModel::stateSize() const
{
    return llama_get_state_size(d_ptr->ctx);
}

size_t LLamaModel::saveState(uint8_t *dest) const
{
    return llama_copy_state_data(d_ptr->ctx, dest);
}

size_t LLamaModel::restoreState(const uint8_t *src)
{
    // const_cast is required, see: https://github.com/ggerganov/llama.cpp/pull/1540
    return llama_set_state_data(d_ptr->ctx, const_cast<uint8_t*>(src));
}

std::vector<LLModel::Token> LLamaModel::tokenize(PromptContext &ctx, const std::string &str) const
{
    const bool useBOS = ctx.n_past == 0 && (ctx.tokens.empty() || ctx.tokens.front() != llama_token_bos());
    std::vector<LLModel::Token> fres(str.size()+4);
    auto fres_len = llama_tokenize(d_ptr->ctx, str.c_str(), fres.data(), fres.size(), useBOS);
    fres.resize(fres_len);
    return fres;
}

std::string LLamaModel::tokenToString(Token id) const
{
    return llama_token_to_str(d_ptr->ctx, id);
}

LLModel::Token LLamaModel::sampleToken(PromptContext &promptCtx) const
{
    const size_t n_prev_toks = std::min((size_t) promptCtx.repeat_last_n, promptCtx.tokens.size());
    return llama_sample_top_p_top_k(d_ptr->ctx,
        promptCtx.tokens.data() + promptCtx.tokens.size() - n_prev_toks,
        n_prev_toks, promptCtx.top_k, promptCtx.top_p, promptCtx.temp,
        promptCtx.repeat_penalty);
}

bool LLamaModel::evalTokens(PromptContext &ctx, const std::vector<int32_t> &tokens) const
{
    // When we recalculate context we could have erased the original BOS token... we need to replace it
    const bool useBOS = ctx.n_past == 0 && (ctx.tokens.empty() || ctx.tokens.front() != llama_token_bos());
    if (useBOS) {
        std::vector<int32_t> myTokens;
        myTokens.push_back(llama_token_bos());
        myTokens.insert(myTokens.end(), tokens.begin(), tokens.end());
        ctx.n_past += 1;
        return llama_eval(d_ptr->ctx, myTokens.data(), myTokens.size(), ctx.n_past, d_ptr->n_threads) == 0;
    } else
        return llama_eval(d_ptr->ctx, tokens.data(), tokens.size(), ctx.n_past, d_ptr->n_threads) == 0;
}

int32_t LLamaModel::contextLength() const
{
    return llama_n_ctx(d_ptr->ctx);
}

const std::vector<LLModel::Token> &LLamaModel::endTokens() const
{
    static const std::vector<LLModel::Token> fres = {llama_token_eos()};
    return fres;
}

#if defined(GGML_USE_KOMPUTE)
#include "ggml-vulkan.h"
#endif

std::vector<LLModel::GPUDevice> LLamaModel::availableGPUDevices(size_t memoryRequired)
{
#if defined(GGML_USE_KOMPUTE)
    std::vector<ggml_vk_device> vkDevices = ggml_vk_available_devices(memoryRequired);

    std::vector<LLModel::GPUDevice> devices;
    for(const auto& vkDevice : vkDevices) {
        LLModel::GPUDevice device;
        device.index = vkDevice.index;
        device.type = vkDevice.type;
        device.heapSize = vkDevice.heapSize;
        device.name = vkDevice.name;
        device.vendor = vkDevice.vendor;

        devices.push_back(device);
    }

    return devices;
#else
    return std::vector<LLModel::GPUDevice>();
#endif
}

bool LLamaModel::initializeGPUDevice(size_t memoryRequired, const std::string& device)
{
#if defined(GGML_USE_KOMPUTE)
    return ggml_vk_init_device(memoryRequired, device);
#else
    return false;
#endif
}

bool LLamaModel::initializeGPUDevice(const LLModel::GPUDevice &device)
{
#if defined(GGML_USE_KOMPUTE)
    ggml_vk_device vkDevice;
    vkDevice.index = device.index;
    vkDevice.type = device.type;
    vkDevice.heapSize = device.heapSize;
    vkDevice.name = device.name;
    vkDevice.vendor = device.vendor;
    return ggml_vk_init_device(vkDevice);
#else
    return false;
#endif
}

bool LLamaModel::initializeGPUDevice(int device)
{
#if defined(GGML_USE_KOMPUTE)
    return ggml_vk_init_device(device);
#else
    return false;
#endif
}

bool LLamaModel::hasGPUDevice()
{
#if defined(GGML_USE_KOMPUTE)
    return ggml_vk_has_device();
#else
    return false;
#endif
}

bool LLamaModel::usingGPUDevice()
{
#if defined(GGML_USE_KOMPUTE)
    return ggml_vk_using_vulkan();
#elif defined(GGML_USE_METAL)
    return true;
#endif
    return false;
}

#if defined(_WIN32)
#define DLL_EXPORT __declspec(dllexport)
#else
#define DLL_EXPORT __attribute__ ((visibility ("default")))
#endif

extern "C" {
DLL_EXPORT bool is_g4a_backend_model_implementation() {
    return true;
}

DLL_EXPORT const char *get_model_type() {
    return modelType_;
}

DLL_EXPORT const char *get_build_variant() {
    return GGML_BUILD_VARIANT;
}

DLL_EXPORT bool magic_match(std::istream& f) {
    // Check magic
    uint32_t magic = 0;
    f.read(reinterpret_cast<char*>(&magic), sizeof(magic));
    if (magic != 0x67676a74) return false;
    // Check version
    uint32_t version = 0;
    f.read(reinterpret_cast<char*>(&version), sizeof(version));
    if (!(version LLAMA_VERSIONS)) {
        return false;
    }
    llama_file_hparams hparams;
    f.read(reinterpret_cast<char*>(&hparams), sizeof(hparams));
    if (!(hparams.n_vocab >= 32000 && hparams.n_vocab <= 32100)) {
        return false; // not a llama.
    }
#ifdef GGML_USE_METAL
    // Check quant supported on metal
    // skip fields
    switch(hparams.ftype) {
        // currently supported on Metal https://github.com/ggerganov/llama.cpp/blob/ae9663f1887513e152839e91f61c513075a19422/ggml-metal.m#L51-L55
        case LLAMA_FTYPE_MOSTLY_F16:
        case LLAMA_FTYPE_MOSTLY_Q2_K:
        case LLAMA_FTYPE_MOSTLY_Q4_0:
        case LLAMA_FTYPE_MOSTLY_Q6_K:
        case LLAMA_FTYPE_MOSTLY_Q4_K_S:
        case LLAMA_FTYPE_MOSTLY_Q4_K_M:
            return true;
        default: // unsupported quant-type for Metal
            return false;
    }
#endif
    return true;
}

DLL_EXPORT LLModel *construct() {
    return new LLamaModel;
}
}

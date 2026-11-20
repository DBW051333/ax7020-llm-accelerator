// Independent read-only operator profiler for the pinned llama.cpp build.
#include "llama.h"
#include "ggml.h"
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>

using Clock = std::chrono::steady_clock;
struct Entry { double ms=0; unsigned count=0; };
struct Profile {
    bool enabled=false;
    Clock::time_point start;
    std::map<std::string,Entry> entries;
};

static const char *category(const ggml_tensor *tensor) {
    const char *name=tensor->name;
    if (std::strstr(name,"ffn_gateup_pl_fused")) return "PL Gate/Up";
    if (std::strcmp(name,"result_output")==0) return "LM Head";
    if (tensor->op==GGML_OP_MUL_MAT && tensor->src[0]) {
        const ggml_tensor *weight=tensor->src[0];
        if (std::strstr(weight->name,"ffn_down.weight"))
            return weight->type==GGML_TYPE_Q4_K ? "Down Q4_K" : "Down Q6_K";
        if (std::strstr(weight->name,"attn_") && std::strstr(weight->name,".weight"))
            return "Attention projections";
        return "Other matrix multiply";
    }
    return "Other graph operations";
}

static bool observe(ggml_tensor *tensor, bool ask, void *userdata) {
    auto &p=*static_cast<Profile *>(userdata);
    if (ask) {
        if (p.enabled) p.start=Clock::now();
        return p.enabled;
    }
    double ms=std::chrono::duration<double,std::milli>(Clock::now()-p.start).count();
    auto &entry=p.entries[category(tensor)];
    entry.ms+=ms;
    entry.count++;
    return true;
}

int main(int argc,char **argv) {
    if (argc!=4) { std::fprintf(stderr,"usage: %s MODEL FIXED_TOKENS warm|profile\n",argv[0]); return 2; }
    const bool instrument=std::strcmp(argv[3],"profile")==0;
    if (!instrument && std::strcmp(argv[3],"warm")!=0) return 2;
    FILE *tokens=std::fopen(argv[2],"r");
    if (!tokens) return 2;
    std::vector<llama_token> forced;
    for (int id; std::fscanf(tokens,"%d",&id)==1;) forced.push_back(id);
    std::fclose(tokens);
    if (forced.size()<16) return 2;
    llama_backend_init();
    auto *model=llama_load_model_from_file(argv[1],llama_model_default_params());
    if (!model) return 2;
    Profile profile;
    auto params=llama_context_default_params();
    params.n_ctx=256; params.n_batch=64; params.n_ubatch=64;
    params.n_threads=2; params.n_threads_batch=2;
    if (instrument) { params.cb_eval=observe; params.cb_eval_user_data=&profile; }
    auto *ctx=llama_new_context_with_model(model,params);
    if (!ctx) return 2;
    const char prompt[]="Write a short story about a robot.";
    llama_token input[64];
    int count=llama_tokenize(model,prompt,sizeof(prompt)-1,input,64,true,false);
    if (count<=0 || llama_decode(ctx,llama_batch_get_one(input,count))) return 2;
    double total=0;
    unsigned measured=0;
    for (unsigned i=0; i<forced.size()-1; i++) {
        // First decode token touches all model layers and initializes BOs.
        profile.enabled=i>=4;
        auto start=Clock::now();
        if (llama_decode(ctx,llama_batch_get_one(&forced[i],1))) return 2;
        if (profile.enabled) {
            total+=std::chrono::duration<double,std::milli>(Clock::now()-start).count();
            measured++;
        }
        float *logits=llama_get_logits_ith(ctx,-1);
        if (!logits || std::max_element(logits,logits+llama_n_vocab(model))-logits!=forced[i+1])
            return 3;
    }
    std::printf("PROFILE mode=%s steps=%u wall_ms_per_token=%.3f tokens_per_second=%.6f\n",
                argv[3],measured,total/measured,1000*measured/total);
    for (const auto &item:profile.entries)
        std::printf("PROFILE %-24s %9.3f ms/token (%u calls)\n",item.first.c_str(),item.second.ms/measured,item.second.count);
    llama_free(ctx);
    llama_free_model(model);
    llama_backend_free();
    return 0;
}

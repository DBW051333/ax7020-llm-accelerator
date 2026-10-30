"""Emit surgical source replacements for the pinned existing board build tree."""
import hashlib,json,runpy
from pathlib import Path
root=Path(__file__).resolve().parents[2]
src=root/'build/upstream/llama.cpp-dafae66cc242eb766797194d3c85c5e502625623'
out=root/'build/gateup2017/software'
out.mkdir(parents=True,exist_ok=True)
originals={}
def save(path,text):
    p=out/path;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(text)
def read(path):
    raw=(src/path).read_bytes();originals[path]=hashlib.sha256(raw).hexdigest()
    return raw.decode().replace('\r\n','\n')
path='ggml/include/ggml.h';s=read(path)
needle='    GGML_API struct ggml_tensor * ggml_map_custom3(\n'
assert s.count(needle)==1
decl='''    // Shaped F32 custom result with explicit graph dependencies.
    GGML_API struct ggml_tensor * ggml_map_custom3_shape(
        struct ggml_context *ctx, struct ggml_tensor *a, struct ggml_tensor *b,
        struct ggml_tensor *c, ggml_custom3_op_t fun, int n_tasks, void *userdata,
        int64_t rows, int64_t columns);

'''
save(path,s.replace(needle,decl+needle))
path='ggml/src/ggml.c';s=read(path)
needle='struct ggml_tensor * ggml_map_custom3(\n';assert s.count(needle)==1
fun='''struct ggml_tensor * ggml_map_custom3_shape(
        struct ggml_context *ctx, struct ggml_tensor *a, struct ggml_tensor *b,
        struct ggml_tensor *c, ggml_custom3_op_t fun, int n_tasks, void *userdata,
        int64_t rows, int64_t columns) {
    GGML_ASSERT(n_tasks>0 && rows>0 && columns>0);
    struct ggml_tensor *result=ggml_new_tensor_2d(ctx,GGML_TYPE_F32,rows,columns);
    struct ggml_map_custom3_op_params params={fun,n_tasks,userdata};
    ggml_set_op_params(result,&params,sizeof(params));
    result->op=GGML_OP_MAP_CUSTOM3;
    result->src[0]=a;result->src[1]=b;result->src[2]=c;
    return result;
}

'''
save(path,s.replace(needle,fun+needle))
path='src/llama.cpp';s=read(path)
s=s.replace('#include "ggml-cpp.h"','#include "ggml-cpp.h"\n#ifdef GGML_USE_GATEUP\n#include "ggml-cpu.h"\n#include "gateup_runtime.h"\n#endif')
needle='static struct ggml_tensor * llm_build_ffn(\n';assert s.count(needle)==1
s=s.replace(needle,(root/'compat/gateup2017/gateup_callback.inc').read_text()+'\n'+needle)
needle='    struct ggml_tensor * tmp = up ? llm_build_lora_mm(lctx, ctx, up, cur) : cur;'
assert s.count(needle)==1
branch='''#ifdef GGML_USE_GATEUP
    if(gateup_enabled() && type_op==LLM_FFN_SILU && type_gate==LLM_FFN_PAR &&
       up && gate && down && !up_b && !up_s && !gate_b && !gate_s &&
       !down_b && !down_s && !act_scales && lctx.lora_adapters.empty() &&
       cur->ne[1]==1 && cur->ne[2]==1 && cur->ne[3]==1 &&
       cur->type==GGML_TYPE_F32 && ggml_is_contiguous(cur) &&
       up->type==GGML_TYPE_Q5_0 && gate->type==GGML_TYPE_Q5_0 &&
       cur->ne[0]==896 && up->ne[0]==896 && gate->ne[0]==896 &&
       up->ne[1]==4864 && gate->ne[1]==4864) {
        cur=ggml_map_custom3_shape(ctx,cur,gate,up,gateup_compute,1,nullptr,4864,1);
        cb(cur,"ffn_gateup_pl_fused",il);
        if(down->type==GGML_TYPE_Q4_K && down->ne[0]==4864 && down->ne[1]==896) {
            cur=ggml_map_custom3_shape(ctx,cur,down,cur,gateup_down_compute,1,nullptr,896,1);
            cb(cur,"ffn_down_pl_q4k",il);
            return cur;
        }
        return llm_build_lora_mm(lctx,ctx,down,cur);
    }
#endif
'''
save(path,s.replace(needle,branch+needle))
path='ggml/src/ggml-cpu/CMakeLists.txt';s=read(path)
needle='    if (GGML_BLITE)\n';assert s.count(needle)==1
cm='''    if (GGML_GATEUP)
        target_sources(${GGML_CPU_NAME} PRIVATE "${GGML_GATEUP_DIR}/gateup_runtime.c")
        target_include_directories(${GGML_CPU_NAME} PRIVATE "${GGML_GATEUP_DIR}")
        target_link_libraries(${GGML_CPU_NAME} PRIVATE ${CMAKE_DL_LIBS})
    endif()
'''
save(path,s.replace(needle,cm+needle))
path='src/CMakeLists.txt';s=read(path)
s+='''
if (GGML_GATEUP)
    target_include_directories(llama PRIVATE "${GGML_GATEUP_DIR}")
    target_compile_definitions(llama PRIVATE GGML_USE_GATEUP)
    target_link_libraries(llama PUBLIC ggml-cpu)
endif()
'''
save(path,s)
# Reuse the already validated logits/forced-token instrumentation, opt-in only.
path='examples/main/main.cpp';read(path)
runpy.run_path(str(root/'compat/vivado2017/diagnostics/prepare_trace.py'))
save(path,(root/'build/logits-diagnosis2017/source/main.cpp').read_text())
(out/'original-hashes.json').write_text(json.dumps(originals,indent=2))
print(out)

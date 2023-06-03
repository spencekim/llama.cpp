#import "mtl.h"

#import "ggml.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>

#ifdef LLAMA_MTL_NDEBUG
#define mtl_printf(...)
#else
#define mtl_printf(...) fprintf(stderr, __VA_ARGS__)
#endif
//#define mtl_printf(...)

struct ggml_mtl_context {
    void   * data_buf;
    size_t   data_size;
    void   * eval_buf;
    size_t   eval_size;
    void   * cach_buf;
    size_t   cach_size;
    size_t   outp_size;

    float * logits;

    id<MTLDevice>       device;
    id<MTLCommandQueue> queue;
    id<MTLLibrary>      library;

    id<MTLBuffer> buffer_data;
    id<MTLBuffer> buffer_eval;
    id<MTLBuffer> buffer_cach;

    id<MTLBuffer> out;

    // custom kernels
    id<MTLFunction>             function_add;
    id<MTLComputePipelineState> pipeline_add;

    id<MTLFunction>             function_mul;
    id<MTLComputePipelineState> pipeline_mul;

    // TODO: avoid this extra kernel, instead extend the "mul" kernel to support broadcast
    id<MTLFunction>             function_mul_row;
    id<MTLComputePipelineState> pipeline_mul_row;

    id<MTLFunction>             function_scale;
    id<MTLComputePipelineState> pipeline_scale;

    id<MTLFunction>             function_silu;
    id<MTLComputePipelineState> pipeline_silu;

    id<MTLFunction>             function_relu;
    id<MTLComputePipelineState> pipeline_relu;

    id<MTLFunction>             function_soft_max;
    id<MTLComputePipelineState> pipeline_soft_max;

    id<MTLFunction>             function_diag_mask_inf;
    id<MTLComputePipelineState> pipeline_diag_mask_inf;

    id<MTLFunction>             function_get_rows_q4_0;
    id<MTLComputePipelineState> pipeline_get_rows_q4_0;

    id<MTLFunction>             function_rms_norm;
    id<MTLComputePipelineState> pipeline_rms_norm;

    id<MTLFunction>             function_mul_mat_q4_0_f32;
    id<MTLComputePipelineState> pipeline_mul_mat_q4_0_f32;

    id<MTLFunction>             function_mul_mat_f16_f32;
    id<MTLComputePipelineState> pipeline_mul_mat_f16_f32;

    id<MTLFunction>             function_rope;
    id<MTLComputePipelineState> pipeline_rope;

    id<MTLFunction>             function_cpy_f32_f16;
    id<MTLComputePipelineState> pipeline_cpy_f32_f16;

    id<MTLFunction>             function_cpy_f32_f32;
    id<MTLComputePipelineState> pipeline_cpy_f32_f32;
};

// MSL code
// TODO: move the contents here when ready
//       for now it is easier to work in a separate file
NSString * const msl_library_llama = @"see mtl.metal";

struct ggml_mtl_context * llama_mtl_init(
                     void   * data_buf,
                     size_t   data_size,
                     void   * eval_buf,
                     size_t   eval_size,
                     void   * cach_buf,
                     size_t   cach_size,
                     size_t   outp_size) {
    fprintf(stderr, "%s: allocating\n", __func__);

    struct ggml_mtl_context * ctx = malloc(sizeof(struct ggml_mtl_context));

    ctx->data_buf  = data_buf;
    ctx->data_size = data_size;
    ctx->eval_buf  = eval_buf;
    ctx->eval_size = eval_size;
    ctx->cach_buf  = cach_buf;
    ctx->cach_size = cach_size;

    ctx->device = MTLCreateSystemDefaultDevice();
    ctx->queue  = [ctx->device newCommandQueue];

    // determine if we can use MPS
    if (MPSSupportsMTLDevice(ctx->device)) {
        fprintf(stderr, "%s: using MPS\n", __func__);
    } else {
        fprintf(stderr, "%s: not using MPS\n", __func__);
        GGML_ASSERT(false && "MPS not supported");
    }

#if 0
    // compile from source string and show compile log
    {
        NSError * error = nil;

        ctx->library = [ctx->device newLibraryWithSource:msl_library_llama options:nil error:&error];
        if (error) {
            fprintf(stderr, "%s: error: %s\n", __func__, [[error description] UTF8String]);
            exit(1);
        }
    }
#else
    // read the source from "../examples/mtl/mtl.metal" into a string and use newLibraryWithSource
    {
        NSError * error = nil;

        NSString * path = [[NSBundle mainBundle] pathForResource:@"../../examples/mtl/mtl" ofType:@"metal"];
        NSString * src  = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
        if (error) {
            fprintf(stderr, "%s: error: %s\n", __func__, [[error description] UTF8String]);
            exit(1);
        }

        ctx->library = [ctx->device newLibraryWithSource:src options:nil error:&error];
        if (error) {
            fprintf(stderr, "%s: error: %s\n", __func__, [[error description] UTF8String]);
            exit(1);
        }
    }
#endif

    // load kernels
    {
        MTLFunctionConstantValues * constants = [MTLFunctionConstantValues new];

        ctx->function_add = [ctx->library newFunctionWithName:@"kernel_add"];
        ctx->pipeline_add = [ctx->device newComputePipelineStateWithFunction:ctx->function_add error:nil];
        fprintf(stderr, "%s: loaded kernel_add: %p\n", __func__, (void *) ctx->pipeline_add);

        ctx->function_mul = [ctx->library newFunctionWithName:@"kernel_mul"];
        ctx->pipeline_mul = [ctx->device newComputePipelineStateWithFunction:ctx->function_mul error:nil];
        fprintf(stderr, "%s: loaded kernel_mul: %p\n", __func__, (void *) ctx->pipeline_mul);

        ctx->function_mul_row = [ctx->library newFunctionWithName:@"kernel_mul_row"];
        ctx->pipeline_mul_row = [ctx->device newComputePipelineStateWithFunction:ctx->function_mul_row error:nil];
        fprintf(stderr, "%s: loaded kernel_mul_row: %p\n", __func__, (void *) ctx->pipeline_mul_row);

        ctx->function_scale = [ctx->library newFunctionWithName:@"kernel_scale"];
        ctx->pipeline_scale = [ctx->device newComputePipelineStateWithFunction:ctx->function_scale error:nil];
        fprintf(stderr, "%s: loaded kernel_scale: %p\n", __func__, (void *) ctx->pipeline_scale);

        ctx->function_silu = [ctx->library newFunctionWithName:@"kernel_silu"];
        ctx->pipeline_silu = [ctx->device newComputePipelineStateWithFunction:ctx->function_silu error:nil];
        fprintf(stderr, "%s: loaded kernel_silu: %p\n", __func__, (void *) ctx->pipeline_silu);

        ctx->function_relu = [ctx->library newFunctionWithName:@"kernel_relu"];
        ctx->pipeline_relu = [ctx->device newComputePipelineStateWithFunction:ctx->function_relu error:nil];
        fprintf(stderr, "%s: loaded kernel_relu: %p\n", __func__, (void *) ctx->pipeline_relu);

        ctx->function_soft_max = [ctx->library newFunctionWithName:@"kernel_soft_max" constantValues:constants error:nil];
        ctx->pipeline_soft_max = [ctx->device newComputePipelineStateWithFunction:ctx->function_soft_max error:nil];
        fprintf(stderr, "%s: loaded kernel_soft_max: %p\n", __func__, (void *) ctx->pipeline_soft_max);

        ctx->function_diag_mask_inf = [ctx->library newFunctionWithName:@"kernel_diag_mask_inf" constantValues:constants error:nil];
        ctx->pipeline_diag_mask_inf = [ctx->device newComputePipelineStateWithFunction:ctx->function_diag_mask_inf error:nil];
        fprintf(stderr, "%s: loaded kernel_diag_mask_inf: %p\n", __func__, (void *) ctx->pipeline_diag_mask_inf);

        ctx->function_get_rows_q4_0 = [ctx->library newFunctionWithName:@"kernel_get_rows_q4_0"];
        ctx->pipeline_get_rows_q4_0 = [ctx->device newComputePipelineStateWithFunction:ctx->function_get_rows_q4_0 error:nil];
        fprintf(stderr, "%s: loaded kernel_get_rows_q4_0: %p\n", __func__, (void *) ctx->pipeline_get_rows_q4_0);

        ctx->function_rms_norm = [ctx->library newFunctionWithName:@"kernel_rms_norm"];
        ctx->pipeline_rms_norm = [ctx->device newComputePipelineStateWithFunction:ctx->function_rms_norm error:nil];
        fprintf(stderr, "%s: loaded kernel_rms_norm: %p\n", __func__, (void *) ctx->pipeline_rms_norm);

        ctx->function_mul_mat_q4_0_f32 = [ctx->library newFunctionWithName:@"kernel_mul_mat_q4_0_f32"];
        ctx->pipeline_mul_mat_q4_0_f32 = [ctx->device newComputePipelineStateWithFunction:ctx->function_mul_mat_q4_0_f32 error:nil];
        fprintf(stderr, "%s: loaded kernel_mul_mat_q4_0_f32: %p\n", __func__, (void *) ctx->pipeline_mul_mat_q4_0_f32);

        ctx->function_mul_mat_f16_f32 = [ctx->library newFunctionWithName:@"kernel_mul_mat_f16_f32"];
        ctx->pipeline_mul_mat_f16_f32 = [ctx->device newComputePipelineStateWithFunction:ctx->function_mul_mat_f16_f32 error:nil];
        fprintf(stderr, "%s: loaded kernel_mul_mat_f16_f32: %p\n", __func__, (void *) ctx->pipeline_mul_mat_f16_f32);

        ctx->function_rope = [ctx->library newFunctionWithName:@"kernel_rope"];
        ctx->pipeline_rope = [ctx->device newComputePipelineStateWithFunction:ctx->function_rope error:nil];
        fprintf(stderr, "%s: loaded kernel_rope: %p\n", __func__, (void *) ctx->pipeline_rope);

        ctx->function_cpy_f32_f16 = [ctx->library newFunctionWithName:@"kernel_cpy_f32_f16"];
        ctx->pipeline_cpy_f32_f16 = [ctx->device newComputePipelineStateWithFunction:ctx->function_cpy_f32_f16 error:nil];
        fprintf(stderr, "%s: loaded kernel_cpy_f32_f16: %p\n", __func__, (void *) ctx->pipeline_cpy_f32_f16);

        ctx->function_cpy_f32_f32 = [ctx->library newFunctionWithName:@"kernel_cpy_f32_f32"];
        ctx->pipeline_cpy_f32_f32 = [ctx->device newComputePipelineStateWithFunction:ctx->function_cpy_f32_f32 error:nil];
        fprintf(stderr, "%s: loaded kernel_cpy_f32_f32: %p\n", __func__, (void *) ctx->pipeline_cpy_f32_f32);
    }

    // MTLBuffer approach

    // pin ctx_data memory to GPU
    // use MTLStorageModeShared to allow us to initialize the weights from the CPU
    // TODO: how to use MTLStorageModeManaged?
    // TODO: see if we can avoid this copy somehow
    {
        void * mem_buffer = data_buf;
        const size_t mem_size   = data_size;

        //ctx->buffer_data = [ctx->device newBufferWithBytesNoCopy:mem_buffer length:mem_size options:MTLResourceStorageModeShared deallocator:nil];
        ctx->buffer_data = [ctx->device newBufferWithBytes:mem_buffer length:mem_size options:MTLResourceStorageModeShared];

        fprintf(stderr, "%s: allocated data buffer, size = %8.2f MB\n", __func__, mem_size / 1024.0 / 1024.0);
    }

    // pin ctx_eval memory to GPU
    // this buffer will be used for the intermediate results of the evaluation
    {
        const void * mem_buffer = eval_buf;
        const size_t mem_size   = eval_size;

        ctx->buffer_eval = [ctx->device newBufferWithBytes:mem_buffer length:mem_size options:MTLResourceStorageModeShared];

        fprintf(stderr, "%s: allocated eval buffer, size = %8.2f MB\n", __func__, mem_size / 1024.0 / 1024.0);
    }

    if (cach_buf) {
        const void * mem_buffer = cach_buf;
        const size_t mem_size   = cach_size;

        ctx->buffer_cach = [ctx->device newBufferWithBytes:mem_buffer length:mem_size options:MTLResourceStorageModeShared];

        fprintf(stderr, "%s: allocated cach buffer, size = %8.2f MB\n", __func__, mem_size / 1024.0 / 1024.0);
    }

    // allocate buffer for result extraction
    {
        const size_t mem_size = outp_size;

        ctx->out = [ctx->device newBufferWithLength:mem_size options:MTLResourceStorageModeShared];

        fprintf(stderr, "%s: allocated  out buffer, size = %8.2f MB\n", __func__, mem_size / 1024.0 / 1024.0);
    }

    return ctx;
}

void llama_mtl_free(struct ggml_mtl_context * ctx) {
    fprintf(stderr, "%s: deallocating\n", __func__);

    free(ctx);
}

// get data / eval buffer + offset
id<MTLBuffer> llama_mtl_get_buffer(struct ggml_mtl_context * ctx, struct ggml_tensor * t, size_t * offs) {
    const int64_t offs_data = (int64_t) t->data - (int64_t) ctx->data_buf;
    const int64_t offs_eval = (int64_t) t->data - (int64_t) ctx->eval_buf;
    const int64_t offs_cach = (int64_t) t->data - (int64_t) ctx->cach_buf;

    //const size_t t_size = ggml_nbytes(t);

    id<MTLBuffer> result;
    size_t t_offs = 0;

    if ( offs_data > 0 &&
        (offs_eval < 0 || (offs_data < offs_eval)) &&
        (offs_cach < 0 || (offs_data < offs_cach))
       ) {
        result = ctx->buffer_data;
        t_offs = offs_data;
        //fprintf(stderr, "%s: data tensor '%16s', offs = %8ld, size = %8ld\n", __func__, t->name, t_offs, t_size);
    }

    if ( offs_eval > 0 &&
        (offs_data < 0 || (offs_eval < offs_data)) &&
        (offs_cach < 0 || (offs_eval < offs_cach))
       ) {
        result = ctx->buffer_eval;
        t_offs = offs_eval;
        //fprintf(stderr, "%s: data tensor '%16s', offs = %8ld, size = %8ld\n", __func__, t->name, t_offs, t_size);
    }

    if ( offs_cach > 0 &&
        (offs_data < 0 || (offs_cach < offs_data)) &&
        (offs_eval < 0 || (offs_cach < offs_eval))
       ) {
        result = ctx->buffer_cach;
        t_offs = offs_cach;
        //fprintf(stderr, "%s: data tensor '%16s', offs = %8ld, size = %8ld\n", __func__, t->name, t_offs, t_size);
    }

    if (result == nil || (t_offs > ctx->data_size && t_offs > ctx->eval_size && t_offs > ctx->cach_size)) {
        fprintf(stderr, "%s: error: buffer is nil\n", __func__);
        GGML_ASSERT(false);
    }

    if (offs != 0) {
        *offs = t_offs;
    }

    return result;
}

int llama_mtl_eval(
        struct ggml_mtl_context * ctx,
             struct ggml_cgraph * gf,
                      const int * tokens,
                            int   n_tokens,
                            int   n_past) {
    mtl_printf("%s: evaluating, n_tokens = %d, n_past = %d\n", __func__, n_tokens, n_past);

    struct ggml_tensor * input = ggml_graph_get_tensor(gf, "embd");
    memcpy(input->data, tokens, n_tokens * sizeof(int));

    size_t offs_src0 = 0;
    size_t offs_src1 = 0;
    size_t offs_dst  = 0;

    // copy the input data to the GPU
    {
        struct ggml_tensor * embd = ggml_graph_get_tensor(gf, "embd");

        id<MTLBuffer> id_dst = llama_mtl_get_buffer(ctx, embd, &offs_src0);

        memcpy((char *) id_dst.contents + offs_src0, embd->data, ggml_nbytes(embd));
    }

    id<MTLCommandBuffer> command_buffer  = [ctx->queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = nil;

    for (int i = 0; i < gf->n_nodes; ++i) {
        //mtl_printf("%s: encoding node %3d, op = %8s\n", __func__, i, ggml_op_name(gf->nodes[i]->op));

        struct ggml_tensor * src0 = gf->nodes[i]->src0;
        struct ggml_tensor * src1 = gf->nodes[i]->src1;
        struct ggml_tensor * dst  = gf->nodes[i];

        const int64_t  ne00 = src0 ? src0->ne[0] : 0;
        const int64_t  ne01 = src0 ? src0->ne[1] : 0;
        const int64_t  ne02 = src0 ? src0->ne[2] : 0;
        const int64_t  ne03 = src0 ? src0->ne[3] : 0;

        const uint64_t nb00 = src0 ? src0->nb[0] : 0;
        const uint64_t nb01 = src0 ? src0->nb[1] : 0;
        const uint64_t nb02 = src0 ? src0->nb[2] : 0;
        const uint64_t nb03 = src0 ? src0->nb[3] : 0;

        const int64_t  ne10 = src1 ? src1->ne[0] : 0;
        const int64_t  ne11 = src1 ? src1->ne[1] : 0;
        const int64_t  ne12 = src1 ? src1->ne[2] : 0;
        //const int64_t  ne13 = src1 ? src1->ne[3] : 0;

        const uint64_t nb10 = src1 ? src1->nb[0] : 0;
        const uint64_t nb11 = src1 ? src1->nb[1] : 0;
        const uint64_t nb12 = src1 ? src1->nb[2] : 0;
        //const uint64_t nb13 = src1 ? src1->nb[3] : 0;

        const int64_t  ne0  = dst ? dst->ne[0] : 0;
        const int64_t  ne1  = dst ? dst->ne[1] : 0;
        const int64_t  ne2  = dst ? dst->ne[2] : 0;
        const int64_t  ne3  = dst ? dst->ne[3] : 0;

        const uint64_t nb0  = dst ? dst->nb[0] : 0;
        const uint64_t nb1  = dst ? dst->nb[1] : 0;
        const uint64_t nb2  = dst ? dst->nb[2] : 0;
        const uint64_t nb3  = dst ? dst->nb[3] : 0;

        const enum ggml_type src0t = src0 ? src0->type : GGML_TYPE_COUNT;
        const enum ggml_type src1t = src1 ? src1->type : GGML_TYPE_COUNT;
        const enum ggml_type dstt  = dst  ? dst->type  : GGML_TYPE_COUNT;

        id<MTLBuffer> id_src0 = src0 ? llama_mtl_get_buffer(ctx, src0, &offs_src0) : nil;
        id<MTLBuffer> id_src1 = src1 ? llama_mtl_get_buffer(ctx, src1, &offs_src1) : nil;
        id<MTLBuffer> id_dst  = dst  ? llama_mtl_get_buffer(ctx, dst,  &offs_dst)  : nil;

        //mtl_printf("%s: op - %s\n", __func__, ggml_op_name(dst->op));
        //if (src0) {
        //    mtl_printf("%s: src0 - %4s [%5lld, %5lld, %5lld], %d, %s\n", __func__, ggml_type_name(src0t), ne00, ne01, ne02,
        //            ggml_is_contiguous(src0), src0->name);
        //}
        //if (src1) {
        //    mtl_printf("%s: src1 - %4s [%5lld, %5lld, %5lld], %d, %s\n", __func__, ggml_type_name(src1t), ne10, ne11, ne12,
        //            ggml_is_contiguous(src1), src1->name);
        //}
        //if (dst) {
        //    mtl_printf("%s: dst  - %4s [%5lld, %5lld, %5lld], 1, %s\n",  __func__, ggml_type_name(dstt),  ne0,  ne1,  ne2,
        //            dst->name);
        //}

        switch (dst->op) {
            case GGML_OP_RESHAPE:
            case GGML_OP_VIEW:
            case GGML_OP_TRANSPOSE:
            case GGML_OP_PERMUTE:
                {
                    // noop
                } break;
            case GGML_OP_ADD:
                {
                    if (encoder == nil) {
                        encoder = [command_buffer computeCommandEncoder];
                    }

                    [encoder setComputePipelineState:ctx->pipeline_add];
                    [encoder setBuffer:id_src0 offset:offs_src0 atIndex:0];
                    [encoder setBuffer:id_src1 offset:offs_src1 atIndex:1];
                    [encoder setBuffer:id_dst  offset:offs_dst  atIndex:2];

                    const int64_t n = ggml_nelements(dst);

                    [encoder dispatchThreadgroups:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                } break;
            case GGML_OP_MUL:
                {
                    if (encoder == nil) {
                        encoder = [command_buffer computeCommandEncoder];
                    }

                    if (ggml_nelements(src1) == ne10) {
                        // src1 is a row
                        [encoder setComputePipelineState:ctx->pipeline_mul_row];
                    } else {
                        [encoder setComputePipelineState:ctx->pipeline_mul];
                    }
                    [encoder setBuffer:id_src0 offset:offs_src0 atIndex:0];
                    [encoder setBuffer:id_src1 offset:offs_src1 atIndex:1];
                    [encoder setBuffer:id_dst  offset:offs_dst  atIndex:2];
                    [encoder setBytes:&ne00 length:sizeof(ne00) atIndex:3];

                    const int64_t n = ggml_nelements(dst);

                    [encoder dispatchThreadgroups:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                } break;
            case GGML_OP_SCALE:
                {
                    if (encoder == nil) {
                        encoder = [command_buffer computeCommandEncoder];
                    }

                    const float scale = *(const float *) src1->data;

                    [encoder setComputePipelineState:ctx->pipeline_scale];
                    [encoder setBuffer:id_src0 offset:offs_src0 atIndex:0];
                    [encoder setBuffer:id_dst  offset:offs_dst  atIndex:1];
                    [encoder setBytes:&scale length:sizeof(scale) atIndex:2];

                    const int64_t n = ggml_nelements(dst);

                    [encoder dispatchThreadgroups:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                } break;
            case GGML_OP_SILU:
                {
                    if (encoder == nil) {
                        encoder = [command_buffer computeCommandEncoder];
                    }

                    [encoder setComputePipelineState:ctx->pipeline_silu];
                    [encoder setBuffer:id_src0 offset:offs_src0 atIndex:0];
                    [encoder setBuffer:id_dst  offset:offs_dst  atIndex:1];

                    const int64_t n = ggml_nelements(dst);

                    [encoder dispatchThreadgroups:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                } break;
            case GGML_OP_RELU:
                {
                    if (encoder == nil) {
                        encoder = [command_buffer computeCommandEncoder];
                    }

                    [encoder setComputePipelineState:ctx->pipeline_relu];
                    [encoder setBuffer:id_src0 offset:offs_src0 atIndex:0];
                    [encoder setBuffer:id_dst  offset:offs_dst  atIndex:1];

                    const int64_t n = ggml_nelements(dst);

                    [encoder dispatchThreadgroups:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                } break;
            case GGML_OP_SOFT_MAX:
                {
                    if (encoder == nil) {
                        encoder = [command_buffer computeCommandEncoder];
                    }

                    const int nth = 32;

                    [encoder setComputePipelineState:ctx->pipeline_soft_max];
                    [encoder setBuffer:id_src0 offset:offs_src0 atIndex:0];
                    [encoder setBuffer:id_dst  offset:offs_dst  atIndex:1];
                    [encoder setBytes:&ne00 length:sizeof(ne00) atIndex:2];
                    [encoder setBytes:&ne01 length:sizeof(ne01) atIndex:3];
                    [encoder setBytes:&ne02 length:sizeof(ne02) atIndex:4];
                    [encoder setThreadgroupMemoryLength:nth*sizeof(float) atIndex:0];

                    [encoder dispatchThreadgroups:MTLSizeMake(ne01, ne02, ne03) threadsPerThreadgroup:MTLSizeMake(nth, 1, 1)];
                } break;
            case GGML_OP_DIAG_MASK_INF:
                {
                    if (encoder == nil) {
                        encoder = [command_buffer computeCommandEncoder];
                    }

                    [encoder setComputePipelineState:ctx->pipeline_diag_mask_inf];
                    [encoder setBuffer:id_src0 offset:offs_src0 atIndex:0];
                    [encoder setBuffer:id_dst  offset:offs_dst  atIndex:1];
                    [encoder setBytes:&ne00   length:sizeof(ne00) atIndex:2];
                    [encoder setBytes:&ne01   length:sizeof(ne01) atIndex:3];
                    [encoder setBytes:&n_past length:sizeof(int)  atIndex:4];

                    [encoder dispatchThreadgroups:MTLSizeMake(ne00, ne01, ne02) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                } break;
            case GGML_OP_MUL_MAT:
                {
                    GGML_ASSERT(ne00 == ne10);
                    GGML_ASSERT(ne02 == ne12);

                    if (ggml_is_contiguous(src0) &&
                        ggml_is_contiguous(src1) &&
                        (src0t == GGML_TYPE_F32 || src0t == GGML_TYPE_F16) && ne11 > 1) {

                        if (encoder != nil) {
                            [encoder endEncoding];
                            encoder = nil;
                        }

                        MPSDataType src0dt = src0t == GGML_TYPE_F32 ? MPSDataTypeFloat32 : MPSDataTypeFloat16;
                        MPSDataType src1dt = src1t == GGML_TYPE_F32 ? MPSDataTypeFloat32 : MPSDataTypeFloat16;

                        // for F32 x F32 we use MPS
                        MPSMatrixDescriptor * desc0 = [MPSMatrixDescriptor
                            matrixDescriptorWithRows:ne01 columns:ne00 rowBytes:src0->nb[1] dataType:src0dt];

                        MPSMatrixDescriptor * desc1 = [MPSMatrixDescriptor
                            matrixDescriptorWithRows:ne11 columns:ne10 rowBytes:src1->nb[1] dataType:src1dt];

                        MPSMatrixDescriptor * desc  = [MPSMatrixDescriptor
                            matrixDescriptorWithRows:ne1 columns:ne0 rowBytes:dst->nb[1] dataType:MPSDataTypeFloat32];

                        MPSMatrixMultiplication * mul = [[MPSMatrixMultiplication alloc]
                            initWithDevice:ctx->device transposeLeft:false transposeRight:true
                                resultRows:ne11 resultColumns:ne01 interiorColumns:ne00 alpha:1.0 beta:0.0];

                        // we need to do ne02 multiplications
                        // TODO: is there a way to do this in parallel - currently very slow ..
                        for (int64_t i02 = 0; i02 < ne02; ++i02) {
                            size_t offs_src0_cur = offs_src0 + i02*nb02;
                            size_t offs_src1_cur = offs_src1 + i02*nb12;
                            size_t offs_dst_cur  = offs_dst  + i02*nb2;

                            MPSMatrix * mat_src0 = [[MPSMatrix alloc] initWithBuffer:id_src0 offset:offs_src0_cur descriptor:desc0];
                            MPSMatrix * mat_src1 = [[MPSMatrix alloc] initWithBuffer:id_src1 offset:offs_src1_cur descriptor:desc1];
                            MPSMatrix * mat_dst  = [[MPSMatrix alloc] initWithBuffer:id_dst  offset:offs_dst_cur  descriptor:desc ];

                            [mul encodeToCommandBuffer:command_buffer leftMatrix:mat_src1 rightMatrix:mat_src0 resultMatrix:mat_dst];
                        }
                    } else {
                        if (encoder == nil) {
                            encoder = [command_buffer computeCommandEncoder];
                        }

                        int nth0 = 32;
                        int nth1 = 1;

                        // use custom matrix x vector kernel
                        switch (src0t) {
                            case GGML_TYPE_Q4_0:
                                {
                                    GGML_ASSERT(ne02 == 1);
                                    GGML_ASSERT(ne12 == 1);

                                    nth0 = 8;
                                    nth1 = 4;
                                    [encoder setComputePipelineState:ctx->pipeline_mul_mat_q4_0_f32];
                                } break;
                            case GGML_TYPE_F16:
                                {
                                    GGML_ASSERT(ne02 == ne12);

                                    nth0 = 32;
                                    nth1 = 1;
                                    [encoder setComputePipelineState:ctx->pipeline_mul_mat_f16_f32];
                                } break;
                            default: GGML_ASSERT(false && "not implemented");
                        };


                        [encoder setBuffer:id_src0 offset:offs_src0 atIndex:0];
                        [encoder setBuffer:id_src1 offset:offs_src1 atIndex:1];
                        [encoder setBuffer:id_dst  offset:offs_dst  atIndex:2];
                        [encoder setBytes:&ne00 length:sizeof(ne00) atIndex:3];
                        [encoder setBytes:&ne01 length:sizeof(ne01) atIndex:4];
                        [encoder setBytes:&nb00 length:sizeof(nb00) atIndex:5];
                        [encoder setBytes:&nb01 length:sizeof(nb01) atIndex:6];
                        [encoder setBytes:&nb02 length:sizeof(nb02) atIndex:7];
                        [encoder setBytes:&ne10 length:sizeof(ne10) atIndex:8];
                        [encoder setBytes:&ne11 length:sizeof(ne11) atIndex:9];
                        [encoder setBytes:&nb10 length:sizeof(nb10) atIndex:10];
                        [encoder setBytes:&nb11 length:sizeof(nb11) atIndex:11];
                        [encoder setBytes:&nb12 length:sizeof(nb12) atIndex:12];
                        [encoder setBytes:&ne0  length:sizeof(ne0)  atIndex:13];
                        [encoder setBytes:&ne1  length:sizeof(ne1)  atIndex:14];

                        if (src0t == GGML_TYPE_Q4_0) {
                            [encoder setThreadgroupMemoryLength:nth0*nth1*sizeof(float) atIndex:0];
                            [encoder dispatchThreadgroups:MTLSizeMake(ne01, ne11, 1) threadsPerThreadgroup:MTLSizeMake(nth0, nth1, 1)];
                        } else {
                            [encoder setThreadgroupMemoryLength:nth0*sizeof(float) atIndex:0];
                            [encoder dispatchThreadgroups:MTLSizeMake(ne01, ne11, ne12) threadsPerThreadgroup:MTLSizeMake(nth0, nth1, 1)];
                        }
                    }
                } break;
            case GGML_OP_GET_ROWS:
                {
                    if (encoder == nil) {
                        encoder = [command_buffer computeCommandEncoder];
                    }

                    switch (src0->type) {
                        case GGML_TYPE_Q4_0: [encoder setComputePipelineState:ctx->pipeline_get_rows_q4_0]; break;
                        default: {
                                     // not implemented
                                     fprintf(stderr, "%s: node %3d, op = %8s, type = %8s not implemented\n", __func__, i, ggml_op_name(dst->op), ggml_type_name(src0->type));
                                 }
                    }

                    [encoder setBuffer:id_src0 offset:offs_src0 atIndex:0];
                    [encoder setBuffer:id_src1 offset:offs_src1 atIndex:1];
                    [encoder setBuffer:id_dst  offset:offs_dst  atIndex:2];
                    [encoder setBytes:&(src0->ne[0]) length:sizeof( int64_t) atIndex:3];
                    [encoder setBytes:&(src0->nb[1]) length:sizeof(uint64_t) atIndex:4];
                    [encoder setBytes:&(dst->nb[1])  length:sizeof(uint64_t) atIndex:5];

                    const int64_t n = ggml_nelements(src1);

                    [encoder dispatchThreadgroups:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                } break;
            case GGML_OP_RMS_NORM:
                {
                    if (encoder == nil) {
                        encoder = [command_buffer computeCommandEncoder];
                    }

                    const float eps = 1e-6f;

                    const int nth = 256;

                    [encoder setComputePipelineState:ctx->pipeline_rms_norm];
                    [encoder setBuffer:id_src0 offset:offs_src0 atIndex:0];
                    [encoder setBuffer:id_dst  offset:offs_dst  atIndex:1];
                    [encoder setBytes:&ne00 length:sizeof( int64_t) atIndex:2];
                    [encoder setBytes:&nb01 length:sizeof(uint64_t) atIndex:3];
                    [encoder setBytes:&eps  length:sizeof(   float) atIndex:4];
                    [encoder setThreadgroupMemoryLength:nth*sizeof(float) atIndex:0];

                    const int64_t nrows = ggml_nrows(src0);

                    [encoder dispatchThreadgroups:MTLSizeMake(nrows, 1, 1) threadsPerThreadgroup:MTLSizeMake(nth, 1, 1)];
                } break;
            case GGML_OP_ROPE:
                {
                    if (encoder == nil) {
                        encoder = [command_buffer computeCommandEncoder];
                    }

                    const int n_dims = ((int32_t *) src1->data)[1];
                    const int mode   = ((int32_t *) src1->data)[2];

                    //mtl_printf("rope: %lld x %lld x %lld x %lld\n", ne00, ne01, ne02, ne03);
                    //mtl_printf("rope: %lld x %lld x %lld x %lld\n", ne0,  ne1,  ne2,  ne3);
                    //mtl_printf("rope: n_past = %d, n_dims = %d, mode = %d\n", n_past, n_dims, mode);

                    [encoder setComputePipelineState:ctx->pipeline_rope];
                    [encoder setBuffer:id_src0 offset:offs_src0 atIndex:0];
                    [encoder setBuffer:id_dst  offset:offs_dst  atIndex:1];
                    [encoder setBytes:&ne00   length:sizeof( int64_t) atIndex:2];
                    [encoder setBytes:&ne01   length:sizeof( int64_t) atIndex:3];
                    [encoder setBytes:&ne02   length:sizeof( int64_t) atIndex:4];
                    [encoder setBytes:&ne03   length:sizeof( int64_t) atIndex:5];
                    [encoder setBytes:&nb00   length:sizeof(uint64_t) atIndex:6];
                    [encoder setBytes:&nb01   length:sizeof(uint64_t) atIndex:7];
                    [encoder setBytes:&nb02   length:sizeof(uint64_t) atIndex:8];
                    [encoder setBytes:&nb03   length:sizeof(uint64_t) atIndex:9];
                    [encoder setBytes:&ne0    length:sizeof( int64_t) atIndex:10];
                    [encoder setBytes:&ne1    length:sizeof( int64_t) atIndex:11];
                    [encoder setBytes:&ne2    length:sizeof( int64_t) atIndex:12];
                    [encoder setBytes:&ne3    length:sizeof( int64_t) atIndex:13];
                    [encoder setBytes:&nb0    length:sizeof(uint64_t) atIndex:14];
                    [encoder setBytes:&nb1    length:sizeof(uint64_t) atIndex:15];
                    [encoder setBytes:&nb2    length:sizeof(uint64_t) atIndex:16];
                    [encoder setBytes:&nb3    length:sizeof(uint64_t) atIndex:17];
                    [encoder setBytes:&n_past length:sizeof(     int) atIndex:18];
                    [encoder setBytes:&n_dims length:sizeof(     int) atIndex:19];
                    [encoder setBytes:&mode   length:sizeof(     int) atIndex:20];

                    [encoder dispatchThreadgroups:MTLSizeMake(ne01, ne02, ne03) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                } break;
            case GGML_OP_CPY:
                {
                    if (encoder == nil) {
                        encoder = [command_buffer computeCommandEncoder];
                    }

                    const int nth = 32;

                    //mtl_printf("cpy: %lld x %lld x %lld x %lld\n", ne00, ne01, ne02, ne03);
                    //mtl_printf("cpy: %lld x %lld x %lld x %lld\n", nb00, nb01, nb02, nb03);
                    //mtl_printf("cpy: %lld x %lld x %lld x %lld\n", ne0,  ne1,  ne2,  ne3);
                    //mtl_printf("cpy: %lld x %lld x %lld x %lld\n", nb0,  nb1,  nb2,  nb3);
                    //mtl_printf("cpy: %s -> %s\n", ggml_type_name(src0t), ggml_type_name(dstt));

                    switch (src0t) {
                        case GGML_TYPE_F32:
                            {
                                switch (dstt) {
                                    case GGML_TYPE_F16: [encoder setComputePipelineState:ctx->pipeline_cpy_f32_f16]; break;
                                    case GGML_TYPE_F32: [encoder setComputePipelineState:ctx->pipeline_cpy_f32_f32]; break;
                                    default: GGML_ASSERT(false && "not implemented");
                                };
                            } break;
                        default: GGML_ASSERT(false && "not implemented");
                    }

                    [encoder setBuffer:id_src0 offset:offs_src0 atIndex:0];
                    [encoder setBuffer:id_dst  offset:offs_dst  atIndex:1];
                    [encoder setBytes:&ne00 length:sizeof( int64_t) atIndex:2];
                    [encoder setBytes:&ne01 length:sizeof( int64_t) atIndex:3];
                    [encoder setBytes:&ne02 length:sizeof( int64_t) atIndex:4];
                    [encoder setBytes:&ne03 length:sizeof( int64_t) atIndex:5];
                    [encoder setBytes:&nb00 length:sizeof(uint64_t) atIndex:6];
                    [encoder setBytes:&nb01 length:sizeof(uint64_t) atIndex:7];
                    [encoder setBytes:&nb02 length:sizeof(uint64_t) atIndex:8];
                    [encoder setBytes:&nb03 length:sizeof(uint64_t) atIndex:9];
                    [encoder setBytes:&ne0  length:sizeof( int64_t) atIndex:10];
                    [encoder setBytes:&ne1  length:sizeof( int64_t) atIndex:11];
                    [encoder setBytes:&ne2  length:sizeof( int64_t) atIndex:12];
                    [encoder setBytes:&ne3  length:sizeof( int64_t) atIndex:13];
                    [encoder setBytes:&nb0  length:sizeof(uint64_t) atIndex:14];
                    [encoder setBytes:&nb1  length:sizeof(uint64_t) atIndex:15];
                    [encoder setBytes:&nb2  length:sizeof(uint64_t) atIndex:16];
                    [encoder setBytes:&nb3  length:sizeof(uint64_t) atIndex:17];

                    [encoder dispatchThreadgroups:MTLSizeMake(ne01, ne02, ne03) threadsPerThreadgroup:MTLSizeMake(nth, 1, 1)];
                } break;
            default:
                fprintf(stderr, "%s: node %3d, op = %8s not implemented\n", __func__, i, ggml_op_name(dst->op));
                GGML_ASSERT(false);
                return -1;
        }
    }

    // extract results from the GPU
    {
        mtl_printf("%s: extract results from the GPU\n", __func__);

        if (encoder != nil) {
            [encoder endEncoding];
            encoder = nil;
        }

        struct ggml_tensor * out = gf->nodes[gf->n_nodes - 1];

        id<MTLBuffer> id_src = llama_mtl_get_buffer(ctx, out, &offs_src0);
        id<MTLBuffer> id_dst = ctx->out;

        id<MTLBlitCommandEncoder> encoder_blit = [command_buffer blitCommandEncoder];
        [encoder_blit copyFromBuffer:id_src sourceOffset:offs_src0 toBuffer:id_dst destinationOffset:0 size:ggml_nbytes(out)];
        [encoder_blit endEncoding];
    }

    [command_buffer commit];
    [command_buffer waitUntilCompleted];

    {
        const double time_elapsed = [command_buffer GPUEndTime] - [command_buffer GPUStartTime];
        mtl_printf("%s: time elapsed = %f ms\n", __func__, time_elapsed * 1000.0);
    }

    ctx->logits = ctx->out.contents;

    const float * logits = ctx->logits;

    struct ggml_tensor * t = gf->nodes[gf->n_nodes - 1];
    memcpy(t->data, logits, ggml_nbytes(t));

#if 1
    mtl_printf("logits: ");
    for (int i = 0; i < 100; i++) {
        mtl_printf("%8.4f ", logits[i]);
    }
    mtl_printf("\n");
    double sum = 0.0;
    int imax = 0;
    double vmax = -INFINITY;
    for (int i = 0; i < 32000; i++) {
        sum += (double) logits[i];
        if (logits[i] > vmax) {
            vmax = logits[i];
            imax = i;
        }
    }
    mtl_printf("sum: %f, imax = %d, vmax = %f\n", sum, imax, vmax);
#endif

    //{
    //    struct ggml_tensor * t = ggml_get_tensor(ctx->ctx_eval, "mtl-check");
    //    if (t->type == GGML_TYPE_F32) {
    //        const const float * data = (float *) ctx->out.contents;
    //        printf("data: ");
    //        for (int i = 0; i < (int) t->ne[0]; i++) {
    //            printf("%f ", data[i]);
    //        }
    //        printf("\n");
    //        double sum = 0.0;
    //        for (int i = 0; i < ggml_nelements(t); i++) {
    //            double cur = data[i];
    //            if (isinf(cur)) continue;
    //            sum += cur;
    //        }
    //        printf("sum:  %f\n", sum);
    //    } else if (t->type == GGML_TYPE_F16) {
    //        ggml_fp16_t * data = (const ggml_fp16_t *) ctx->out.contents;
    //        printf("data: ");
    //        for (int i = 0; i < (int) t->ne[0]; i++) {
    //            printf("%f ", ggml_fp16_to_fp32(data[i]));
    //        }
    //        printf("\n");
    //        double sum = 0.0;
    //        printf("nb: %lld %lld %lld %lld\n", t->nb[0], t->nb[1], t->nb[2], t->nb[3]);
    //        for (int64_t i3 = 0; i3 < t->ne[3]; ++i3) {
    //            for (int64_t i2 = 0; i2 < t->ne[2]; ++i2) {
    //                for (int64_t i1 = 0; i1 < t->ne[1]; ++i1) {
    //                    for (int64_t i0 = 0; i0 < t->ne[0]; ++i0) {
    //                        const size_t offs = i3*t->nb[3] + i2*t->nb[2] + i1*t->nb[1] + i0*t->nb[0];
    //                        const ggml_fp16_t cur = *((ggml_fp16_t *)((char *) data + offs));
    //                        const float curf = ggml_fp16_to_fp32(cur);
    //                        if (isinf(curf)) continue;
    //                        sum += curf;
    //                    }
    //                }
    //            }
    //        }
    //        printf("sum:  %f\n", sum);
    //    } else {
    //        GGML_ASSERT(false && "not implemented");
    //    }
    //}

    return 0;
}

float * llama_mtl_get_logits(struct ggml_mtl_context * ctx) {
    return ctx->logits;
}

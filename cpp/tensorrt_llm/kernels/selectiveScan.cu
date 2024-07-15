/*
 * Copyright (c) 2020-2023, NVIDIA CORPORATION.  All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <cuda_runtime_api.h>

#include <cooperative_groups/memcpy_async.h>
#include <cuda/pipeline>

#include <cuda_bf16.h>
#include <cuda_fp16.h>

#ifdef ENABLE_FP8
#include <cuda_fp8.h>
#endif

#include "selectiveScan.h"

#include "chunkScan/bmmchunk.h"
#include "chunkScan/chunkcumsum.h"
#include "chunkScan/chunkscan.h"
#include "chunkScan/chunkstate.h"
#include "chunkScan/statepassing.h"

namespace tensorrt_llm
{
namespace kernels
{

__device__ float toFloat(float f)
{
    return f;
}

__device__ float toFloat(__half h)
{
    return __half2float(h);
}
#ifdef ENABLE_BF16
__device__ float toFloat(__nv_bfloat16 val)
{
    return __bfloat162float(val);
}
#endif

__device__ void convertAndStore(float* output, float input)
{
    *output = input;
}

__device__ void convertAndStore(__half* output, float input)
{
    *output = __float2half(input);
}
#ifdef ENABLE_BF16
__device__ void convertAndStore(__nv_bfloat16* output, float input)
{
    *output = __float2bfloat16(input);
}
#endif

#pragma nv_diag_suppress static_var_with_dynamic_init

template <typename input_t, typename weight_t, int DSTATE = 16, int CHANNELS_PER_BLOCK = 128, int STAGES = 12,
    int SEQ_UNROLL = 6>
__launch_bounds__(256, 1) __global__ void selective_scan_loop_kernel(SSMParamsBase params)
{
    input_t* output = reinterpret_cast<input_t*>(params.out_ptr);
    input_t* state = reinterpret_cast<input_t*>(params.x_ptr);
    input_t* x = reinterpret_cast<input_t*>(params.u_ptr);
    input_t* dt = reinterpret_cast<input_t*>(params.delta_ptr);
    weight_t* A = reinterpret_cast<weight_t*>(params.A_ptr);
    input_t* B = reinterpret_cast<input_t*>(params.BC_ptr);
    input_t* C = reinterpret_cast<input_t*>(params.BC_ptr);
    weight_t* D = reinterpret_cast<weight_t*>(params.D_ptr);
    input_t* z = reinterpret_cast<input_t*>(params.z_ptr);
    weight_t* dt_bias = reinterpret_cast<weight_t*>(params.delta_bias_ptr);
    bool dt_softplus = params.delta_softplus;
    int num_channels = params.dim;

    __shared__ cuda::pipeline_shared_state<cuda::thread_scope::thread_scope_block, STAGES / SEQ_UNROLL> pipeline_state;
    auto block = cooperative_groups::this_thread_block();

    __shared__ __align__(16) input_t sh_B[STAGES][DSTATE];
    __shared__ __align__(16) input_t sh_C[STAGES][DSTATE];

    __shared__ __align__(128) input_t sh_dt[STAGES][CHANNELS_PER_BLOCK];
    __shared__ input_t sh_x[STAGES][CHANNELS_PER_BLOCK];
    __shared__ input_t sh_z[STAGES][CHANNELS_PER_BLOCK];

    int const channel = blockIdx.x * blockDim.x + threadIdx.x;
    int const sample = blockIdx.y; // batch id

    int const slot_idx = params.slot_mapping_ptr == nullptr ? sample : params.slot_mapping_ptr[sample];
    int const bc_cols = DSTATE * 2 + params.dt_rank;
    int const b_offset = params.dt_rank;
    int const c_offset = params.dt_rank + DSTATE;

    int num_tokens;
    int start_token_idx;
    if (params.remove_padding)
    {
        start_token_idx = sample == 0 ? 0 : params.last_token_ids_ptr[sample - 1];
        int end_token_idx = params.last_token_ids_ptr[sample];
        num_tokens = end_token_idx - start_token_idx;
    }
    else
    {
        start_token_idx = sample * params.max_seqlen;
        num_tokens = params.last_token_ids_ptr[sample];
    }
    int const seq_loops = (num_tokens + SEQ_UNROLL - 1) / SEQ_UNROLL;

    int const input_matrix_row_id = start_token_idx;

    if (threadIdx.y == 1)
    {
        cuda::pipeline pipeline = cuda::make_pipeline(block, &pipeline_state, cuda::pipeline_role::producer);

        int stage = 0;
        for (int si = 0; si < seq_loops; si++)
        {

            pipeline.producer_acquire();

#pragma unroll
            for (int token_id = si * SEQ_UNROLL; token_id < num_tokens && token_id < (si + 1) * SEQ_UNROLL; token_id++)
            {

                input_t* my_B = &B[(input_matrix_row_id + token_id) * bc_cols + b_offset];
                input_t* my_C = &C[(input_matrix_row_id + token_id) * bc_cols + c_offset];

                int block_channel_per_token = blockIdx.x * blockDim.x;
                int block_channel
                    = input_matrix_row_id * num_channels + token_id * num_channels + block_channel_per_token;

                if (threadIdx.x < DSTATE)
                    cuda::memcpy_async(&sh_B[stage][threadIdx.x], &my_B[threadIdx.x], sizeof(input_t), pipeline);
                else if (threadIdx.x >= 32 && threadIdx.x < 32 + DSTATE)
                    cuda::memcpy_async(
                        &sh_C[stage][threadIdx.x - 32], &my_C[threadIdx.x - 32], sizeof(input_t), pipeline);
                if (sizeof(input_t) == 4)
                {
                    cuda::memcpy_async(&sh_dt[stage][threadIdx.x],
                        &dt[input_matrix_row_id * num_channels + token_id * num_channels + channel], sizeof(input_t),
                        pipeline);
                    cuda::memcpy_async(&sh_x[stage][threadIdx.x],
                        &x[input_matrix_row_id * num_channels + token_id * num_channels + channel], sizeof(input_t),
                        pipeline);
                    if (z)
                        cuda::memcpy_async(&sh_z[stage][threadIdx.x],
                            &z[input_matrix_row_id * num_channels + token_id * num_channels + channel], sizeof(input_t),
                            pipeline);
                }
                else
                {
                    // sh_dt[stage][threadIdx.x] = dt[block_channel + threadIdx.x];
                    if (threadIdx.x < 32)
                    {
                        int tid = threadIdx.x;
                        float2* block_dt = (float2*) &dt[block_channel];
                        cuda::memcpy_async((float2*) &sh_dt[stage][tid * 4], &block_dt[tid], sizeof(float2), pipeline);
                    }
                    // sh_x[stage][threadIdx.x] = x[block_channel + threadIdx.x];
                    else if (threadIdx.x < 64)
                    {
                        int tid = threadIdx.x - 32;
                        float2* block_x = (float2*) &x[block_channel];
                        cuda::memcpy_async((float2*) &sh_x[stage][tid * 4], &block_x[tid], sizeof(float2), pipeline);
                    }
                    // sh_z[stage][threadIdx.x] = z[block_channel + threadIdx.x];
                    else if (threadIdx.x < 96)
                    {
                        int tid = threadIdx.x - 64;
                        if (z)
                        {
                            float2* block_z = (float2*) &z[block_channel];
                            cuda::memcpy_async(
                                (float2*) &sh_z[stage][tid * 4], &block_z[tid], sizeof(float2), pipeline);
                        }
                    }
                    else
                    {
                    }
                }

                stage++;
                if (stage >= STAGES)
                    stage = 0;
            }
            pipeline.producer_commit();
        }
    }
    else
    {

        // Compute warps
        // Load state and A matrix into registers
        float state_reg[DSTATE];
        float A_reg[DSTATE];
        for (int i = 0; i < DSTATE; i++)
        {
            state_reg[i] = 0.f;
            A_reg[i] = toFloat(A[i * num_channels + channel]);
        }
        float dt_bias_reg = dt_bias[channel];
        float D_reg = D ? D[channel] : 0.f;

        cuda::pipeline pipeline = cuda::make_pipeline(block, &pipeline_state, cuda::pipeline_role::consumer);
        int stage = 0;
        for (int si = 0; si < seq_loops; si++)
        {

            pipeline.consumer_wait();

#pragma unroll
            for (int token_id = si * SEQ_UNROLL; token_id < num_tokens && token_id < (si + 1) * SEQ_UNROLL; token_id++)
            {

                float dt_b = toFloat(sh_dt[stage][threadIdx.x]) + dt_bias_reg;
                float dt_b_sp;
                if (dt_softplus)
                {
                    dt_b_sp = dt_b <= 20.f ? __logf(1.f + __expf(dt_b)) : dt_b; // softplus
                }
                float my_x = toFloat(sh_x[stage][threadIdx.x]);
                float Dx = my_x * D_reg;
                float dtx = dt_b_sp * my_x;
                float my_z = z ? toFloat(sh_z[stage][threadIdx.x]) : 0.f;

                float out = Dx;

                if (sizeof(input_t) == 4)
                {
                    float4* B4 = (float4*) &sh_B[stage][0];
                    float4* C4 = (float4*) &sh_C[stage][0];
#pragma unroll
                    for (int i = 0; i < DSTATE / 4; i++)
                    {

                        float4 Bi4 = B4[i];
                        float4 Ci4 = C4[i];

                        float* Bi = (float*) &Bi4;
                        float* Ci = (float*) &Ci4;

#pragma unroll
                        for (int j = 0; j < 4; j++)
                        {
                            float dtA = A_reg[i * 4 + j] * dt_b_sp;
                            float dA = __expf(dtA);
                            float sdA = state_reg[i * 4 + j] * dA;
                            float dBx = Bi[j] * dtx;
                            float newState = sdA + dBx;
                            state_reg[i * 4 + j] = newState;
                            out += newState * Ci[j];
                        }
                    }
                }
                else
                {
                    float4* B8 = (float4*) &sh_B[stage][0];
                    float4* C8 = (float4*) &sh_C[stage][0];
#pragma unroll
                    for (int i = 0; i < DSTATE / 8; i++)
                    {
                        input_t* Bi = (input_t*) (&B8[i]);
                        input_t* Ci = (input_t*) (&C8[i]);
#pragma unroll
                        for (int j = 0; j < 8; j++)
                        {
                            float dtA = A_reg[i * 8 + j] * dt_b_sp;
                            float dA = __expf(dtA);
                            float sdA = state_reg[i * 8 + j] * dA;
                            float dBx = toFloat(Bi[j]) * dtx;
                            float newState = sdA + dBx;
                            state_reg[i * 8 + j] = newState;
                            out += newState * toFloat(Ci[j]);
                        }
                    }
                }

                if (z)
                {
                    float enz = __expf(0.f - my_z);
                    enz += 1.0;
                    float sig_z = __fdividef(1.f, enz);
                    float silu_z = my_z * sig_z;
                    out *= silu_z;
                }
                input_t* my_output = &output[input_matrix_row_id * num_channels + token_id * num_channels];
                convertAndStore(&my_output[channel], out);

                stage++;
                if (stage >= STAGES)
                    stage = 0;
            }
            pipeline.consumer_release();
        }
        // Write the new state back out to the cache
        for (int i = 0; i < DSTATE; i++)
        {
            input_t* my_state = &state[slot_idx * num_channels * DSTATE];
            int offset = i * num_channels + channel;
            convertAndStore(&my_state[offset], state_reg[i]);
        }
    }
}

template <typename input_t, typename weight_t>
void invokeSelectiveScan(SSMParamsBase& params, cudaStream_t stream)
{
    int samples = params.batch;
    int channels = params.dim;

    TLLM_CHECK(params.dstate == 16);

    int const threads = 128;
    int const blocks = (channels + threads - 1) / threads;
    dim3 block(threads, 2);
    dim3 grid(blocks, samples);
    TLLM_CHECK((channels % block.x) == 0);
    selective_scan_loop_kernel<input_t, weight_t><<<grid, block, 0, stream>>>(params);
}

template <typename input_t, typename weight_t>
void invokeChunkScan(SSMParamsBase& params, cudaStream_t stream)
{
    int B = params.batch;
    int L = params.max_seqlen;
    int H = params.nheads;
    int P = params.dim / H;
    int G = params.ngroups;
    int N = params.dstate;
    int Q = params.chunk_size;

    bool dtsp = params.delta_softplus;

    if constexpr (std::is_same_v<input_t, half>)
    {
        dim3 bds[5], tds[5];
        int shms[5];

        ChunkCumsumKernelFuncFp16 chunk_cumsum = getChunkCumsumKernelFp16(B, L, H, Q, dtsp, &bds[0], &tds[0], &shms[0]);
        ChunkStateKernelFuncFp16 chunk_state = getChunkStateKernelFp16(B, L, H, P, G, N, Q, &bds[1], &tds[1], &shms[1]);
        StatePassingKernelFuncFp16 state_passing
            = getStatePassingKernelFp16(B, L, H, P, N, Q, &bds[2], &tds[2], &shms[2]);
        BmmChunkKernelFuncFp16 bmm_chunk = getBmmChunkKernelFp16(B, L, G, N, Q, &bds[3], &tds[3], &shms[3]);
        ChunkScanKernelFuncFp16 chunk_scan = getChunkScanKernelFp16(B, L, H, P, G, N, Q, &bds[4], &tds[4], &shms[4]);

        half* mxY = (half*) params.out_ptr;
        half* mxOs = (half*) params.Os_ptr;
        half* mxFs = (half*) params.x_ptr;
        float* mxSt = (float*) params.St_ptr;
        float* mxdc = (float*) params.dc_ptr;
        float* mxdA = (float*) params.dA_ptr;
        half const* mxdt = (half const*) params.delta_ptr;
        float const* mxdb = (float const*) params.delta_bias_ptr;
        float const* mxA = (float const*) params.A_ptr;
        half* mxCB = (half*) params.CB_ptr;
        half const* mxBC = (half const*) params.BC_ptr;
        float const* mxD = (float const*) params.D_ptr;
        half const* mxX = (half const*) params.u_ptr;
        half const* mxZ = (half const*) params.z_ptr;

        auto rp = params.remove_padding;
        auto ltip = params.last_token_ids_ptr;
        auto ssmp = params.slot_mapping_ptr;

        cudaFuncSetAttribute(chunk_cumsum, cudaFuncAttributeMaxDynamicSharedMemorySize, shms[0]);
        chunk_cumsum<<<bds[0], tds[0], shms[0], stream>>>(B, L, H, mxdc, mxdA, mxdt, mxdb, mxA, rp, ltip);
        cudaFuncSetAttribute(chunk_state, cudaFuncAttributeMaxDynamicSharedMemorySize, shms[1]);
        chunk_state<<<bds[1], tds[1], shms[1], stream>>>(B, L, H, P, G, N, mxSt, mxdc, mxdA, mxBC, mxX, rp, ltip);
        cudaFuncSetAttribute(state_passing, cudaFuncAttributeMaxDynamicSharedMemorySize, shms[2]);
        state_passing<<<bds[2], tds[2], shms[2], stream>>>(B, L, H, P, N, mxOs, mxFs, mxSt, mxdA, rp, ltip, ssmp);
        cudaFuncSetAttribute(bmm_chunk, cudaFuncAttributeMaxDynamicSharedMemorySize, shms[3]);
        bmm_chunk<<<bds[3], tds[3], shms[3], stream>>>(B, L, G, N, mxCB, mxBC, rp, ltip);
        cudaFuncSetAttribute(chunk_scan, cudaFuncAttributeMaxDynamicSharedMemorySize, shms[4]);
        chunk_scan<<<bds[4], tds[4], shms[4], stream>>>(
            B, L, H, P, G, N, mxY, mxOs, mxdc, mxdA, mxCB, mxBC, mxD, mxX, mxZ, rp, ltip);
    }
    else if constexpr (std::is_same_v<input_t, __nv_bfloat16>)
    {
        dim3 bds[5], tds[5];
        int shms[5];

        ChunkCumsumKernelFuncBf16 chunk_cumsum = getChunkCumsumKernelBf16(B, L, H, Q, dtsp, &bds[0], &tds[0], &shms[0]);
        ChunkStateKernelFuncBf16 chunk_state = getChunkStateKernelBf16(B, L, H, P, G, N, Q, &bds[1], &tds[1], &shms[1]);
        StatePassingKernelFuncBf16 state_passing
            = getStatePassingKernelBf16(B, L, H, P, N, Q, &bds[2], &tds[2], &shms[2]);
        BmmChunkKernelFuncBf16 bmm_chunk = getBmmChunkKernelBf16(B, L, G, N, Q, &bds[3], &tds[3], &shms[3]);
        ChunkScanKernelFuncBf16 chunk_scan = getChunkScanKernelBf16(B, L, H, P, G, N, Q, &bds[4], &tds[4], &shms[4]);

        __nv_bfloat16* mxY = (__nv_bfloat16*) params.out_ptr;
        __nv_bfloat16* mxOs = (__nv_bfloat16*) params.Os_ptr;
        __nv_bfloat16* mxFs = (__nv_bfloat16*) params.x_ptr;
        float* mxSt = (float*) params.St_ptr;
        float* mxdc = (float*) params.dc_ptr;
        float* mxdA = (float*) params.dA_ptr;
        __nv_bfloat16 const* mxdt = (__nv_bfloat16 const*) params.delta_ptr;
        float const* mxdb = (float const*) params.delta_bias_ptr;
        float const* mxA = (float const*) params.A_ptr;
        __nv_bfloat16* mxCB = (__nv_bfloat16*) params.CB_ptr;
        __nv_bfloat16 const* mxBC = (__nv_bfloat16 const*) params.BC_ptr;
        float const* mxD = (float const*) params.D_ptr;
        __nv_bfloat16 const* mxX = (__nv_bfloat16 const*) params.u_ptr;
        __nv_bfloat16 const* mxZ = (__nv_bfloat16 const*) params.z_ptr;

        auto rp = params.remove_padding;
        auto ltip = params.last_token_ids_ptr;
        auto ssmp = params.slot_mapping_ptr;

        cudaFuncSetAttribute(chunk_cumsum, cudaFuncAttributeMaxDynamicSharedMemorySize, shms[0]);
        chunk_cumsum<<<bds[0], tds[0], shms[0], stream>>>(B, L, H, mxdc, mxdA, mxdt, mxdb, mxA, rp, ltip);
        cudaFuncSetAttribute(chunk_state, cudaFuncAttributeMaxDynamicSharedMemorySize, shms[1]);
        chunk_state<<<bds[1], tds[1], shms[1], stream>>>(B, L, H, P, G, N, mxSt, mxdc, mxdA, mxBC, mxX, rp, ltip);
        cudaFuncSetAttribute(state_passing, cudaFuncAttributeMaxDynamicSharedMemorySize, shms[2]);
        state_passing<<<bds[2], tds[2], shms[2], stream>>>(B, L, H, P, N, mxOs, mxFs, mxSt, mxdA, rp, ltip, ssmp);
        cudaFuncSetAttribute(bmm_chunk, cudaFuncAttributeMaxDynamicSharedMemorySize, shms[3]);
        bmm_chunk<<<bds[3], tds[3], shms[3], stream>>>(B, L, G, N, mxCB, mxBC, rp, ltip);
        cudaFuncSetAttribute(chunk_scan, cudaFuncAttributeMaxDynamicSharedMemorySize, shms[4]);
        chunk_scan<<<bds[4], tds[4], shms[4], stream>>>(
            B, L, H, P, G, N, mxY, mxOs, mxdc, mxdA, mxCB, mxBC, mxD, mxX, mxZ, rp, ltip);
    }
}

#define INSTANTIATE_SELECTIVE_SCAN_DATA_TYPE(input_t, weight_t)                                                        \
    template void invokeSelectiveScan<input_t, weight_t>(SSMParamsBase & params, cudaStream_t stream);

INSTANTIATE_SELECTIVE_SCAN_DATA_TYPE(float, float);
INSTANTIATE_SELECTIVE_SCAN_DATA_TYPE(half, float);
#ifdef ENABLE_BF16
INSTANTIATE_SELECTIVE_SCAN_DATA_TYPE(__nv_bfloat16, float);
#endif
#undef INSTANTIATE_SELECTIVE_SCAN_DATA_TYPE

#define INSTANTIATE_CHUNK_SCAN_DATA_TYPE(input_t, weight_t)                                                            \
    template void invokeChunkScan<input_t, weight_t>(SSMParamsBase & params, cudaStream_t stream);

INSTANTIATE_CHUNK_SCAN_DATA_TYPE(float, float);
INSTANTIATE_CHUNK_SCAN_DATA_TYPE(half, float);
#ifdef ENABLE_BF16
INSTANTIATE_CHUNK_SCAN_DATA_TYPE(__nv_bfloat16, float);
#endif
#undef INSTANTIATE_CHUNK_SCAN_DATA_TYPE

////////////////////////////////////////////////////////////////////////////////////////////////////

template <typename input_t, typename weight_t, int DSTATE = 16, int CHANNELS_PER_BLOCK = 128, bool MAMBA_V1 = true>
__launch_bounds__(128, 2) __global__ void selective_scan_update_kernel(SSMParamsBase params)
{

    input_t* output = reinterpret_cast<input_t*>(params.out_ptr);
    input_t* state = reinterpret_cast<input_t*>(params.x_ptr);
    input_t* x = reinterpret_cast<input_t*>(params.u_ptr);
    input_t* dt = reinterpret_cast<input_t*>(params.delta_ptr);
    weight_t* A = reinterpret_cast<weight_t*>(params.A_ptr);
    input_t* B = reinterpret_cast<input_t*>(params.BC_ptr);
    input_t* C = reinterpret_cast<input_t*>(params.BC_ptr);
    weight_t* D = reinterpret_cast<weight_t*>(params.D_ptr);
    input_t* z = reinterpret_cast<input_t*>(params.z_ptr);
    weight_t* dt_bias = reinterpret_cast<weight_t*>(params.delta_bias_ptr);
    bool dt_softplus = params.delta_softplus;
    int num_channels = params.dim;
    int nheads = params.nheads;
    int ngroups = params.ngroups;

    int const channel = blockIdx.x * blockDim.x + threadIdx.x;
    if (channel >= num_channels)
        return;
    int const sample = blockIdx.y;
    int const head_dim = num_channels / nheads;
    int const head = channel / head_dim;
    int const head_chl = channel % head_dim;
    int const group = head / (nheads / ngroups);
    int const slot_idx = params.slot_mapping_ptr == nullptr ? sample : params.slot_mapping_ptr[sample];
    int const bc_offset = MAMBA_V1 ? sample * (DSTATE * 2 + params.dt_rank) : sample * DSTATE * ngroups * 2;
    int const b_offset = MAMBA_V1 ? params.dt_rank : DSTATE * group;
    int const c_offset = MAMBA_V1 ? params.dt_rank + DSTATE : DSTATE * (ngroups + group);

    input_t* my_state = &state[slot_idx * num_channels * DSTATE];
    input_t* my_output = &output[sample * num_channels];

    float rA[DSTATE];
    float rB[DSTATE];
    float rC[DSTATE];
    float rState[DSTATE];
    float my_x, my_dt, my_z, my_dt_bias, my_D;
    my_x = toFloat(x[sample * num_channels + channel]);
    my_z = z ? toFloat(z[sample * num_channels + channel]) : 0.f;

    if (MAMBA_V1)
    {
#pragma unroll
        for (int i = 0; i < DSTATE; i++)
        {
            rA[i] = toFloat(A[i * num_channels + channel]);
            rB[i] = toFloat(B[bc_offset + b_offset + i]);
            rC[i] = toFloat(C[bc_offset + c_offset + i]);
            rState[i] = toFloat(my_state[i * num_channels + channel]);
        }
        my_dt = toFloat(dt[sample * num_channels + channel]);
        my_dt_bias = dt_bias ? toFloat(dt_bias[channel]) : 0.f;
        my_D = D ? toFloat(D[channel]) : 0.f;
    }
    else
    {
        float A_tmp = toFloat(A[head]);
#pragma unroll
        for (int i = 0; i < DSTATE; i++)
        {
            rA[i] = A_tmp;
            rB[i] = toFloat(B[bc_offset + b_offset + i]);
            rC[i] = toFloat(C[bc_offset + c_offset + i]);
            rState[i] = toFloat(my_state[(head * DSTATE + i) * head_dim + head_chl]);
        }
        my_dt = toFloat(dt[sample * nheads + head]);
        my_dt_bias = dt_bias ? toFloat(dt_bias[head]) : 0.f;
        my_D = D ? toFloat(D[head]) : 0.f;
    }

    float dt_b = my_dt + my_dt_bias;
    float dt_b_sp;
    if (dt_softplus)
    {
        dt_b_sp = dt_b <= 20.f ? __logf(1.f + __expf(dt_b)) : dt_b; // softplus
    }

    float out = D ? my_D * my_x : 0.f;

#pragma unroll
    for (int i = 0; i < DSTATE; i++)
    {
        float dA = __expf(rA[i] * dt_b_sp);
        float dB = rB[i] * dt_b_sp;
        float sdA = rState[i] * dA;
        float dBx = dB * my_x;
        float newState = sdA + dBx;
        // Write the new state back out to the cache
        if (MAMBA_V1)
            convertAndStore(&my_state[i * num_channels + channel], newState);
        else
            convertAndStore(&my_state[(head * DSTATE + i) * head_dim + head_chl], newState);
        out += newState * rC[i];
    }

    if (z)
    {
        float sig_z = __fdividef(1.f, (1.f + __expf(0.f - my_z)));
        float silu_z = my_z * sig_z;
        out *= silu_z;
    }

    convertAndStore(&my_output[channel], out);
}

template <typename input_t, typename weight_t>
void invokeSelectiveScanUpdate(SSMParamsBase& params, cudaStream_t stream)
{
    int samples = params.batch;
    int channels = params.dim;
    int nheads = params.nheads;
    int ngroups = params.ngroups;

    int const threads = 128;
    int const blocks = (channels + threads - 1) / threads;
    dim3 block(threads, 1);
    dim3 grid(blocks, samples);

    TLLM_CHECK_WITH_INFO(nheads % ngroups == 0, "nheads must be divisible by ngroups");
    if (params.is_mamab2)
    {
        TLLM_CHECK(params.dstate == 128);
        selective_scan_update_kernel<input_t, weight_t, 128, 128, false><<<grid, block, 0, stream>>>(params);
    }
    else
    {
        TLLM_CHECK(params.dstate == 16);
        selective_scan_update_kernel<input_t, weight_t, 16, 128, true><<<grid, block, 0, stream>>>(params);
    }
}

#define INSTANTIATE_SELECTIVE_SCAN_UPDATE_DATA_TYPE(input_t, weight_t)                                                 \
    template void invokeSelectiveScanUpdate<input_t, weight_t>(SSMParamsBase & params, cudaStream_t stream)

INSTANTIATE_SELECTIVE_SCAN_UPDATE_DATA_TYPE(float, float);
INSTANTIATE_SELECTIVE_SCAN_UPDATE_DATA_TYPE(half, float);
#ifdef ENABLE_BF16
INSTANTIATE_SELECTIVE_SCAN_UPDATE_DATA_TYPE(__nv_bfloat16, float);
#endif
#undef INSTANTIATE_SELECTIVE_SCAN_UPDATE_DATA_TYPE

} // namespace kernels
} // namespace tensorrt_llm

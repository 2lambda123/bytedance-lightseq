#include <cub/block/block_load.cuh>
#include <cub/block/block_scan.cuh>
#include <cub/block/block_store.cuh>

#include "kernels.h"

using namespace cub;

/**
@brief: transform_0213
Split the attention heads and reshape input
during backward progress of encoder self-attention

@thread
gridDim.x = batch_size
gridDim.y = seq_len
blockDim.x = min(hidden_dim, MAX_THREADS)

@param
input: [batch_size, seq_len, hidden_dim]
output: [batch_size, nhead, seq_len, head_dim]
batch_size: the size of the current batch
seq_len: the sequence length of the current batch
hidden_dim: dim of the hidden tensor
nhead: number of attention heads
*/

template <typename T>
__global__ void transform_0213(T *output, const T *input, int hidden_dim,
                               int head_dim);

template <>
__global__ void transform_0213<float>(float *output, const float *input,
                                      int hidden_dim, int head_dim) {
  int batch_id = blockIdx.x;
  int token_id = blockIdx.y;
  int seq_len = gridDim.y;
  int nhead = hidden_dim / head_dim;

  // [b, s, h]
  int src_offset = flat_3dim(batch_id, token_id, 0, seq_len, hidden_dim);
  // [b, nh, s, ad]
  int trg_offset =
      flat_4dim(batch_id, 0, token_id, 0, nhead, seq_len, head_dim);

  const float4 *input4 = reinterpret_cast<const float4 *>(input);
  float4 *res4 = reinterpret_cast<float4 *>(output);
  float4 vinput4;

  for (std::size_t i = threadIdx.x; i < hidden_dim; i += blockDim.x) {
    vinput4 = input4[src_offset + i];

    int head_id = i / head_dim;
    int dim_id = i % head_dim;
    int cur_trg_offset = flat_3dim(head_id, 0, dim_id, seq_len, head_dim);
    res4[trg_offset + cur_trg_offset] = vinput4;
  }
}

template <>
__global__ void transform_0213<__half>(__half *output, const __half *input,
                                       int hidden_dim, int head_dim) {
  int batch_id = blockIdx.x;
  int token_id = blockIdx.y;
  int seq_len = gridDim.y;
  int nhead = hidden_dim / head_dim;

  // [b, s, h]
  int src_offset = flat_3dim(batch_id, token_id, 0, seq_len, hidden_dim);
  // [b, nh, s, ad]
  int trg_offset =
      flat_4dim(batch_id, 0, token_id, 0, nhead, seq_len, head_dim);

  const float4 *input4 = reinterpret_cast<const float4 *>(input);
  float4 *res4 = reinterpret_cast<float4 *>(output);
  float4 vinput4;

  for (std::size_t i = threadIdx.x; i < hidden_dim; i += blockDim.x) {
    vinput4 = input4[src_offset + i];

    int head_id = i / head_dim;
    int dim_id = i % head_dim;
    int cur_trg_offset = flat_3dim(head_id, 0, dim_id, seq_len, head_dim);
    res4[trg_offset + cur_trg_offset] = vinput4;
  }
}

// [b, s, h] -> [b, nh, s, ad]
template <>
void launch_transform_0213<float>(float *output, const float *input,
                                  int batch_size, int seq_len, int hidden_dim,
                                  int nhead, cudaStream_t stream) {
  hidden_dim >>= 2;
  int head_dim = hidden_dim / nhead;

  dim3 grid_dim(batch_size, seq_len);
  dim3 block_dim(min(hidden_dim, MAX_THREADS));

  transform_0213<float>
      <<<grid_dim, block_dim, 0, stream>>>(output, input, hidden_dim, head_dim);
}

template <>
void launch_transform_0213<__half>(__half *output, const __half *input,
                                   int batch_size, int seq_len, int hidden_dim,
                                   int nhead, cudaStream_t stream) {
  hidden_dim >>= 3;
  int head_dim = hidden_dim / nhead;

  dim3 grid_dim(batch_size, seq_len);
  dim3 block_dim(min(hidden_dim, MAX_THREADS));

  transform_0213<__half>
      <<<grid_dim, block_dim, 0, stream>>>(output, input, hidden_dim, head_dim);
}

/**
@brief: bias_add_transform_20314
Add bias to input, transform from
[0, 1, 2, 3, 4] to [2, 0, 3, 1, 4]

@thread
gridDim.x = dim_0
gridDim.y = dim_1
gridDim.z = dim_2
blockDim.x = min(dim_3 * dim_4, MAX_THREADS)

@param
input: [dim_0, dim_1, dim_2, dim_3, dim_4]
bias: [dim_2, dim_3, dim_4]
output: [dim_2, dim_0, dim_3, dim_1, dim_4]
*/
template <typename T>
__global__ void bias_add_transform_20314(T *output, const T *input,
                                         const T *bias, int dim_3, int dim_4);

template <>
__global__ void bias_add_transform_20314<float>(float *output,
                                                const float *input,
                                                const float *bias, int dim_3,
                                                int dim_4) {
  int id0 = blockIdx.x;
  int id1 = blockIdx.y;
  int id2 = blockIdx.z;
  int dim_0 = gridDim.x;
  int dim_1 = gridDim.y;
  int dim_2 = gridDim.z;
  int dim_34 = dim_3 * dim_4;

  int src_offset = flat_4dim(id0, id1, id2, 0, dim_1, dim_2, dim_34);
  int trg_offset = flat_5dim(id2, id0, 0, id1, 0, dim_0, dim_3, dim_1, dim_4);
  int bias_offset = flat_2dim(id2, 0, dim_34);

  const float4 *qkv4 = reinterpret_cast<const float4 *>(input);
  const float4 *bias4 = reinterpret_cast<const float4 *>(bias);
  float4 *res4 = reinterpret_cast<float4 *>(output);
  float4 vqkv4;
  float4 vbias4;
  float4 vres4;

  for (std::size_t i = threadIdx.x; i < dim_34; i += blockDim.x) {
    vqkv4 = qkv4[src_offset + i];
    vbias4 = bias4[bias_offset + i];
    vres4.x = vqkv4.x + vbias4.x;
    vres4.y = vqkv4.y + vbias4.y;
    vres4.z = vqkv4.z + vbias4.z;
    vres4.w = vqkv4.w + vbias4.w;

    int id3 = i / dim_4;
    int id4 = i % dim_4;
    int cur_trg_offset = flat_3dim(id3, 0, id4, dim_1, dim_4);
    res4[trg_offset + cur_trg_offset] = vres4;
  }
}

template <>
__global__ void bias_add_transform_20314<__half>(__half *output,
                                                 const __half *input,
                                                 const __half *bias, int dim_3,
                                                 int dim_4) {
  int id0 = blockIdx.x;
  int id1 = blockIdx.y;
  int id2 = blockIdx.z;
  int dim_0 = gridDim.x;
  int dim_1 = gridDim.y;
  int dim_2 = gridDim.z;
  int dim_34 = dim_3 * dim_4;

  int src_offset = flat_4dim(id0, id1, id2, 0, dim_1, dim_2, dim_34);
  int trg_offset = flat_5dim(id2, id0, 0, id1, 0, dim_0, dim_3, dim_1, dim_4);
  int bias_offset = flat_2dim(id2, 0, dim_34);

  const float4 *qkv4 = reinterpret_cast<const float4 *>(input);
  const float4 *bias4 = reinterpret_cast<const float4 *>(bias);
  float4 *res4 = reinterpret_cast<float4 *>(output);
  float4 vqkv4;
  float4 vbias4;
  float4 vres4;
  __half2 *h2_qkv = reinterpret_cast<__half2 *>(&vqkv4);
  __half2 *h2_bias = reinterpret_cast<__half2 *>(&vbias4);
  __half2 *h2_res = reinterpret_cast<__half2 *>(&vres4);

  for (std::size_t i = threadIdx.x; i < dim_34; i += blockDim.x) {
    vqkv4 = qkv4[src_offset + i];
    vbias4 = bias4[bias_offset + i];
    h2_res[0] = __hadd2(h2_qkv[0], h2_bias[0]);
    h2_res[1] = __hadd2(h2_qkv[1], h2_bias[1]);
    h2_res[2] = __hadd2(h2_qkv[2], h2_bias[2]);
    h2_res[3] = __hadd2(h2_qkv[3], h2_bias[3]);

    int id3 = i / dim_4;
    int id4 = i % dim_4;
    int cur_trg_offset = flat_3dim(id3, 0, id4, dim_1, dim_4);
    res4[trg_offset + cur_trg_offset] = vres4;
  }
}

// [b, s, 3, h] -> [3, b, nh, s, ad]
template <>
void launch_bias_add_transform_20314<float>(float *output, const float *input,
                                            const float *bias, int dim_0,
                                            int dim_1, int dim_2, int dim_3,
                                            int dim_4, cudaStream_t stream) {
  dim_4 >>= 2;

  dim3 grid_dim(dim_0, dim_1, dim_2);
  dim3 block_dim(min(dim_3 * dim_4, MAX_THREADS));

  bias_add_transform_20314<float>
      <<<grid_dim, block_dim, 0, stream>>>(output, input, bias, dim_3, dim_4);
}

template <>
void launch_bias_add_transform_20314<__half>(__half *output,
                                             const __half *input,
                                             const __half *bias, int dim_0,
                                             int dim_1, int dim_2, int dim_3,
                                             int dim_4, cudaStream_t stream) {
  dim_4 >>= 3;

  dim3 grid_dim(dim_0, dim_1, dim_2);
  dim3 block_dim(min(dim_3 * dim_4, MAX_THREADS));

  bias_add_transform_20314<__half>
      <<<grid_dim, block_dim, 0, stream>>>(output, input, bias, dim_3, dim_4);
}

/**
@brief: quant_bias_add_transform_20314
Add bias to input, transform from
[0, 1, 2, 3, 4] to [2, 0, 3, 1, 4]

@thread
gridDim.x = dim_0
gridDim.y = dim_1
gridDim.z = dim_2
blockDim.x = min(dim_3 * dim_4, MAX_THREADS)

@param
input: [dim_0, dim_1, dim_2, dim_3, dim_4]
bias: [dim_2, dim_3, dim_4]
output: [dim_2, dim_0, dim_3, dim_1, dim_4]
*/
template <typename T>
__global__ void quant_bias_add_transform_20314(T *output, uint8_t *clip_mask,
                                               const int8_t *input,
                                               const T *bias, const T *clip_max,
                                               int dim_3, int dim_4,
                                               const T *out_clip_max);

template <>
__global__ void quant_bias_add_transform_20314<float>(
    float *output, uint8_t *clip_mask, const int8_t *input, const float *bias,
    const float *clip_max, int dim_3, int dim_4, const float *out_clip_max) {
  int id0 = blockIdx.x;
  int id1 = blockIdx.y;
  int id2 = blockIdx.z;
  int dim_0 = gridDim.x;
  int dim_1 = gridDim.y;
  int dim_2 = gridDim.z;
  int dim_34 = dim_3 * dim_4;

  int src_offset = flat_4dim(id0, id1, id2, 0, dim_1, dim_2, dim_34);
  int trg_offset = flat_5dim(id2, id0, 0, id1, 0, dim_0, dim_3, dim_1, dim_4);
  int bias_offset = flat_2dim(id2, 0, dim_34);

  const int32_t *qkv4 = reinterpret_cast<const int32_t *>(input);
  const float4 *bias4 = reinterpret_cast<const float4 *>(bias);
  float4 *res4 = reinterpret_cast<float4 *>(output);

  int32_t vqkv4;
  float4 vbias4;
  float4 vres4;

  float clip_max_val = clip_max[0];
  float out_clip_max_val;
  if (out_clip_max) out_clip_max_val = out_clip_max[0];
  // fix me
  uint8_t clip_mask_val;

  for (std::size_t i = threadIdx.x; i < dim_34; i += blockDim.x) {
    vqkv4 = qkv4[src_offset + i];
    vbias4 = bias4[bias_offset + i];
    int8_t *qkv = reinterpret_cast<int8_t *>(&vqkv4);
    vres4.x = dequantize(qkv[0], clip_max_val) + vbias4.x;
    vres4.y = dequantize(qkv[1], clip_max_val) + vbias4.y;
    vres4.z = dequantize(qkv[2], clip_max_val) + vbias4.z;
    vres4.w = dequantize(qkv[3], clip_max_val) + vbias4.w;

    if (out_clip_max) {
      vres4.x = fake_quantize(vres4.x, out_clip_max_val, clip_mask_val, 6);
      vres4.y = fake_quantize(vres4.y, out_clip_max_val, clip_mask_val, 6);
      vres4.z = fake_quantize(vres4.z, out_clip_max_val, clip_mask_val, 6);
      vres4.w = fake_quantize(vres4.w, out_clip_max_val, clip_mask_val, 6);
    }

    int id3 = i / dim_4;
    int id4 = i % dim_4;
    int cur_trg_offset = flat_3dim(id3, 0, id4, dim_1, dim_4);
    res4[trg_offset + cur_trg_offset] = vres4;
  }
}

template <>
__global__ void quant_bias_add_transform_20314<__half>(
    __half *output, uint8_t *clip_mask, const int8_t *input, const __half *bias,
    const __half *clip_max, int dim_3, int dim_4, const __half *out_clip_max) {
  int id0 = blockIdx.x;
  int id1 = blockIdx.y;
  int id2 = blockIdx.z;
  int dim_0 = gridDim.x;
  int dim_1 = gridDim.y;
  int dim_2 = gridDim.z;
  int dim_34 = dim_3 * dim_4;

  int src_offset = flat_4dim(id0, id1, id2, 0, dim_1, dim_2, dim_34);
  int trg_offset = flat_5dim(id2, id0, 0, id1, 0, dim_0, dim_3, dim_1, dim_4);
  int bias_offset = flat_2dim(id2, 0, dim_34);

  // const float4 *qkv4 = reinterpret_cast<const float4 *>(input);
  const int64_t *qkv8 = reinterpret_cast<const int64_t *>(input);
  const float4 *bias4 = reinterpret_cast<const float4 *>(bias);
  float4 *res4 = reinterpret_cast<float4 *>(output);
  int64_t vqkv8;
  float4 vbias4;
  float4 vres4;
  int8_t *qkv = reinterpret_cast<int8_t *>(&vqkv8);
  __half2 *h2_bias = reinterpret_cast<__half2 *>(&vbias4);
  __half2 *h2_res = reinterpret_cast<__half2 *>(&vres4);

  float clip_max_val = __half2float(clip_max[0]);
  float out_clip_max_val;
  if (out_clip_max) out_clip_max_val = __half2float(out_clip_max[0]);
  uint8_t clip_mask_val;

  for (std::size_t i = threadIdx.x; i < dim_34; i += blockDim.x) {
    vqkv8 = qkv8[src_offset + i];
    vbias4 = bias4[bias_offset + i];
#pragma unroll
    for (int j = 0; j < 4; ++j) {
      h2_res[j] =
          __hadd2(__floats2half2_rn(dequantize(qkv[j * 2], clip_max_val),
                                    dequantize(qkv[j * 2 + 1], clip_max_val)),
                  h2_bias[j]);
      if (out_clip_max) {
        h2_res[j].x = __float2half(fake_quantize(
            __half2float(h2_res[j].x), out_clip_max_val, clip_mask_val, 6));
        h2_res[j].y = __float2half(fake_quantize(
            __half2float(h2_res[j].y), out_clip_max_val, clip_mask_val, 6));
      }
    }

    int id3 = i / dim_4;
    int id4 = i % dim_4;
    int cur_trg_offset = flat_3dim(id3, 0, id4, dim_1, dim_4);
    res4[trg_offset + cur_trg_offset] = vres4;
  }
}

template <>
void launch_quant_bias_add_transform_20314<float>(
    float *output, uint8_t *clip_mask, const int8_t *input, const float *bias,
    const float *clip_max, int dim_0, int dim_1, int dim_2, int dim_3,
    int dim_4, cudaStream_t stream, const float *out_clip_max) {
  dim_4 >>= 2;

  dim3 grid_dim(dim_0, dim_1, dim_2);
  dim3 block_dim(min(dim_3 * dim_4, MAX_THREADS));

  quant_bias_add_transform_20314<float><<<grid_dim, block_dim, 0, stream>>>(
      output, clip_mask, input, bias, clip_max, dim_3, dim_4, out_clip_max);
}

template <>
void launch_quant_bias_add_transform_20314<__half>(
    __half *output, uint8_t *clip_mask, const int8_t *input, const __half *bias,
    const __half *clip_max, int dim_0, int dim_1, int dim_2, int dim_3,
    int dim_4, cudaStream_t stream, const __half *out_clip_max) {
  dim_4 >>= 3;

  dim3 grid_dim(dim_0, dim_1, dim_2);
  dim3 block_dim(min(dim_3 * dim_4, MAX_THREADS));

  quant_bias_add_transform_20314<__half><<<grid_dim, block_dim, 0, stream>>>(
      output, clip_mask, input, bias, clip_max, dim_3, dim_4, out_clip_max);
}

/**
@brief: transform4d_0213
Reshape the input matrix to merge the heads

@thread
gridDim.x = (num_all + max_block_thread - 1) / max_block_thread
blockDim.x = max_block_thread

@param
input: [trans_count, batch_size, nhead, seq_len, head_dim]
output: [batch_size, seq_len, trans_count, nhead, head_dim]
batch_size: the size of the current batch
seq_len: the sequence length of the current batch
hidden_dim: dim of the hidden tensor
nhead: number of attention heads
trans_count: 1 or 3, the count of matrice need to be transformed
*/
template <typename T>
__global__ void transform4d_0213(T *output, const T *input, int batch_size,
                                 int seq_len, int trans_count, int nhead,
                                 int head_dim, int num_all) {
  int offset = blockIdx.x * blockDim.x + threadIdx.x;
  if (offset >= num_all) {
    return;
  }
  int trans_id, batch_id, head_id, token_id, dim_id;
  decompose_5dim(offset, batch_size, nhead, seq_len, head_dim, &trans_id,
                 &batch_id, &head_id, &token_id, &dim_id);
  // [b, s, tc, nh, ad]
  int trg_offset = flat_5dim(batch_id, token_id, trans_id, head_id, dim_id,
                             seq_len, trans_count, nhead, head_dim);

  const float4 *input4 = reinterpret_cast<const float4 *>(input);
  float4 *res4 = reinterpret_cast<float4 *>(output);
  res4[trg_offset] = input4[offset];
}

// [tc, b, nh, s, ad] -> [b, s, tc, nh, ad]
template <>
void launch_transform4d_0213<float>(float *output, const float *input,
                                    int batch_size, int seq_len, int hidden_dim,
                                    int nhead, int trans_count,
                                    cudaStream_t stream) {
  hidden_dim >>= 2;
  int head_dim = hidden_dim / nhead;
  int num_all = batch_size * seq_len * trans_count * hidden_dim;
  int nblock = (num_all + MAX_THREADS - 1) / MAX_THREADS;

  transform4d_0213<float><<<nblock, MAX_THREADS, 0, stream>>>(
      output, input, batch_size, seq_len, trans_count, nhead, head_dim,
      num_all);
}

template <>
void launch_transform4d_0213<__half>(__half *output, const __half *input,
                                     int batch_size, int seq_len,
                                     int hidden_dim, int nhead, int trans_count,
                                     cudaStream_t stream) {
  hidden_dim >>= 3;
  int head_dim = hidden_dim / nhead;
  int num_all = batch_size * seq_len * trans_count * hidden_dim;
  int nblock = (num_all + MAX_THREADS - 1) / MAX_THREADS;

  transform4d_0213<__half><<<nblock, MAX_THREADS, 0, stream>>>(
      output, input, batch_size, seq_len, trans_count, nhead, head_dim,
      num_all);
}

/**
@brief: quant_transform4d_0213
Reshape the input matrix to merge the heads, and quantize output

@thread
gridDim.x = (num_all + max_block_thread - 1) / max_block_thread
blockDim.x = max_block_thread

@param
input: [trans_count, batch_size, nhead, seq_len, head_dim]
output: [batch_size, seq_len, trans_count, nhead, head_dim]
batch_size: the size of the current batch
seq_len: the sequence length of the current batch
hidden_dim: dim of the hidden tensor
nhead: number of attention heads
trans_count: 1 or 3, the count of matrice need to be transformed
*/
template <typename T>
__global__ void quant_transform4d_0213(int8_t *output, uint8_t *clip_mask,
                                       const T *input, const T *clip_max,
                                       int batch_size, int seq_len,
                                       int trans_count, int nhead, int head_dim,
                                       int num_all) {
  int offset = blockIdx.x * blockDim.x + threadIdx.x;
  if (offset >= num_all) {
    return;
  }
  int trans_id, batch_id, head_id, token_id, dim_id;
  decompose_5dim(offset, batch_size, nhead, seq_len, head_dim, &trans_id,
                 &batch_id, &head_id, &token_id, &dim_id);
  // [b, s, tc, nh, ad]
  int trg_offset = flat_5dim(batch_id, token_id, trans_id, head_id, dim_id,
                             seq_len, trans_count, nhead, head_dim);

  float clip_max_val = clip_max[0];

  const float4 *input4 = reinterpret_cast<const float4 *>(input);
  int8_t res[4];
  uint8_t cmask[4];
  float4 input4_i = input4[offset];
  res[0] = quantize(input4_i.x, clip_max_val, cmask[0], 2);
  res[1] = quantize(input4_i.y, clip_max_val, cmask[1], 2);
  res[2] = quantize(input4_i.z, clip_max_val, cmask[2], 2);
  res[3] = quantize(input4_i.w, clip_max_val, cmask[3], 2);

  int32_t *res4 = reinterpret_cast<int32_t *>(output);
  uint32_t *cmask4 = reinterpret_cast<uint32_t *>(clip_mask);
  res4[trg_offset] = reinterpret_cast<int32_t *>(res)[0];
  cmask4[trg_offset] |= reinterpret_cast<uint32_t *>(cmask)[0];
}

template <>
__global__ void quant_transform4d_0213<__half>(
    int8_t *output, uint8_t *clip_mask, const __half *input,
    const __half *clip_max, int batch_size, int seq_len, int trans_count,
    int nhead, int head_dim, int num_all) {
  int offset = blockIdx.x * blockDim.x + threadIdx.x;
  if (offset >= num_all) {
    return;
  }
  int trans_id, batch_id, head_id, token_id, dim_id;
  decompose_5dim(offset, batch_size, nhead, seq_len, head_dim, &trans_id,
                 &batch_id, &head_id, &token_id, &dim_id);
  // [b, s, tc, nh, ad]
  int trg_offset = flat_5dim(batch_id, token_id, trans_id, head_id, dim_id,
                             seq_len, trans_count, nhead, head_dim);

  float clip_max_val = __half2float(clip_max[0]);

  const float4 *input_f4 = reinterpret_cast<const float4 *>(input);
  int8_t res[8];
  uint8_t cmask[8];
  float4 input_f4_i = input_f4[offset];
  __half *input8 = reinterpret_cast<__half *>(&input_f4_i);
#pragma unroll
  for (int i = 0; i < 8; i++) {
    res[i] = quantize(__half2float(input8[i]), clip_max_val, cmask[i], 2);
  }

  int64_t *res8 = reinterpret_cast<int64_t *>(output);
  uint64_t *cmask8 = reinterpret_cast<uint64_t *>(clip_mask);
  res8[trg_offset] = reinterpret_cast<int64_t *>(res)[0];
  cmask8[trg_offset] |= reinterpret_cast<uint64_t *>(cmask)[0];
}

// [tc, b, nh, s, ad] -> [b, s, tc, nh, ad]
template <>
void launch_quant_transform4d_0213<float>(int8_t *output, uint8_t *clip_mask,
                                          const float *vals,
                                          const float *clip_max, int batch_size,
                                          int seq_len, int hidden_dim,
                                          int nhead, int trans_count,
                                          cudaStream_t stream) {
  hidden_dim >>= 2;
  int head_dim = hidden_dim / nhead;
  int num_all = batch_size * seq_len * trans_count * hidden_dim;
  int nblock = (num_all + MAX_THREADS - 1) / MAX_THREADS;

  quant_transform4d_0213<float><<<nblock, MAX_THREADS, 0, stream>>>(
      output, clip_mask, vals, clip_max, batch_size, seq_len, trans_count,
      nhead, head_dim, num_all);
}

template <>
void launch_quant_transform4d_0213<__half>(
    int8_t *output, uint8_t *clip_mask, const __half *vals,
    const __half *clip_max, int batch_size, int seq_len, int hidden_dim,
    int nhead, int trans_count, cudaStream_t stream) {
  hidden_dim >>= 3;
  int head_dim = hidden_dim / nhead;
  int num_all = batch_size * seq_len * trans_count * hidden_dim;
  int nblock = (num_all + MAX_THREADS - 1) / MAX_THREADS;

  quant_transform4d_0213<__half><<<nblock, MAX_THREADS, 0, stream>>>(
      output, clip_mask, vals, clip_max, batch_size, seq_len, trans_count,
      nhead, head_dim, num_all);
}

/**
@brief: transform4d_0213_dcmax
Reshape the input matrix to merge the heads, and reduce grad of clip_max

@thread
gridDim.x = (num_all + max_block_thread - 1) / max_block_thread
blockDim.x = max_block_thread

@param
input: [trans_count, batch_size, nhead, seq_len, head_dim]
output: [batch_size, seq_len, trans_count, nhead, head_dim]
batch_size: the size of the current batch
seq_len: the sequence length of the current batch
hidden_dim: dim of the hidden tensor
nhead: number of attention heads
trans_count: 1 or 3, the count of matrice need to be transformed
*/
template <typename T>
__global__ void transform_0213_dcmax(T *output, T *grad_cmax, const T *input,
                                     const uint8_t *clip_mask, int hidden_dim,
                                     int head_dim) {
  int batch_id = blockIdx.x;
  int token_id = blockIdx.y;
  int seq_len = gridDim.y;
  int nhead = hidden_dim / head_dim;

  // [b, s, h]
  int src_offset = flat_3dim(batch_id, token_id, 0, seq_len, hidden_dim);
  // [b, nh, s, ad]
  int trg_offset =
      flat_4dim(batch_id, 0, token_id, 0, nhead, seq_len, head_dim);

  const float4 *input4 = reinterpret_cast<const float4 *>(input);
  const uint32_t *cmask4 = reinterpret_cast<const uint32_t *>(clip_mask);
  float4 *res4 = reinterpret_cast<float4 *>(output);
  float4 vinput4, voutput4;
  float thread_cmax_grad = 0;
  float cmax_grad = 0;
  uint32_t cmask4_i;
  uint8_t *cmask = reinterpret_cast<uint8_t *>(&cmask4_i);

  for (int i = threadIdx.x; i < hidden_dim; i += blockDim.x) {
    vinput4 = input4[src_offset + i];
    cmask4_i = cmask4[src_offset + i];
    int head_id = i / head_dim;
    int dim_id = i % head_dim;
    int cur_trg_offset = flat_3dim(head_id, 0, dim_id, seq_len, head_dim);

    clip_bwd(voutput4.x, cmax_grad, vinput4.x, cmask[0], 2);
    thread_cmax_grad += cmax_grad;
    clip_bwd(voutput4.y, cmax_grad, vinput4.y, cmask[1], 2);
    thread_cmax_grad += cmax_grad;
    clip_bwd(voutput4.z, cmax_grad, vinput4.z, cmask[2], 2);
    thread_cmax_grad += cmax_grad;
    clip_bwd(voutput4.w, cmax_grad, vinput4.w, cmask[3], 2);
    thread_cmax_grad += cmax_grad;

    res4[trg_offset + cur_trg_offset] = voutput4;
  }

  __shared__ float block_cmax_grad;

  if (threadIdx.x == 0) block_cmax_grad = 0;
  __syncthreads();

  if (thread_cmax_grad != 0) {
    atomicAdd(&block_cmax_grad, thread_cmax_grad);
  }
  __syncthreads();

  if (threadIdx.x == 0) {
    if (block_cmax_grad != 0) {
      atomicAdd(&grad_cmax[0], __float2half(block_cmax_grad));
    }
  }
}

template <>
__global__ void transform_0213_dcmax<__half>(__half *output, __half *grad_cmax,
                                             const __half *input,
                                             const uint8_t *clip_mask,
                                             int hidden_dim, int head_dim) {
  int batch_id = blockIdx.x;
  int token_id = blockIdx.y;
  int seq_len = gridDim.y;
  int nhead = hidden_dim / head_dim;

  // [b, s, h]
  int src_offset = flat_3dim(batch_id, token_id, 0, seq_len, hidden_dim);
  // [b, nh, s, ad]
  int trg_offset =
      flat_4dim(batch_id, 0, token_id, 0, nhead, seq_len, head_dim);

  const float4 *input4 = reinterpret_cast<const float4 *>(input);
  const uint64_t *cmask8 = reinterpret_cast<const uint64_t *>(clip_mask);
  float4 *res4 = reinterpret_cast<float4 *>(output);
  float4 vinput4;
  __half *input8 = reinterpret_cast<__half *>(&vinput4);
  float4 res8;
  __half *res = reinterpret_cast<__half *>(&res8);
  uint64_t cmask8_i;
  uint8_t *cmask = reinterpret_cast<uint8_t *>(&cmask8_i);
  float thread_cmax_grad = 0;
  float cmax_grad = 0;

  for (int i = threadIdx.x; i < hidden_dim; i += blockDim.x) {
    vinput4 = input4[src_offset + i];
    cmask8_i = cmask8[src_offset + i];
#pragma unroll
    for (int j = 0; j < 8; j++) {
      clip_bwd(res[j], cmax_grad, input8[j], cmask[j], 2);
      thread_cmax_grad += cmax_grad;
    }

    int head_id = i / head_dim;
    int dim_id = i % head_dim;
    int cur_trg_offset = flat_3dim(head_id, 0, dim_id, seq_len, head_dim);
    res4[trg_offset + cur_trg_offset] = vinput4;
  }

  __shared__ float block_cmax_grad;

  if (threadIdx.x == 0) block_cmax_grad = 0;
  __syncthreads();

  if (thread_cmax_grad != 0) {
    atomicAdd(&block_cmax_grad, thread_cmax_grad);
  }
  __syncthreads();

  if (threadIdx.x == 0) {
    if (block_cmax_grad != 0) {
      atomicAdd(&grad_cmax[0], __float2half(block_cmax_grad));
    }
  }
}

// [b, nh, s, ad] -> [b, s, nh, ad]
template <>
void launch_transform_0213_dcmax<float>(float *output, float *grad_cmax,
                                        const float *input,
                                        const uint8_t *clip_mask,
                                        int batch_size, int seq_len,
                                        int hidden_dim, int nhead,
                                        cudaStream_t stream) {
  hidden_dim >>= 2;
  int head_dim = hidden_dim / nhead;

  zero_grad<<<1, 1>>>(grad_cmax);
  dim3 grid_dim(batch_size, seq_len);
  dim3 block_dim(min(hidden_dim, MAX_THREADS));

  transform_0213_dcmax<float><<<grid_dim, block_dim, 0, stream>>>(
      output, grad_cmax, input, clip_mask, hidden_dim, head_dim);
}

template <>
void launch_transform_0213_dcmax<__half>(__half *output, __half *grad_cmax,
                                         const __half *input,
                                         const uint8_t *clip_mask,
                                         int batch_size, int seq_len,
                                         int hidden_dim, int nhead,
                                         cudaStream_t stream) {
  hidden_dim >>= 3;
  int head_dim = hidden_dim / nhead;

  zero_grad<<<1, 1>>>(grad_cmax);
  dim3 grid_dim(batch_size, seq_len);
  dim3 block_dim(min(hidden_dim, MAX_THREADS));

  transform_0213_dcmax<__half><<<grid_dim, block_dim, 0, stream>>>(
      output, grad_cmax, input, clip_mask, hidden_dim, head_dim);
}

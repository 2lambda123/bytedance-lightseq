#include "strided_batch_gemm.h"

namespace lightseq {

template <typename T1, typename T2>
Variable* StridedBatchGemmOp<T1, T2>::operator()(Variable* inpA,
                                                 Variable* inpB) {
  Variable* result =
      new Variable("StridedBatchGemmOp_out", _max_ele_num * sizeof(T1),
                   _max_ele_num * sizeof(T2));
  set_parents({inpA, inpB});
  this->set_children({result});
  return result;
}

template <typename T1, typename T2>
void StridedBatchGemmOp<T1, T2>::forward() {
  T1* _buffer_a = (T1*)parent(0)->value();
  T1* _buffer_b = (T1*)parent(1)->value();
  T1* output = (T1*)child(0)->value();

  if (!_context_ptr->is_built()) {
    return;
  }

  int stride_a = _m * _k;
  int stride_b = _n * _k;
  int stride_c = _m * _n;
  if (_max_seq > 0) {
    stride_a = _max_seq * ((_op_AA == MATRIX_OP::NonTranspose) ? _m : _k);
  }

#ifdef LIGHTSEQ_cuda
  cublasHandle_t handle = _context_ptr->get_cublashandle();
  cublas_strided_batched_gemm(handle, _m, _n, _k, &_alpha, &_beta, _buffer_a,
                              _buffer_b, output, _op_A, _op_B, stride_a,
                              stride_b, stride_c, _batch_heads,
                              cublasGemmAlgo_t(_gemm_algos[0]));
#endif
}

template <typename T1, typename T2>
void StridedBatchGemmOp<T1, T2>::backward() {
  int mb = (_op_AA == MATRIX_OP::Transpose ? _k : _m);
  int kb = (_op_AA == MATRIX_OP::Transpose ? _m : _k);

  int stride_a = mb * _n;
  int stride_b = _n * kb;
  int stride_c = _m * _k;

  T1* _buffer_a = (T1*)parent(0)->value();
  T1* _buffer_b = (T1*)parent(1)->value();

  T2* d_output = (T2*)child(0)->grad();

  T2* inpGradA = (T2*)parent(0)->grad();
  T2* inpGradB = (T2*)parent(1)->grad();

  if (!_context_ptr->is_built()) {
    return;
  }

#ifdef LIGHTSEQ_cuda
  // B need to transpose.
  cublasOperation_t op_b = (_op_B == CUBLAS_OP_T ? CUBLAS_OP_N : CUBLAS_OP_T);

  cublasHandle_t handle = _context_ptr->get_cublashandle();
  // Calculate d_A.
  cublas_strided_batched_gemm(handle, mb, kb, _n, &_alpha, &_beta,
                              (_op_A == CUBLAS_OP_T ? _buffer_b : d_output),
                              (_op_A == CUBLAS_OP_T ? d_output : _buffer_b),
                              inpGradA, CUBLAS_OP_N, op_b, stride_a, stride_b,
                              stride_c, _batch_heads,
                              cublasGemmAlgo_t(_gemm_algos[1]));

  // A need to transpose.
  cublasOperation_t op_a = (_op_A == CUBLAS_OP_T ? CUBLAS_OP_N : CUBLAS_OP_T);

  stride_a = _m * _k;
  stride_b = _m * _n;
  stride_c = _n * _k;

  // Calculate d_B.
  cublas_strided_batched_gemm(handle, _k, _n, _m, &_alpha, &_beta, _buffer_a,
                              d_output, inpGradB, op_a, CUBLAS_OP_N, stride_a,
                              stride_b, stride_c, _batch_heads,
                              cublasGemmAlgo_t(_gemm_algos[2]));
#endif
}

template class StridedBatchGemmOp<float, float>;
#ifdef LIGHTSEQ_cuda
template class StridedBatchGemmOp<__half, __half>;
#endif
}  // namespace lightseq

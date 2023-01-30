#pragma once
#include "declaration.h"
#include "node.h"

namespace lightseq {

// after attention softmax
template <typename T1, typename T2>
class StridedBatchGemmOp : public Operator {
 private:
  int _m;
  int _n;
  int _k;
  size_t _max_ele_num;
  int _batch_heads;
  float _alpha;
  float _beta;
  std::array<int, 3> _gemm_algos;
  int _max_seq;
#ifdef LIGHTSEQ_cuda
  cublasOperation_t _op_A;
  cublasOperation_t _op_B;
#endif
  MATRIX_OP _op_AA;
  MATRIX_OP _op_BB;

  int _dec_layer_id;

 public:
  StridedBatchGemmOp(size_t max_ele_num, float param_alpha, float param_beta,
                     MATRIX_OP opA, MATRIX_OP opB)
      : Operator("StridedBatchGemmOp"),
        _max_ele_num(max_ele_num),
        _alpha(param_alpha),
        _beta(param_beta),
#ifdef LIGHTSEQ_cuda
        _op_A(opA == MATRIX_OP::Transpose ? CUBLAS_OP_T : CUBLAS_OP_N),
        _op_B(opB == MATRIX_OP::Transpose ? CUBLAS_OP_T : CUBLAS_OP_N),
#endif
        _op_AA(opA),
        _op_BB(opB),
        _gemm_algos(std::array<int, 3>({99, 99, 99})) {
  }

  virtual ~StridedBatchGemmOp() {}

  Variable* operator()(Variable* inpA, Variable* inpB);

  void before_forward(int mm, int nn, int kk, int batch_heads) {
    _m = mm, _n = nn, _k = kk;
    _batch_heads = batch_heads;
    _max_seq = -1;
  }

  void before_forward(int mm, int nn, int kk, int batch_heads, int max_seq) {
    _m = mm, _n = nn, _k = kk;
    _batch_heads = batch_heads;
    _max_seq = max_seq;
  }

  void forward() override;

  void before_backward(int mm, int nn, int kk, int batch_heads) {
    _m = mm, _n = nn, _k = kk;
    _batch_heads = batch_heads;
  }

  void backward() override;
};
}  // namespace lightseq

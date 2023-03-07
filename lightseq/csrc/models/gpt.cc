#include "gpt.h"

namespace lightseq {

Gpt::Gpt(const std::string weight_path, const int max_batch_size)
    : LSModel({"token_ids"}, {"encoder_output"}),
      _max_batch_size(max_batch_size) {
  /* --- step.1 initial context --- */
  Context::create_global_context(StatusType::Inference);
  _context_ptr = Context::global_instance();

  /* --- step.2 load model weights into GPU memory --- */
  // saved in custom proto file
  std::string model_weights_path = weight_path;
  std::string res = tw_.initializing(model_weights_path);
  if (!res.empty()) {
    throw std::runtime_error(res);
  }
  tw_.print_model_config();
  _generate_method = get_generate_method(tw_._sampling_method);

  _context_ptr->regress_begin();

  /* --- step.3 initial input Variable node --- */
  _inp_tokens = new Variable("inp_tokens", g_dtype<OpType_>());

  /* --- step.4 inital operator & layer --- */
  int max_batch_tokens = tw_._max_step * _max_batch_size;

  // initial LaunchEncEmb layer
  _launch_gpt_emb_layer.reset(new LaunchGptEmbLayer<OpType_>(
      max_batch_tokens, tw_._max_step, tw_._beam_size, tw_._padding_id,
      tw_._hidden_size));
  _launch_gpt_emb_layer->load_params(tw_.get_src_emb_wei(), 0);

  // initial TransformerEncoder layers
  float attn_prob_dropout_ratio = 0.0;
  float activation_dropout_ratio = 0.0;
  float hidden_dropout_ratio = 0.0;
  int enc_wei_offset = 0;
  for (int idx = 0; idx < tw_._n_enc_layer; idx++) {
    GptLayerPtr<OpType_, OpType_> gpt_layer(new GptLayer<OpType_, OpType_>(
        idx, max_batch_tokens * tw_._beam_size, tw_._max_step, tw_._hidden_size,
        tw_._head_num, tw_._inner_size, attn_prob_dropout_ratio,
        activation_dropout_ratio, hidden_dropout_ratio,
        tw_._use_gelu ? "gelu" : "relu", false));
    enc_wei_offset += gpt_layer->load_params(tw_.get_enc_wei(), enc_wei_offset);
    _gpt_layers_vec.push_back(gpt_layer);
  }

  // initial LayerNormalize layer
  _lyr_norm_layer.reset(new LyrNormalizeLayer<OpType_, OpType_>(
      max_batch_tokens * tw_._beam_size, tw_._hidden_size));
  _lyr_norm_layer->load_params(tw_.get_src_emb_wei(), 2);

  // intial Project hidden states to vocab logits
  _linear_layer.reset(new LinearLayer<OpType_, OpType_>(
      max_batch_tokens * tw_._beam_size, tw_._hidden_size, tw_._src_vocab_size,
      MATRIX_OP::Transpose, MATRIX_OP::NonTranspose, 1.f));
  _linear_layer->load_params(tw_.get_src_emb_wei(), 0);

  _generator_layer.reset(new GeneratorLayer<OpType_>(
      _generate_method, max_batch_size, tw_._max_step, tw_._src_vocab_size,
      tw_._hidden_size, 1024, tw_._beam_size, tw_._diverse_lambda,
      tw_._dim_per_head, tw_._eos_id, tw_._head_num, tw_._length_penalty,
      tw_._topk, tw_._topp, false));

  _context_ptr->regress_end();
  printf("Finish initialize layers and assign weights!\n");

  /* --- step.5 construct network --- */
  std::tuple<Variable *, Variable *> gpt_emb_outs =
      (*_launch_gpt_emb_layer)(_inp_tokens);
  Variable *gpt_emb = std::get<0>(gpt_emb_outs);
  for (auto iter : _gpt_layers_vec) {
    gpt_emb = (*iter)(gpt_emb);
  }
  gpt_emb = (*_lyr_norm_layer)(gpt_emb);
  Variable *logits_prob = (*_linear_layer)(gpt_emb);

  std::tuple<Variable *, Variable *> gen_outs =
      (*_generator_layer)(logits_prob, _inp_tokens);
  _out_tokens = std::get<0>(gen_outs);
  _out_scores = std::get<1>(gen_outs);
  _inp_tokens->malloc_memory(_max_batch_size * tw_._beam_size * tw_._max_step);
  _out_tokens->malloc_memory(_max_batch_size * tw_._beam_size * tw_._max_step);

  printf("Finish construct network!\n");
  // exit(0);
}

Gpt::~Gpt() {}

void Gpt::before_forward(int batch_size, int seq_len, int steps) {
  if (steps == 0) {
    _launch_gpt_emb_layer->before_forward(batch_size * tw_._beam_size, seq_len,
                                          0);
    for (auto iter : _gpt_layers_vec) {
      iter->before_forward(batch_size * tw_._beam_size, seq_len, 0);
    }
    _lyr_norm_layer->before_forward(batch_size * tw_._beam_size, seq_len);
    _linear_layer->before_forward(batch_size * tw_._beam_size, seq_len);
    _generator_layer->before_forward(batch_size, seq_len, 0);
  } else {
    _launch_gpt_emb_layer->before_forward(batch_size * tw_._beam_size, 1,
                                          seq_len + steps - 1);
    for (auto iter : _gpt_layers_vec) {
      iter->before_forward(batch_size * tw_._beam_size, 1, seq_len + steps);
    }
    _lyr_norm_layer->before_forward(batch_size * tw_._beam_size, 1);
    _linear_layer->before_forward(batch_size * tw_._beam_size, 1);
    _generator_layer->before_forward(batch_size, 1, seq_len + steps - 1);
  }
}

void Gpt::Infer() {
  int batch_size = input_shapes_[0][0], seq_len = input_shapes_[0][1];

  /* --- notice that the order of forward should be the same with network --- */

#ifdef LIGHTSEQ_cuda
  cudaMemset(_inp_tokens->value(), int(345),
             batch_size * tw_._beam_size * tw_._max_step * sizeof(int));
  for (int i = 0; i < batch_size; i++) {
    for (int j = 0; j < tw_._beam_size; j++) {
      CHECK_GPU_ERROR(cudaMemcpy(
          _inp_tokens->value<int>() + (i * tw_._beam_size + j) * tw_._max_step,
          _input_ptr, seq_len * sizeof(int), cudaMemcpyDefault));

      print_vec(_input_ptr, "original _input_ptr", seq_len);
      print_vec(
          _inp_tokens->value<int>() + (i * tw_._beam_size + j) * tw_._max_step,
          "copied _input_ptr", seq_len + 1);
    }
  }
#endif

  int steps = 0;
  while (true) {
    before_forward(batch_size, seq_len, steps);

    _launch_gpt_emb_layer->forward();
    for (auto iter : _gpt_layers_vec) {
      iter->forward();
    }
    _lyr_norm_layer->forward();
    _linear_layer->forward();
    _generator_layer->forward();

    if (_generator_layer->is_stop()) {
      break;
    }
    if (_generate_method == GenerateMethod::BeamSearch) {
      // refresh cache
    }
    Variable::swap_tensor(_inp_tokens, _out_tokens);
    if (steps == 1) {
      break;
    }
    steps++;
  }
  _context_ptr->synchronize();

  set_output_shape(0, {batch_size, seq_len + steps});
}

void Gpt::set_input_ptr(int index, void *input_ptr) {
  switch (index) {
    case 0:
      // _inp_tokens->set_value((char *)input_ptr);
      _input_ptr = (int *)input_ptr;
      break;

    default:
      throw std::runtime_error("invalid input index");
      break;
  }
}

void Gpt::set_output_ptr(int index, void *output_ptr) {
  switch (index) {
    case 0:
      // _out_tokens->set_value((char *)output_ptr);
      _gpt_out_ptr = (int *)output_ptr;
      break;

    default:
      throw std::runtime_error("invalid output index");
      break;
  }
}

const void *Gpt::get_output_ptr(int index) {
  switch (index) {
    case 0:
      // return static_cast<void *>(_out_tokens->value());
      return static_cast<void *>(_gpt_out_ptr);
    default:
      throw std::runtime_error("invalid output index");
      break;
  }
}

std::vector<int> Gpt::get_input_max_shape(int index) {
  switch (index) {
    case 0:
      return {_max_batch_size, tw_._max_step};

    default:
      throw std::runtime_error("invalid input index");
      break;
  }
}
std::vector<int> Gpt::get_output_max_shape(int index) {
  switch (index) {
    case 0:
      return {_max_batch_size, tw_._max_step, tw_._hidden_size};

    default:
      throw std::runtime_error("invalid output index");
      break;
  }
}

DataType Gpt::get_input_dtype(int index) {
  switch (index) {
    case 0:
      return DataType::kInt32;
      break;

    default:
      throw std::runtime_error("invalid input index");
      break;
  }
}

DataType Gpt::get_output_dtype(int index) {
  switch (index) {
    case 0:
#ifdef FP16_MODE
      return DataType::kFloat16;
#else
      return DataType::kFloat32;
#endif

      break;

    default:
      throw std::runtime_error("invalid output index");
      break;
  }
}

}  // namespace lightseq

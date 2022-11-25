#include "model_base.h"
#include "util.h"
#include<unistd.h>  

/**
@file
Example of how to run transformer inference using our implementation.
*/

int main(int argc, char* argv[]) {
  std::string model_weights_path = argv[1];
  std::vector<int> example_input{};

  int max_batch_size = 32;
  int batch_seq_len = 255;
  int rand_seed = 772002;

  if (argc == 4) {
    max_batch_size = atoi(argv[2]);
    batch_seq_len = atoi(argv[3]);
  } else if (argc == 5) {
    max_batch_size = atoi(argv[2]);
    batch_seq_len = atoi(argv[3]);
    rand_seed = atoi(argv[4]);
  }

  std::vector<int> host_input;
  for (int i = 0; i < max_batch_size; ++i) {
    for (int j = 0; j < batch_seq_len; ++j) {
      host_input.push_back(rand() % 9000 + 1000);
    }
  }

  auto model = lightseq::cuda::LSModelFactory::GetInstance().CreateModel(
      "Transformer", model_weights_path, max_batch_size);

  void* d_input;
  CHECK_GPU_ERROR(
      cudaMalloc(&d_input, sizeof(int) * max_batch_size * batch_seq_len));
  CHECK_GPU_ERROR(cudaMemcpy(d_input, host_input.data(),
                             sizeof(int) * max_batch_size * batch_seq_len,
                             cudaMemcpyHostToDevice));

  model->set_input_ptr(0, d_input);
  model->set_input_shape(0, {max_batch_size, batch_seq_len});

  for (int i = 0; i < model->get_output_size(); i++) {
    void* d_output;
    std::vector<int> shape = model->get_output_max_shape(i);
    int total_size = 1;
    for (int j = 0; j < shape.size(); j++) {
      total_size *= shape[j];
    }
    CHECK_GPU_ERROR(cudaMalloc(&d_output, std::max(10, total_size) * sizeof(int)));
    model->set_output_ptr(i, d_output);
  }
  CHECK_GPU_ERROR(cudaStreamSynchronize(0));
  std::cout << "infer preprocessing finished" << std::endl;

  std::chrono::duration<double> elapsed(0);
  int iter = 0;
  /* ---step5. infer and log--- */
  for (int i = 0; i < 2; i++) {
    printf("\n\n\n\n\n\n");
    printf("***************************************************************************\n");
    auto start = std::chrono::high_resolution_clock::now();
    model->Infer();
    CHECK_GPU_ERROR(cudaStreamSynchronize(0));
    auto finish = std::chrono::high_resolution_clock::now();
    if (i > 0) {
      iter++;
      elapsed += finish - start;
    }
  }

  std::cout << "new arch lightseq inference latency: " << elapsed.count() * 1000 / iter
            << " ms" << std::endl;

  for (int i = 0; i < model->get_output_size(); i++) {
    const float* d_output;
    d_output = static_cast<const float*>(model->get_output_ptr(i));
    std::vector<int> shape = model->get_output_shape(i);
    std::cout << "output shape: ";
    int size = 1;
    for (int j = 0; j < shape.size(); j++) {
      std::cout << shape[j] << " ";
      size *= shape[j];
    }
    std::cout << std::endl;

    if(!i) {
      print_vec((int*)d_output, "generate tokens", std::min(size, 10));
    }
    else {
      print_vec((float*)d_output, "score: ", 1);
    }
  }

  return 0;
}

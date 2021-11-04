#include <ATen/cuda/CUDAContext.h>

#include <torch/csrc/jit/resource_guard.h>
#include <sstream>
#include <torch/csrc/jit/frontend/code_template.h>
#include <torch/csrc/jit/codegen/fuser/cuda/fused_kernel.h>
#include <c10/core/ScalarType.h>
//#include <c10/util/Optional.h>
#include <ATen/native/cuda/jit_utils.h>
#include <ATen/cuda/detail/OffsetCalculator.cuh>
#include <c10/util/irange.h>
namespace at{

namespace cuda{

namespace jit {

//FIXME - this are defined in Loops.cuh, but including Loops.cuh here would lead to circular includes Loops.cuh -> CUDALoops.cuh -> jit_utils.h -> Loops.cuh
#define THREAD_WORK_SIZE 4
constexpr int thread_work_size = THREAD_WORK_SIZE;


torch::jit::CodeTemplate load_code_template(const std::string& path) {
  std::ifstream ifs{path};
  std::string s{
    std::istreambuf_iterator<char>(ifs),
    std::istreambuf_iterator<char>()};
  return s;

}

// std::string silly_generate_code() {
//     torch::jit::TemplateEnv env;
//     env.s("name", "i0");
//     env.s("scalar_t", "float");
//     env.s("nTensorArgs", "2");
//     env.s("nInputTensors", "1");
//     static auto cuda_template = load_code_template(
//       "/private/home/mruberry/git/pytorch/aten/src/ATen/native/cuda/silly_code_template.cuh");
//     return cuda_template.format(env);
// }

std::string generate_code(
    int nTensors,
    const std::string& func,
    const std::string& name,
    const std::string& common_type,
    const std::string& result_type,
    bool contiguous,
    bool dynamic_casting,
    bool vectorized,
    int vec_size) {
  torch::jit::TemplateEnv env;
  env.s("index_type", "unsigned int");
  const int nInputs = nTensors - 1;
  env.s("nInputs", std::to_string(nInputs));
  env.s("scalar_type", common_type);
  env.s("functor", func);
  env.s("name", name);
  std::stringstream declare_load_arrays;
  for (int i = 0; i < nInputs; i++) {
    // TODO these arrays are potentially of the different types, use function
    // traits to determine the types
    declare_load_arrays << common_type << " arg" << std::to_string(i)
                        << "[" << std::to_string(thread_work_size) << "];\n";
  }
  env.s("declare_load_arrays", declare_load_arrays.str());
  std::stringstream declare_store_arrays;
  declare_store_arrays << result_type << " out"
                       << "[" << std::to_string(thread_work_size) << "];\n";
  env.s("declare_store_arrays", declare_store_arrays.str());
  const int nOutputs = 1; // FIXME
  std::stringstream functor_args;
  for (int i = 0; i < nInputs - 1; i++) {
    functor_args << "arg" << std::to_string(i) << "[j], ";
  }
  functor_args << "arg" << std::to_string(nInputs - 1) << "[j]";
  env.s("args", functor_args.str());
  if (!vectorized) {
    if (!dynamic_casting) {
      env.s("loader", "LoadWithoutCast");
      env.s("storer", "StoreWithoutCast");
    } else {
      env.s(
          "loader", std::string("LoadWithCast<" + std::to_string(nInputs) + ">"));
      env.s("storer", "StoreWithCast");
    }
    if (contiguous) {
      env.s("offset_calculator", "TrivialOffsetCalculator");
    } else {
      env.s("offset_calculator", "OffsetCalculator");
    }
    std::stringstream load_inputs;
    for (int i = 0; i < nInputs; i++) {
      auto i_string = std::to_string(i);
      load_inputs << "arg" << i_string << "[j] = l.load<" << common_type
                  << ">(data[" << std::to_string(i + nOutputs)
                  << "], input_offsets[" << i_string << "], " << i_string
                  << ");\n";
    }
    env.s("load_inputs", load_inputs.str());
    std::stringstream store_outputs;
    store_outputs << "s.store<" << result_type
                  << ">(out[j], data[0], output_offsets[0]);\n";
    env.s("store_outputs", store_outputs.str());
      static auto cuda_template = load_code_template(
        "/home/ngimel/local/pytorch/aten/src/ATen/native/cuda/jit_code_template.cuh");
    return cuda_template.format(env);
  } else {
    env.s("vec_size", std::to_string(vec_size));
    env.s("result_type", result_type);
    std::stringstream vector_pointers;
    for (const auto i : c10::irange(nInputs)){
      auto i_string = std::to_string(i);
      vector_pointers << "vec_t_input * vec" << i_string <<
      " = reinterpret_cast<vec_t_input *>(data[" << i_string << "+1])" <<
      " + block_work_size / vec_size * idx;\n";
    }
    env.s("vector_pointers", vector_pointers.str());
    std::stringstream load_vectorized_inputs;
    for (const auto i : c10::irange(nInputs)) {
      auto i_string = std::to_string(i);
      load_vectorized_inputs << "v = vec" << i_string << "[thread_idx];\n";
      load_vectorized_inputs << "#pragma unroll\n";
      load_vectorized_inputs << "for (int j=0; j < vec_size; j++){\n";
      load_vectorized_inputs << "  arg" << i_string << "[vec_size * i + j] = v.val[j];\n";
      load_vectorized_inputs << "}\n";
    }
    env.s("load_vectorized_inputs", load_vectorized_inputs.str());
    std::stringstream load_unrolled_inputs;
    for (const auto i: c10::irange(nInputs)){
      auto i_string = std::to_string(i);
      load_unrolled_inputs << "arg" << i_string << "[j] = load<" << common_type
        << ">(data[" << std::to_string(i + nOutputs) << "], linear_idx);\n";
    }
    env.s("load_unrolled_inputs", load_unrolled_inputs.str());

    static auto cuda_template = load_code_template(
      "/home/ngimel/local/pytorch/aten/src/ATen/native/cuda/jit_vectorized_template.cuh");
    return cuda_template.format(env);
  }

}


NvrtcFunction jit_pwise_function(
    const std::string& code,
    const std::string& kernel_name) {

  // TODO: this lock is could be acquired around the cache updates
//  std::lock_guard<std::mutex> guard{jiterator_mutex};

  // Compiles the kernel ---

  // Acquires device and NVRTC properties (for compile arch and occupancy calculations)
  const cudaDeviceProp* prop = at::cuda::getCurrentDeviceProperties();
  int major = 0, minor = 0;
  bool compile_to_sass = false;
  torch::jit::fuser::cuda::codegenOutputQuery(prop, major, minor, compile_to_sass);
  //std::cout << "create program\n";
  // Creates the NVRTC program
  nvrtcProgram program;
  const auto& nvrtc = at::globalContext().getNVRTC();
  AT_CUDA_NVRTC_CHECK(nvrtc.nvrtcCreateProgram(
      &program, code.c_str(), nullptr, 0, nullptr, nullptr));
  // constructs nvrtc build arguments
#if defined(CUDA_VERSION) && CUDA_VERSION < 11010
  // compile to sass is not allowed prior to CUDA 11.1
  compile_to_sass = false;
#endif
  // CUDA 11.1 allows going directly to SASS (sm_) instead of PTX (compute_)
  // which gives better backwards compatibility to work on older driver,
  // (since older driver doesn't necessrily recognize PTX emitted by new
  // toolkit);
  // Meanwhile, for forward compatibility (future device with
  // `unsupported_arch==True`), since SASS are not necessarily compatible,
  // we fallback to PTX instead.
  const std::string compute = std::string("--gpu-architecture=") +
      (compile_to_sass ? "sm_" : "compute_") + std::to_string(major) +
      std::to_string(minor);
  // NOLINTNEXTLINE(cppcoreguidelines-init-variables)
  std::vector<const char*> args = {
      "--std=c++14", compute.c_str(), "-default-device"};

#ifndef NDEBUG
  // Add line info to generated kernels
  args.push_back("-lineinfo");
#else
  // Avoid excessive register usage from assertion
  args.push_back("-DNDEBUG");
#endif
//  std::cout << "compile program\n";
  // compiles and validates result
  const auto compilation_result =
      nvrtc.nvrtcCompileProgram(program, args.size(), args.data());
  if (compilation_result != NVRTC_SUCCESS) {
    std::cout << "Compilation failed!" << std::endl;
    size_t logsize;
    AT_CUDA_NVRTC_CHECK(nvrtc.nvrtcGetProgramLogSize(program, &logsize));
    std::vector<char> log(logsize);
    AT_CUDA_NVRTC_CHECK(nvrtc.nvrtcGetProgramLog(program, log.data()));
    std::stringstream cu;
    cu << log.data();
    throw std::runtime_error(cu.str());
  }
  size_t ptx_size = 0;
  std::vector<char> ptx;
#if defined(CUDA_VERSION) && CUDA_VERSION >= 11010
    // compile_to_sass determines whether we are generating SASS or PTX, hence
    // the different API.
    const auto getSize = compile_to_sass
        ? at::globalContext().getNVRTC().nvrtcGetCUBINSize
        : at::globalContext().getNVRTC().nvrtcGetPTXSize;
    const auto getFunc = compile_to_sass
        ? at::globalContext().getNVRTC().nvrtcGetCUBIN
        : at::globalContext().getNVRTC().nvrtcGetPTX;
#else
    const auto getSize = at::globalContext().getNVRTC().nvrtcGetPTXSize;
    const auto getFunc = at::globalContext().getNVRTC().nvrtcGetPTX;
#endif
    AT_CUDA_NVRTC_CHECK(getSize(program, &ptx_size));
    ptx.resize(ptx_size);
    AT_CUDA_NVRTC_CHECK(getFunc(program, ptx.data()));

    NvrtcFunction compiled_kernel_;
    AT_CUDA_DRIVER_CHECK(nvrtc.cuModuleLoadData(&(compiled_kernel_.module), ptx.data()));
    std::string name = kernel_name + "_kernel";
    AT_CUDA_DRIVER_CHECK(
        nvrtc.cuModuleGetFunction(&(compiled_kernel_.function), compiled_kernel_.module, name.c_str()));

    //TODO use guards to avoid leaking
    AT_CUDA_NVRTC_CHECK(nvrtc.nvrtcDestroyProgram(&program));

    return compiled_kernel_;
}

// TODO: may need/want to initialize CUDA context here (refactor into nvrtc call)
void launch_jitted_pwise_function(
    NvrtcFunction function,
    std::array<void*, 6>& args,
    const int nBlocks,
    const int kBlockSize) {

  const auto& nvrtc = at::globalContext().getNVRTC();
  // Launches kernel on current stream
  auto stream = at::cuda::getCurrentCUDAStream();
  AT_CUDA_DRIVER_CHECK(nvrtc.cuLaunchKernel(
    function.function,
    nBlocks,
    1,
    1,
    kBlockSize,
    1,
    1,
    0,
    stream,
    args.data(),
    nullptr));
}

// TODO: may need/want to initialize CUDA context here (refactor into nvrtc call)


}
}
}

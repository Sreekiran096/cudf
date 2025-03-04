/*
 * Copyright (c) 2020-2022, NVIDIA CORPORATION.
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

#include <benchmarks/common/generate_input.hpp>
#include <benchmarks/fixture/benchmark_fixture.hpp>
#include <benchmarks/synchronization/synchronization.hpp>

#include <cudf/column/column_view.hpp>
#include <cudf/reduction.hpp>
#include <cudf/types.hpp>

class Reduction : public cudf::benchmark {
};

template <typename type>
void BM_reduction(benchmark::State& state)
{
  const cudf::size_type column_size{(cudf::size_type)state.range(0)};
  auto const dtype = cudf::type_to_id<type>();
  auto const table = create_random_table({dtype}, row_count{column_size});
  table->get_column(0).set_null_mask(rmm::device_buffer{}, 0);
  cudf::column_view input_column(table->view().column(0));

  for (auto _ : state) {
    cuda_event_timer timer(state, true);
    auto result = cudf::minmax(input_column);
  }
}

#define concat(a, b, c) a##b##c
#define get_agg(op)     concat(cudf::make_, op, _aggregation())

// TYPE, OP
#define RBM_BENCHMARK_DEFINE(name, type, aggregation)                                            \
  BENCHMARK_DEFINE_F(Reduction, name)(::benchmark::State & state) { BM_reduction<type>(state); } \
  BENCHMARK_REGISTER_F(Reduction, name)                                                          \
    ->UseManualTime()                                                                            \
    ->Arg(10000)      /* 10k */                                                                  \
    ->Arg(100000)     /* 100k */                                                                 \
    ->Arg(1000000)    /* 1M */                                                                   \
    ->Arg(10000000)   /* 10M */                                                                  \
    ->Arg(100000000); /* 100M */

#define REDUCE_BENCHMARK_DEFINE(type, aggregation) \
  RBM_BENCHMARK_DEFINE(concat(type, _, aggregation), type, aggregation)

REDUCE_BENCHMARK_DEFINE(bool, minmax);
REDUCE_BENCHMARK_DEFINE(int8_t, minmax);
REDUCE_BENCHMARK_DEFINE(int32_t, minmax);
using cudf::timestamp_ms;
REDUCE_BENCHMARK_DEFINE(timestamp_ms, minmax);
REDUCE_BENCHMARK_DEFINE(float, minmax);

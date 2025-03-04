/*
 * Copyright (c) 2019-2022, NVIDIA CORPORATION.
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

#include <cudf_test/base_fixture.hpp>
#include <cudf_test/column_utilities.hpp>
#include <cudf_test/column_wrapper.hpp>
#include <cudf_test/cudf_gtest.hpp>
#include <cudf_test/io_metadata_utilities.hpp>
#include <cudf_test/iterator_utilities.hpp>
#include <cudf_test/table_utilities.hpp>
#include <cudf_test/type_lists.hpp>

#include <cudf/concatenate.hpp>
#include <cudf/copying.hpp>
#include <cudf/detail/iterator.cuh>
#include <cudf/io/orc.hpp>
#include <cudf/io/orc_metadata.hpp>
#include <cudf/strings/strings_column_view.hpp>
#include <cudf/table/table.hpp>
#include <cudf/table/table_view.hpp>
#include <cudf/utilities/span.hpp>

#include <type_traits>

namespace cudf_io = cudf::io;

template <typename T, typename SourceElementT = T>
using column_wrapper =
  typename std::conditional<std::is_same_v<T, cudf::string_view>,
                            cudf::test::strings_column_wrapper,
                            cudf::test::fixed_width_column_wrapper<T, SourceElementT>>::type;

using str_col     = column_wrapper<cudf::string_view>;
using bool_col    = column_wrapper<bool>;
using int8_col    = column_wrapper<int8_t>;
using int16_col   = column_wrapper<int16_t>;
using int32_col   = column_wrapper<int32_t>;
using int64_col   = column_wrapper<int64_t>;
using float32_col = column_wrapper<float>;
using float64_col = column_wrapper<double>;
using dec32_col   = column_wrapper<numeric::decimal32>;
using dec64_col   = column_wrapper<numeric::decimal64>;
using dec128_col  = column_wrapper<numeric::decimal128>;
using struct_col  = cudf::test::structs_column_wrapper;
template <typename T>
using list_col = cudf::test::lists_column_wrapper<T>;

using column     = cudf::column;
using table      = cudf::table;
using table_view = cudf::table_view;

// Global environment for temporary files
auto const temp_env = static_cast<cudf::test::TempDirTestEnvironment*>(
  ::testing::AddGlobalTestEnvironment(new cudf::test::TempDirTestEnvironment));

template <typename T>
std::unique_ptr<cudf::table> create_random_fixed_table(cudf::size_type num_columns,
                                                       cudf::size_type num_rows,
                                                       bool include_validity)
{
  auto valids =
    cudf::detail::make_counting_transform_iterator(0, [](auto i) { return i % 2 == 0; });
  std::vector<column_wrapper<T>> src_cols(num_columns);
  for (int idx = 0; idx < num_columns; idx++) {
    auto rand_elements =
      cudf::detail::make_counting_transform_iterator(0, [](T i) { return rand(); });
    if (include_validity) {
      src_cols[idx] = column_wrapper<T>(rand_elements, rand_elements + num_rows, valids);
    } else {
      src_cols[idx] = column_wrapper<T>(rand_elements, rand_elements + num_rows);
    }
  }
  std::vector<std::unique_ptr<cudf::column>> columns(num_columns);
  std::transform(src_cols.begin(), src_cols.end(), columns.begin(), [](column_wrapper<T>& in) {
    auto ret                    = in.release();
    [[maybe_unused]] auto nulls = ret->has_nulls();  // pre-cache the null count
    return ret;
  });
  return std::make_unique<cudf::table>(std::move(columns));
}

// Base test fixture for tests
struct OrcWriterTest : public cudf::test::BaseFixture {
};

// Typed test fixture for numeric type tests
template <typename T>
struct OrcWriterNumericTypeTest : public OrcWriterTest {
  auto type() { return cudf::data_type{cudf::type_to_id<T>()}; }
};

// Typed test fixture for timestamp type tests
template <typename T>
struct OrcWriterTimestampTypeTest : public OrcWriterTest {
  auto type() { return cudf::data_type{cudf::type_to_id<T>()}; }
};

// Declare typed test cases
// TODO: Replace with `NumericTypes` when unsigned support is added. Issue #5351
using SupportedTypes = cudf::test::Types<int8_t, int16_t, int32_t, int64_t, bool, float, double>;
TYPED_TEST_SUITE(OrcWriterNumericTypeTest, SupportedTypes);
using SupportedTimestampTypes =
  cudf::test::RemoveIf<cudf::test::ContainedIn<cudf::test::Types<cudf::timestamp_D>>,
                       cudf::test::TimestampTypes>;
TYPED_TEST_SUITE(OrcWriterTimestampTypeTest, SupportedTimestampTypes);

// Base test fixture for chunked writer tests
struct OrcChunkedWriterTest : public cudf::test::BaseFixture {
};

// Typed test fixture for numeric type tests
template <typename T>
struct OrcChunkedWriterNumericTypeTest : public OrcChunkedWriterTest {
  auto type() { return cudf::data_type{cudf::type_to_id<T>()}; }
};

// Declare typed test cases
TYPED_TEST_SUITE(OrcChunkedWriterNumericTypeTest, SupportedTypes);

// Test fixture for reader tests
struct OrcReaderTest : public cudf::test::BaseFixture {
};

// Test fixture for statistics tests
struct OrcStatisticsTest : public cudf::test::BaseFixture {
};

namespace {
// Generates a vector of uniform random values of type T
template <typename T>
inline auto random_values(size_t size)
{
  std::vector<T> values(size);

  using T1 = T;
  using uniform_distribution =
    typename std::conditional_t<std::is_same_v<T1, bool>,
                                std::bernoulli_distribution,
                                std::conditional_t<std::is_floating_point_v<T1>,
                                                   std::uniform_real_distribution<T1>,
                                                   std::uniform_int_distribution<T1>>>;

  static constexpr auto seed = 0xf00d;
  static std::mt19937 engine{seed};
  static uniform_distribution dist{};
  std::generate_n(values.begin(), size, [&]() { return T{dist(engine)}; });

  return values;
}

struct SkipRowTest {
  int test_calls{0};
  SkipRowTest() {}

  std::unique_ptr<table> get_expected_result(const std::string& filepath,
                                             int skip_rows,
                                             int file_num_rows,
                                             int read_num_rows)
  {
    auto sequence = cudf::detail::make_counting_transform_iterator(0, [](auto i) { return i; });
    column_wrapper<int32_t, typename decltype(sequence)::value_type> input_col(
      sequence, sequence + file_num_rows);
    table_view input_table({input_col});

    cudf_io::orc_writer_options out_opts =
      cudf_io::orc_writer_options::builder(cudf_io::sink_info{filepath}, input_table);
    cudf_io::write_orc(out_opts);

    auto begin_sequence = sequence, end_sequence = sequence;
    if (skip_rows < file_num_rows) {
      begin_sequence += skip_rows;
      end_sequence += std::min(skip_rows + read_num_rows, file_num_rows);
    }
    column_wrapper<int32_t, typename decltype(sequence)::value_type> output_col(begin_sequence,
                                                                                end_sequence);
    std::vector<std::unique_ptr<column>> output_cols;
    output_cols.push_back(output_col.release());
    return std::make_unique<table>(std::move(output_cols));
  }

  void test(int skip_rows, int file_num_rows, int read_num_rows)
  {
    auto filepath =
      temp_env->get_temp_filepath("SkipRowTest" + std::to_string(test_calls++) + ".orc");
    auto expected_result = get_expected_result(filepath, skip_rows, file_num_rows, read_num_rows);
    cudf_io::orc_reader_options in_opts =
      cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath})
        .use_index(false)
        .skip_rows(skip_rows)
        .num_rows(read_num_rows);
    auto result = cudf_io::read_orc(in_opts);
    CUDF_TEST_EXPECT_TABLES_EQUAL(expected_result->view(), result.tbl->view());
  }

  void test(int skip_rows, int file_num_rows)
  {
    auto filepath =
      temp_env->get_temp_filepath("SkipRowTest" + std::to_string(test_calls++) + ".orc");
    auto expected_result =
      get_expected_result(filepath, skip_rows, file_num_rows, file_num_rows - skip_rows);
    cudf_io::orc_reader_options in_opts =
      cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath})
        .use_index(false)
        .skip_rows(skip_rows);
    auto result = cudf_io::read_orc(in_opts);
    CUDF_TEST_EXPECT_TABLES_EQUAL(expected_result->view(), result.tbl->view());
  }
};

}  // namespace

TYPED_TEST(OrcWriterNumericTypeTest, SingleColumn)
{
  auto sequence = cudf::detail::make_counting_transform_iterator(0, [](auto i) { return i; });

  constexpr auto num_rows = 100;
  column_wrapper<TypeParam, typename decltype(sequence)::value_type> col(sequence,
                                                                         sequence + num_rows);
  table_view expected({col});

  auto filepath = temp_env->get_temp_filepath("OrcSingleColumn.orc");
  cudf_io::orc_writer_options out_opts =
    cudf_io::orc_writer_options::builder(cudf_io::sink_info{filepath}, expected);
  cudf_io::write_orc(out_opts);

  cudf_io::orc_reader_options in_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath}).use_index(false);
  auto result = cudf_io::read_orc(in_opts);

  CUDF_TEST_EXPECT_TABLES_EQUAL(expected, result.tbl->view());
}

TYPED_TEST(OrcWriterNumericTypeTest, SingleColumnWithNulls)
{
  auto sequence = cudf::detail::make_counting_transform_iterator(0, [](auto i) { return i; });
  auto validity = cudf::detail::make_counting_transform_iterator(0, [](auto i) { return (i % 2); });

  constexpr auto num_rows = 100;
  column_wrapper<TypeParam, typename decltype(sequence)::value_type> col(
    sequence, sequence + num_rows, validity);
  table_view expected({col});

  auto filepath = temp_env->get_temp_filepath("OrcSingleColumnWithNulls.orc");
  cudf_io::orc_writer_options out_opts =
    cudf_io::orc_writer_options::builder(cudf_io::sink_info{filepath}, expected);
  cudf_io::write_orc(out_opts);

  cudf_io::orc_reader_options in_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath}).use_index(false);
  auto result = cudf_io::read_orc(in_opts);

  CUDF_TEST_EXPECT_TABLES_EQUAL(expected, result.tbl->view());
}

TYPED_TEST(OrcWriterTimestampTypeTest, Timestamps)
{
  auto sequence =
    cudf::detail::make_counting_transform_iterator(0, [](auto i) { return (std::rand() / 10); });

  constexpr auto num_rows = 100;
  column_wrapper<TypeParam, typename decltype(sequence)::value_type> col(sequence,
                                                                         sequence + num_rows);
  table_view expected({col});

  auto filepath = temp_env->get_temp_filepath("OrcTimestamps.orc");
  cudf_io::orc_writer_options out_opts =
    cudf_io::orc_writer_options::builder(cudf_io::sink_info{filepath}, expected);
  cudf_io::write_orc(out_opts);

  cudf_io::orc_reader_options in_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath})
      .use_index(false)
      .timestamp_type(this->type());
  auto result = cudf_io::read_orc(in_opts);

  CUDF_TEST_EXPECT_TABLES_EQUAL(expected, result.tbl->view());
}

TYPED_TEST(OrcWriterTimestampTypeTest, TimestampsWithNulls)
{
  auto sequence =
    cudf::detail::make_counting_transform_iterator(0, [](auto i) { return (std::rand() / 10); });
  auto validity =
    cudf::detail::make_counting_transform_iterator(0, [](auto i) { return (i > 30) && (i < 60); });

  constexpr auto num_rows = 100;
  column_wrapper<TypeParam, typename decltype(sequence)::value_type> col(
    sequence, sequence + num_rows, validity);
  table_view expected({col});

  auto filepath = temp_env->get_temp_filepath("OrcTimestampsWithNulls.orc");
  cudf_io::orc_writer_options out_opts =
    cudf_io::orc_writer_options::builder(cudf_io::sink_info{filepath}, expected);
  cudf_io::write_orc(out_opts);

  cudf_io::orc_reader_options in_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath})
      .use_index(false)
      .timestamp_type(this->type());
  auto result = cudf_io::read_orc(in_opts);

  CUDF_TEST_EXPECT_TABLES_EQUAL(expected, result.tbl->view());
}

TYPED_TEST(OrcWriterTimestampTypeTest, TimestampOverflow)
{
  constexpr int64_t max = std::numeric_limits<int64_t>::max();
  auto sequence = cudf::detail::make_counting_transform_iterator(0, [](auto i) { return max - i; });

  constexpr auto num_rows = 100;
  column_wrapper<TypeParam, typename decltype(sequence)::value_type> col(sequence,
                                                                         sequence + num_rows);
  table_view expected({col});

  auto filepath = temp_env->get_temp_filepath("OrcTimestampOverflow.orc");
  cudf_io::orc_writer_options out_opts =
    cudf_io::orc_writer_options::builder(cudf_io::sink_info{filepath}, expected);
  cudf_io::write_orc(out_opts);

  cudf_io::orc_reader_options in_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath})
      .use_index(false)
      .timestamp_type(this->type());
  auto result = cudf_io::read_orc(in_opts);

  CUDF_TEST_EXPECT_TABLES_EQUAL(expected, result.tbl->view());
}

TEST_F(OrcWriterTest, MultiColumn)
{
  constexpr auto num_rows = 10;

  auto col0_data = random_values<bool>(num_rows);
  auto col1_data = random_values<int8_t>(num_rows);
  auto col2_data = random_values<int16_t>(num_rows);
  auto col3_data = random_values<int32_t>(num_rows);
  auto col4_data = random_values<float>(num_rows);
  auto col5_data = random_values<double>(num_rows);
  auto col6_vals = random_values<int64_t>(num_rows);
  auto col6_data = cudf::detail::make_counting_transform_iterator(0, [&](auto i) {
    return numeric::decimal128{col6_vals[i], numeric::scale_type{12}};
  });
  auto col7_data = cudf::detail::make_counting_transform_iterator(0, [&](auto i) {
    return numeric::decimal128{col6_vals[i], numeric::scale_type{-12}};
  });

  bool_col col0(col0_data.begin(), col0_data.end());
  int8_col col1(col1_data.begin(), col1_data.end());
  int16_col col2(col2_data.begin(), col2_data.end());
  int32_col col3(col3_data.begin(), col3_data.end());
  float32_col col4(col4_data.begin(), col4_data.end());
  float64_col col5(col5_data.begin(), col5_data.end());
  dec128_col col6(col6_data, col6_data + num_rows);
  dec128_col col7(col7_data, col7_data + num_rows);

  list_col<int64_t> col8{
    {9, 8}, {7, 6, 5}, {}, {4}, {3, 2, 1, 0}, {20, 21, 22, 23, 24}, {}, {66, 666}, {}, {-1, -2}};

  int32_col child_col{48, 27, 25, 31, 351, 351, 29, 15, -1, -99};
  struct_col col9{child_col};

  table_view expected({col0, col1, col2, col3, col4, col5, col6, col7, col8, col9});

  cudf_io::table_input_metadata expected_metadata(expected);
  expected_metadata.column_metadata[0].set_name("bools");
  expected_metadata.column_metadata[1].set_name("int8s");
  expected_metadata.column_metadata[2].set_name("int16s");
  expected_metadata.column_metadata[3].set_name("int32s");
  expected_metadata.column_metadata[4].set_name("floats");
  expected_metadata.column_metadata[5].set_name("doubles");
  expected_metadata.column_metadata[6].set_name("decimal_pos_scale");
  expected_metadata.column_metadata[7].set_name("decimal_neg_scale");
  expected_metadata.column_metadata[8].set_name("lists");
  expected_metadata.column_metadata[9].set_name("structs");

  auto filepath = temp_env->get_temp_filepath("OrcMultiColumn.orc");
  cudf_io::orc_writer_options out_opts =
    cudf_io::orc_writer_options::builder(cudf_io::sink_info{filepath}, expected)
      .metadata(&expected_metadata);
  cudf_io::write_orc(out_opts);

  cudf_io::orc_reader_options in_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath}).use_index(false);
  auto result = cudf_io::read_orc(in_opts);

  CUDF_TEST_EXPECT_TABLES_EQUAL(expected, result.tbl->view());
  cudf::test::expect_metadata_equal(expected_metadata, result.metadata);
}

TEST_F(OrcWriterTest, MultiColumnWithNulls)
{
  constexpr auto num_rows = 10;

  auto col0_data = random_values<bool>(num_rows);
  auto col1_data = random_values<int8_t>(num_rows);
  auto col2_data = random_values<int16_t>(num_rows);
  auto col3_data = random_values<int32_t>(num_rows);
  auto col4_data = random_values<float>(num_rows);
  auto col5_data = random_values<double>(num_rows);
  auto col6_vals = random_values<int32_t>(num_rows);
  auto col6_data = cudf::detail::make_counting_transform_iterator(0, [&](auto i) {
    return numeric::decimal64{col6_vals[i], numeric::scale_type{2}};
  });
  auto col0_mask =
    cudf::detail::make_counting_transform_iterator(0, [](auto i) { return (i % 2); });
  auto col1_mask =
    cudf::detail::make_counting_transform_iterator(0, [](auto i) { return (i < 2); });
  auto col3_mask =
    cudf::detail::make_counting_transform_iterator(0, [](auto i) { return (i == (num_rows - 1)); });
  auto col4_mask =
    cudf::detail::make_counting_transform_iterator(0, [](auto i) { return (i >= 4 && i <= 6); });
  auto col5_mask =
    cudf::detail::make_counting_transform_iterator(0, [](auto i) { return (i > 8); });
  auto col6_mask =
    cudf::detail::make_counting_transform_iterator(0, [](auto i) { return (i % 3); });

  bool_col col0{col0_data.begin(), col0_data.end(), col0_mask};
  int8_col col1{col1_data.begin(), col1_data.end(), col1_mask};
  int16_col col2(col2_data.begin(), col2_data.end());
  int32_col col3{col3_data.begin(), col3_data.end(), col3_mask};
  float32_col col4{col4_data.begin(), col4_data.end(), col4_mask};
  float64_col col5{col5_data.begin(), col5_data.end(), col5_mask};
  dec64_col col6{col6_data, col6_data + num_rows, col6_mask};
  list_col<int32_t> col7{
    {{9, 8}, {7, 6, 5}, {}, {4}, {3, 2, 1, 0}, {20, 21, 22, 23, 24}, {}, {66, 666}, {}, {-1, -2}},
    col0_mask};
  auto ages_col = cudf::test::fixed_width_column_wrapper<int32_t>{
    {48, 27, 25, 31, 351, 351, 29, 15, -1, -99}, {1, 0, 1, 1, 0, 1, 1, 1, 0, 1}};
  struct_col col8{{ages_col}, {0, 1, 1, 0, 1, 1, 0, 1, 1, 0}};
  table_view expected({col0, col1, col2, col3, col4, col5, col6, col7, col8});

  cudf_io::table_input_metadata expected_metadata(expected);
  expected_metadata.column_metadata[0].set_name("bools");
  expected_metadata.column_metadata[1].set_name("int8s");
  expected_metadata.column_metadata[2].set_name("int16s");
  expected_metadata.column_metadata[3].set_name("int32s");
  expected_metadata.column_metadata[4].set_name("floats");
  expected_metadata.column_metadata[5].set_name("doubles");
  expected_metadata.column_metadata[6].set_name("decimal");
  expected_metadata.column_metadata[7].set_name("lists");
  expected_metadata.column_metadata[8].set_name("structs");

  auto filepath = temp_env->get_temp_filepath("OrcMultiColumnWithNulls.orc");
  cudf_io::orc_writer_options out_opts =
    cudf_io::orc_writer_options::builder(cudf_io::sink_info{filepath}, expected)
      .metadata(&expected_metadata);
  cudf_io::write_orc(out_opts);

  cudf_io::orc_reader_options in_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath}).use_index(false);
  auto result = cudf_io::read_orc(in_opts);

  CUDF_TEST_EXPECT_TABLES_EQUAL(expected, result.tbl->view());
  cudf::test::expect_metadata_equal(expected_metadata, result.metadata);
}

TEST_F(OrcWriterTest, ReadZeroRows)
{
  auto sequence = cudf::detail::make_counting_transform_iterator(0, [](auto i) { return i; });

  constexpr auto num_rows = 10;
  column_wrapper<int64_t, typename decltype(sequence)::value_type> col(sequence,
                                                                       sequence + num_rows);
  table_view expected({col});

  auto filepath = temp_env->get_temp_filepath("OrcSingleColumn.orc");
  cudf_io::orc_writer_options out_opts =
    cudf_io::orc_writer_options::builder(cudf_io::sink_info{filepath}, expected);
  cudf_io::write_orc(out_opts);

  cudf_io::orc_reader_options in_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath})
      .use_index(false)
      .num_rows(0);
  auto result = cudf_io::read_orc(in_opts);

  EXPECT_EQ(0, result.tbl->num_rows());
  EXPECT_EQ(1, result.tbl->num_columns());
}

TEST_F(OrcWriterTest, Strings)
{
  std::vector<const char*> strings{
    "Monday", "Monday", "Friday", "Monday", "Friday", "Friday", "Friday", "Funday"};
  const auto num_rows = strings.size();

  auto seq_col0 = random_values<int>(num_rows);
  auto seq_col2 = random_values<float>(num_rows);

  int32_col col0(seq_col0.begin(), seq_col0.end());
  str_col col1(strings.begin(), strings.end());
  float32_col col2(seq_col2.begin(), seq_col2.end());

  table_view expected({col0, col1, col2});

  cudf_io::table_input_metadata expected_metadata(expected);
  expected_metadata.column_metadata[0].set_name("col_other");
  expected_metadata.column_metadata[1].set_name("col_string");
  expected_metadata.column_metadata[2].set_name("col_another");

  auto filepath = temp_env->get_temp_filepath("OrcStrings.orc");
  cudf_io::orc_writer_options out_opts =
    cudf_io::orc_writer_options::builder(cudf_io::sink_info{filepath}, expected)
      .metadata(&expected_metadata);
  cudf_io::write_orc(out_opts);

  cudf_io::orc_reader_options in_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath}).use_index(false);
  auto result = cudf_io::read_orc(in_opts);

  CUDF_TEST_EXPECT_TABLES_EQUAL(expected, result.tbl->view());
  cudf::test::expect_metadata_equal(expected_metadata, result.metadata);
}

TEST_F(OrcWriterTest, SlicedTable)
{
  // This test checks for writing zero copy, offsetted views into existing cudf tables

  std::vector<const char*> strings{
    "Monday", "Monday", "Friday", "Monday", "Friday", "Friday", "Friday", "Funday"};
  const auto num_rows = strings.size();

  auto seq_col0  = random_values<int32_t>(num_rows);
  auto seq_col2  = random_values<float>(num_rows);
  auto vals_col3 = random_values<int32_t>(num_rows);
  auto seq_col3  = cudf::detail::make_counting_transform_iterator(0, [&](auto i) {
    return numeric::decimal64{vals_col3[i], numeric::scale_type{2}};
  });

  int32_col col0(seq_col0.begin(), seq_col0.end());
  str_col col1(strings.begin(), strings.end());
  float32_col col2(seq_col2.begin(), seq_col2.end());
  float32_col col3(seq_col3, seq_col3 + num_rows);

  list_col<int64_t> col4{
    {9, 8}, {7, 6, 5}, {}, {4}, {3, 2, 1, 0}, {20, 21, 22, 23, 24}, {}, {66, 666}};

  int16_col ages_col{{48, 27, 25, 31, 351, 351, 29, 15}, cudf::test::iterators::null_at(5)};
  struct_col col5{{ages_col}, cudf::test::iterators::null_at(4)};

  table_view expected({col0, col1, col2, col3, col4, col5});

  cudf_io::table_input_metadata expected_metadata(expected);
  expected_metadata.column_metadata[0].set_name("col_other");
  expected_metadata.column_metadata[1].set_name("col_string");
  expected_metadata.column_metadata[2].set_name("col_another");
  expected_metadata.column_metadata[3].set_name("col_decimal");
  expected_metadata.column_metadata[4].set_name("lists");
  expected_metadata.column_metadata[5].set_name("structs");

  auto expected_slice = cudf::slice(expected, {2, static_cast<cudf::size_type>(num_rows)});

  auto filepath = temp_env->get_temp_filepath("SlicedTable.orc");
  cudf_io::orc_writer_options out_opts =
    cudf_io::orc_writer_options::builder(cudf_io::sink_info{filepath}, expected_slice)
      .metadata(&expected_metadata);
  cudf_io::write_orc(out_opts);

  cudf_io::orc_reader_options in_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath});
  auto result = cudf_io::read_orc(in_opts);

  CUDF_TEST_EXPECT_TABLES_EQUAL(expected_slice, result.tbl->view());
  cudf::test::expect_metadata_equal(expected_metadata, result.metadata);
}

TEST_F(OrcWriterTest, HostBuffer)
{
  constexpr auto num_rows = 100 << 10;
  const auto seq_col      = random_values<int>(num_rows);
  int32_col col(seq_col.begin(), seq_col.end());

  table_view expected{{col}};

  cudf_io::table_input_metadata expected_metadata(expected);
  expected_metadata.column_metadata[0].set_name("col_other");

  std::vector<char> out_buffer;
  cudf_io::orc_writer_options out_opts =
    cudf_io::orc_writer_options::builder(cudf_io::sink_info(&out_buffer), expected)
      .metadata(&expected_metadata);
  cudf_io::write_orc(out_opts);

  cudf_io::orc_reader_options in_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info(out_buffer.data(), out_buffer.size()))
      .use_index(false);
  const auto result = cudf_io::read_orc(in_opts);

  CUDF_TEST_EXPECT_TABLES_EQUAL(expected, result.tbl->view());
  cudf::test::expect_metadata_equal(expected_metadata, result.metadata);
}

TEST_F(OrcWriterTest, negTimestampsNano)
{
  // This is a separate test because ORC format has a bug where writing a timestamp between -1 and 0
  // seconds from UNIX epoch is read as that timestamp + 1 second. We mimic that behavior and so
  // this test has to hardcode test values which are < -1 second.
  // Details: https://github.com/rapidsai/cudf/pull/5529#issuecomment-648768925
  using namespace cudf::test;
  auto timestamps_ns = fixed_width_column_wrapper<cudf::timestamp_ns, cudf::timestamp_ns::rep>{
    -131968727238000000,
    -1530705634500000000,
    -1674638741932929000,
  };
  table_view expected({timestamps_ns});

  auto filepath = temp_env->get_temp_filepath("OrcNegTimestamp.orc");
  cudf_io::orc_writer_options out_opts =
    cudf_io::orc_writer_options::builder(cudf_io::sink_info{filepath}, expected);

  cudf_io::write_orc(out_opts);

  cudf_io::orc_reader_options in_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath}).use_index(false);
  auto result = cudf_io::read_orc(in_opts);

  CUDF_TEST_EXPECT_COLUMNS_EQUAL(
    expected.column(0), result.tbl->view().column(0), cudf::test::debug_output_level::ALL_ERRORS);
  CUDF_TEST_EXPECT_TABLES_EQUAL(expected, result.tbl->view());
}

TEST_F(OrcWriterTest, Slice)
{
  int32_col col{{1, 2, 3, 4, 5}, cudf::test::iterators::null_at(3)};
  std::vector<cudf::size_type> indices{2, 5};
  std::vector<cudf::column_view> result = cudf::slice(col, indices);
  cudf::table_view tbl{result};

  auto filepath = temp_env->get_temp_filepath("Slice.orc");
  cudf_io::orc_writer_options out_opts =
    cudf_io::orc_writer_options::builder(cudf_io::sink_info{filepath}, tbl);
  cudf_io::write_orc(out_opts);

  cudf_io::orc_reader_options in_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath});
  auto read_table = cudf_io::read_orc(in_opts);

  CUDF_TEST_EXPECT_TABLES_EQUIVALENT(read_table.tbl->view(), tbl);
}

TEST_F(OrcChunkedWriterTest, SingleTable)
{
  srand(31337);
  auto table1 = create_random_fixed_table<int>(5, 5, true);

  auto filepath = temp_env->get_temp_filepath("ChunkedSingle.orc");
  cudf_io::chunked_orc_writer_options opts =
    cudf_io::chunked_orc_writer_options::builder(cudf_io::sink_info{filepath});
  cudf_io::orc_chunked_writer(opts).write(*table1);

  cudf_io::orc_reader_options read_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath});
  auto result = cudf_io::read_orc(read_opts);

  CUDF_TEST_EXPECT_TABLES_EQUAL(*result.tbl, *table1);
}

TEST_F(OrcChunkedWriterTest, SimpleTable)
{
  srand(31337);
  auto table1 = create_random_fixed_table<int>(5, 5, true);
  auto table2 = create_random_fixed_table<int>(5, 5, true);

  auto full_table = cudf::concatenate(std::vector<table_view>({*table1, *table2}));

  auto filepath = temp_env->get_temp_filepath("ChunkedSimple.orc");
  cudf_io::chunked_orc_writer_options opts =
    cudf_io::chunked_orc_writer_options::builder(cudf_io::sink_info{filepath});
  cudf_io::orc_chunked_writer(opts).write(*table1).write(*table2);

  cudf_io::orc_reader_options read_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath});
  auto result = cudf_io::read_orc(read_opts);

  CUDF_TEST_EXPECT_TABLES_EQUAL(*result.tbl, *full_table);
}

TEST_F(OrcChunkedWriterTest, LargeTables)
{
  srand(31337);
  auto table1 = create_random_fixed_table<int>(512, 4096, true);
  auto table2 = create_random_fixed_table<int>(512, 8192, true);

  auto full_table = cudf::concatenate(std::vector<table_view>({*table1, *table2}));

  auto filepath = temp_env->get_temp_filepath("ChunkedLarge.orc");
  cudf_io::chunked_orc_writer_options opts =
    cudf_io::chunked_orc_writer_options::builder(cudf_io::sink_info{filepath});
  cudf_io::orc_chunked_writer(opts).write(*table1).write(*table2);

  cudf_io::orc_reader_options read_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath});
  auto result = cudf_io::read_orc(read_opts);

  CUDF_TEST_EXPECT_TABLES_EQUAL(*result.tbl, *full_table);
}

TEST_F(OrcChunkedWriterTest, ManyTables)
{
  srand(31337);
  std::vector<std::unique_ptr<table>> tables;
  std::vector<table_view> table_views;
  constexpr int num_tables = 96;
  for (int idx = 0; idx < num_tables; idx++) {
    auto tbl = create_random_fixed_table<int>(16, 64, true);
    table_views.push_back(*tbl);
    tables.push_back(std::move(tbl));
  }

  auto expected = cudf::concatenate(table_views);

  auto filepath = temp_env->get_temp_filepath("ChunkedManyTables.orc");
  cudf_io::chunked_orc_writer_options opts =
    cudf_io::chunked_orc_writer_options::builder(cudf_io::sink_info{filepath});
  cudf_io::orc_chunked_writer writer(opts);
  std::for_each(table_views.begin(), table_views.end(), [&writer](table_view const& tbl) {
    writer.write(tbl);
  });
  writer.close();

  cudf_io::orc_reader_options read_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath});
  auto result = cudf_io::read_orc(read_opts);

  CUDF_TEST_EXPECT_TABLES_EQUAL(*result.tbl, *expected);
}

TEST_F(OrcChunkedWriterTest, Metadata)
{
  std::vector<const char*> strings{
    "Monday", "Tuesday", "THURSDAY", "Wednesday", "Friday", "Sunday", "Saturday"};
  const auto num_rows = strings.size();

  auto seq_col0 = random_values<int>(num_rows);
  auto seq_col2 = random_values<float>(num_rows);

  int32_col col0(seq_col0.begin(), seq_col0.end());
  str_col col1{strings.begin(), strings.end()};
  float32_col col2(seq_col2.begin(), seq_col2.end());

  table_view expected({col0, col1, col2});

  cudf_io::table_input_metadata expected_metadata(expected);
  expected_metadata.column_metadata[0].set_name("col_other");
  expected_metadata.column_metadata[1].set_name("col_string");
  expected_metadata.column_metadata[2].set_name("col_another");

  auto filepath = temp_env->get_temp_filepath("ChunkedMetadata.orc");
  cudf_io::chunked_orc_writer_options opts =
    cudf_io::chunked_orc_writer_options::builder(cudf_io::sink_info{filepath})
      .metadata(&expected_metadata);
  cudf_io::orc_chunked_writer(opts).write(expected).write(expected);

  cudf_io::orc_reader_options read_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath});
  auto result = cudf_io::read_orc(read_opts);

  cudf::test::expect_metadata_equal(expected_metadata, result.metadata);
}

TEST_F(OrcChunkedWriterTest, Strings)
{
  bool mask1[] = {true, true, false, true, true, true, true};
  std::vector<const char*> h_strings1{"four", "score", "and", "seven", "years", "ago", "abcdefgh"};
  str_col strings1(h_strings1.begin(), h_strings1.end(), mask1);
  table_view tbl1({strings1});

  bool mask2[] = {false, true, true, true, true, true, true};
  std::vector<const char*> h_strings2{"ooooo", "ppppppp", "fff", "j", "cccc", "bbb", "zzzzzzzzzzz"};
  str_col strings2(h_strings2.begin(), h_strings2.end(), mask2);
  table_view tbl2({strings2});

  auto expected = cudf::concatenate(std::vector<table_view>({tbl1, tbl2}));

  auto filepath = temp_env->get_temp_filepath("ChunkedStrings.orc");
  cudf_io::chunked_orc_writer_options opts =
    cudf_io::chunked_orc_writer_options::builder(cudf_io::sink_info{filepath});
  cudf_io::orc_chunked_writer(opts).write(tbl1).write(tbl2);

  cudf_io::orc_reader_options read_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath});
  auto result = cudf_io::read_orc(read_opts);

  CUDF_TEST_EXPECT_TABLES_EQUAL(*result.tbl, *expected);
}

TEST_F(OrcChunkedWriterTest, MismatchedTypes)
{
  srand(31337);
  auto table1 = create_random_fixed_table<int>(4, 4, true);
  auto table2 = create_random_fixed_table<float>(4, 4, true);

  auto filepath = temp_env->get_temp_filepath("ChunkedMismatchedTypes.orc");
  cudf_io::chunked_orc_writer_options opts =
    cudf_io::chunked_orc_writer_options::builder(cudf_io::sink_info{filepath});
  cudf_io::orc_chunked_writer writer(opts);
  writer.write(*table1);
  EXPECT_THROW(writer.write(*table2), cudf::logic_error);
}

TEST_F(OrcChunkedWriterTest, ChunkedWritingAfterClosing)
{
  srand(31337);
  auto table1 = create_random_fixed_table<int>(4, 4, true);

  auto filepath = temp_env->get_temp_filepath("ChunkedWritingAfterClosing.orc");
  cudf_io::chunked_orc_writer_options opts =
    cudf_io::chunked_orc_writer_options::builder(cudf_io::sink_info{filepath});
  cudf_io::orc_chunked_writer writer(opts);
  writer.write(*table1);
  writer.close();
  EXPECT_THROW(writer.write(*table1), cudf::logic_error);
}

TEST_F(OrcChunkedWriterTest, MismatchedStructure)
{
  srand(31337);
  auto table1 = create_random_fixed_table<int>(4, 4, true);
  auto table2 = create_random_fixed_table<int>(3, 4, true);

  auto filepath = temp_env->get_temp_filepath("ChunkedMismatchedStructure.orc");
  cudf_io::chunked_orc_writer_options opts =
    cudf_io::chunked_orc_writer_options::builder(cudf_io::sink_info{filepath});
  cudf_io::orc_chunked_writer writer(opts);
  writer.write(*table1);
  EXPECT_THROW(writer.write(*table2), cudf::logic_error);
}

TEST_F(OrcChunkedWriterTest, ReadStripes)
{
  srand(31337);
  auto table1 = create_random_fixed_table<int>(5, 5, true);
  auto table2 = create_random_fixed_table<int>(5, 5, true);

  auto full_table = cudf::concatenate(std::vector<table_view>({*table2, *table1, *table2}));

  auto filepath = temp_env->get_temp_filepath("ChunkedStripes.orc");
  cudf_io::chunked_orc_writer_options opts =
    cudf_io::chunked_orc_writer_options::builder(cudf_io::sink_info{filepath});
  cudf_io::orc_chunked_writer(opts).write(*table1).write(*table2);

  cudf_io::orc_reader_options read_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath}).stripes({{1, 0, 1}});
  auto result = cudf_io::read_orc(read_opts);

  CUDF_TEST_EXPECT_TABLES_EQUAL(*result.tbl, *full_table);
}

TEST_F(OrcChunkedWriterTest, ReadStripesError)
{
  srand(31337);
  auto table1 = create_random_fixed_table<int>(5, 5, true);

  auto filepath = temp_env->get_temp_filepath("ChunkedStripesError.orc");
  cudf_io::chunked_orc_writer_options opts =
    cudf_io::chunked_orc_writer_options::builder(cudf_io::sink_info{filepath});
  cudf_io::orc_chunked_writer(opts).write(*table1);

  cudf_io::orc_reader_options read_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath}).stripes({{0, 1}});
  EXPECT_THROW(cudf_io::read_orc(read_opts), cudf::logic_error);
  read_opts.set_stripes({{-1}});
  EXPECT_THROW(cudf_io::read_orc(read_opts), cudf::logic_error);
}

TYPED_TEST(OrcChunkedWriterNumericTypeTest, UnalignedSize)
{
  // write out two 31 row tables and make sure they get
  // read back with all their validity bits in the right place

  using T = TypeParam;

  int num_els = 31;

  bool mask[] = {false, true, true, true, true, true, true, true, true, true, true,
                 true,  true, true, true, true, true, true, true, true, true, true,
                 true,  true, true, true, true, true, true, true, true};

  T c1a[num_els];
  std::fill(c1a, c1a + num_els, static_cast<T>(5));
  T c1b[num_els];
  std::fill(c1b, c1b + num_els, static_cast<T>(6));
  column_wrapper<T> c1a_w(c1a, c1a + num_els, mask);
  column_wrapper<T> c1b_w(c1b, c1b + num_els, mask);
  table_view tbl1({c1a_w, c1b_w});

  T c2a[num_els];
  std::fill(c2a, c2a + num_els, static_cast<T>(8));
  T c2b[num_els];
  std::fill(c2b, c2b + num_els, static_cast<T>(9));
  column_wrapper<T> c2a_w(c2a, c2a + num_els, mask);
  column_wrapper<T> c2b_w(c2b, c2b + num_els, mask);
  table_view tbl2({c2a_w, c2b_w});

  auto expected = cudf::concatenate(std::vector<table_view>({tbl1, tbl2}));

  auto filepath = temp_env->get_temp_filepath("ChunkedUnalignedSize.orc");
  cudf_io::chunked_orc_writer_options opts =
    cudf_io::chunked_orc_writer_options::builder(cudf_io::sink_info{filepath});
  cudf_io::orc_chunked_writer(opts).write(tbl1).write(tbl2);

  cudf_io::orc_reader_options read_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath});
  auto result = cudf_io::read_orc(read_opts);

  CUDF_TEST_EXPECT_TABLES_EQUAL(*result.tbl, *expected);
}

TYPED_TEST(OrcChunkedWriterNumericTypeTest, UnalignedSize2)
{
  // write out two 33 row tables and make sure they get
  // read back with all their validity bits in the right place

  using T = TypeParam;

  int num_els = 33;

  bool mask[] = {false, true, true, true, true, true, true, true, true, true, true,
                 true,  true, true, true, true, true, true, true, true, true, true,
                 true,  true, true, true, true, true, true, true, true, true, true};

  T c1a[num_els];
  std::fill(c1a, c1a + num_els, static_cast<T>(5));
  T c1b[num_els];
  std::fill(c1b, c1b + num_els, static_cast<T>(6));
  column_wrapper<T> c1a_w(c1a, c1a + num_els, mask);
  column_wrapper<T> c1b_w(c1b, c1b + num_els, mask);
  table_view tbl1({c1a_w, c1b_w});

  T c2a[num_els];
  std::fill(c2a, c2a + num_els, static_cast<T>(8));
  T c2b[num_els];
  std::fill(c2b, c2b + num_els, static_cast<T>(9));
  column_wrapper<T> c2a_w(c2a, c2a + num_els, mask);
  column_wrapper<T> c2b_w(c2b, c2b + num_els, mask);
  table_view tbl2({c2a_w, c2b_w});

  auto expected = cudf::concatenate(std::vector<table_view>({tbl1, tbl2}));

  auto filepath = temp_env->get_temp_filepath("ChunkedUnalignedSize2.orc");
  cudf_io::chunked_orc_writer_options opts =
    cudf_io::chunked_orc_writer_options::builder(cudf_io::sink_info{filepath});
  cudf_io::orc_chunked_writer(opts).write(tbl1).write(tbl2);

  cudf_io::orc_reader_options read_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath});
  auto result = cudf_io::read_orc(read_opts);

  CUDF_TEST_EXPECT_TABLES_EQUAL(*result.tbl, *expected);
}

TEST_F(OrcReaderTest, CombinedSkipRowTest)
{
  SkipRowTest skip_row;
  skip_row.test(50, 75);
  skip_row.test(2, 100);
  skip_row.test(2, 100, 50);
  skip_row.test(2, 100, 98);
  skip_row.test(2, 100, 99);
  skip_row.test(2, 100, 100);
  skip_row.test(2, 100, 110);
}

TEST_F(OrcStatisticsTest, Basic)
{
  auto sequence = cudf::detail::make_counting_transform_iterator(0, [](auto i) { return i; });
  auto validity = cudf::detail::make_counting_transform_iterator(0, [](auto i) { return i % 2; });

  std::vector<const char*> strings{
    "Monday", "Monday", "Friday", "Monday", "Friday", "Friday", "Friday", "Wednesday", "Tuesday"};
  int num_rows = strings.size();

  column_wrapper<int32_t, typename decltype(sequence)::value_type> col1(
    sequence, sequence + num_rows, validity);
  column_wrapper<float, typename decltype(sequence)::value_type> col2(
    sequence, sequence + num_rows, validity);
  column_wrapper<cudf::string_view> col3{strings.begin(), strings.end()};
  column_wrapper<bool, typename decltype(sequence)::value_type> col4(sequence, sequence + num_rows);
  column_wrapper<cudf::timestamp_s, typename decltype(sequence)::value_type> col5(
    sequence, sequence + num_rows, validity);
  table_view expected({col1, col2, col3, col4, col5});

  auto filepath = temp_env->get_temp_filepath("OrcStatsMerge.orc");

  cudf_io::orc_writer_options out_opts =
    cudf_io::orc_writer_options::builder(cudf_io::sink_info{filepath}, expected);
  cudf_io::write_orc(out_opts);

  auto const stats = cudf_io::read_parsed_orc_statistics(cudf_io::source_info{filepath});

  auto const expected_column_names =
    std::vector<std::string>{"", "_col0", "_col1", "_col2", "_col3", "_col4"};
  EXPECT_EQ(stats.column_names, expected_column_names);

  auto validate_statistics = [&](std::vector<cudf_io::column_statistics> const& stats) {
    auto& s0 = stats[0];
    EXPECT_EQ(*s0.number_of_values, 9ul);

    auto& s1 = stats[1];
    EXPECT_EQ(*s1.number_of_values, 4ul);
    auto& ts1 = std::get<cudf_io::integer_statistics>(s1.type_specific_stats);
    EXPECT_EQ(*ts1.minimum, 1);
    EXPECT_EQ(*ts1.maximum, 7);
    EXPECT_EQ(*ts1.sum, 16);

    auto& s2 = stats[2];
    EXPECT_EQ(*s2.number_of_values, 4ul);
    auto& ts2 = std::get<cudf_io::double_statistics>(s2.type_specific_stats);
    EXPECT_EQ(*ts2.minimum, 1.);
    EXPECT_EQ(*ts2.maximum, 7.);
    // No sum ATM, filed #7087
    ASSERT_FALSE(ts2.sum);

    auto& s3 = stats[3];
    EXPECT_EQ(*s3.number_of_values, 9ul);
    auto& ts3 = std::get<cudf_io::string_statistics>(s3.type_specific_stats);
    EXPECT_EQ(*ts3.minimum, "Friday");
    EXPECT_EQ(*ts3.maximum, "Wednesday");
    EXPECT_EQ(*ts3.sum, 58ul);

    auto& s4 = stats[4];
    EXPECT_EQ(*s4.number_of_values, 9ul);
    EXPECT_EQ(std::get<cudf_io::bucket_statistics>(s4.type_specific_stats).count[0], 8ul);

    auto& s5 = stats[5];
    EXPECT_EQ(*s5.number_of_values, 4ul);
    auto& ts5 = std::get<cudf_io::timestamp_statistics>(s5.type_specific_stats);
    EXPECT_EQ(*ts5.minimum_utc, 1000);
    EXPECT_EQ(*ts5.maximum_utc, 7000);
    ASSERT_FALSE(ts5.minimum);
    ASSERT_FALSE(ts5.maximum);
  };

  validate_statistics(stats.file_stats);
  // There's only one stripe, so column stats are the same as stripe stats
  validate_statistics(stats.stripes_stats[0]);
}

TEST_F(OrcWriterTest, SlicedValidMask)
{
  std::vector<const char*> strings;
  // Need more than 32 elements to reproduce the issue
  for (int i = 0; i < 34; ++i)
    strings.emplace_back("a long string to make sure overflow affects the output");
  // An element is null only to enforce the output column to be nullable
  str_col col{strings.begin(), strings.end(), cudf::test::iterators::null_at(32)};

  // Bug tested here is easiest to reproduce when column_offset % 32 is 31
  std::vector<cudf::size_type> indices{31, 34};
  auto sliced_col = cudf::slice(static_cast<cudf::column_view>(col), indices);
  cudf::table_view tbl{sliced_col};

  cudf_io::table_input_metadata expected_metadata(tbl);
  expected_metadata.column_metadata[0].set_name("col_string");

  auto filepath = temp_env->get_temp_filepath("OrcStrings.orc");
  cudf_io::orc_writer_options out_opts =
    cudf_io::orc_writer_options::builder(cudf_io::sink_info{filepath}, tbl)
      .metadata(&expected_metadata);
  cudf_io::write_orc(out_opts);

  cudf_io::orc_reader_options in_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath}).use_index(false);
  auto result = cudf_io::read_orc(in_opts);

  CUDF_TEST_EXPECT_TABLES_EQUAL(tbl, result.tbl->view());
  cudf::test::expect_metadata_equal(expected_metadata, result.metadata);
}

TEST_F(OrcReaderTest, SingleInputs)
{
  srand(31533);
  auto table1 = create_random_fixed_table<int>(5, 5, true);

  auto filepath1 = temp_env->get_temp_filepath("SimpleTable1.orc");
  cudf_io::orc_writer_options write_opts =
    cudf_io::orc_writer_options::builder(cudf_io::sink_info{filepath1}, table1->view());
  cudf_io::write_orc(write_opts);

  cudf_io::orc_reader_options read_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{{filepath1}});
  auto result = cudf_io::read_orc(read_opts);

  CUDF_TEST_EXPECT_TABLES_EQUAL(*result.tbl, *table1);
}

TEST_F(OrcReaderTest, MultipleInputs)
{
  srand(31537);
  auto table1 = create_random_fixed_table<int>(5, 5, true);
  auto table2 = create_random_fixed_table<int>(5, 5, true);

  auto full_table = cudf::concatenate(std::vector<table_view>({*table1, *table2}));

  auto const filepath1 = temp_env->get_temp_filepath("SimpleTable1.orc");
  {
    cudf_io::orc_writer_options out_opts =
      cudf_io::orc_writer_options::builder(cudf_io::sink_info{filepath1}, table1->view());
    cudf_io::write_orc(out_opts);
  }

  auto const filepath2 = temp_env->get_temp_filepath("SimpleTable2.orc");
  {
    cudf_io::orc_writer_options out_opts =
      cudf_io::orc_writer_options::builder(cudf_io::sink_info{filepath2}, table2->view());
    cudf_io::write_orc(out_opts);
  }

  cudf_io::orc_reader_options read_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{{filepath1, filepath2}});
  auto result = cudf_io::read_orc(read_opts);

  CUDF_TEST_EXPECT_TABLES_EQUAL(*result.tbl, *full_table);
}

struct OrcWriterTestDecimal : public OrcWriterTest,
                              public ::testing::WithParamInterface<std::tuple<int, int>> {
};

TEST_P(OrcWriterTestDecimal, Decimal64)
{
  auto const [num_rows, scale] = GetParam();

  // Using int16_t because scale causes values to overflow if they already require 32 bits
  auto const vals = random_values<int32_t>(num_rows);
  auto data       = cudf::detail::make_counting_transform_iterator(0, [&](auto i) {
    return numeric::decimal64{vals[i], numeric::scale_type{scale}};
  });
  auto mask = cudf::detail::make_counting_transform_iterator(0, [](auto i) { return i % 7 == 0; });
  dec64_col col{data, data + num_rows, mask};
  cudf::table_view tbl({static_cast<cudf::column_view>(col)});

  auto filepath = temp_env->get_temp_filepath("Decimal64.orc");
  cudf_io::orc_writer_options out_opts =
    cudf_io::orc_writer_options::builder(cudf_io::sink_info{filepath}, tbl);

  cudf_io::write_orc(out_opts);

  cudf_io::orc_reader_options in_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath});
  auto result = cudf_io::read_orc(in_opts);

  CUDF_TEST_EXPECT_COLUMNS_EQUAL(tbl.column(0), result.tbl->view().column(0));
}

INSTANTIATE_TEST_CASE_P(OrcWriterTest,
                        OrcWriterTestDecimal,
                        ::testing::Combine(::testing::Values(1, 10000, 10001, 34567),
                                           ::testing::Values(-2, 0, 2)));

TEST_F(OrcWriterTest, Decimal32)
{
  constexpr auto num_rows = 12000;

  // Using int16_t because scale causes values to overflow if they already require 32 bits
  auto const vals = random_values<int16_t>(num_rows);
  auto data       = cudf::detail::make_counting_transform_iterator(0, [&vals](auto i) {
    return numeric::decimal32{vals[i], numeric::scale_type{2}};
  });
  auto mask = cudf::detail::make_counting_transform_iterator(0, [](auto i) { return i % 13; });
  dec32_col col{data, data + num_rows, mask};
  cudf::table_view expected({col});

  auto filepath = temp_env->get_temp_filepath("Decimal32.orc");
  cudf_io::orc_writer_options out_opts =
    cudf_io::orc_writer_options::builder(cudf_io::sink_info{filepath}, expected);

  cudf_io::write_orc(out_opts);

  cudf_io::orc_reader_options in_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath});
  auto result = cudf_io::read_orc(in_opts);

  CUDF_TEST_EXPECT_COLUMNS_EQUAL(col, result.tbl->view().column(0));
}

TEST_F(OrcStatisticsTest, Overflow)
{
  int num_rows       = 10;
  auto too_large_seq = cudf::detail::make_counting_transform_iterator(
    0, [](auto i) { return i * (std::numeric_limits<int64_t>::max() / 20); });
  auto too_small_seq = cudf::detail::make_counting_transform_iterator(
    0, [](auto i) { return i * (std::numeric_limits<int64_t>::min() / 20); });
  auto not_too_large_seq = cudf::detail::make_counting_transform_iterator(
    0, [](auto i) { return i * (std::numeric_limits<int64_t>::max() / 200); });
  auto not_too_small_seq = cudf::detail::make_counting_transform_iterator(
    0, [](auto i) { return i * (std::numeric_limits<int64_t>::min() / 200); });
  auto validity = cudf::detail::make_counting_transform_iterator(0, [](auto i) { return i % 2; });

  column_wrapper<int64_t, typename decltype(too_large_seq)::value_type> col1(
    too_large_seq, too_large_seq + num_rows, validity);
  column_wrapper<int64_t, typename decltype(too_small_seq)::value_type> col2(
    too_small_seq, too_small_seq + num_rows, validity);
  column_wrapper<int64_t, typename decltype(not_too_large_seq)::value_type> col3(
    not_too_large_seq, not_too_large_seq + num_rows, validity);
  column_wrapper<int64_t, typename decltype(not_too_small_seq)::value_type> col4(
    not_too_small_seq, not_too_small_seq + num_rows, validity);
  table_view tbl({col1, col2, col3, col4});

  auto filepath = temp_env->get_temp_filepath("OrcStatsMerge.orc");

  cudf_io::orc_writer_options out_opts =
    cudf_io::orc_writer_options::builder(cudf_io::sink_info{filepath}, tbl);
  cudf_io::write_orc(out_opts);

  auto const stats = cudf_io::read_parsed_orc_statistics(cudf_io::source_info{filepath});

  auto check_sum_exist = [&](int idx, bool expected) {
    auto const& s  = stats.file_stats[idx];
    auto const& ts = std::get<cudf_io::integer_statistics>(s.type_specific_stats);
    EXPECT_EQ(ts.sum.has_value(), expected);
  };
  check_sum_exist(1, false);
  check_sum_exist(2, false);
  check_sum_exist(3, true);
  check_sum_exist(4, true);
}
struct OrcWriterTestStripes
  : public OrcWriterTest,
    public ::testing::WithParamInterface<std::tuple<size_t, cudf::size_type>> {
};

TEST_P(OrcWriterTestStripes, StripeSize)
{
  constexpr auto num_rows            = 1000000;
  auto const [size_bytes, size_rows] = GetParam();

  const auto seq_col = random_values<int>(num_rows);
  const auto validity =
    cudf::detail::make_counting_transform_iterator(0, [](auto i) { return true; });
  column_wrapper<int64_t> col{seq_col.begin(), seq_col.end(), validity};

  std::vector<std::unique_ptr<column>> cols;
  cols.push_back(col.release());
  const auto expected = std::make_unique<table>(std::move(cols));

  auto validate = [&](std::vector<char> const& orc_buffer) {
    auto const expected_stripe_num =
      std::max<cudf::size_type>(num_rows / size_rows, (num_rows * sizeof(int64_t)) / size_bytes);
    auto const stats = cudf_io::read_parsed_orc_statistics(
      cudf_io::source_info(orc_buffer.data(), orc_buffer.size()));
    EXPECT_EQ(stats.stripes_stats.size(), expected_stripe_num);

    cudf_io::orc_reader_options in_opts =
      cudf_io::orc_reader_options::builder(
        cudf_io::source_info(orc_buffer.data(), orc_buffer.size()))
        .use_index(false);
    auto result = cudf_io::read_orc(in_opts);

    CUDF_TEST_EXPECT_TABLES_EQUAL(expected->view(), result.tbl->view());
  };

  {
    std::vector<char> out_buffer_chunked;
    cudf_io::chunked_orc_writer_options opts =
      cudf_io::chunked_orc_writer_options::builder(cudf_io::sink_info(&out_buffer_chunked))
        .stripe_size_rows(size_rows)
        .stripe_size_bytes(size_bytes);
    cudf_io::orc_chunked_writer(opts).write(expected->view());
    validate(out_buffer_chunked);
  }
  {
    std::vector<char> out_buffer;
    cudf_io::orc_writer_options out_opts =
      cudf_io::orc_writer_options::builder(cudf_io::sink_info(&out_buffer), expected->view())
        .stripe_size_rows(size_rows)
        .stripe_size_bytes(size_bytes);
    cudf_io::write_orc(out_opts);
    validate(out_buffer);
  }
}

INSTANTIATE_TEST_CASE_P(OrcWriterTest,
                        OrcWriterTestStripes,
                        ::testing::Values(std::make_tuple(800000ul, 1000000),
                                          std::make_tuple(2000000ul, 1000000),
                                          std::make_tuple(4000000ul, 1000000),
                                          std::make_tuple(8000000ul, 1000000),
                                          std::make_tuple(8000000ul, 500000),
                                          std::make_tuple(8000000ul, 250000),
                                          std::make_tuple(8000000ul, 100000)));

TEST_F(OrcWriterTest, StripeSizeInvalid)
{
  const auto unused_table = std::make_unique<table>();
  std::vector<char> out_buffer;

  EXPECT_THROW(
    cudf_io::orc_writer_options::builder(cudf_io::sink_info(&out_buffer), unused_table->view())
      .stripe_size_rows(511),
    cudf::logic_error);
  EXPECT_THROW(
    cudf_io::orc_writer_options::builder(cudf_io::sink_info(&out_buffer), unused_table->view())
      .stripe_size_bytes(63 << 10),
    cudf::logic_error);
  EXPECT_THROW(
    cudf_io::orc_writer_options::builder(cudf_io::sink_info(&out_buffer), unused_table->view())
      .row_index_stride(511),
    cudf::logic_error);
}

TEST_F(OrcWriterTest, TestMap)
{
  auto const num_rows       = 1200000;
  auto const lists_per_row  = 4;
  auto const num_child_rows = (num_rows * lists_per_row) / 2;  // half due to validity

  auto keys      = random_values<int>(num_child_rows);
  auto vals      = random_values<float>(num_child_rows);
  auto vals_mask = cudf::detail::make_counting_transform_iterator(0, [](auto i) { return i % 3; });
  int32_col keys_col(keys.begin(), keys.end());
  float32_col vals_col{vals.begin(), vals.end(), vals_mask};
  auto s_col = struct_col({keys_col, vals_col}).release();

  auto valids = cudf::detail::make_counting_transform_iterator(0, [](auto i) { return i % 2; });

  std::vector<int> row_offsets(num_rows + 1);
  int offset = 0;
  for (int idx = 0; idx < (num_rows) + 1; ++idx) {
    row_offsets[idx] = offset;
    if (valids[idx]) { offset += lists_per_row; }
  }
  int32_col offsets(row_offsets.begin(), row_offsets.end());

  auto num_list_rows = static_cast<cudf::column_view>(offsets).size() - 1;
  auto list_col =
    cudf::make_lists_column(num_list_rows,
                            offsets.release(),
                            std::move(s_col),
                            cudf::UNKNOWN_NULL_COUNT,
                            cudf::test::detail::make_null_mask(valids, valids + num_list_rows));

  table_view expected({*list_col});

  cudf_io::table_input_metadata expected_metadata(expected);
  expected_metadata.column_metadata[0].set_list_column_as_map();

  auto filepath = temp_env->get_temp_filepath("MapColumn.orc");
  cudf_io::orc_writer_options out_opts =
    cudf_io::orc_writer_options::builder(cudf_io::sink_info{filepath}, expected)
      .metadata(&expected_metadata);
  cudf_io::write_orc(out_opts);

  cudf_io::orc_reader_options in_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath}).use_index(false);
  auto result = cudf_io::read_orc(in_opts);

  CUDF_TEST_EXPECT_TABLES_EQUAL(expected, result.tbl->view());
  cudf::test::expect_metadata_equal(expected_metadata, result.metadata);
}

TEST_F(OrcReaderTest, NestedColumnSelection)
{
  auto const num_rows  = 1000;
  auto child_col1_data = random_values<int32_t>(num_rows);
  auto child_col2_data = random_values<int64_t>(num_rows);
  auto validity = cudf::detail::make_counting_transform_iterator(0, [](auto i) { return i % 3; });
  int32_col child_col1{child_col1_data.begin(), child_col1_data.end(), validity};
  int64_col child_col2{child_col2_data.begin(), child_col2_data.end(), validity};
  struct_col s_col{child_col1, child_col2};
  table_view expected({s_col});

  cudf_io::table_input_metadata expected_metadata(expected);
  expected_metadata.column_metadata[0].set_name("struct_s");
  expected_metadata.column_metadata[0].child(0).set_name("field_a");
  expected_metadata.column_metadata[0].child(1).set_name("field_b");

  auto filepath = temp_env->get_temp_filepath("OrcNestedSelection.orc");
  cudf_io::orc_writer_options out_opts =
    cudf_io::orc_writer_options::builder(cudf_io::sink_info{filepath}, expected)
      .metadata(&expected_metadata);
  cudf_io::write_orc(out_opts);

  cudf_io::orc_reader_options in_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath})
      .use_index(false)
      .columns({"struct_s.field_b"});
  auto result = cudf_io::read_orc(in_opts);

  // Verify that only one child column is included in the output table
  ASSERT_EQ(1, result.tbl->view().column(0).num_children());
  // Verify that the first child column is `field_b`
  int64_col expected_col{child_col2_data.begin(), child_col2_data.end(), validity};
  CUDF_TEST_EXPECT_COLUMNS_EQUIVALENT(expected_col, result.tbl->view().column(0).child(0));
  ASSERT_EQ("field_b", result.metadata.schema_info[0].children[0].name);
}

TEST_F(OrcReaderTest, DecimalOptions)
{
  constexpr auto num_rows = 10;
  auto col_vals           = random_values<int64_t>(num_rows);
  auto col_data           = cudf::detail::make_counting_transform_iterator(0, [&](auto i) {
    return numeric::decimal128{col_vals[i], numeric::scale_type{2}};
  });
  auto mask = cudf::detail::make_counting_transform_iterator(0, [](auto i) { return i % 3 == 0; });

  dec128_col col{col_data, col_data + num_rows, mask};
  table_view expected({col});

  cudf_io::table_input_metadata expected_metadata(expected);
  expected_metadata.column_metadata[0].set_name("dec");

  auto filepath = temp_env->get_temp_filepath("OrcDecimalOptions.orc");
  cudf_io::orc_writer_options out_opts =
    cudf_io::orc_writer_options::builder(cudf_io::sink_info{filepath}, expected)
      .metadata(&expected_metadata);
  cudf_io::write_orc(out_opts);

  cudf_io::orc_reader_options valid_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath})
      .decimal128_columns({"dec", "fake_name"});
  // Should not throw, even with "fake name"
  EXPECT_NO_THROW(cudf_io::read_orc(valid_opts));
}

TEST_F(OrcWriterTest, DecimalOptionsNested)
{
  auto const num_rows = 100;

  auto dec_vals  = random_values<int32_t>(num_rows);
  auto dec1_data = cudf::detail::make_counting_transform_iterator(0, [&](auto i) {
    return numeric::decimal64{dec_vals[i], numeric::scale_type{2}};
  });
  auto dec2_data = cudf::detail::make_counting_transform_iterator(0, [&](auto i) {
    return numeric::decimal128{dec_vals[i], numeric::scale_type{2}};
  });
  dec64_col dec1_col(dec1_data, dec1_data + num_rows);
  dec128_col dec2_col(dec2_data, dec2_data + num_rows);
  auto child_struct_col = cudf::test::structs_column_wrapper{dec1_col, dec2_col};

  auto int_vals = random_values<int32_t>(num_rows);
  int32_col int_col(int_vals.begin(), int_vals.end());
  auto map_struct_col = struct_col({child_struct_col, int_col}).release();

  std::vector<int> row_offsets(num_rows + 1);
  std::iota(row_offsets.begin(), row_offsets.end(), 0);
  int32_col offsets(row_offsets.begin(), row_offsets.end());

  auto map_list_col = cudf::make_lists_column(
    num_rows, offsets.release(), std::move(map_struct_col), 0, rmm::device_buffer{});

  table_view expected({*map_list_col});

  cudf_io::table_input_metadata expected_metadata(expected);
  expected_metadata.column_metadata[0].set_name("maps");
  expected_metadata.column_metadata[0].set_list_column_as_map();
  expected_metadata.column_metadata[0].child(1).child(0).child(0).set_name("dec64");
  expected_metadata.column_metadata[0].child(1).child(0).child(1).set_name("dec128");

  auto filepath = temp_env->get_temp_filepath("OrcMultiColumn.orc");
  cudf_io::orc_writer_options out_opts =
    cudf_io::orc_writer_options::builder(cudf_io::sink_info{filepath}, expected)
      .metadata(&expected_metadata);
  cudf_io::write_orc(out_opts);

  cudf_io::orc_reader_options in_opts =
    cudf_io::orc_reader_options::builder(cudf_io::source_info{filepath})
      .use_index(false)
      // One less level of nesting because children of map columns are the child struct's children
      .decimal128_columns({"maps.0.dec64"});
  auto result = cudf_io::read_orc(in_opts);

  // Both columns should be read as decimal128
  CUDF_TEST_EXPECT_COLUMNS_EQUIVALENT(result.tbl->view().column(0).child(1).child(0).child(0),
                                      result.tbl->view().column(0).child(1).child(0).child(1));
}

CUDF_TEST_PROGRAM_MAIN()

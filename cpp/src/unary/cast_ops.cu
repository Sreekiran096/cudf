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

#include <cudf/column/column.hpp>
#include <cudf/detail/binaryop.hpp>
#include <cudf/detail/fill.hpp>
#include <cudf/detail/null_mask.hpp>
#include <cudf/detail/nvtx/ranges.hpp>
#include <cudf/detail/unary.hpp>
#include <cudf/fixed_point/fixed_point.hpp>
#include <cudf/null_mask.hpp>
#include <cudf/scalar/scalar_factories.hpp>
#include <cudf/unary.hpp>
#include <cudf/utilities/traits.hpp>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/exec_policy.hpp>

#include <thrust/transform.h>

namespace cudf {
namespace detail {
namespace {  // anonymous namespace
template <typename _TargetT>
struct unary_cast {
  template <
    typename SourceT,
    typename TargetT                                                                = _TargetT,
    std::enable_if_t<(cudf::is_numeric<SourceT>() && cudf::is_numeric<TargetT>())>* = nullptr>
  __device__ inline TargetT operator()(SourceT const element)
  {
    return static_cast<TargetT>(element);
  }

  template <
    typename SourceT,
    typename TargetT                                                                    = _TargetT,
    std::enable_if_t<(cudf::is_timestamp<SourceT>() && cudf::is_timestamp<TargetT>())>* = nullptr>
  __device__ inline TargetT operator()(SourceT const element)
  {
    // Convert source tick counts into target tick counts without blindly truncating them
    // by dividing the respective duration time periods (which may not work for time before
    // UNIX epoch)
    return TargetT{cuda::std::chrono::floor<TargetT::duration>(element.time_since_epoch())};
  }

  template <
    typename SourceT,
    typename TargetT                                                                  = _TargetT,
    std::enable_if_t<(cudf::is_duration<SourceT>() && cudf::is_duration<TargetT>())>* = nullptr>
  __device__ inline TargetT operator()(SourceT const element)
  {
    return TargetT{cuda::std::chrono::floor<TargetT>(element)};
  }

  template <
    typename SourceT,
    typename TargetT                                                               = _TargetT,
    std::enable_if_t<cudf::is_numeric<SourceT>() && cudf::is_duration<TargetT>()>* = nullptr>
  __device__ inline TargetT operator()(SourceT const element)
  {
    return TargetT{static_cast<typename TargetT::rep>(element)};
  }

  template <
    typename SourceT,
    typename TargetT                                                                   = _TargetT,
    std::enable_if_t<(cudf::is_timestamp<SourceT>() && cudf::is_duration<TargetT>())>* = nullptr>
  __device__ inline TargetT operator()(SourceT const element)
  {
    return TargetT{cuda::std::chrono::floor<TargetT>(element.time_since_epoch())};
  }

  template <
    typename SourceT,
    typename TargetT                                                               = _TargetT,
    std::enable_if_t<cudf::is_duration<SourceT>() && cudf::is_numeric<TargetT>()>* = nullptr>
  __device__ inline TargetT operator()(SourceT const element)
  {
    return static_cast<TargetT>(element.count());
  }

  template <
    typename SourceT,
    typename TargetT                                                                   = _TargetT,
    std::enable_if_t<(cudf::is_duration<SourceT>() && cudf::is_timestamp<TargetT>())>* = nullptr>
  __device__ inline TargetT operator()(SourceT const element)
  {
    return TargetT{cuda::std::chrono::floor<TargetT::duration>(element)};
  }
};

template <typename _SourceT, typename _TargetT>
struct fixed_point_unary_cast {
  numeric::scale_type scale;
  using FixedPointT = std::conditional_t<cudf::is_fixed_point<_SourceT>(), _SourceT, _TargetT>;
  using DeviceT     = device_storage_type_t<FixedPointT>;

  template <
    typename SourceT                                                                     = _SourceT,
    typename TargetT                                                                     = _TargetT,
    std::enable_if_t<(cudf::is_fixed_point<_SourceT>() && cudf::is_numeric<TargetT>())>* = nullptr>
  __device__ inline TargetT operator()(DeviceT const element)
  {
    auto const fp = SourceT{numeric::scaled_integer<DeviceT>{element, scale}};
    return static_cast<TargetT>(fp);
  }

  template <
    typename SourceT                                                                     = _SourceT,
    typename TargetT                                                                     = _TargetT,
    std::enable_if_t<(cudf::is_numeric<_SourceT>() && cudf::is_fixed_point<TargetT>())>* = nullptr>
  __device__ inline DeviceT operator()(SourceT const element)
  {
    return TargetT{element, scale}.value();
  }
};

template <typename From, typename To>
constexpr inline auto is_supported_non_fixed_point_cast()
{
  return cudf::is_fixed_width<To>() &&
         // Disallow fixed_point here (requires different specialization)
         !(cudf::is_fixed_point<From>() || cudf::is_fixed_point<To>()) &&
         // Disallow conversions between timestamps and numeric
         !(cudf::is_timestamp<From>() && is_numeric<To>()) &&
         !(cudf::is_timestamp<To>() && is_numeric<From>());
}

template <typename From, typename To>
constexpr inline auto is_supported_fixed_point_cast()
{
  return (cudf::is_fixed_point<From>() && cudf::is_numeric<To>()) ||
         (cudf::is_numeric<From>() && cudf::is_fixed_point<To>()) ||
         (cudf::is_fixed_point<From>() && cudf::is_fixed_point<To>());
}

template <typename From, typename To>
constexpr inline auto is_supported_cast()
{
  return is_supported_non_fixed_point_cast<From, To>() || is_supported_fixed_point_cast<From, To>();
}

template <typename From, typename To>
struct device_cast {
  __device__ To operator()(From element) { return static_cast<To>(element); }
};

/**
 * @brief Takes a `fixed_point` column_view as @p input and returns a `fixed_point` column with new
 * @p scale
 *
 * @tparam T     Type of the `fixed_point` column_view (`decimal32`, `decimal64` or `decimal128`)
 * @param input  Input `column_view`
 * @param scale  `scale` of the returned `column`
 * @param stream CUDA stream used for device memory operations and kernel launches
 * @param mr     Device memory resource used to allocate the returned column's device memory
 *
 * @return std::unique_ptr<column> Returned column with new @p scale
 */
template <typename T, std::enable_if_t<is_fixed_point<T>()>* = nullptr>
std::unique_ptr<column> rescale(column_view input,
                                numeric::scale_type scale,
                                rmm::cuda_stream_view stream,
                                rmm::mr::device_memory_resource* mr)
{
  using namespace numeric;
  using RepType = device_storage_type_t<T>;

  auto const type = cudf::data_type{cudf::type_to_id<T>(), scale};
  if (input.type().scale() >= scale) {
    auto const scalar = make_fixed_point_scalar<T>(0, scale_type{scale}, stream);
    return detail::binary_operation(input, *scalar, binary_operator::ADD, type, stream, mr);
  } else {
    auto const diff = input.type().scale() - scale;
    // The value of fixed point scalar will overflow if the scale difference is larger than the
    // max digits of underlying integral type. Under this condition, the output values can be
    // nothing other than zero value. Therefore, we simply return a zero column.
    if (-diff > cuda::std::numeric_limits<RepType>::digits10) {
      auto const scalar  = make_fixed_point_scalar<T>(0, scale_type{scale}, stream);
      auto output_column = make_column_from_scalar(*scalar, input.size(), stream, mr);
      if (input.nullable()) {
        auto const null_mask = copy_bitmask(input, stream, mr);
        output_column->set_null_mask(std::move(null_mask));
      }
      return output_column;
    }
    auto const scalar = make_fixed_point_scalar<T>(std::pow(10, -diff), scale_type{diff}, stream);
    return detail::binary_operation(input, *scalar, binary_operator::DIV, type, stream, mr);
  }
};

template <typename _SourceT>
struct dispatch_unary_cast_to {
  column_view input;

  dispatch_unary_cast_to(column_view inp) : input(inp) {}

  template <typename TargetT,
            typename SourceT                                                         = _SourceT,
            std::enable_if_t<is_supported_non_fixed_point_cast<SourceT, TargetT>()>* = nullptr>
  std::unique_ptr<column> operator()(data_type type,
                                     rmm::cuda_stream_view stream,
                                     rmm::mr::device_memory_resource* mr)
  {
    auto const size = input.size();
    auto output =
      std::make_unique<column>(type,
                               size,
                               rmm::device_buffer{size * cudf::size_of(type), stream, mr},
                               detail::copy_bitmask(input, stream, mr),
                               input.null_count());

    mutable_column_view output_mutable = *output;

    thrust::transform(rmm::exec_policy(stream),
                      input.begin<SourceT>(),
                      input.end<SourceT>(),
                      output_mutable.begin<TargetT>(),
                      unary_cast<TargetT>{});

    return output;
  }

  template <
    typename TargetT,
    typename SourceT                                                                  = _SourceT,
    std::enable_if_t<cudf::is_fixed_point<SourceT>() && cudf::is_numeric<TargetT>()>* = nullptr>
  std::unique_ptr<column> operator()(data_type type,
                                     rmm::cuda_stream_view stream,
                                     rmm::mr::device_memory_resource* mr)
  {
    auto const size = input.size();
    auto output =
      std::make_unique<column>(type,
                               size,
                               rmm::device_buffer{size * cudf::size_of(type), stream, mr},
                               copy_bitmask(input, stream, mr),
                               input.null_count());

    mutable_column_view output_mutable = *output;

    using DeviceT    = device_storage_type_t<SourceT>;
    auto const scale = numeric::scale_type{input.type().scale()};

    thrust::transform(rmm::exec_policy(stream),
                      input.begin<DeviceT>(),
                      input.end<DeviceT>(),
                      output_mutable.begin<TargetT>(),
                      fixed_point_unary_cast<SourceT, TargetT>{scale});

    return output;
  }

  template <
    typename TargetT,
    typename SourceT                                                                  = _SourceT,
    std::enable_if_t<cudf::is_numeric<SourceT>() && cudf::is_fixed_point<TargetT>()>* = nullptr>
  std::unique_ptr<column> operator()(data_type type,
                                     rmm::cuda_stream_view stream,
                                     rmm::mr::device_memory_resource* mr)
  {
    auto const size = input.size();
    auto output =
      std::make_unique<column>(type,
                               size,
                               rmm::device_buffer{size * cudf::size_of(type), stream, mr},
                               copy_bitmask(input, stream, mr),
                               input.null_count());

    mutable_column_view output_mutable = *output;

    using DeviceT    = device_storage_type_t<TargetT>;
    auto const scale = numeric::scale_type{type.scale()};

    thrust::transform(rmm::exec_policy(stream),
                      input.begin<SourceT>(),
                      input.end<SourceT>(),
                      output_mutable.begin<DeviceT>(),
                      fixed_point_unary_cast<SourceT, TargetT>{scale});

    return output;
  }

  template <typename TargetT,
            typename SourceT                                    = _SourceT,
            std::enable_if_t<cudf::is_fixed_point<SourceT>() && cudf::is_fixed_point<TargetT>() &&
                             std::is_same_v<SourceT, TargetT>>* = nullptr>
  std::unique_ptr<column> operator()(data_type type,
                                     rmm::cuda_stream_view stream,
                                     rmm::mr::device_memory_resource* mr)
  {
    if (input.type() == type) {
      return std::make_unique<column>(input, stream, mr);  // TODO add test for this
    }

    return detail::rescale<TargetT>(input, numeric::scale_type{type.scale()}, stream, mr);
  }

  template <typename TargetT,
            typename SourceT                                        = _SourceT,
            std::enable_if_t<cudf::is_fixed_point<SourceT>() && cudf::is_fixed_point<TargetT>() &&
                             not std::is_same_v<SourceT, TargetT>>* = nullptr>
  std::unique_ptr<column> operator()(data_type type,
                                     rmm::cuda_stream_view stream,
                                     rmm::mr::device_memory_resource* mr)
  {
    using namespace numeric;
    using SourceDeviceT = device_storage_type_t<SourceT>;
    using TargetDeviceT = device_storage_type_t<TargetT>;

    auto casted = [&]() {
      auto const size = input.size();
      auto output     = std::make_unique<column>(cudf::data_type{type.id(), input.type().scale()},
                                             size,
                                             rmm::device_buffer{size * cudf::size_of(type), stream},
                                             copy_bitmask(input, stream),
                                             input.null_count());

      mutable_column_view output_mutable = *output;

      thrust::transform(rmm::exec_policy(stream),
                        input.begin<SourceDeviceT>(),
                        input.end<SourceDeviceT>(),
                        output_mutable.begin<TargetDeviceT>(),
                        device_cast<SourceDeviceT, TargetDeviceT>{});

      return output;
    };

    if (input.type().scale() == type.scale()) return casted();

    if constexpr (sizeof(SourceDeviceT) < sizeof(TargetDeviceT)) {
      // device_cast BEFORE rescale when SourceDeviceT is < TargetDeviceT
      auto temporary = casted();
      return detail::rescale<TargetT>(*temporary, scale_type{type.scale()}, stream, mr);
    } else {
      // device_cast AFTER rescale when SourceDeviceT is > TargetDeviceT to avoid overflow
      auto temporary = detail::rescale<SourceT>(input, scale_type{type.scale()}, stream, mr);
      return detail::cast(*temporary, type, stream, mr);
    }
  }

  template <typename TargetT,
            typename SourceT                                             = _SourceT,
            std::enable_if_t<not is_supported_cast<SourceT, TargetT>()>* = nullptr>
  std::unique_ptr<column> operator()(data_type,
                                     rmm::cuda_stream_view,
                                     rmm::mr::device_memory_resource*)

  {
    if (!cudf::is_fixed_width<TargetT>())
      CUDF_FAIL("Column type must be numeric or chrono or decimal32/64/128");
    else if (cudf::is_fixed_point<SourceT>())
      CUDF_FAIL("Currently only decimal32/64/128 to floating point/integral is supported");
    else if (cudf::is_timestamp<SourceT>() && is_numeric<TargetT>())
      CUDF_FAIL("Timestamps can be created only from duration");
    else
      CUDF_FAIL("Timestamps cannot be converted to numeric without converting it to a duration");
  }
};

struct dispatch_unary_cast_from {
  column_view input;

  dispatch_unary_cast_from(column_view inp) : input(inp) {}

  template <typename T, std::enable_if_t<cudf::is_fixed_width<T>()>* = nullptr>
  std::unique_ptr<column> operator()(data_type type,
                                     rmm::cuda_stream_view stream,
                                     rmm::mr::device_memory_resource* mr)
  {
    return type_dispatcher(type, dispatch_unary_cast_to<T>{input}, type, stream, mr);
  }

  template <typename T, typename... Args>
  std::enable_if_t<!cudf::is_fixed_width<T>(), std::unique_ptr<column>> operator()(Args&&...)
  {
    CUDF_FAIL("Column type must be numeric or chrono or decimal32/64/128");
  }
};
}  // anonymous namespace

std::unique_ptr<column> cast(column_view const& input,
                             data_type type,
                             rmm::cuda_stream_view stream,
                             rmm::mr::device_memory_resource* mr)
{
  CUDF_EXPECTS(is_fixed_width(type), "Unary cast type must be fixed-width.");

  return type_dispatcher(input.type(), detail::dispatch_unary_cast_from{input}, type, stream, mr);
}

}  // namespace detail

std::unique_ptr<column> cast(column_view const& input,
                             data_type type,
                             rmm::mr::device_memory_resource* mr)
{
  CUDF_FUNC_RANGE();
  return detail::cast(input, type, rmm::cuda_stream_default, mr);
}

}  // namespace cudf

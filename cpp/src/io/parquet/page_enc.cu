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
#include "parquet_gpu.hpp"

#include <io/utilities/block_utils.cuh>

#include <cudf/detail/iterator.cuh>
#include <cudf/detail/utilities/cuda.cuh>
#include <cudf/detail/utilities/vector_factories.hpp>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/exec_policy.hpp>

#include <cub/cub.cuh>

#include <cuda/std/chrono>

#include <thrust/binary_search.h>
#include <thrust/copy.h>
#include <thrust/execution_policy.h>
#include <thrust/for_each.h>
#include <thrust/gather.h>
#include <thrust/host_vector.h>
#include <thrust/iterator/constant_iterator.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/iterator/discard_iterator.h>
#include <thrust/iterator/reverse_iterator.h>
#include <thrust/iterator/transform_iterator.h>
#include <thrust/merge.h>
#include <thrust/scan.h>
#include <thrust/scatter.h>
#include <thrust/tuple.h>

namespace cudf {
namespace io {
namespace parquet {
namespace gpu {
// Spark doesn't support RLE encoding for BOOLEANs
#ifdef ENABLE_BOOL_RLE
constexpr bool enable_bool_rle = true;
#else
constexpr bool enable_bool_rle = false;
#endif

using ::cudf::detail::device_2dspan;

constexpr int init_hash_bits       = 12;
constexpr uint32_t rle_buffer_size = (1 << 9);

struct frag_init_state_s {
  parquet_column_device_view col;
  PageFragment frag;
};

struct page_enc_state_s {
  uint8_t* cur;          //!< current output ptr
  uint8_t* rle_out;      //!< current RLE write ptr
  uint32_t rle_run;      //!< current RLE run
  uint32_t run_val;      //!< current RLE run value
  uint32_t rle_pos;      //!< RLE encoder positions
  uint32_t rle_numvals;  //!< RLE input value count
  uint32_t rle_lit_count;
  uint32_t rle_rpt_count;
  uint32_t page_start_val;
  uint32_t chunk_start_val;
  volatile uint32_t rpt_map[4];
  volatile uint32_t scratch_red[32];
  EncPage page;
  EncColumnChunk ck;
  parquet_column_device_view col;
  uint16_t vals[rle_buffer_size];
};

/**
 * @brief Returns the size of the type in the Parquet file.
 */
uint32_t __device__ physical_type_len(Type physical_type, type_id id)
{
  if (physical_type == FIXED_LEN_BYTE_ARRAY and id == type_id::DECIMAL128) {
    return sizeof(__int128_t);
  }
  switch (physical_type) {
    case INT96: return 12u;
    case INT64:
    case DOUBLE: return sizeof(int64_t);
    case BOOLEAN: return 1u;
    default: return sizeof(int32_t);
  }
}

/**
 * @brief Return a 12-bit hash from a byte sequence
 */
inline __device__ uint32_t hash_string(const string_view& val)
{
  char const* ptr = val.data();
  uint32_t len    = val.size_bytes();
  if (len != 0) {
    return (ptr[0] + (ptr[len - 1] << 5) + (len << 10)) & ((1 << init_hash_bits) - 1);
  } else {
    return 0;
  }
}

inline __device__ uint32_t uint32_init_hash(uint32_t v)
{
  return (v + (v >> 11) + (v >> 22)) & ((1 << init_hash_bits) - 1);
}

inline __device__ uint32_t uint64_init_hash(uint64_t v)
{
  return uint32_init_hash(static_cast<uint32_t>(v + (v >> 32)));
}

// blockDim {512,1,1}
template <int block_size>
__global__ void __launch_bounds__(block_size)
  gpuInitPageFragments(device_2dspan<PageFragment> frag,
                       device_span<parquet_column_device_view const> col_desc,
                       device_span<partition_info const> partitions,
                       device_span<int const> part_frag_offset,
                       uint32_t fragment_size)
{
  __shared__ __align__(16) frag_init_state_s state_g;

  using block_reduce = cub::BlockReduce<uint32_t, block_size>;
  __shared__ typename block_reduce::TempStorage reduce_storage;

  frag_init_state_s* const s = &state_g;
  uint32_t t                 = threadIdx.x;
  int frag_y                 = blockIdx.y;

  if (t == 0) s->col = col_desc[blockIdx.x];
  __syncthreads();
  if (!t) {
    // Find which partition this fragment came from
    auto it =
      thrust::upper_bound(thrust::seq, part_frag_offset.begin(), part_frag_offset.end(), frag_y);
    int p             = it - part_frag_offset.begin() - 1;
    int part_end_row  = partitions[p].start_row + partitions[p].num_rows;
    s->frag.start_row = (frag_y - part_frag_offset[p]) * fragment_size + partitions[p].start_row;

    // frag.num_rows = fragment_size except for the last fragment in partition which can be smaller.
    // num_rows is fixed but fragment size could be larger if the data is strings or nested.
    s->frag.num_rows           = min(fragment_size, part_end_row - s->frag.start_row);
    s->frag.num_dict_vals      = 0;
    s->frag.fragment_data_size = 0;
    s->frag.dict_data_size     = 0;

    auto col                = *(s->col.parent_column);
    s->frag.start_value_idx = row_to_value_idx(s->frag.start_row, col);
    size_type end_value_idx = row_to_value_idx(s->frag.start_row + s->frag.num_rows, col);
    s->frag.num_leaf_values = end_value_idx - s->frag.start_value_idx;

    if (s->col.level_offsets != nullptr) {
      // For nested schemas, the number of values in a fragment is not directly related to the
      // number of encoded data elements or the number of rows.  It is simply the number of
      // repetition/definition values which together encode validity and nesting information.
      size_type first_level_val_idx = s->col.level_offsets[s->frag.start_row];
      size_type last_level_val_idx  = s->col.level_offsets[s->frag.start_row + s->frag.num_rows];
      s->frag.num_values            = last_level_val_idx - first_level_val_idx;
    } else {
      s->frag.num_values = s->frag.num_rows;
    }
  }
  auto const physical_type = s->col.physical_type;
  auto const dtype_len     = physical_type_len(physical_type, s->col.leaf_column->type().id());
  __syncthreads();

  size_type nvals           = s->frag.num_leaf_values;
  size_type start_value_idx = s->frag.start_value_idx;

  for (uint32_t i = 0; i < nvals; i += block_size) {
    uint32_t val_idx  = start_value_idx + i + t;
    uint32_t is_valid = (i + t < nvals && val_idx < s->col.leaf_column->size())
                          ? s->col.leaf_column->is_valid(val_idx)
                          : 0;
    uint32_t len;
    if (is_valid) {
      len = dtype_len;
      if (physical_type != BOOLEAN) {
        if (physical_type == BYTE_ARRAY) {
          auto str = s->col.leaf_column->element<string_view>(val_idx);
          len += str.size_bytes();
        }
      }
    } else {
      len = 0;
    }

    len = block_reduce(reduce_storage).Sum(len);
    if (!t) { s->frag.fragment_data_size += len; }
    __syncthreads();
  }
  __syncthreads();
  if (t == 0) frag[blockIdx.x][blockIdx.y] = s->frag;
}

// blockDim {128,1,1}
__global__ void __launch_bounds__(128)
  gpuInitFragmentStats(device_2dspan<statistics_group> groups,
                       device_2dspan<PageFragment const> fragments,
                       device_span<parquet_column_device_view const> col_desc)
{
  // TODO: why not 1 block per warp?
  __shared__ __align__(8) statistics_group group_g[4];

  uint32_t lane_id              = threadIdx.x & 0x1f;
  uint32_t frag_id              = blockIdx.y * 4 + (threadIdx.x >> 5);
  uint32_t column_id            = blockIdx.x;
  auto num_fragments_per_column = fragments.size().second;
  statistics_group* const g     = &group_g[threadIdx.x >> 5];
  if (!lane_id && frag_id < num_fragments_per_column) {
    g->col       = &col_desc[column_id];
    g->start_row = fragments[column_id][frag_id].start_value_idx;
    g->num_rows  = fragments[column_id][frag_id].num_leaf_values;
  }
  __syncthreads();
  if (frag_id < num_fragments_per_column and lane_id == 0) groups[column_id][frag_id] = *g;
}

// blockDim {128,1,1}
__global__ void __launch_bounds__(128)
  gpuInitPages(device_2dspan<EncColumnChunk> chunks,
               device_span<gpu::EncPage> pages,
               device_span<parquet_column_device_view const> col_desc,
               statistics_merge_group* page_grstats,
               statistics_merge_group* chunk_grstats,
               size_t max_page_comp_data_size,
               int32_t num_columns,
               size_t max_page_size_bytes,
               size_type max_page_size_rows)
{
  // TODO: All writing seems to be done by thread 0. Could be replaced by thrust foreach
  __shared__ __align__(8) parquet_column_device_view col_g;
  __shared__ __align__(8) EncColumnChunk ck_g;
  __shared__ __align__(8) PageFragment frag_g;
  __shared__ __align__(8) EncPage page_g;
  __shared__ __align__(8) statistics_merge_group pagestats_g;

  uint32_t t = threadIdx.x;

  if (t == 0) {
    col_g  = col_desc[blockIdx.x];
    ck_g   = chunks[blockIdx.y][blockIdx.x];
    page_g = {};
  }
  __syncthreads();
  if (t < 32) {
    uint32_t fragments_in_chunk  = 0;
    uint32_t rows_in_page        = 0;
    uint32_t values_in_page      = 0;
    uint32_t leaf_values_in_page = 0;
    uint32_t page_size           = 0;
    uint32_t num_pages           = 0;
    uint32_t num_rows            = 0;
    uint32_t page_start          = 0;
    uint32_t page_offset         = ck_g.ck_stat_size;
    uint32_t num_dict_entries    = 0;
    uint32_t comp_page_offset    = ck_g.ck_stat_size;
    uint32_t page_headers_size   = 0;
    uint32_t max_page_data_size  = 0;
    uint32_t cur_row             = ck_g.start_row;
    uint32_t ck_max_stats_len    = 0;
    uint32_t max_stats_len       = 0;

    if (!t) {
      pagestats_g.col_dtype   = col_g.leaf_column->type();
      pagestats_g.stats_dtype = col_g.stats_dtype;
      pagestats_g.start_chunk = ck_g.first_fragment;
      pagestats_g.num_chunks  = 0;
    }
    if (ck_g.use_dictionary) {
      if (!t) {
        page_g.page_data       = ck_g.uncompressed_bfr + page_offset;
        page_g.compressed_data = ck_g.compressed_bfr + comp_page_offset;
        page_g.num_fragments   = 0;
        page_g.page_type       = PageType::DICTIONARY_PAGE;
        page_g.chunk           = &chunks[blockIdx.y][blockIdx.x];
        page_g.chunk_id        = blockIdx.y * num_columns + blockIdx.x;
        page_g.hdr_size        = 0;
        page_g.max_hdr_size    = 32;
        page_g.max_data_size   = ck_g.uniq_data_size;
        page_g.start_row       = cur_row;
        page_g.num_rows        = ck_g.num_dict_entries;
        page_g.num_leaf_values = ck_g.num_dict_entries;
        page_g.num_values      = ck_g.num_dict_entries;  // TODO: shouldn't matter for dict page
        page_offset += page_g.max_hdr_size + page_g.max_data_size;
        comp_page_offset += page_g.max_hdr_size + max_page_comp_data_size;
        page_headers_size += page_g.max_hdr_size;
        max_page_data_size = max(max_page_data_size, page_g.max_data_size);
      }
      __syncwarp();
      if (t == 0) {
        if (not pages.empty()) pages[ck_g.first_page] = page_g;
        if (page_grstats) page_grstats[ck_g.first_page] = pagestats_g;
      }
      num_pages = 1;
    }
    __syncwarp();
    // This loop goes over one page fragment at a time and adds it to page.
    // When page size crosses a particular limit, then it moves on to the next page and then next
    // page fragment gets added to that one.

    // This doesn't actually deal with data. It's agnostic. It only cares about number of rows and
    // page size.
    do {
      uint32_t minmax_len = 0;
      __syncwarp();
      if (num_rows < ck_g.num_rows) {
        if (t == 0) { frag_g = ck_g.fragments[fragments_in_chunk]; }
        if (!t && ck_g.stats && col_g.stats_dtype == dtype_string) {
          minmax_len = max(ck_g.stats[fragments_in_chunk].min_value.str_val.length,
                           ck_g.stats[fragments_in_chunk].max_value.str_val.length);
        }
      } else if (!t) {
        frag_g.fragment_data_size = 0;
        frag_g.num_rows           = 0;
      }
      __syncwarp();
      uint32_t fragment_data_size =
        (ck_g.use_dictionary)
          ? frag_g.num_leaf_values * 2  // Assume worst-case of 2-bytes per dictionary index
          : frag_g.fragment_data_size;
      // TODO (dm): this convoluted logic to limit page size needs refactoring
      size_t this_max_page_size = (values_in_page * 2 >= ck_g.num_values)   ? 256 * 1024
                                  : (values_in_page * 3 >= ck_g.num_values) ? 384 * 1024
                                                                            : 512 * 1024;

      // override this_max_page_size if the requested size is smaller
      this_max_page_size = min(this_max_page_size, max_page_size_bytes);

      if (num_rows >= ck_g.num_rows ||
          (values_in_page > 0 && (page_size + fragment_data_size > this_max_page_size)) ||
          rows_in_page > max_page_size_rows) {
        if (ck_g.use_dictionary) {
          page_size =
            1 + 5 + ((values_in_page * ck_g.dict_rle_bits + 7) >> 3) + (values_in_page >> 8);
        }
        if (!t) {
          page_g.num_fragments = fragments_in_chunk - page_start;
          page_g.chunk         = &chunks[blockIdx.y][blockIdx.x];
          page_g.chunk_id      = blockIdx.y * num_columns + blockIdx.x;
          page_g.page_type     = PageType::DATA_PAGE;
          page_g.hdr_size      = 0;
          page_g.max_hdr_size  = 32;  // Max size excluding statistics
          if (ck_g.stats) {
            uint32_t stats_hdr_len = 16;
            if (col_g.stats_dtype == dtype_string) {
              stats_hdr_len += 5 * 3 + 2 * max_stats_len;
            } else {
              stats_hdr_len += ((col_g.stats_dtype >= dtype_int64) ? 10 : 5) * 3;
            }
            page_g.max_hdr_size += stats_hdr_len;
          }
          page_g.page_data        = ck_g.uncompressed_bfr + page_offset;
          page_g.compressed_data  = ck_g.compressed_bfr + comp_page_offset;
          page_g.start_row        = cur_row;
          page_g.num_rows         = rows_in_page;
          page_g.num_leaf_values  = leaf_values_in_page;
          page_g.num_values       = values_in_page;
          uint32_t def_level_bits = col_g.num_def_level_bits();
          uint32_t rep_level_bits = col_g.num_rep_level_bits();
          // Run length = 4, max(rle/bitpack header) = 5, add one byte per 256 values for overhead
          // TODO (dm): Improve readability of these calculations.
          uint32_t def_level_size =
            (def_level_bits != 0)
              ? 4 + 5 + ((def_level_bits * page_g.num_values + 7) >> 3) + (page_g.num_values >> 8)
              : 0;
          uint32_t rep_level_size =
            (rep_level_bits != 0)
              ? 4 + 5 + ((rep_level_bits * page_g.num_values + 7) >> 3) + (page_g.num_values >> 8)
              : 0;
          page_g.max_data_size = page_size + def_level_size + rep_level_size;

          pagestats_g.start_chunk = ck_g.first_fragment + page_start;
          pagestats_g.num_chunks  = page_g.num_fragments;
          page_offset += page_g.max_hdr_size + page_g.max_data_size;
          comp_page_offset += page_g.max_hdr_size + max_page_comp_data_size;
          page_headers_size += page_g.max_hdr_size;
          max_page_data_size = max(max_page_data_size, page_g.max_data_size);
          cur_row += rows_in_page;
          ck_max_stats_len = max(ck_max_stats_len, max_stats_len);
        }
        __syncwarp();
        if (t == 0) {
          if (not pages.empty()) { pages[ck_g.first_page + num_pages] = page_g; }

          if (page_grstats) { page_grstats[ck_g.first_page + num_pages] = pagestats_g; }
        }

        num_pages++;
        page_size           = 0;
        rows_in_page        = 0;
        values_in_page      = 0;
        leaf_values_in_page = 0;
        page_start          = fragments_in_chunk;
        max_stats_len       = 0;
      }
      max_stats_len = max(max_stats_len, minmax_len);
      num_dict_entries += frag_g.num_dict_vals;
      page_size += fragment_data_size;
      rows_in_page += frag_g.num_rows;
      values_in_page += frag_g.num_values;
      leaf_values_in_page += frag_g.num_leaf_values;
      num_rows += frag_g.num_rows;
      fragments_in_chunk++;
    } while (frag_g.num_rows != 0);
    __syncwarp();
    if (!t) {
      if (ck_g.ck_stat_size == 0 && ck_g.stats) {
        uint32_t ck_stat_size = 48 + 2 * ck_max_stats_len;
        page_offset += ck_stat_size;
        comp_page_offset += ck_stat_size;
        ck_g.ck_stat_size = ck_stat_size;
      }
      ck_g.num_pages          = num_pages;
      ck_g.bfr_size           = page_offset;
      ck_g.page_headers_size  = page_headers_size;
      ck_g.max_page_data_size = max_page_data_size;
      pagestats_g.start_chunk = ck_g.first_page + ck_g.use_dictionary;  // Exclude dictionary
      pagestats_g.num_chunks  = num_pages - ck_g.use_dictionary;
    }
  }
  __syncthreads();
  if (t == 0) {
    if (not pages.empty()) ck_g.pages = &pages[ck_g.first_page];
    chunks[blockIdx.y][blockIdx.x] = ck_g;
    if (chunk_grstats) chunk_grstats[blockIdx.y * num_columns + blockIdx.x] = pagestats_g;
  }
}

/**
 * @brief Mask table representing how many consecutive repeats are needed to code a repeat run
 *[nbits-1]
 */
static __device__ __constant__ uint32_t kRleRunMask[16] = {
  0x00ffffff, 0x0fff, 0x00ff, 0x3f, 0x0f, 0x0f, 0x7, 0x7, 0x3, 0x3, 0x3, 0x3, 0x1, 0x1, 0x1, 0x1};

/**
 * @brief Variable-length encode an integer
 */
inline __device__ uint8_t* VlqEncode(uint8_t* p, uint32_t v)
{
  while (v > 0x7f) {
    *p++ = (v | 0x80);
    v >>= 7;
  }
  *p++ = v;
  return p;
}

/**
 * @brief Pack literal values in output bitstream (1,2,4,8,12 or 16 bits per value)
 */
inline __device__ void PackLiterals(
  uint8_t* dst, uint32_t v, uint32_t count, uint32_t w, uint32_t t)
{
  if (w == 1 || w == 2 || w == 4 || w == 8 || w == 12 || w == 16) {
    if (t <= (count | 0x1f)) {
      if (w == 1 || w == 2 || w == 4) {
        uint32_t mask = 0;
        if (w == 1) {
          v |= shuffle_xor(v, 1) << 1;
          v |= shuffle_xor(v, 2) << 2;
          v |= shuffle_xor(v, 4) << 4;
          mask = 0x7;
        } else if (w == 2) {
          v |= shuffle_xor(v, 1) << 2;
          v |= shuffle_xor(v, 2) << 4;
          mask = 0x3;
        } else if (w == 4) {
          v |= shuffle_xor(v, 1) << 4;
          mask = 0x1;
        }
        if (t < count && mask && !(t & mask)) { dst[(t * w) >> 3] = v; }
        return;
      } else if (w == 8) {
        if (t < count) { dst[t] = v; }
        return;
      } else if (w == 12) {
        v |= shuffle_xor(v, 1) << 12;
        if (t < count && !(t & 1)) {
          dst[(t >> 1) * 3 + 0] = v;
          dst[(t >> 1) * 3 + 1] = v >> 8;
          dst[(t >> 1) * 3 + 2] = v >> 16;
        }
        return;
      } else if (w == 16) {
        if (t < count) {
          dst[t * 2 + 0] = v;
          dst[t * 2 + 1] = v >> 8;
        }
        return;
      }
    } else {
      return;
    }
  } else {
    // Scratch space to temporarily write to. Needed because we will use atomics to write 32 bit
    // words but the destination mem may not be a multiple of 4 bytes.
    // TODO (dm): This assumes blockdim = 128 and max bits per value = 16. Reduce magic numbers.
    __shared__ uint32_t scratch[64];
    if (t < 64) { scratch[t] = 0; }
    __syncthreads();

    if (t <= count) {
      uint64_t v64 = v;
      v64 <<= (t * w) & 0x1f;

      // Copy 64 bit word into two 32 bit words while following C++ strict aliasing rules.
      uint32_t v32[2];
      memcpy(&v32, &v64, sizeof(uint64_t));

      // Atomically write result to scratch
      if (v32[0]) { atomicOr(scratch + ((t * w) >> 5), v32[0]); }
      if (v32[1]) { atomicOr(scratch + ((t * w) >> 5) + 1, v32[1]); }
    }
    __syncthreads();

    // Copy scratch data to final destination
    auto available_bytes = (count * w + 7) / 8;

    auto scratch_bytes = reinterpret_cast<char*>(&scratch[0]);
    if (t < available_bytes) { dst[t] = scratch_bytes[t]; }
    if (t + 128 < available_bytes) { dst[t + 128] = scratch_bytes[t + 128]; }
    __syncthreads();
  }
}

/**
 * @brief RLE encoder
 *
 * @param[in,out] s Page encode state
 * @param[in] numvals Total count of input values
 * @param[in] nbits number of bits per symbol (1..16)
 * @param[in] flush nonzero if last batch in block
 * @param[in] t thread id (0..127)
 */
static __device__ void RleEncode(
  page_enc_state_s* s, uint32_t numvals, uint32_t nbits, uint32_t flush, uint32_t t)
{
  uint32_t rle_pos = s->rle_pos;
  uint32_t rle_run = s->rle_run;

  while (rle_pos < numvals || (flush && rle_run)) {
    uint32_t pos = rle_pos + t;
    if (rle_run > 0 && !(rle_run & 1)) {
      // Currently in a long repeat run
      uint32_t mask = ballot(pos < numvals && s->vals[pos & (rle_buffer_size - 1)] == s->run_val);
      uint32_t rle_rpt_count, max_rpt_count;
      if (!(t & 0x1f)) { s->rpt_map[t >> 5] = mask; }
      __syncthreads();
      if (t < 32) {
        uint32_t c32 = ballot(t >= 4 || s->rpt_map[t] != 0xffffffffu);
        if (!t) {
          uint32_t last_idx = __ffs(c32) - 1;
          s->rle_rpt_count =
            last_idx * 32 + ((last_idx < 4) ? __ffs(~s->rpt_map[last_idx]) - 1 : 0);
        }
      }
      __syncthreads();
      max_rpt_count = min(numvals - rle_pos, 128);
      rle_rpt_count = s->rle_rpt_count;
      rle_run += rle_rpt_count << 1;
      rle_pos += rle_rpt_count;
      if (rle_rpt_count < max_rpt_count || (flush && rle_pos == numvals)) {
        if (t == 0) {
          uint32_t const run_val = s->run_val;
          uint8_t* dst           = VlqEncode(s->rle_out, rle_run);
          *dst++                 = run_val;
          if (nbits > 8) { *dst++ = run_val >> 8; }
          s->rle_out = dst;
        }
        rle_run = 0;
      }
    } else {
      // New run or in a literal run
      uint32_t v0      = s->vals[pos & (rle_buffer_size - 1)];
      uint32_t v1      = s->vals[(pos + 1) & (rle_buffer_size - 1)];
      uint32_t mask    = ballot(pos + 1 < numvals && v0 == v1);
      uint32_t maxvals = min(numvals - rle_pos, 128);
      uint32_t rle_lit_count, rle_rpt_count;
      if (!(t & 0x1f)) { s->rpt_map[t >> 5] = mask; }
      __syncthreads();
      if (t < 32) {
        // Repeat run can only start on a multiple of 8 values
        uint32_t idx8        = (t * 8) >> 5;
        uint32_t pos8        = (t * 8) & 0x1f;
        uint32_t m0          = (idx8 < 4) ? s->rpt_map[idx8] : 0;
        uint32_t m1          = (idx8 < 3) ? s->rpt_map[idx8 + 1] : 0;
        uint32_t needed_mask = kRleRunMask[nbits - 1];
        mask                 = ballot((__funnelshift_r(m0, m1, pos8) & needed_mask) == needed_mask);
        if (!t) {
          uint32_t rle_run_start = (mask != 0) ? min((__ffs(mask) - 1) * 8, maxvals) : maxvals;
          uint32_t rpt_len       = 0;
          if (rle_run_start < maxvals) {
            uint32_t idx_cur = rle_run_start >> 5;
            uint32_t idx_ofs = rle_run_start & 0x1f;
            while (idx_cur < 4) {
              m0   = (idx_cur < 4) ? s->rpt_map[idx_cur] : 0;
              m1   = (idx_cur < 3) ? s->rpt_map[idx_cur + 1] : 0;
              mask = ~__funnelshift_r(m0, m1, idx_ofs);
              if (mask != 0) {
                rpt_len += __ffs(mask) - 1;
                break;
              }
              rpt_len += 32;
              idx_cur++;
            }
          }
          s->rle_lit_count = rle_run_start;
          s->rle_rpt_count = min(rpt_len, maxvals - rle_run_start);
        }
      }
      __syncthreads();
      rle_lit_count = s->rle_lit_count;
      rle_rpt_count = s->rle_rpt_count;
      if (rle_lit_count != 0 || (rle_run != 0 && rle_rpt_count != 0)) {
        uint32_t lit_div8;
        bool need_more_data = false;
        if (!flush && rle_pos + rle_lit_count == numvals) {
          // Wait for more data
          rle_lit_count -= min(rle_lit_count, 24);
          need_more_data = true;
        }
        if (rle_lit_count != 0) {
          lit_div8 = (rle_lit_count + ((flush && rle_pos + rle_lit_count == numvals) ? 7 : 0)) >> 3;
          if (rle_run + lit_div8 * 2 > 0x7f) {
            lit_div8      = 0x3f - (rle_run >> 1);  // Limit to fixed 1-byte header (504 literals)
            rle_rpt_count = 0;                      // Defer repeat run
          }
          if (lit_div8 != 0) {
            uint8_t* dst = s->rle_out + 1 + (rle_run >> 1) * nbits;
            PackLiterals(dst, (rle_pos + t < numvals) ? v0 : 0, lit_div8 * 8, nbits, t);
            rle_run = (rle_run + lit_div8 * 2) | 1;
            rle_pos = min(rle_pos + lit_div8 * 8, numvals);
          }
        }
        if (rle_run >= ((rle_rpt_count != 0 || (flush && rle_pos == numvals)) ? 0x03 : 0x7f)) {
          __syncthreads();
          // Complete literal run
          if (!t) {
            uint8_t* dst = s->rle_out;
            dst[0]       = rle_run;  // At most 0x7f
            dst += 1 + nbits * (rle_run >> 1);
            s->rle_out = dst;
          }
          rle_run = 0;
        }
        if (need_more_data) { break; }
      }
      // Start a repeat run
      if (rle_rpt_count != 0) {
        if (t == s->rle_lit_count) { s->run_val = v0; }
        rle_run = rle_rpt_count * 2;
        rle_pos += rle_rpt_count;
        if (rle_pos + 1 == numvals && !flush) { break; }
      }
    }
    __syncthreads();
  }
  __syncthreads();
  if (!t) {
    s->rle_run     = rle_run;
    s->rle_pos     = rle_pos;
    s->rle_numvals = numvals;
  }
}

/**
 * @brief PLAIN bool encoder
 *
 * @param[in,out] s Page encode state
 * @param[in] numvals Total count of input values
 * @param[in] flush nonzero if last batch in block
 * @param[in] t thread id (0..127)
 */
static __device__ void PlainBoolEncode(page_enc_state_s* s,
                                       uint32_t numvals,
                                       uint32_t flush,
                                       uint32_t t)
{
  uint32_t rle_pos = s->rle_pos;
  uint8_t* dst     = s->rle_out;

  while (rle_pos < numvals) {
    uint32_t pos    = rle_pos + t;
    uint32_t v      = (pos < numvals) ? s->vals[pos & (rle_buffer_size - 1)] : 0;
    uint32_t n      = min(numvals - rle_pos, 128);
    uint32_t nbytes = (n + ((flush) ? 7 : 0)) >> 3;
    if (!nbytes) { break; }
    v |= shuffle_xor(v, 1) << 1;
    v |= shuffle_xor(v, 2) << 2;
    v |= shuffle_xor(v, 4) << 4;
    if (t < n && !(t & 7)) { dst[t >> 3] = v; }
    rle_pos = min(rle_pos + nbytes * 8, numvals);
    dst += nbytes;
  }
  __syncthreads();
  if (!t) {
    s->rle_pos     = rle_pos;
    s->rle_numvals = numvals;
    s->rle_out     = dst;
  }
}

/**
 * @brief Determines the difference between the Proleptic Gregorian Calendar epoch (1970-01-01
 * 00:00:00 UTC) and the Julian date epoch (-4713-11-24 12:00:00 UTC).
 *
 * @return The difference between two epochs in `cuda::std::chrono::duration` format with a period
 * of hours.
 */
constexpr auto julian_calendar_epoch_diff()
{
  using namespace cuda::std::chrono;
  using namespace cuda::std::chrono_literals;
  return sys_days{January / 1 / 1970} - (sys_days{November / 24 / -4713} + 12h);
}

/**
 * @brief Converts a timestamp_ns into a pair with nanoseconds since midnight and number of Julian
 * days. Does not deal with time zones. Used by INT96 code.
 *
 * @param ns number of nanoseconds since epoch
 * @return std::pair<nanoseconds,days> where nanoseconds is the number of nanoseconds
 * elapsed in the day and days is the number of days from Julian epoch.
 */
static __device__ std::pair<duration_ns, duration_D> convert_nanoseconds(timestamp_ns const ns)
{
  using namespace cuda::std::chrono;
  auto const nanosecond_ticks = ns.time_since_epoch();
  auto const gregorian_days   = floor<days>(nanosecond_ticks);
  auto const julian_days      = gregorian_days + ceil<days>(julian_calendar_epoch_diff());

  auto const last_day_ticks = nanosecond_ticks - gregorian_days;
  return {last_day_ticks, julian_days};
}

// blockDim(128, 1, 1)
template <int block_size>
__global__ void __launch_bounds__(128, 8)
  gpuEncodePages(device_span<gpu::EncPage> pages,
                 device_span<device_span<uint8_t const>> comp_in,
                 device_span<device_span<uint8_t>> comp_out,
                 device_span<decompress_status> comp_stats)
{
  __shared__ __align__(8) page_enc_state_s state_g;
  using block_scan = cub::BlockScan<uint32_t, block_size>;
  __shared__ typename block_scan::TempStorage temp_storage;

  page_enc_state_s* const s = &state_g;
  uint32_t t                = threadIdx.x;

  if (t == 0) {
    state_g = page_enc_state_s{};
    s->page = pages[blockIdx.x];
    s->ck   = *s->page.chunk;
    s->col  = *s->ck.col_desc;
    s->cur  = s->page.page_data + s->page.max_hdr_size;
  }
  __syncthreads();

  // Encode Repetition and Definition levels
  if (s->page.page_type != PageType::DICTIONARY_PAGE &&
      (s->col.num_def_level_bits()) != 0 &&  // This means max definition level is not 0 (nullable)
      (s->col.num_rep_level_bits()) == 0     // This means there are no repetition levels (non-list)
  ) {
    // Calculate definition levels from validity
    uint32_t def_lvl_bits = s->col.num_def_level_bits();
    if (def_lvl_bits != 0) {
      if (!t) {
        s->rle_run     = 0;
        s->rle_pos     = 0;
        s->rle_numvals = 0;
        s->rle_out     = s->cur + 4;
      }
      __syncthreads();
      while (s->rle_numvals < s->page.num_rows) {
        uint32_t rle_numvals = s->rle_numvals;
        uint32_t nrows       = min(s->page.num_rows - rle_numvals, 128);
        uint32_t row         = s->page.start_row + rle_numvals + t;
        // Definition level encodes validity. Checks the valid map and if it is valid, then sets the
        // def_lvl accordingly and sets it in s->vals which is then given to RleEncode to encode
        uint32_t def_lvl = [&]() {
          bool within_bounds = rle_numvals + t < s->page.num_rows && row < s->col.num_rows;
          if (not within_bounds) { return 0u; }
          uint32_t def       = 0;
          size_type l        = 0;
          bool is_col_struct = false;
          auto col           = *s->col.parent_column;
          do {
            // If col not nullable then it does not contribute to def levels
            if (s->col.nullability[l]) {
              if (col.is_valid(row)) {
                ++def;
              } else {
                // We have found the shallowest level at which this row is null
                break;
              }
            }
            is_col_struct = (col.type().id() == type_id::STRUCT);
            if (is_col_struct) {
              row += col.offset();
              col = col.child(0);
              ++l;
            }
          } while (is_col_struct);
          return def;
        }();
        s->vals[(rle_numvals + t) & (rle_buffer_size - 1)] = def_lvl;
        __syncthreads();
        rle_numvals += nrows;
        RleEncode(s, rle_numvals, def_lvl_bits, (rle_numvals == s->page.num_rows), t);
        __syncthreads();
      }
      if (t < 32) {
        uint8_t* cur     = s->cur;
        uint8_t* rle_out = s->rle_out;
        if (t < 4) {
          uint32_t rle_bytes = (uint32_t)(rle_out - cur) - 4;
          cur[t]             = rle_bytes >> (t * 8);
        }
        __syncwarp();
        if (t == 0) { s->cur = rle_out; }
      }
    }
  } else if (s->page.page_type != PageType::DICTIONARY_PAGE &&
             s->col.num_rep_level_bits() != 0  // This means there ARE repetition levels (has list)
  ) {
    auto encode_levels = [&](uint8_t const* lvl_val_data, uint32_t nbits) {
      // For list types, the repetition and definition levels are pre-calculated. We just need to
      // encode and write them now.
      if (!t) {
        s->rle_run     = 0;
        s->rle_pos     = 0;
        s->rle_numvals = 0;
        s->rle_out     = s->cur + 4;
      }
      __syncthreads();
      size_type page_first_val_idx = s->col.level_offsets[s->page.start_row];
      size_type col_last_val_idx   = s->col.level_offsets[s->col.num_rows];
      while (s->rle_numvals < s->page.num_values) {
        uint32_t rle_numvals = s->rle_numvals;
        uint32_t nvals       = min(s->page.num_values - rle_numvals, 128);
        uint32_t idx         = page_first_val_idx + rle_numvals + t;
        uint32_t lvl_val =
          (rle_numvals + t < s->page.num_values && idx < col_last_val_idx) ? lvl_val_data[idx] : 0;
        s->vals[(rle_numvals + t) & (rle_buffer_size - 1)] = lvl_val;
        __syncthreads();
        rle_numvals += nvals;
        RleEncode(s, rle_numvals, nbits, (rle_numvals == s->page.num_values), t);
        __syncthreads();
      }
      if (t < 32) {
        uint8_t* cur     = s->cur;
        uint8_t* rle_out = s->rle_out;
        if (t < 4) {
          uint32_t rle_bytes = (uint32_t)(rle_out - cur) - 4;
          cur[t]             = rle_bytes >> (t * 8);
        }
        __syncwarp();
        if (t == 0) { s->cur = rle_out; }
      }
    };
    encode_levels(s->col.rep_values, s->col.num_rep_level_bits());
    __syncthreads();
    encode_levels(s->col.def_values, s->col.num_def_level_bits());
  }
  // Encode data values
  __syncthreads();
  auto const physical_type = s->col.physical_type;
  auto const type_id       = s->col.leaf_column->type().id();
  auto const dtype_len_out = physical_type_len(physical_type, type_id);
  auto const dtype_len_in  = [&]() -> uint32_t {
    if (physical_type == INT32) { return int32_logical_len(type_id); }
    if (physical_type == INT96) { return sizeof(int64_t); }
    return dtype_len_out;
  }();

  auto const dict_bits = (physical_type == BOOLEAN) ? 1
                         : (s->ck.use_dictionary and s->page.page_type != PageType::DICTIONARY_PAGE)
                           ? s->ck.dict_rle_bits
                           : -1;
  if (t == 0) {
    uint8_t* dst   = s->cur;
    s->rle_run     = 0;
    s->rle_pos     = 0;
    s->rle_numvals = 0;
    s->rle_out     = dst;
    if (dict_bits >= 0 && physical_type != BOOLEAN) {
      dst[0]     = dict_bits;
      s->rle_out = dst + 1;
    }
    auto col           = *(s->col.parent_column);
    s->page_start_val  = row_to_value_idx(s->page.start_row, col);
    s->chunk_start_val = row_to_value_idx(s->ck.start_row, col);
  }
  __syncthreads();
  for (uint32_t cur_val_idx = 0; cur_val_idx < s->page.num_leaf_values;) {
    uint32_t nvals = min(s->page.num_leaf_values - cur_val_idx, 128);
    uint32_t len, pos;

    auto [is_valid, val_idx] = [&]() {
      uint32_t val_idx;
      uint32_t is_valid;

      size_type val_idx_in_block = cur_val_idx + t;
      if (s->page.page_type == PageType::DICTIONARY_PAGE) {
        val_idx  = val_idx_in_block;
        is_valid = (val_idx < s->page.num_leaf_values);
        if (is_valid) { val_idx = s->ck.dict_data[val_idx]; }
      } else {
        size_type val_idx_in_leaf_col = s->page_start_val + val_idx_in_block;

        is_valid = (val_idx_in_leaf_col < s->col.leaf_column->size() &&
                    val_idx_in_block < s->page.num_leaf_values)
                     ? s->col.leaf_column->is_valid(val_idx_in_leaf_col)
                     : 0;
        val_idx =
          (s->ck.use_dictionary) ? val_idx_in_leaf_col - s->chunk_start_val : val_idx_in_leaf_col;
      }
      return std::make_tuple(is_valid, val_idx);
    }();

    cur_val_idx += nvals;
    if (dict_bits >= 0) {
      // Dictionary encoding
      if (dict_bits > 0) {
        uint32_t rle_numvals;
        uint32_t rle_numvals_in_block;
        block_scan(temp_storage).ExclusiveSum(is_valid, pos, rle_numvals_in_block);
        rle_numvals = s->rle_numvals;
        if (is_valid) {
          uint32_t v;
          if (physical_type == BOOLEAN) {
            v = s->col.leaf_column->element<uint8_t>(val_idx);
          } else {
            v = s->ck.dict_index[val_idx];
          }
          s->vals[(rle_numvals + pos) & (rle_buffer_size - 1)] = v;
        }
        rle_numvals += rle_numvals_in_block;
        __syncthreads();
        if ((!enable_bool_rle) && (physical_type == BOOLEAN)) {
          PlainBoolEncode(s, rle_numvals, (cur_val_idx == s->page.num_leaf_values), t);
        } else {
          RleEncode(s, rle_numvals, dict_bits, (cur_val_idx == s->page.num_leaf_values), t);
        }
        __syncthreads();
      }
      if (t == 0) { s->cur = s->rle_out; }
      __syncthreads();
    } else {
      // Non-dictionary encoding
      uint8_t* dst = s->cur;

      if (is_valid) {
        len = dtype_len_out;
        if (physical_type == BYTE_ARRAY) {
          len += s->col.leaf_column->element<string_view>(val_idx).size_bytes();
        }
      } else {
        len = 0;
      }
      uint32_t total_len = 0;
      block_scan(temp_storage).ExclusiveSum(len, pos, total_len);
      __syncthreads();
      if (t == 0) { s->cur = dst + total_len; }
      if (is_valid) {
        switch (physical_type) {
          case INT32:
          case FLOAT: {
            int32_t v;
            if (dtype_len_in == 4)
              v = s->col.leaf_column->element<int32_t>(val_idx);
            else if (dtype_len_in == 2)
              v = s->col.leaf_column->element<int16_t>(val_idx);
            else
              v = s->col.leaf_column->element<int8_t>(val_idx);
            dst[pos + 0] = v;
            dst[pos + 1] = v >> 8;
            dst[pos + 2] = v >> 16;
            dst[pos + 3] = v >> 24;
          } break;
          case INT64: {
            int64_t v        = s->col.leaf_column->element<int64_t>(val_idx);
            int32_t ts_scale = s->col.ts_scale;
            if (ts_scale != 0) {
              if (ts_scale < 0) {
                v /= -ts_scale;
              } else {
                v *= ts_scale;
              }
            }
            dst[pos + 0] = v;
            dst[pos + 1] = v >> 8;
            dst[pos + 2] = v >> 16;
            dst[pos + 3] = v >> 24;
            dst[pos + 4] = v >> 32;
            dst[pos + 5] = v >> 40;
            dst[pos + 6] = v >> 48;
            dst[pos + 7] = v >> 56;
          } break;
          case INT96: {
            int64_t v        = s->col.leaf_column->element<int64_t>(val_idx);
            int32_t ts_scale = s->col.ts_scale;
            if (ts_scale != 0) {
              if (ts_scale < 0) {
                v /= -ts_scale;
              } else {
                v *= ts_scale;
              }
            }

            auto const ret = convert_nanoseconds([&]() {
              switch (s->col.leaf_column->type().id()) {
                case type_id::TIMESTAMP_SECONDS:
                case type_id::TIMESTAMP_MILLISECONDS: {
                  return timestamp_ns{duration_ms{v}};
                } break;
                case type_id::TIMESTAMP_MICROSECONDS:
                case type_id::TIMESTAMP_NANOSECONDS: {
                  return timestamp_ns{duration_us{v}};
                } break;
              }
              return timestamp_ns{duration_ns{0}};
            }());

            // the 12 bytes of fixed length data.
            v             = ret.first.count();
            dst[pos + 0]  = v;
            dst[pos + 1]  = v >> 8;
            dst[pos + 2]  = v >> 16;
            dst[pos + 3]  = v >> 24;
            dst[pos + 4]  = v >> 32;
            dst[pos + 5]  = v >> 40;
            dst[pos + 6]  = v >> 48;
            dst[pos + 7]  = v >> 56;
            uint32_t w    = ret.second.count();
            dst[pos + 8]  = w;
            dst[pos + 9]  = w >> 8;
            dst[pos + 10] = w >> 16;
            dst[pos + 11] = w >> 24;
          } break;

          case DOUBLE: {
            auto v = s->col.leaf_column->element<double>(val_idx);
            memcpy(dst + pos, &v, 8);
          } break;
          case BYTE_ARRAY: {
            auto str     = s->col.leaf_column->element<string_view>(val_idx);
            uint32_t v   = len - 4;  // string length
            dst[pos + 0] = v;
            dst[pos + 1] = v >> 8;
            dst[pos + 2] = v >> 16;
            dst[pos + 3] = v >> 24;
            if (v != 0) memcpy(dst + pos + 4, str.data(), v);
          } break;
          case FIXED_LEN_BYTE_ARRAY: {
            if (type_id == type_id::DECIMAL128) {
              // When using FIXED_LEN_BYTE_ARRAY for decimals, the rep is encoded in big-endian
              auto const v = s->col.leaf_column->element<numeric::decimal128>(val_idx).value();
              auto const v_char_ptr = reinterpret_cast<char const*>(&v);
              thrust::copy(thrust::seq,
                           thrust::make_reverse_iterator(v_char_ptr + sizeof(v)),
                           thrust::make_reverse_iterator(v_char_ptr),
                           dst + pos);
            }
          } break;
        }
      }
      __syncthreads();
    }
  }
  if (t == 0) {
    uint8_t* base                = s->page.page_data + s->page.max_hdr_size;
    auto actual_data_size        = static_cast<uint32_t>(s->cur - base);
    uint32_t compressed_bfr_size = GetMaxCompressedBfrSize(actual_data_size);
    s->page.max_data_size        = actual_data_size;
    if (not comp_in.empty()) {
      comp_in[blockIdx.x]  = {base, actual_data_size};
      comp_out[blockIdx.x] = {s->page.compressed_data + s->page.max_hdr_size, compressed_bfr_size};
    }
    pages[blockIdx.x] = s->page;
    if (not comp_stats.empty()) {
      comp_stats[blockIdx.x]      = {0, ~0u};
      pages[blockIdx.x].comp_stat = &comp_stats[blockIdx.x];
    }
  }
}

// blockDim(128, 1, 1)
__global__ void __launch_bounds__(128) gpuDecideCompression(device_span<EncColumnChunk> chunks)
{
  // After changing the way structs are loaded from coop to normal, this kernel has no business
  // being launched with 128 thread block. It can easily be a single warp.
  __shared__ __align__(8) EncColumnChunk ck_g;
  __shared__ __align__(4) unsigned int error_count;
  using warp_reduce = cub::WarpReduce<uint32_t>;
  __shared__ typename warp_reduce::TempStorage temp_storage[2];
  __shared__ volatile bool has_compression;

  uint32_t t                      = threadIdx.x;
  uint32_t uncompressed_data_size = 0;
  uint32_t compressed_data_size   = 0;
  uint32_t num_pages;

  if (t == 0) {
    ck_g = chunks[blockIdx.x];
    atomicAnd(&error_count, 0);
    has_compression = false;
  }
  __syncthreads();
  if (t < 32) {
    num_pages = ck_g.num_pages;
    for (uint32_t page = t; page < num_pages; page += 32) {
      auto& curr_page         = ck_g.pages[page];
      uint32_t page_data_size = curr_page.max_data_size;
      uncompressed_data_size += page_data_size;
      if (auto comp_status = curr_page.comp_stat; comp_status != nullptr) {
        has_compression = true;
        compressed_data_size += comp_status->bytes_written;
        if (comp_status->status != 0) { atomicAdd(&error_count, 1); }
      }
    }
    uncompressed_data_size = warp_reduce(temp_storage[0]).Sum(uncompressed_data_size);
    compressed_data_size   = warp_reduce(temp_storage[1]).Sum(compressed_data_size);
  }
  __syncthreads();
  if (t == 0) {
    bool is_compressed;
    if (has_compression) {
      uint32_t compression_error = atomicAdd(&error_count, 0);
      is_compressed = (!compression_error && compressed_data_size < uncompressed_data_size);
    } else {
      is_compressed = false;
    }
    chunks[blockIdx.x].is_compressed = is_compressed;
    chunks[blockIdx.x].bfr_size      = uncompressed_data_size;
    chunks[blockIdx.x].compressed_size =
      (is_compressed) ? compressed_data_size : uncompressed_data_size;
  }
}

/**
 * Minimal thrift compact protocol support
 */
inline __device__ uint8_t* cpw_put_uint32(uint8_t* p, uint32_t v)
{
  while (v > 0x7f) {
    *p++ = v | 0x80;
    v >>= 7;
  }
  *p++ = v;
  return p;
}

inline __device__ uint8_t* cpw_put_uint64(uint8_t* p, uint64_t v)
{
  while (v > 0x7f) {
    *p++ = v | 0x80;
    v >>= 7;
  }
  *p++ = v;
  return p;
}

inline __device__ uint8_t* cpw_put_int32(uint8_t* p, int32_t v)
{
  int32_t s = (v < 0);
  return cpw_put_uint32(p, (v ^ -s) * 2 + s);
}

inline __device__ uint8_t* cpw_put_int64(uint8_t* p, int64_t v)
{
  int64_t s = (v < 0);
  return cpw_put_uint64(p, (v ^ -s) * 2 + s);
}

inline __device__ uint8_t* cpw_put_fldh(uint8_t* p, int f, int cur, int t)
{
  if (f > cur && f <= cur + 15) {
    *p++ = ((f - cur) << 4) | t;
    return p;
  } else {
    *p++ = t;
    return cpw_put_int32(p, f);
  }
}

class header_encoder {
  uint8_t* current_header_ptr;
  int current_field_index;

 public:
  inline __device__ header_encoder(uint8_t* header_start)
    : current_header_ptr(header_start), current_field_index(0)
  {
  }

  inline __device__ void field_struct_begin(int field)
  {
    current_header_ptr =
      cpw_put_fldh(current_header_ptr, field, current_field_index, ST_FLD_STRUCT);
    current_field_index = 0;
  }

  inline __device__ void field_struct_end(int field)
  {
    *current_header_ptr++ = 0;
    current_field_index   = field;
  }

  template <typename T>
  inline __device__ void field_int32(int field, T value)
  {
    current_header_ptr  = cpw_put_fldh(current_header_ptr, field, current_field_index, ST_FLD_I32);
    current_header_ptr  = cpw_put_int32(current_header_ptr, static_cast<int32_t>(value));
    current_field_index = field;
  }

  template <typename T>
  inline __device__ void field_int64(int field, T value)
  {
    current_header_ptr  = cpw_put_fldh(current_header_ptr, field, current_field_index, ST_FLD_I64);
    current_header_ptr  = cpw_put_int64(current_header_ptr, static_cast<int64_t>(value));
    current_field_index = field;
  }

  inline __device__ void field_binary(int field, const void* value, uint32_t length)
  {
    current_header_ptr =
      cpw_put_fldh(current_header_ptr, field, current_field_index, ST_FLD_BINARY);
    current_header_ptr = cpw_put_uint32(current_header_ptr, length);
    memcpy(current_header_ptr, value, length);
    current_header_ptr += length;
    current_field_index = field;
  }

  inline __device__ void end(uint8_t** header_end, bool termination_flag = true)
  {
    if (termination_flag == false) { *current_header_ptr++ = 0; }
    *header_end = current_header_ptr;
  }

  inline __device__ uint8_t* get_ptr() { return current_header_ptr; }

  inline __device__ void set_ptr(uint8_t* ptr) { current_header_ptr = ptr; }
};

__device__ uint8_t* EncodeStatistics(uint8_t* start,
                                     const statistics_chunk* s,
                                     uint8_t dtype,
                                     float* fp_scratch)
{
  uint8_t *end, dtype_len;
  switch (dtype) {
    case dtype_bool: dtype_len = 1; break;
    case dtype_int8:
    case dtype_int16:
    case dtype_int32:
    case dtype_date32:
    case dtype_float32: dtype_len = 4; break;
    case dtype_int64:
    case dtype_timestamp64:
    case dtype_float64:
    case dtype_decimal64: dtype_len = 8; break;
    case dtype_decimal128: dtype_len = 16; break;
    case dtype_string:
    default: dtype_len = 0; break;
  }
  header_encoder encoder(start);
  encoder.field_int64(3, s->null_count);
  if (s->has_minmax) {
    const void *vmin, *vmax;
    uint32_t lmin, lmax;

    if (dtype == dtype_string) {
      lmin = s->min_value.str_val.length;
      vmin = s->min_value.str_val.ptr;
      lmax = s->max_value.str_val.length;
      vmax = s->max_value.str_val.ptr;
    } else {
      lmin = lmax = dtype_len;
      if (dtype == dtype_float32) {  // Convert from double to float32
        fp_scratch[0] = s->min_value.fp_val;
        fp_scratch[1] = s->max_value.fp_val;
        vmin          = &fp_scratch[0];
        vmax          = &fp_scratch[1];
      } else {
        vmin = &s->min_value;
        vmax = &s->max_value;
      }
    }
    encoder.field_binary(5, vmax, lmax);
    encoder.field_binary(6, vmin, lmin);
  }
  encoder.end(&end);
  return end;
}

// blockDim(128, 1, 1)
__global__ void __launch_bounds__(128)
  gpuEncodePageHeaders(device_span<EncPage> pages,
                       device_span<decompress_status const> comp_stat,
                       device_span<statistics_chunk const> page_stats,
                       const statistics_chunk* chunk_stats)
{
  // When this whole kernel becomes single thread, the following variables need not be __shared__
  __shared__ __align__(8) parquet_column_device_view col_g;
  __shared__ __align__(8) EncColumnChunk ck_g;
  __shared__ __align__(8) EncPage page_g;
  __shared__ __align__(8) float fp_scratch[2];

  uint32_t t = threadIdx.x;

  if (t == 0) {
    uint8_t *hdr_start, *hdr_end;
    uint32_t compressed_page_size, uncompressed_page_size;

    page_g = pages[blockIdx.x];
    ck_g   = *page_g.chunk;
    col_g  = *ck_g.col_desc;

    if (chunk_stats && &pages[blockIdx.x] == ck_g.pages) {  // Is this the first page in a chunk?
      hdr_start = (ck_g.is_compressed) ? ck_g.compressed_bfr : ck_g.uncompressed_bfr;
      hdr_end =
        EncodeStatistics(hdr_start, &chunk_stats[page_g.chunk_id], col_g.stats_dtype, fp_scratch);
      page_g.chunk->ck_stat_size = static_cast<uint32_t>(hdr_end - hdr_start);
    }
    uncompressed_page_size = page_g.max_data_size;
    if (ck_g.is_compressed) {
      hdr_start            = page_g.compressed_data;
      compressed_page_size = (uint32_t)comp_stat[blockIdx.x].bytes_written;
      page_g.max_data_size = compressed_page_size;
    } else {
      hdr_start            = page_g.page_data;
      compressed_page_size = uncompressed_page_size;
    }
    header_encoder encoder(hdr_start);
    PageType page_type = page_g.page_type;
    // NOTE: For dictionary encoding, parquet v2 recommends using PLAIN in dictionary page and
    // RLE_DICTIONARY in data page, but parquet v1 uses PLAIN_DICTIONARY in both dictionary and
    // data pages (actual encoding is identical).
    Encoding encoding;
    if (enable_bool_rle) {
      encoding = (col_g.physical_type == BOOLEAN) ? Encoding::RLE
                 : (page_type == PageType::DICTIONARY_PAGE || page_g.chunk->use_dictionary)
                   ? Encoding::PLAIN_DICTIONARY
                   : Encoding::PLAIN;
    } else {
      encoding = (page_type == PageType::DICTIONARY_PAGE || page_g.chunk->use_dictionary)
                   ? Encoding::PLAIN_DICTIONARY
                   : Encoding::PLAIN;
    }
    encoder.field_int32(1, page_type);
    encoder.field_int32(2, uncompressed_page_size);
    encoder.field_int32(3, compressed_page_size);
    if (page_type == PageType::DATA_PAGE) {
      // DataPageHeader
      encoder.field_struct_begin(5);
      encoder.field_int32(1, page_g.num_values);  // NOTE: num_values != num_rows for list types
      encoder.field_int32(2, encoding);           // encoding
      encoder.field_int32(3, Encoding::RLE);      // definition_level_encoding
      encoder.field_int32(4, Encoding::RLE);      // repetition_level_encoding
      // Optionally encode page-level statistics
      if (not page_stats.empty()) {
        encoder.field_struct_begin(5);
        encoder.set_ptr(EncodeStatistics(
          encoder.get_ptr(), &page_stats[blockIdx.x], col_g.stats_dtype, fp_scratch));
        encoder.field_struct_end(5);
      }
      encoder.field_struct_end(5);
    } else {
      // DictionaryPageHeader
      encoder.field_struct_begin(7);
      encoder.field_int32(1, ck_g.num_dict_entries);  // number of values in dictionary
      encoder.field_int32(2, encoding);
      encoder.field_struct_end(7);
    }
    encoder.end(&hdr_end, false);
    page_g.hdr_size = (uint32_t)(hdr_end - hdr_start);
  }
  __syncthreads();
  if (t == 0) pages[blockIdx.x] = page_g;
}

// blockDim(1024, 1, 1)
__global__ void __launch_bounds__(1024)
  gpuGatherPages(device_span<EncColumnChunk> chunks, device_span<gpu::EncPage const> pages)
{
  __shared__ __align__(8) EncColumnChunk ck_g;
  __shared__ __align__(8) EncPage page_g;

  uint32_t t = threadIdx.x;
  uint8_t *dst, *dst_base;
  const EncPage* first_page;
  uint32_t num_pages, uncompressed_size;

  if (t == 0) ck_g = chunks[blockIdx.x];
  __syncthreads();

  first_page = ck_g.pages;
  num_pages  = ck_g.num_pages;
  dst        = (ck_g.is_compressed) ? ck_g.compressed_bfr : ck_g.uncompressed_bfr;
  dst += ck_g.ck_stat_size;  // Skip over chunk statistics
  dst_base          = dst;
  uncompressed_size = ck_g.bfr_size;
  for (uint32_t page = 0; page < num_pages; page++) {
    const uint8_t* src;
    uint32_t hdr_len, data_len;

    if (t == 0) { page_g = first_page[page]; }
    __syncthreads();

    src = (ck_g.is_compressed) ? page_g.compressed_data : page_g.page_data;
    // Copy page header
    hdr_len = page_g.hdr_size;
    memcpy_block<1024, true>(dst, src, hdr_len, t);
    src += page_g.max_hdr_size;
    dst += hdr_len;
    // Copy page data
    uncompressed_size += hdr_len;
    data_len = page_g.max_data_size;
    memcpy_block<1024, true>(dst, src, data_len, t);
    dst += data_len;
    __syncthreads();
    if (!t && page == 0 && ck_g.use_dictionary) { ck_g.dictionary_size = hdr_len + data_len; }
  }
  if (t == 0) {
    chunks[blockIdx.x].bfr_size        = uncompressed_size;
    chunks[blockIdx.x].compressed_size = (dst - dst_base);
    if (ck_g.use_dictionary) { chunks[blockIdx.x].dictionary_size = ck_g.dictionary_size; }
  }
}

/**
 * @brief Functor to get definition level value for a nested struct column until the leaf level or
 * the first list level.
 *
 */
struct def_level_fn {
  column_device_view const* parent_col;
  uint8_t const* d_nullability;
  uint8_t sub_level_start;
  uint8_t curr_def_level;

  __device__ uint32_t operator()(size_type i)
  {
    uint32_t def       = curr_def_level;
    uint8_t l          = sub_level_start;
    bool is_col_struct = false;
    auto col           = *parent_col;
    do {
      // If col not nullable then it does not contribute to def levels
      if (d_nullability[l]) {
        if (not col.nullable() or bit_is_set(col.null_mask(), i)) {
          ++def;
        } else {  // We have found the shallowest level at which this row is null
          break;
        }
      }
      is_col_struct = (col.type().id() == type_id::STRUCT);
      if (is_col_struct) {
        col = col.child(0);
        ++l;
      }
    } while (is_col_struct);
    return def;
  }
};

/**
 * @brief Get the dremel offsets and repetition and definition levels for a LIST column
 *
 * The repetition and definition level values are ideally computed using a recursive call over a
 * nested structure but in order to better utilize GPU resources, this function calculates them
 * with a bottom up merge method.
 *
 * Given a LIST column of type `List<List<int>>` like so:
 * ```
 * col = {
 *    [],
 *    [[], [1, 2, 3], [4, 5]],
 *    [[]]
 * }
 * ```
 * We can represent it in cudf format with two level of offsets like this:
 * ```
 * Level 0 offsets = {0, 0, 3, 5, 6}
 * Level 1 offsets = {0, 0, 3, 5, 5}
 * Values          = {1, 2, 3, 4, 5}
 * ```
 * The desired result of this function is the repetition and definition level values that
 * correspond to the data values:
 * ```
 * col = {[], [[], [1, 2, 3], [4, 5]], [[]]}
 * def = { 0    1,  2, 2, 2,   2, 2,     1 }
 * rep = { 0,   0,  0, 2, 2,   1, 2,     0 }
 * ```
 *
 * Since repetition and definition levels arrays contain a value for each empty list, the size of
 * the rep/def level array can be given by
 * ```
 * rep_level.size() = size of leaf column + number of empty lists in level 0
 *                                        + number of empty lists in level 1 ...
 * ```
 *
 * We start with finding the empty lists in the penultimate level and merging it with the indices
 * of the leaf level. The values for the merge are the definition and repetition levels
 * ```
 * empties at level 1 = {0, 5}
 * def values at 1    = {1, 1}
 * rep values at 1    = {1, 1}
 * indices at leaf    = {0, 1, 2, 3, 4}
 * def values at leaf = {2, 2, 2, 2, 2}
 * rep values at leaf = {2, 2, 2, 2, 2}
 * ```
 *
 * merged def values  = {1, 2, 2, 2, 2, 2, 1}
 * merged rep values  = {1, 2, 2, 2, 2, 2, 1}
 *
 * The size of the rep/def values is now larger than the leaf values and the offsets need to be
 * adjusted in order to point to the correct start indices. We do this with an exclusive scan over
 * the indices of offsets of empty lists and adding to existing offsets.
 * ```
 * Level 1 new offsets = {0, 1, 4, 6, 7}
 * ```
 * Repetition values at the beginning of a list need to be decremented. We use the new offsets to
 * scatter the rep value.
 * ```
 * merged rep values  = {1, 2, 2, 2, 2, 2, 1}
 * scatter (1, new offsets)
 * new offsets        = {0, 1,       4,    6, 7}
 * new rep values     = {1, 1, 2, 2, 1, 2, 1}
 * ```
 *
 * Similarly we merge up all the way till level 0 offsets
 *
 * STRUCT COLUMNS :
 * In case of struct columns, we don't have to merge struct levels with their children because a
 * struct is the same size as its children. e.g. for a column `struct<int, float>`, if the row `i`
 * is null, then the children columns `int` and `float` are also null at `i`. They also have the
 * null entry represented in their respective null masks. So for any case of strictly struct based
 * nesting, we can get the definition levels merely by iterating over the nesting for the same row.
 *
 * In case struct and lists are intermixed, the definition levels of all the contiguous struct
 * levels can be constructed using the aforementioned iterative method. Only when we reach a list
 * level, we need to do a merge with the subsequent level.
 *
 * So, for a column like `struct<list<int>>`, we are going to merge between the levels `struct<list`
 * and `int`.
 * For a column like `list<struct<int>>`, we are going to merge between `list` and `struct<int>`.
 *
 * In general, one nesting level is the list level and any struct level that precedes it.
 *
 * A few more examples to visualize the partitioning of column hierarchy into nesting levels:
 * (L is list, S is struct, i is integer(leaf data level), angle brackets omitted)
 * ```
 * 1. LSi     = L   Si
 *              - | --
 *
 * 2. LLSi    = L   L   Si
 *              - | - | --
 *
 * 3. SSLi    = SSL   i
 *              --- | -
 *
 * 4. LLSLSSi = L   L   SL   SSi
 *              - | - | -- | ---
 * ```
 */
dremel_data get_dremel_data(column_view h_col,
                            // TODO(cp): use device_span once it is converted to a single hd_vec
                            rmm::device_uvector<uint8_t> const& d_nullability,
                            std::vector<uint8_t> const& nullability,
                            rmm::cuda_stream_view stream)
{
  auto get_list_level = [](column_view col) {
    while (col.type().id() == type_id::STRUCT) {
      col = col.child(0);
    }
    return col;
  };

  auto get_empties = [&](column_view col, size_type start, size_type end) {
    auto lcv = lists_column_view(get_list_level(col));
    rmm::device_uvector<size_type> empties_idx(lcv.size(), stream);
    rmm::device_uvector<size_type> empties(lcv.size(), stream);
    auto d_off = lcv.offsets().data<size_type>();

    auto empties_idx_end =
      thrust::copy_if(rmm::exec_policy(stream),
                      thrust::make_counting_iterator(start),
                      thrust::make_counting_iterator(end),
                      empties_idx.begin(),
                      [d_off] __device__(auto i) { return d_off[i] == d_off[i + 1]; });
    auto empties_end = thrust::gather(rmm::exec_policy(stream),
                                      empties_idx.begin(),
                                      empties_idx_end,
                                      lcv.offsets().begin<size_type>(),
                                      empties.begin());

    auto empties_size = empties_end - empties.begin();
    return std::make_tuple(std::move(empties), std::move(empties_idx), empties_size);
  };

  auto curr_col = h_col;
  std::vector<column_view> nesting_levels;
  std::vector<uint8_t> def_at_level;
  std::vector<uint8_t> start_at_sub_level;
  uint8_t curr_nesting_level_idx = 0;

  auto add_def_at_level = [&](column_view col) {
    // Add up all def level contributions in this column all the way till the first list column
    // appears in the hierarchy or until we get to leaf
    uint32_t def = 0;
    start_at_sub_level.push_back(curr_nesting_level_idx);
    while (col.type().id() == type_id::STRUCT) {
      def += (nullability[curr_nesting_level_idx]) ? 1 : 0;
      col = col.child(0);
      ++curr_nesting_level_idx;
    }
    // At the end of all those structs is either a list column or the leaf. Leaf column contributes
    // at least one def level. It doesn't matter what the leaf contributes because it'll be at the
    // end of the exclusive scan.
    def += (nullability[curr_nesting_level_idx]) ? 2 : 1;
    def_at_level.push_back(def);
    ++curr_nesting_level_idx;
  };
  while (cudf::is_nested(curr_col.type())) {
    nesting_levels.push_back(curr_col);
    add_def_at_level(curr_col);
    while (curr_col.type().id() == type_id::STRUCT) {
      // Go down the hierarchy until we get to the LIST or the leaf level
      curr_col = curr_col.child(0);
    }
    if (curr_col.type().id() == type_id::LIST) {
      curr_col = curr_col.child(lists_column_view::child_column_index);
      if (not is_nested(curr_col.type())) {
        // Special case: when the leaf data column is the immediate child of the list col then we
        // want it to be included right away. Otherwise the struct containing it will be included in
        // the next iteration of this loop.
        nesting_levels.push_back(curr_col);
        add_def_at_level(curr_col);
        break;
      }
    }
  }

  auto [device_view_owners, d_nesting_levels] =
    contiguous_copy_column_device_views<column_device_view>(nesting_levels, stream);

  thrust::exclusive_scan(
    thrust::host, def_at_level.begin(), def_at_level.end(), def_at_level.begin());

  // Sliced list column views only have offsets applied to top level. Get offsets for each level.
  rmm::device_uvector<size_type> d_column_offsets(nesting_levels.size(), stream);
  rmm::device_uvector<size_type> d_column_ends(nesting_levels.size(), stream);

  auto d_col = column_device_view::create(h_col, stream);
  cudf::detail::device_single_thread(
    [offset_at_level  = d_column_offsets.data(),
     end_idx_at_level = d_column_ends.data(),
     col              = *d_col] __device__() {
      auto curr_col           = col;
      size_type off           = curr_col.offset();
      size_type end           = off + curr_col.size();
      size_type level         = 0;
      offset_at_level[level]  = off;
      end_idx_at_level[level] = end;
      ++level;
      // Apply offset recursively until we get to leaf data
      // Skip doing the following for any structs we encounter in between.
      while (curr_col.type().id() == type_id::LIST or curr_col.type().id() == type_id::STRUCT) {
        if (curr_col.type().id() == type_id::LIST) {
          off = curr_col.child(lists_column_view::offsets_column_index).element<size_type>(off);
          end = curr_col.child(lists_column_view::offsets_column_index).element<size_type>(end);
          offset_at_level[level]  = off;
          end_idx_at_level[level] = end;
          ++level;
          curr_col = curr_col.child(lists_column_view::child_column_index);
        } else {
          curr_col = curr_col.child(0);
        }
      }
    },
    stream);

  thrust::host_vector<size_type> column_offsets =
    cudf::detail::make_host_vector_async(d_column_offsets, stream);
  thrust::host_vector<size_type> column_ends =
    cudf::detail::make_host_vector_async(d_column_ends, stream);
  stream.synchronize();

  size_t max_vals_size = 0;
  for (size_t l = 0; l < column_offsets.size(); ++l) {
    max_vals_size += column_ends[l] - column_offsets[l];
  }

  rmm::device_uvector<uint8_t> rep_level(max_vals_size, stream);
  rmm::device_uvector<uint8_t> def_level(max_vals_size, stream);

  rmm::device_uvector<uint8_t> temp_rep_vals(max_vals_size, stream);
  rmm::device_uvector<uint8_t> temp_def_vals(max_vals_size, stream);
  rmm::device_uvector<size_type> new_offsets(0, stream);
  size_type curr_rep_values_size = 0;
  {
    // At this point, curr_col contains the leaf column. Max nesting level is
    // nesting_levels.size().

    // We are going to start by merging the last column in nesting_levels (the leaf, which is at the
    // index `nesting_levels.size() - 1`) with the second-to-last (which is at
    // `nesting_levels.size() - 2`).
    size_t level              = nesting_levels.size() - 2;
    curr_col                  = nesting_levels[level];
    auto lcv                  = lists_column_view(get_list_level(curr_col));
    auto offset_size_at_level = column_ends[level] - column_offsets[level] + 1;

    // Get empties at this level
    auto [empties, empties_idx, empties_size] =
      get_empties(nesting_levels[level], column_offsets[level], column_ends[level]);

    // Merge empty at deepest parent level with the rep, def level vals at leaf level

    auto input_parent_rep_it = thrust::make_constant_iterator(level);
    auto input_parent_def_it =
      thrust::make_transform_iterator(empties_idx.begin(),
                                      def_level_fn{d_nesting_levels + level,
                                                   d_nullability.data(),
                                                   start_at_sub_level[level],
                                                   def_at_level[level]});

    // `nesting_levels.size()` == no of list levels + leaf. Max repetition level = no of list levels
    auto input_child_rep_it = thrust::make_constant_iterator(nesting_levels.size() - 1);
    auto input_child_def_it =
      thrust::make_transform_iterator(thrust::make_counting_iterator(column_offsets[level + 1]),
                                      def_level_fn{d_nesting_levels + level + 1,
                                                   d_nullability.data(),
                                                   start_at_sub_level[level + 1],
                                                   def_at_level[level + 1]});

    // Zip the input and output value iterators so that merge operation is done only once
    auto input_parent_zip_it =
      thrust::make_zip_iterator(thrust::make_tuple(input_parent_rep_it, input_parent_def_it));

    auto input_child_zip_it =
      thrust::make_zip_iterator(thrust::make_tuple(input_child_rep_it, input_child_def_it));

    auto output_zip_it =
      thrust::make_zip_iterator(thrust::make_tuple(rep_level.begin(), def_level.begin()));

    auto ends = thrust::merge_by_key(rmm::exec_policy(stream),
                                     empties.begin(),
                                     empties.begin() + empties_size,
                                     thrust::make_counting_iterator(column_offsets[level + 1]),
                                     thrust::make_counting_iterator(column_ends[level + 1]),
                                     input_parent_zip_it,
                                     input_child_zip_it,
                                     thrust::make_discard_iterator(),
                                     output_zip_it);

    curr_rep_values_size = ends.second - output_zip_it;

    // Scan to get distance by which each offset value is shifted due to the insertion of empties
    auto scan_it = cudf::detail::make_counting_transform_iterator(
      column_offsets[level],
      [off = lcv.offsets().data<size_type>(), size = lcv.offsets().size()] __device__(
        auto i) -> int { return (i + 1 < size) && (off[i] == off[i + 1]); });
    rmm::device_uvector<size_type> scan_out(offset_size_at_level, stream);
    thrust::exclusive_scan(
      rmm::exec_policy(stream), scan_it, scan_it + offset_size_at_level, scan_out.begin());

    // Add scan output to existing offsets to get new offsets into merged rep level values
    new_offsets = rmm::device_uvector<size_type>(offset_size_at_level, stream);
    thrust::for_each_n(rmm::exec_policy(stream),
                       thrust::make_counting_iterator(0),
                       offset_size_at_level,
                       [off      = lcv.offsets().data<size_type>() + column_offsets[level],
                        scan_out = scan_out.data(),
                        new_off  = new_offsets.data()] __device__(auto i) {
                         new_off[i] = off[i] - off[0] + scan_out[i];
                       });

    // Set rep level values at level starts to appropriate rep level
    auto scatter_it = thrust::make_constant_iterator(level);
    thrust::scatter(rmm::exec_policy(stream),
                    scatter_it,
                    scatter_it + new_offsets.size() - 1,
                    new_offsets.begin(),
                    rep_level.begin());
  }

  // Having already merged the last two levels, we are now going to merge the result with the
  // third-last level which is at index `nesting_levels.size() - 3`.
  for (int level = nesting_levels.size() - 3; level >= 0; level--) {
    curr_col                  = nesting_levels[level];
    auto lcv                  = lists_column_view(get_list_level(curr_col));
    auto offset_size_at_level = column_ends[level] - column_offsets[level] + 1;

    // Get empties at this level
    auto [empties, empties_idx, empties_size] =
      get_empties(nesting_levels[level], column_offsets[level], column_ends[level]);

    auto offset_transformer = [new_child_offsets = new_offsets.data(),
                               child_start       = column_offsets[level + 1]] __device__(auto x) {
      return new_child_offsets[x - child_start];  // (x - child's offset)
    };

    // We will be reading from old rep_levels and writing again to rep_levels. Swap the current
    // rep values into temp_rep_vals so it can become the input and rep_levels can again be output.
    std::swap(temp_rep_vals, rep_level);
    std::swap(temp_def_vals, def_level);

    // Merge empty at parent level with the rep, def level vals at current level
    auto transformed_empties = thrust::make_transform_iterator(empties.begin(), offset_transformer);

    auto input_parent_rep_it = thrust::make_constant_iterator(level);
    auto input_parent_def_it =
      thrust::make_transform_iterator(empties_idx.begin(),
                                      def_level_fn{d_nesting_levels + level,
                                                   d_nullability.data(),
                                                   start_at_sub_level[level],
                                                   def_at_level[level]});

    // Zip the input and output value iterators so that merge operation is done only once
    auto input_parent_zip_it =
      thrust::make_zip_iterator(thrust::make_tuple(input_parent_rep_it, input_parent_def_it));

    auto input_child_zip_it =
      thrust::make_zip_iterator(thrust::make_tuple(temp_rep_vals.begin(), temp_def_vals.begin()));

    auto output_zip_it =
      thrust::make_zip_iterator(thrust::make_tuple(rep_level.begin(), def_level.begin()));

    auto ends = thrust::merge_by_key(rmm::exec_policy(stream),
                                     transformed_empties,
                                     transformed_empties + empties_size,
                                     thrust::make_counting_iterator(0),
                                     thrust::make_counting_iterator(curr_rep_values_size),
                                     input_parent_zip_it,
                                     input_child_zip_it,
                                     thrust::make_discard_iterator(),
                                     output_zip_it);

    curr_rep_values_size = ends.second - output_zip_it;

    // Scan to get distance by which each offset value is shifted due to the insertion of dremel
    // level value fof an empty list
    auto scan_it = cudf::detail::make_counting_transform_iterator(
      column_offsets[level],
      [off = lcv.offsets().data<size_type>(), size = lcv.offsets().size()] __device__(
        auto i) -> int { return (i + 1 < size) && (off[i] == off[i + 1]); });
    rmm::device_uvector<size_type> scan_out(offset_size_at_level, stream);
    thrust::exclusive_scan(
      rmm::exec_policy(stream), scan_it, scan_it + offset_size_at_level, scan_out.begin());

    // Add scan output to existing offsets to get new offsets into merged rep level values
    rmm::device_uvector<size_type> temp_new_offsets(offset_size_at_level, stream);
    thrust::for_each_n(rmm::exec_policy(stream),
                       thrust::make_counting_iterator(0),
                       offset_size_at_level,
                       [off      = lcv.offsets().data<size_type>() + column_offsets[level],
                        scan_out = scan_out.data(),
                        new_off  = temp_new_offsets.data(),
                        offset_transformer] __device__(auto i) {
                         new_off[i] = offset_transformer(off[i]) + scan_out[i];
                       });
    new_offsets = std::move(temp_new_offsets);

    // Set rep level values at level starts to appropriate rep level
    auto scatter_it = thrust::make_constant_iterator(level);
    thrust::scatter(rmm::exec_policy(stream),
                    scatter_it,
                    scatter_it + new_offsets.size() - 1,
                    new_offsets.begin(),
                    rep_level.begin());
  }

  size_t level_vals_size = new_offsets.back_element(stream);
  rep_level.resize(level_vals_size, stream);
  def_level.resize(level_vals_size, stream);

  stream.synchronize();

  size_type leaf_data_size = column_ends.back() - column_offsets.back();

  return dremel_data{
    std::move(new_offsets), std::move(rep_level), std::move(def_level), leaf_data_size};
}

void InitPageFragments(device_2dspan<PageFragment> frag,
                       device_span<parquet_column_device_view const> col_desc,
                       device_span<partition_info const> partitions,
                       device_span<int const> part_frag_offset,
                       uint32_t fragment_size,
                       rmm::cuda_stream_view stream)
{
  auto num_columns              = frag.size().first;
  auto num_fragments_per_column = frag.size().second;
  dim3 dim_grid(num_columns, num_fragments_per_column);  // 1 threadblock per fragment
  gpuInitPageFragments<512><<<dim_grid, 512, 0, stream.value()>>>(
    frag, col_desc, partitions, part_frag_offset, fragment_size);
}

void InitFragmentStatistics(device_2dspan<statistics_group> groups,
                            device_2dspan<PageFragment const> fragments,
                            device_span<parquet_column_device_view const> col_desc,
                            rmm::cuda_stream_view stream)
{
  int const num_columns              = col_desc.size();
  int const num_fragments_per_column = fragments.size().second;
  auto grid_y = util::div_rounding_up_safe(num_fragments_per_column, 128 / cudf::detail::warp_size);
  dim3 dim_grid(num_columns, grid_y);  // 1 warp per fragment
  gpuInitFragmentStats<<<dim_grid, 128, 0, stream.value()>>>(groups, fragments, col_desc);
}

void InitEncoderPages(device_2dspan<EncColumnChunk> chunks,
                      device_span<gpu::EncPage> pages,
                      device_span<parquet_column_device_view const> col_desc,
                      int32_t num_columns,
                      size_t max_page_size_bytes,
                      size_type max_page_size_rows,
                      statistics_merge_group* page_grstats,
                      statistics_merge_group* chunk_grstats,
                      size_t max_page_comp_data_size,
                      rmm::cuda_stream_view stream)
{
  auto num_rowgroups = chunks.size().first;
  dim3 dim_grid(num_columns, num_rowgroups);  // 1 threadblock per rowgroup
  gpuInitPages<<<dim_grid, 128, 0, stream.value()>>>(chunks,
                                                     pages,
                                                     col_desc,
                                                     page_grstats,
                                                     chunk_grstats,
                                                     max_page_comp_data_size,
                                                     num_columns,
                                                     max_page_size_bytes,
                                                     max_page_size_rows);
}

void EncodePages(device_span<gpu::EncPage> pages,
                 device_span<device_span<uint8_t const>> comp_in,
                 device_span<device_span<uint8_t>> comp_out,
                 device_span<decompress_status> comp_stats,
                 rmm::cuda_stream_view stream)
{
  auto num_pages = pages.size();
  // A page is part of one column. This is launching 1 block per page. 1 block will exclusively
  // deal with one datatype.
  gpuEncodePages<128><<<num_pages, 128, 0, stream.value()>>>(pages, comp_in, comp_out, comp_stats);
}

void DecideCompression(device_span<EncColumnChunk> chunks, rmm::cuda_stream_view stream)
{
  gpuDecideCompression<<<chunks.size(), 128, 0, stream.value()>>>(chunks);
}

void EncodePageHeaders(device_span<EncPage> pages,
                       device_span<decompress_status const> comp_stats,
                       device_span<statistics_chunk const> page_stats,
                       const statistics_chunk* chunk_stats,
                       rmm::cuda_stream_view stream)
{
  // TODO: single thread task. No need for 128 threads/block. Earlier it used to employ rest of the
  // threads to coop load structs
  gpuEncodePageHeaders<<<pages.size(), 128, 0, stream.value()>>>(
    pages, comp_stats, page_stats, chunk_stats);
}

void GatherPages(device_span<EncColumnChunk> chunks,
                 device_span<gpu::EncPage const> pages,
                 rmm::cuda_stream_view stream)
{
  gpuGatherPages<<<chunks.size(), 1024, 0, stream.value()>>>(chunks, pages);
}

}  // namespace gpu
}  // namespace parquet
}  // namespace io
}  // namespace cudf

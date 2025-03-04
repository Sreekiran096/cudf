# Copyright (c) 2020-2022, NVIDIA CORPORATION.

from libcpp.memory cimport unique_ptr
from libcpp.utility cimport move
from libcpp.vector cimport vector

cimport cudf._lib.cpp.search as cpp_search
cimport cudf._lib.cpp.types as libcudf_types
from cudf._lib.column cimport Column
from cudf._lib.cpp.column.column cimport column
from cudf._lib.cpp.column.column_view cimport column_view
from cudf._lib.cpp.table.table_view cimport table_view
from cudf._lib.utils cimport table_view_from_columns


def search_sorted(
    list source, list values, side, ascending=True, na_position="last"
):
    """Find indices where elements should be inserted to maintain order

    Parameters
    ----------
    source : list of columns
        List of columns to search in
    values : List of columns
        List of value columns to search for
    side : str {‘left’, ‘right’} optional
        If ‘left’, the index of the first suitable location is given.
        If ‘right’, return the last such index
    """
    cdef unique_ptr[column] c_result
    cdef vector[libcudf_types.order] c_column_order
    cdef vector[libcudf_types.null_order] c_null_precedence
    cdef libcudf_types.order c_order
    cdef libcudf_types.null_order c_null_order
    cdef table_view c_table_data = table_view_from_columns(source)
    cdef table_view c_values_data = table_view_from_columns(values)

    # Note: We are ignoring index columns here
    c_order = (libcudf_types.order.ASCENDING
               if ascending
               else libcudf_types.order.DESCENDING)
    c_null_order = (
        libcudf_types.null_order.AFTER
        if na_position=="last"
        else libcudf_types.null_order.BEFORE
    )
    c_column_order = vector[libcudf_types.order](len(source), c_order)
    c_null_precedence = vector[libcudf_types.null_order](
        len(source), c_null_order
    )

    if side == 'left':
        with nogil:
            c_result = move(
                cpp_search.lower_bound(
                    c_table_data,
                    c_values_data,
                    c_column_order,
                    c_null_precedence,
                )
            )
    elif side == 'right':
        with nogil:
            c_result = move(
                cpp_search.upper_bound(
                    c_table_data,
                    c_values_data,
                    c_column_order,
                    c_null_precedence,
                )
            )
    return Column.from_unique_ptr(move(c_result))


def contains(Column haystack, Column needles):
    """Check whether column contains multiple values

    Parameters
    ----------
    column : NumericalColumn
        Column to search in
    needles :
        A column of values to search for
    """
    cdef unique_ptr[column] c_result
    cdef column_view c_haystack = haystack.view()
    cdef column_view c_needles = needles.view()

    with nogil:
        c_result = move(
            cpp_search.contains(
                c_haystack,
                c_needles,
            )
        )
    return Column.from_unique_ptr(move(c_result))

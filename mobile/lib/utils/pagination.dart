/// Pagination state manager for infinite scroll lists.
/// Prevents duplicate requests and manages load-more logic efficiently.
class PaginationState<T> {
  final List<T> items;
  final bool hasMore;
  final bool isLoading;
  final bool isError;
  final int page;
  final int pageSize;

  const PaginationState({
    this.items = const [],
    this.hasMore = true,
    this.isLoading = false,
    this.isError = false,
    this.page = 1,
    this.pageSize = 20,
  });

  /// Create new state with updated values.
  PaginationState<T> copyWith({
    List<T>? items,
    bool? hasMore,
    bool? isLoading,
    bool? isError,
    int? page,
    int? pageSize,
  }) =>
      PaginationState(
        items: items ?? this.items,
        hasMore: hasMore ?? this.hasMore,
        isLoading: isLoading ?? this.isLoading,
        isError: isError ?? this.isError,
        page: page ?? this.page,
        pageSize: pageSize ?? this.pageSize,
      );

  /// Append new items to the list.
  PaginationState<T> appendItems(List<T> newItems) => copyWith(
    items: [...items, ...newItems],
    hasMore: newItems.length >= pageSize,
    page: page + 1,
    isLoading: false,
  );

  /// Start loading the next page.
  PaginationState<T> setLoading() => copyWith(isLoading: true, isError: false);

  /// Handle load error.
  PaginationState<T> setError() => copyWith(isLoading: false, isError: true);

  /// Reset pagination state (for refresh).
  PaginationState<T> reset() => PaginationState(pageSize: pageSize);

  /// Check if should load next page (throttles requests).
  bool shouldLoadMore(double scrollOffset, double maxExtent) {
    // Load when user scrolls within 500px of bottom
    final threshold = maxExtent > 500 ? 500 : maxExtent * 0.8;
    return !isLoading && hasMore && (maxExtent - scrollOffset) < threshold;
  }
}

/// Manager for combining pagination with filtering.
class FilteredPaginationState<T> extends PaginationState<T> {
  final String currentFilter;
  final Map<String, PaginationState<T>> filterStates;

  const FilteredPaginationState({
    List<T> items = const [],
    bool hasMore = true,
    bool isLoading = false,
    bool isError = false,
    int page = 1,
    int pageSize = 20,
    this.currentFilter = 'all',
    this.filterStates = const {},
  }) : super(
    items: items,
    hasMore: hasMore,
    isLoading: isLoading,
    isError: isError,
    page: page,
    pageSize: pageSize,
  );

  /// Switch to a different filter and load its cached state or start fresh.
  FilteredPaginationState<T> switchFilter(String filter) {
    final cached = filterStates[filter] ?? PaginationState<T>(pageSize: pageSize);
    return FilteredPaginationState(
      items: cached.items,
      hasMore: cached.hasMore,
      isLoading: cached.isLoading,
      isError: cached.isError,
      page: cached.page,
      pageSize: pageSize,
      currentFilter: filter,
      filterStates: filterStates,
    );
  }

  /// Save current filter state and update map.
  FilteredPaginationState<T> saveFilterState() {
    final updated = Map<String, PaginationState<T>>.from(filterStates);
    updated[currentFilter] = PaginationState(
      items: items,
      hasMore: hasMore,
      isLoading: isLoading,
      isError: isError,
      page: page,
      pageSize: pageSize,
    );
    return FilteredPaginationState(
      items: items,
      hasMore: hasMore,
      isLoading: isLoading,
      isError: isError,
      page: page,
      pageSize: pageSize,
      currentFilter: currentFilter,
      filterStates: updated,
    );
  }

  @override
  FilteredPaginationState<T> copyWith({
    List<T>? items,
    bool? hasMore,
    bool? isLoading,
    bool? isError,
    int? page,
    int? pageSize,
  }) {
    final state = FilteredPaginationState(
      items: items ?? this.items,
      hasMore: hasMore ?? this.hasMore,
      isLoading: isLoading ?? this.isLoading,
      isError: isError ?? this.isError,
      page: page ?? this.page,
      pageSize: pageSize ?? this.pageSize,
      currentFilter: currentFilter,
      filterStates: filterStates,
    );
    return state.saveFilterState();
  }

  @override
  FilteredPaginationState<T> appendItems(List<T> newItems) {
    final updated = copyWith(
      items: [...items, ...newItems],
      hasMore: newItems.length >= pageSize,
      page: page + 1,
      isLoading: false,
    );
    return updated;
  }

  @override
  FilteredPaginationState<T> setLoading() =>
      copyWith(isLoading: true, isError: false);

  @override
  FilteredPaginationState<T> setError() =>
      copyWith(isLoading: false, isError: true);

  @override
  FilteredPaginationState<T> reset() => FilteredPaginationState(
    pageSize: pageSize,
    currentFilter: currentFilter,
    filterStates: filterStates,
  );
}

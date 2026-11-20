/**
 * Generic {@link IDataSource} backed by an in-memory array for ArkUI {@link LazyForEach}.
 *
 * Calling {@link replaceAll} swaps the backing slice and emits {@code onDataReloaded()}
 * so {@link LazyForEach} diffs keys lazily and materializes only visible rows plus
 * {@code cachedCount} neighbors.
 */
export class ArrayDataSource<T> implements IDataSource {
  private items: T[] = [];
  private listeners: DataChangeListener[] = [];

  constructor(initial?: T[]) {
    if (initial && initial.length > 0) {
      this.items = initial.slice();
    }
  }

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): T {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const idx: number = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  /** Replace backing items and emit {@code onDataReloaded()} to re-diff item keys. */
  replaceAll(next: T[]): void {
    this.items = next.slice();
    this.notifyReload();
  }

  /** Emit {@code onDataReloaded()} when external UI state that affects item keys changes. */
  notifyReload(): void {
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded();
    }
  }
}

using System.Collections;

namespace Smack.Core;

/// Fixed-capacity history, oldest first; adding to a full buffer drops the oldest entry.
public sealed class RingBuffer<T>(int capacity) : IReadOnlyList<T>
{
    private readonly T[] _items = new T[capacity];
    private int _start;

    public int Count { get; private set; }

    public T this[int index]
    {
        get
        {
            ArgumentOutOfRangeException.ThrowIfNegative(index);
            ArgumentOutOfRangeException.ThrowIfGreaterThanOrEqual(index, Count);
            return _items[(_start + index) % _items.Length];
        }
    }

    public void Add(T item)
    {
        if (Count < _items.Length)
        {
            _items[(_start + Count++) % _items.Length] = item;
            return;
        }
        _items[_start] = item;
        _start = (_start + 1) % _items.Length;
    }

    public void Clear()
    {
        Array.Clear(_items);
        _start = 0;
        Count = 0;
    }

    public IEnumerator<T> GetEnumerator()
    {
        for (var index = 0; index < Count; index++) yield return this[index];
    }

    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();
}

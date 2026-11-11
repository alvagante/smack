namespace Smack.Core;

/// What one collection of a source costs. The tier is a claim to be backed by a measurement.
public enum CostTier
{
    /// A fixed handful of system calls, whatever the machine runs.
    Light,
    /// Scales with the number of processes or sockets, in one pass and without opening each of them.
    Moderate,
    /// Opens or inspects items one by one. Never runs with the window closed.
    Heavy,
}

public enum DemandKind
{
    /// Counts only while the window is on screen.
    WhileVisible,
    /// Counts with the window closed too: a feature the user switched on.
    Background,
}

public sealed record SourceDescriptor(string Id, CostTier Cost, TimeSpan MinimumInterval);

public sealed record SourceStatus(
    string Id, CostTier Cost, int Demands, TimeSpan? Interval, long Collections, TimeSpan LastDuration);

/// Runs each registered source only while something demands it, at the fastest interval demanded.
/// With no demand there is no armed timer and no wakeup: what Smack costs is the sum of what is on screen
/// and what the user switched on.
public sealed class CollectionEngine : IDisposable
{
    private readonly Lock _gate = new();
    private readonly TimeProvider _time;
    private readonly long _epoch;
    private readonly ITimer _timer;
    private readonly List<Source> _sources = [];
    private bool _visible;
    private bool _powerConstrained;
    private int _batterySlowdown = 1;
    private bool _collecting;
    private bool _disposed;
    private TimeSpan? _armedFor;

    public CollectionEngine(TimeProvider time)
    {
        _time = time;
        _epoch = time.GetTimestamp();
        _timer = time.CreateTimer(_ => Tick(), null, Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
    }

    /// True while no timer is armed and nothing is being collected.
    public bool IsIdle
    {
        get { lock (_gate) return _armedFor is null && !_collecting; }
    }

    /// `collect` runs on a timer thread, never on the caller's, and must not throw: what it cannot read
    /// it reports as Unavailable.
    public Source<T> Register<T>(SourceDescriptor descriptor, Func<T> collect)
    {
        var source = new Source<T>(this, descriptor, collect);
        lock (_gate) _sources.Add(source);
        return source;
    }

    public void SetVisible(bool visible) => Change(() => _visible = visible);

    /// On battery or in energy saver. The host sets it from power notifications instead of the engine polling.
    public void SetPowerConstrained(bool constrained) => Change(() => _powerConstrained = constrained);

    /// Factor that stretches Background intervals while power is constrained.
    public void SetBatterySlowdown(int factor)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(factor, 1);
        Change(() => _batterySlowdown = factor);
    }

    public IReadOnlyList<SourceStatus> Status()
    {
        lock (_gate) return [.. _sources.Select(source => source.Status())];
    }

    public void Dispose()
    {
        lock (_gate) _disposed = true;
        _timer.Dispose();
    }

    private TimeSpan Now => _time.GetElapsedTime(_epoch);

    private void Change(Action change)
    {
        lock (_gate)
        {
            change();
            Reschedule();
        }
    }

    /// A source that starts being demanded, and `immediate`, are due now; a changed interval applies from now.
    private void Reschedule(Source? immediate = null)
    {
        var now = Now;
        foreach (var source in _sources)
        {
            var interval = source.DemandedInterval();
            if (interval is null) source.Due = null;
            else if (source.Due is null || source == immediate) source.Due = now;
            else if (interval != source.Interval) source.Due = NextSlot(now, interval.Value);
            source.Interval = interval;
        }
        Arm(now);
    }

    private void Arm(TimeSpan now)
    {
        if (_collecting || _disposed) return;
        TimeSpan? next = null;
        foreach (var source in _sources)
        {
            if (source.Due is { } due && (next is null || due < next)) next = due;
        }
        if (next == _armedFor) return;
        _armedFor = next;
        _timer.Change(next is { } at ? Max(at - now, TimeSpan.Zero) : Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
    }

    private void Tick()
    {
        List<Source> due;
        lock (_gate)
        {
            if (_disposed || _collecting) return;
            _armedFor = null;
            var now = Now;
            due = _sources.FindAll(source => source.Due <= now);
            if (due.Count == 0)
            {
                Arm(now);
                return;
            }
            _collecting = true;
        }

        foreach (var source in due) source.Collect();

        lock (_gate)
        {
            _collecting = false;
            var now = Now;
            foreach (var source in due)
            {
                if (source.Interval is { } interval) source.Due = NextSlot(now, interval);
            }
            Arm(now);
        }
    }

    /// Slots are multiples of the interval on the engine clock, so sources demanded at different moments
    /// share wakeups, and a collection that overruns its interval skips slots instead of running back to back.
    private static TimeSpan NextSlot(TimeSpan now, TimeSpan interval) =>
        new((now.Ticks / interval.Ticks + 1) * interval.Ticks);

    private static TimeSpan Max(TimeSpan a, TimeSpan b) => a > b ? a : b;

    public abstract class Source
    {
        private protected Source(SourceDescriptor descriptor) => Descriptor = descriptor;

        public SourceDescriptor Descriptor { get; }

        internal TimeSpan? Interval { get; set; }

        internal TimeSpan? Due { get; set; }

        internal abstract TimeSpan? DemandedInterval();

        internal abstract void Collect();

        internal abstract SourceStatus Status();
    }

    public sealed class Source<T> : Source
    {
        private readonly CollectionEngine _engine;
        private readonly Func<T> _collect;
        private readonly List<Lease> _leases = [];
        private long _collections;
        private TimeSpan _lastDuration;

        internal Source(CollectionEngine engine, SourceDescriptor descriptor, Func<T> collect) : base(descriptor)
        {
            _engine = engine;
            _collect = collect;
        }

        /// Asks for samples until the result is disposed. Every demand on a source shares one collection,
        /// run at the fastest interval demanded, and each receives every sample. `onSample` runs on a timer thread.
        public IDisposable Demand(TimeSpan interval, DemandKind kind, Action<T> onSample)
        {
            ArgumentOutOfRangeException.ThrowIfLessThanOrEqual(interval, TimeSpan.Zero);
            if (kind == DemandKind.Background && Descriptor.Cost == CostTier.Heavy)
            {
                throw new ArgumentException($"{Descriptor.Id} is too costly to run with the window closed.", nameof(kind));
            }

            var lease = new Lease(this, interval, kind, onSample);
            lock (_engine._gate)
            {
                _leases.Add(lease);
                // A new demand gets its first sample right away instead of waiting for the next slot.
                _engine.Reschedule(immediate: IsActive(lease) ? this : null);
            }
            return lease;
        }

        internal override TimeSpan? DemandedInterval()
        {
            TimeSpan? fastest = null;
            foreach (var lease in _leases)
            {
                if (!IsActive(lease)) continue;
                var interval = lease.Kind == DemandKind.Background && _engine._powerConstrained
                    ? lease.Interval * _engine._batterySlowdown
                    : lease.Interval;
                if (fastest is null || interval < fastest) fastest = interval;
            }
            return fastest is { } value ? Max(value, Descriptor.MinimumInterval) : null;
        }

        internal override void Collect()
        {
            var started = _engine._time.GetTimestamp();
            var sample = _collect();
            Lease[] receivers;
            lock (_engine._gate)
            {
                _collections++;
                _lastDuration = _engine._time.GetElapsedTime(started);
                receivers = [.. _leases.Where(IsActive)];
            }
            foreach (var lease in receivers) lease.OnSample(sample);
        }

        internal override SourceStatus Status() =>
            new(Descriptor.Id, Descriptor.Cost, _leases.Count(IsActive), Interval, _collections, _lastDuration);

        private bool IsActive(Lease lease) => lease.Kind == DemandKind.Background || _engine._visible;

        private sealed class Lease(Source<T> source, TimeSpan interval, DemandKind kind, Action<T> onSample) : IDisposable
        {
            public TimeSpan Interval => interval;

            public DemandKind Kind => kind;

            public Action<T> OnSample => onSample;

            public void Dispose()
            {
                lock (source._engine._gate)
                {
                    if (source._leases.Remove(this)) source._engine.Reschedule();
                }
            }
        }
    }
}

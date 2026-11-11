namespace Smack.Core.Tests;

/// A clock that moves only when a test moves it, and fires timers on the calling thread.
internal sealed class ManualTimeProvider : TimeProvider
{
    private readonly List<ManualTimer> _timers = [];
    private long _ticks;

    public override long TimestampFrequency => TimeSpan.TicksPerSecond;

    public int ArmedTimers => _timers.Count(timer => timer.Due is not null);

    /// How many times a timer woke the process.
    public int Wakeups { get; private set; }

    public override long GetTimestamp() => _ticks;

    public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
    {
        var timer = new ManualTimer(this, callback, state);
        _timers.Add(timer);
        timer.Change(dueTime, period);
        return timer;
    }

    public void Advance(TimeSpan by)
    {
        var target = _ticks + by.Ticks;
        while (_timers.Where(timer => timer.Due <= target).MinBy(timer => timer.Due) is { } next)
        {
            _ticks = Math.Max(_ticks, next.Due!.Value);
            Wakeups++;
            next.Fire();
        }
        _ticks = Math.Max(_ticks, target);
    }

    public void AdvanceSeconds(double seconds) => Advance(TimeSpan.FromSeconds(seconds));

    /// Moves the clock without firing timers: time spent inside a collection.
    public void Spend(TimeSpan duration) => _ticks += duration.Ticks;

    private sealed class ManualTimer(ManualTimeProvider owner, TimerCallback callback, object? state) : ITimer
    {
        public long? Due { get; private set; }

        public bool Change(TimeSpan dueTime, TimeSpan period)
        {
            if (period != Timeout.InfiniteTimeSpan) throw new NotSupportedException("One-shot timers only.");
            Due = dueTime == Timeout.InfiniteTimeSpan ? null : owner._ticks + dueTime.Ticks;
            return true;
        }

        public void Fire()
        {
            Due = null;
            callback(state);
        }

        public void Dispose() => owner._timers.Remove(this);

        public ValueTask DisposeAsync()
        {
            Dispose();
            return ValueTask.CompletedTask;
        }
    }
}

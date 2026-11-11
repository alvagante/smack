namespace Smack.Core;

public enum UnavailableReason
{
    /// Not collected yet; a rate needs two samples.
    NotSampled,
    AccessDenied,
    NotSupported,
    ProcessExited,
    /// The underlying counter went backwards, so the interval cannot be measured.
    CounterReset,
}

/// A measurement that is a value, Unavailable, or Off (its feature is switched off).
/// The default is Unavailable, so a field nobody filled never reads as zero.
public readonly record struct Metric<T> where T : struct
{
    private enum State : byte { Unavailable, Value, Off }

    private readonly State _state;
    private readonly T _value;
    private readonly UnavailableReason _reason;

    private Metric(State state, T value, UnavailableReason reason)
    {
        _state = state;
        _value = value;
        _reason = reason;
    }

    public bool IsOff => _state == State.Off;

    /// Why there is no value; null when there is one or the feature is off.
    public UnavailableReason? Reason => _state == State.Unavailable ? _reason : null;

    public bool TryGetValue(out T value)
    {
        value = _value;
        return _state == State.Value;
    }

    public static implicit operator Metric<T>(T value) => new(State.Value, value, default);

    internal static Metric<T> Unavailable(UnavailableReason reason) => new(State.Unavailable, default, reason);

    internal static Metric<T> Off => new(State.Off, default, default);
}

public static class Metric
{
    public static Metric<T> Of<T>(T value) where T : struct => value;

    public static Metric<T> Unavailable<T>(UnavailableReason reason) where T : struct => Metric<T>.Unavailable(reason);

    public static Metric<T> Off<T>() where T : struct => Metric<T>.Off;

    /// Per-second rate between two readings of a cumulative counter.
    public static Metric<double> Rate(ulong current, ulong previous, TimeSpan elapsed)
    {
        if (elapsed <= TimeSpan.Zero) return Unavailable<double>(UnavailableReason.NotSampled);
        if (current < previous) return Unavailable<double>(UnavailableReason.CounterReset);
        return (current - previous) / elapsed.TotalSeconds;
    }
}

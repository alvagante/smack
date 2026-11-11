namespace Smack.Core.Tests;

public sealed class CoreTypesTests
{
    [Fact]
    public void AnUnsetMetricIsUnavailableNotZero()
    {
        Metric<double> metric = default;

        Assert.False(metric.TryGetValue(out _));
        Assert.Equal(UnavailableReason.NotSampled, metric.Reason);
        Assert.NotEqual(Metric.Of(0.0), metric);
    }

    [Fact]
    public void OffIsNeitherAValueNorUnavailable()
    {
        var metric = Metric.Off<long>();

        Assert.True(metric.IsOff);
        Assert.False(metric.TryGetValue(out _));
        Assert.Null(metric.Reason);
    }

    [Fact]
    public void RateIsUnavailableWhenTheCounterWentBackwardsOrNoTimePassed()
    {
        Assert.Equal(Metric.Of(50.0), Metric.Rate(300, 200, TimeSpan.FromSeconds(2)));
        Assert.Equal(Metric.Of(0.0), Metric.Rate(200, 200, TimeSpan.FromSeconds(2)));
        Assert.Equal(UnavailableReason.CounterReset, Metric.Rate(100, 200, TimeSpan.FromSeconds(2)).Reason);
        Assert.Equal(UnavailableReason.NotSampled, Metric.Rate(300, 200, TimeSpan.Zero).Reason);
    }

    [Fact]
    public void RingBufferKeepsTheNewestEntriesOldestFirst()
    {
        var history = new RingBuffer<int>(3);
        for (var value = 1; value <= 5; value++) history.Add(value);

        Assert.Equal([3, 4, 5], history);
        Assert.Equal(3, history[0]);

        history.Clear();
        history.Add(9);
        Assert.Equal([9], history);
    }
}

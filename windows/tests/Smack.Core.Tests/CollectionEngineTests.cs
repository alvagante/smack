namespace Smack.Core.Tests;

public sealed class CollectionEngineTests : IDisposable
{
    private static readonly TimeSpan OneSecond = TimeSpan.FromSeconds(1);

    private readonly ManualTimeProvider _time = new();
    private readonly CollectionEngine _engine;

    public CollectionEngineTests() => _engine = new CollectionEngine(_time);

    public void Dispose() => _engine.Dispose();

    private CollectionEngine.Source<int> Counter(string id, CostTier cost = CostTier.Light, double minimumSeconds = 0.5)
    {
        var count = 0;
        return _engine.Register(new SourceDescriptor(id, cost, TimeSpan.FromSeconds(minimumSeconds)), () => ++count);
    }

    private long Collections(string id) => _engine.Status().Single(status => status.Id == id).Collections;

    [Fact]
    public void WithoutDemandNothingIsArmedOrCollected()
    {
        Counter("cpu");
        Counter("processes", CostTier.Moderate);

        _time.Advance(TimeSpan.FromHours(1));

        Assert.True(_engine.IsIdle);
        Assert.Equal(0, _time.ArmedTimers);
        Assert.Equal(0, _time.Wakeups);
        Assert.All(_engine.Status(), status => Assert.Equal(0, status.Collections));
    }

    [Fact]
    public void WhileVisibleDemandCollectsOnlyWhileTheWindowIsOnScreen()
    {
        var samples = new List<int>();
        using var demand = Counter("cpu").Demand(OneSecond, DemandKind.WhileVisible, samples.Add);

        _time.AdvanceSeconds(10);
        Assert.Empty(samples);
        Assert.Equal(0, _time.Wakeups);

        _engine.SetVisible(true);
        _time.AdvanceSeconds(0);
        Assert.Equal([1], samples);

        _time.AdvanceSeconds(3);
        Assert.Equal([1, 2, 3, 4], samples);

        _engine.SetVisible(false);
        var wakeups = _time.Wakeups;
        _time.Advance(TimeSpan.FromHours(1));
        Assert.Equal(4, samples.Count);
        Assert.Equal(wakeups, _time.Wakeups);
        Assert.True(_engine.IsIdle);
    }

    [Fact]
    public void DemandsOnOneSourceShareOneCollectionAtTheFastestInterval()
    {
        _engine.SetVisible(true);
        var source = Counter("processes", CostTier.Moderate);
        var list = new List<int>();
        var chart = new List<int>();
        var fast = source.Demand(OneSecond, DemandKind.WhileVisible, list.Add);
        using var slow = source.Demand(TimeSpan.FromSeconds(5), DemandKind.WhileVisible, chart.Add);

        _time.AdvanceSeconds(10);
        Assert.Equal(11, Collections("processes"));
        Assert.Equal(list, chart);

        fast.Dispose();
        _time.AdvanceSeconds(10);
        Assert.Equal(13, Collections("processes"));
        Assert.Equal(11, list.Count);
        Assert.Equal(13, chart.Count);
    }

    [Fact]
    public void DisposingTheLastDemandStopsTheSource()
    {
        _engine.SetVisible(true);
        var demand = Counter("ports", CostTier.Moderate).Demand(OneSecond, DemandKind.WhileVisible, _ => { });
        _time.AdvanceSeconds(2);

        demand.Dispose();
        _time.Advance(TimeSpan.FromHours(1));

        Assert.Equal(3, Collections("ports"));
        Assert.True(_engine.IsIdle);
    }

    [Fact]
    public void SourcesDemandedAtDifferentMomentsShareWakeups()
    {
        _engine.SetVisible(true);
        using var cpu = Counter("cpu").Demand(OneSecond, DemandKind.WhileVisible, _ => { });
        _time.AdvanceSeconds(0.4);
        using var memory = Counter("memory").Demand(OneSecond, DemandKind.WhileVisible, _ => { });

        _time.AdvanceSeconds(9.6);

        Assert.Equal(11, Collections("cpu"));
        Assert.Equal(11, Collections("memory"));
        // Two first samples, then one wakeup per second for both.
        Assert.Equal(12, _time.Wakeups);
    }

    [Fact]
    public void BackgroundDemandRunsWithTheWindowClosedAndSlowsDownOnBattery()
    {
        using var demand = Counter("cpu").Demand(TimeSpan.FromSeconds(10), DemandKind.Background, _ => { });

        _time.AdvanceSeconds(60);
        Assert.Equal(7, Collections("cpu"));

        _engine.SetBatterySlowdown(3);
        _engine.SetPowerConstrained(true);
        _time.AdvanceSeconds(60);
        Assert.Equal(9, Collections("cpu"));

        _engine.SetPowerConstrained(false);
        _time.AdvanceSeconds(60);
        Assert.Equal(15, Collections("cpu"));
    }

    [Fact]
    public void HeavySourcesRefuseBackgroundDemand()
    {
        var details = Counter("process-details", CostTier.Heavy);

        Assert.Throws<ArgumentException>(() => details.Demand(OneSecond, DemandKind.Background, _ => { }));
        Assert.True(_engine.IsIdle);
    }

    [Fact]
    public void MinimumIntervalBoundsWhatADemandCanAsk()
    {
        _engine.SetVisible(true);
        using var demand = Counter("ports", CostTier.Moderate, minimumSeconds: 5)
            .Demand(TimeSpan.FromMilliseconds(100), DemandKind.WhileVisible, _ => { });

        _time.AdvanceSeconds(10);

        Assert.Equal(3, Collections("ports"));
    }

    [Fact]
    public void ACollectionThatOverrunsSkipsSlotsInsteadOfRunningBackToBack()
    {
        _engine.SetVisible(true);
        var starts = new List<double>();
        var slow = _engine.Register(new SourceDescriptor("slow", CostTier.Moderate, OneSecond), () =>
        {
            starts.Add(_time.GetElapsedTime(0).TotalSeconds);
            _time.Spend(TimeSpan.FromSeconds(2.5));
            return 0;
        });
        using var demand = slow.Demand(OneSecond, DemandKind.WhileVisible, _ => { });

        _time.AdvanceSeconds(9);

        Assert.Equal([0, 3, 6, 9], starts);
    }

    [Fact]
    public void StatusReportsWhatEachSourceCosts()
    {
        _engine.SetVisible(true);
        var source = _engine.Register(new SourceDescriptor("processes", CostTier.Moderate, OneSecond), () =>
        {
            _time.Spend(TimeSpan.FromMilliseconds(4));
            return 0;
        });
        Counter("ports", CostTier.Moderate);
        using var demand = source.Demand(TimeSpan.FromSeconds(2), DemandKind.WhileVisible, _ => { });
        _time.AdvanceSeconds(0);

        Assert.Equal(
            [
                new SourceStatus("processes", CostTier.Moderate, 1, TimeSpan.FromSeconds(2), 1, TimeSpan.FromMilliseconds(4)),
                new SourceStatus("ports", CostTier.Moderate, 0, null, 0, TimeSpan.Zero),
            ],
            _engine.Status());
    }

    [Fact]
    public void ADemandCanBeDisposedFromItsOwnCallback()
    {
        _engine.SetVisible(true);
        IDisposable? demand = null;
        demand = Counter("once").Demand(OneSecond, DemandKind.WhileVisible, _ => demand!.Dispose());

        _time.AdvanceSeconds(10);

        Assert.Equal(1, Collections("once"));
        Assert.True(_engine.IsIdle);
    }
}

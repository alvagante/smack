namespace Smack.Core.Tests;

public sealed class ConfirmedProcessActionTests
{
    private static readonly ProcessIdentity Confirmed = new(4242, StartTime: 1000);

    [Fact]
    public void ActsOnTheConfirmedProcessOnly()
    {
        var access = new FakeAccess { Running = { [4242] = Confirmed, [4243] = new(4243, 1000) } };

        var outcome = ConfirmedProcessAction.Execute(ProcessAction.ForceKill, Confirmed, access);

        Assert.Equal(ActionOutcome.Done, outcome);
        Assert.Equal([4242], access.Opened);
        Assert.Equal([(Confirmed, ProcessAction.ForceKill)], access.Applied);
        Assert.Equal(0, access.OpenHandles);
    }

    [Fact]
    public void AReusedPidIsLeftAlone()
    {
        var access = new FakeAccess { Running = { [4242] = Confirmed with { StartTime = 2000 } } };

        var outcome = ConfirmedProcessAction.Execute(ProcessAction.Terminate, Confirmed, access);

        Assert.Equal(ActionOutcome.IdentityChanged, outcome);
        Assert.Empty(access.Applied);
        Assert.Equal(0, access.OpenHandles);
    }

    [Theory]
    [InlineData(ActionOutcome.ProcessExited)]
    [InlineData(ActionOutcome.AccessDenied)]
    public void AProcessThatCannotBeOpenedReportsWhy(ActionOutcome failure)
    {
        var access = new FakeAccess { OpenFailure = failure };

        Assert.Equal(failure, ConfirmedProcessAction.Execute(ProcessAction.ForceKill, Confirmed, access));
        Assert.Empty(access.Applied);
    }

    [Fact]
    public void AProcessThatCannotBeAskedToCloseIsNotKilledInstead()
    {
        var access = new FakeAccess { Running = { [4242] = Confirmed }, ApplyOutcome = ActionOutcome.NotSupported };

        var outcome = ConfirmedProcessAction.Execute(ProcessAction.Terminate, Confirmed, access);

        Assert.Equal(ActionOutcome.NotSupported, outcome);
        Assert.Equal([(Confirmed, ProcessAction.Terminate)], access.Applied);
    }

    private sealed class FakeAccess : IProcessAccess
    {
        public Dictionary<int, ProcessIdentity> Running { get; } = [];
        public ActionOutcome OpenFailure { get; init; } = ActionOutcome.ProcessExited;
        public ActionOutcome ApplyOutcome { get; init; } = ActionOutcome.Done;
        public List<int> Opened { get; } = [];
        public List<(ProcessIdentity, ProcessAction)> Applied { get; } = [];
        public int OpenHandles { get; private set; }

        public (IOpenProcess?, ActionOutcome) Open(int pid)
        {
            Opened.Add(pid);
            if (!Running.TryGetValue(pid, out var identity)) return (null, OpenFailure);
            OpenHandles++;
            return (new Handle(this, identity), ActionOutcome.Done);
        }

        private sealed class Handle(FakeAccess owner, ProcessIdentity identity) : IOpenProcess
        {
            public ProcessIdentity Identity => identity;

            public ActionOutcome Apply(ProcessAction action)
            {
                owner.Applied.Add((identity, action));
                return owner.ApplyOutcome;
            }

            public void Dispose() => owner.OpenHandles--;
        }
    }
}

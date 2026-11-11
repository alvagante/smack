namespace Smack.Core;

/// A PID alone is reused by Windows; the creation time (FILETIME ticks) pins one process instance.
public readonly record struct ProcessIdentity(int Pid, long StartTime);

public enum ProcessAction
{
    /// Ask the process to close, so it can save.
    Terminate,
    /// End it immediately.
    ForceKill,
}

public enum ActionOutcome
{
    Done,
    ProcessExited,
    /// The PID now belongs to another process than the one the user confirmed.
    IdentityChanged,
    AccessDenied,
    /// The process has no way to be asked to close; only Force Kill applies.
    NotSupported,
}

public interface IProcessAccess
{
    /// Opens the process and keeps it open: the PID cannot be reused until the result is disposed.
    /// Returns the failure when it cannot be opened.
    (IOpenProcess? Process, ActionOutcome Failure) Open(int pid);
}

public interface IOpenProcess : IDisposable
{
    ProcessIdentity Identity { get; }

    ActionOutcome Apply(ProcessAction action);
}

public static class ConfirmedProcessAction
{
    /// Acts on the process the user confirmed and on nothing else: identity is checked on the same open
    /// process the action is applied to, so no reuse can slip between the check and the action.
    public static ActionOutcome Execute(ProcessAction action, ProcessIdentity confirmed, IProcessAccess access)
    {
        var (process, failure) = access.Open(confirmed.Pid);
        if (process is null) return failure;
        using (process)
        {
            return process.Identity == confirmed ? process.Apply(action) : ActionOutcome.IdentityChanged;
        }
    }
}

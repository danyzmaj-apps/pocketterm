using System.ComponentModel;
using System.Runtime.CompilerServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PocketTerm.Core;

namespace PocketTerm.App.Views;

/// <summary>
/// A screen, or a part of one, built once in code. What the Flutter widgets rebuilt is here an update
/// registered with <see cref="Bind{T}"/> or <see cref="OnRefresh"/>: <see cref="Refresh"/> runs them all,
/// on the UI thread, whenever a <see cref="Watch"/>ed source changes (the services raise their changes on
/// any thread; several in a row make one refresh). The controls themselves stay, so a field keeps its text,
/// focus and caret while the state around it changes.
/// </summary>
internal abstract class View : UserControl
{
    private readonly DispatcherQueue _dispatcher;
    private readonly List<Action> _updates = [];
    private readonly List<INotifyPropertyChanged> _sources = [];
    private readonly List<(TimeSpan Every, Func<Task> Tick, DispatcherQueueTimer? Timer)> _polls = [];
    private int _queued;

    protected View()
    {
        _dispatcher = DispatcherQueue.GetForCurrentThread();
        IsTabStop = false;
        Loaded += (_, _) => Attach();
        Unloaded += (_, _) => Detach();
    }

    /// <summary>On screen (Flutter's <c>mounted</c>): after an await, a view that left does nothing more.</summary>
    public bool Live { get; private set; }

    protected DispatcherQueue UiQueue => _dispatcher;

    /// <summary>Refreshes on every change of <paramref name="source"/> while on screen.</summary>
    protected void Watch(INotifyPropertyChanged? source)
    {
        if (source == null || _sources.Contains(source)) return;
        _sources.Add(source);
        if (Live) source.PropertyChanged += Changed;
    }

    protected void Unwatch(INotifyPropertyChanged? source)
    {
        if (source == null || !_sources.Remove(source)) return;
        source.PropertyChanged -= Changed;
    }

    /// <summary>Watches whatever <paramref name="current"/> gives, looked at on each refresh: a source that comes
    /// and goes (the built-in server, say).</summary>
    protected void Follow(Func<INotifyPropertyChanged?> current)
    {
        INotifyPropertyChanged? followed = null;
        OnRefresh(() =>
        {
            var now = current();
            if (ReferenceEquals(now, followed)) return;
            Unwatch(followed);
            followed = now;
            Watch(now);
        });
    }

    /// <summary>Runs <paramref name="update"/> on <paramref name="element"/> now and at each refresh.</summary>
    protected T Bind<T>(T element, Action<T> update)
    {
        _updates.Add(() => update(element));
        update(element);
        return element;
    }

    /// <summary>Runs <paramref name="update"/> now and at each refresh.</summary>
    protected void OnRefresh(Action update)
    {
        _updates.Add(update);
        update();
    }

    /// <summary>Runs <paramref name="tick"/> when the view shows and every <paramref name="every"/> while it does
    /// (the Flutter pages' polls). A tick still running when the next is due makes it skip.</summary>
    protected void Every(TimeSpan every, Func<Task> tick)
    {
        _polls.Add((every, tick, null));
        if (Live) StartPoll(_polls.Count - 1);
    }

    /// <summary>Brings every bound property up to date now.</summary>
    public void Refresh()
    {
        foreach (var update in _updates.ToArray())
        {
            try
            {
                update();
            }
            catch (Exception e)
            {
                Log.Print($"PocketTerm: {GetType().Name}: {e}");
            }
        }
    }

    /// <summary>A refresh soon, on the UI thread, from any thread.</summary>
    protected void Schedule()
    {
        if (Interlocked.Exchange(ref _queued, 1) == 1) return;
        if (!_dispatcher.TryEnqueue(() =>
        {
            Interlocked.Exchange(ref _queued, 0);
            if (Live) Refresh();
        }))
        {
            Interlocked.Exchange(ref _queued, 0);
        }
    }

    /// <summary>Runs <paramref name="work"/> (a button's action) on the UI thread: what it throws is logged, and the
    /// view refreshes when it ends, as a Flutter <c>setState</c> after it would.</summary>
    protected void Run(Func<Task> work, [CallerMemberName] string? caller = null) => _ = RunAsync(work, caller);

    private async Task RunAsync(Func<Task> work, string? caller)
    {
        try
        {
            await work();
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: {GetType().Name}.{caller}: {e.Message}");
        }
        finally
        {
            if (Live) Refresh();
        }
    }

    /// <summary>Runs <paramref name="action"/> on the UI thread (from a service's callback).</summary>
    protected void OnUi(Action action)
    {
        if (_dispatcher.HasThreadAccess) action();
        else _dispatcher.TryEnqueue(() => action());
    }

    private void Changed(object? sender, PropertyChangedEventArgs e) => Schedule();

    private void Attach()
    {
        if (Live) return;
        Live = true;
        foreach (var s in _sources) s.PropertyChanged += Changed;
        Refresh();
        for (var i = 0; i < _polls.Count; i++) StartPoll(i);
        OnShown();
    }

    private void Detach()
    {
        if (!Live) return;
        Live = false;
        foreach (var s in _sources) s.PropertyChanged -= Changed;
        for (var i = 0; i < _polls.Count; i++)
        {
            _polls[i].Timer?.Stop();
            _polls[i] = (_polls[i].Every, _polls[i].Tick, null);
        }
        OnHidden();
    }

    /// <summary>The view came on screen (again).</summary>
    protected virtual void OnShown()
    {
    }

    /// <summary>The view left the screen.</summary>
    protected virtual void OnHidden()
    {
    }

    private void StartPoll(int i)
    {
        var (every, tick, _) = _polls[i];
        var busy = false;
        async void Tick()
        {
            if (busy || !Live) return;
            busy = true;
            try
            {
                await tick();
            }
            catch (Exception e)
            {
                Log.Print($"PocketTerm: {GetType().Name} poll: {e.Message}");
            }
            finally
            {
                busy = false;
            }
            if (Live) Refresh();
        }
        var timer = _dispatcher.CreateTimer();
        timer.Interval = every;
        timer.IsRepeating = true;
        timer.Tick += (_, _) => Tick();
        timer.Start();
        _polls[i] = (every, tick, timer);
        Tick();
    }
}

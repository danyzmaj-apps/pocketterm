using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace PocketTerm.Core;

/// <summary>
/// What Flutter's <c>ChangeNotifier</c> was: state the UI binds to. Raises
/// <see cref="PropertyChanged"/> on whatever thread changed it; the app marshals to its UI
/// thread (core doesn't know it). <see cref="NotifyChanged"/> is <c>notifyListeners()</c>:
/// an empty property name, which WinUI reads as "every property may have changed".
/// </summary>
public abstract class ObservableObject : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Everything may have changed (Dart's <c>notifyListeners()</c>).</summary>
    protected void NotifyChanged() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));

    /// <summary>One property changed.</summary>
    protected void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    /// <summary>Sets <paramref name="field"/> and says so when it changed.</summary>
    protected bool SetField<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        OnPropertyChanged(name);
        return true;
    }
}
